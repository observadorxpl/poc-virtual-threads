// k6 load test for an MCP server over Streamable HTTP.
// Each VU performs the MCP handshake once (initialize + notifications/initialized),
// keeps its Mcp-Session-Id and then loops calling tools/call -> getBalance.
//
// Env vars:
//   MCP_URL       MCP endpoint (default http://localhost:8080/mcp)
//   LABEL         name shown in the results row (default "run")
//   OUT_NAME      base name for result files (default LABEL)
//   START_VUS     initial VUs (default 10)
//   MAX_VUS       peak VUs (default 500)
//   RAMP_UP       ramp duration 10 -> MAX_VUS (default 2m)
//   HOLD          time held at MAX_VUS (default 1m)
//   RAMP_DOWN     ramp-down duration (default 20s)
//   REQ_TIMEOUT   per-request timeout (default 30s)
import http from 'k6/http';
import { check } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const MCP_URL = __ENV.MCP_URL || 'http://localhost:8080/mcp';
const LABEL = __ENV.LABEL || 'run';
const OUT_NAME = __ENV.OUT_NAME || LABEL;
const PROTOCOL_VERSION = '2025-06-18';
const REQ_TIMEOUT = __ENV.REQ_TIMEOUT || '30s';

export const options = {
  scenarios: {
    ramp: {
      executor: 'ramping-vus',
      startVUs: parseInt(__ENV.START_VUS || '10'),
      stages: [
        { duration: __ENV.RAMP_UP || '2m', target: parseInt(__ENV.MAX_VUS || '500') },
        { duration: __ENV.HOLD || '1m', target: parseInt(__ENV.MAX_VUS || '500') },
        { duration: __ENV.RAMP_DOWN || '20s', target: 0 },
      ],
      gracefulRampDown: '30s',
    },
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
  discardResponseBodies: false,
};

const toolCallDuration = new Trend('tool_call_duration', true);
const toolCalls = new Counter('tool_calls');
const toolCallErrors = new Rate('tool_call_errors');
const handshakeErrors = new Rate('handshake_errors');

const baseHeaders = {
  'Content-Type': 'application/json',
  Accept: 'application/json, text/event-stream',
};

// VU-scoped state: one MCP session per VU.
let sessionId = null;
let requestId = 0;

// Responses may be plain JSON or an SSE stream ("event:message\ndata:{...}").
function parseJsonRpc(res) {
  if (!res || !res.body) return null;
  const contentType = String(res.headers['Content-Type'] || '');
  try {
    if (contentType.includes('text/event-stream')) {
      const dataLines = res.body
        .split(/\r?\n/)
        .filter((l) => l.startsWith('data:'))
        .map((l) => l.substring(5).trim());
      for (const line of dataLines) {
        const msg = JSON.parse(line);
        if (msg.id !== undefined) return msg;
      }
      return null;
    }
    return JSON.parse(res.body);
  } catch (e) {
    return null;
  }
}

function handshake() {
  const init = http.post(
    MCP_URL,
    JSON.stringify({
      jsonrpc: '2.0',
      id: ++requestId,
      method: 'initialize',
      params: {
        protocolVersion: PROTOCOL_VERSION,
        capabilities: {},
        clientInfo: { name: 'k6-mcp-load', version: '1.0.0' },
      },
    }),
    { headers: baseHeaders, timeout: REQ_TIMEOUT, tags: { mcp: 'initialize' } }
  );
  const initMsg = parseJsonRpc(init);
  // STREAMABLE returns Mcp-Session-Id; STATELESS returns none.
  const sid = init.headers['Mcp-Session-Id'] || '';
  const initOk = check(init, {
    'initialize 200': (r) => r.status === 200,
    'initialize has result': () => !!(initMsg && initMsg.result),
  });
  if (!initOk) {
    handshakeErrors.add(true);
    return null;
  }

  const notified = http.post(
    MCP_URL,
    JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }),
    {
      headers: sessionHeaders(sid),
      timeout: REQ_TIMEOUT,
      tags: { mcp: 'initialized' },
    }
  );
  const notifiedOk = check(notified, {
    'notifications/initialized 2xx': (r) => r.status >= 200 && r.status < 300,
  });
  handshakeErrors.add(!notifiedOk);
  return notifiedOk ? sid : null;
}

function sessionHeaders(sid) {
  const headers = Object.assign({}, baseHeaders, { 'MCP-Protocol-Version': PROTOCOL_VERSION });
  if (sid) headers['Mcp-Session-Id'] = sid;
  return headers;
}

export default function () {
  // null = handshake pending; '' = handshake done on a stateless server (no session id).
  if (sessionId === null) {
    sessionId = handshake();
    if (sessionId === null) return;
  }

  const accountId = `ACC-${String((__VU * 1000 + __ITER) % 10000).padStart(4, '0')}`;
  const res = http.post(
    MCP_URL,
    JSON.stringify({
      jsonrpc: '2.0',
      id: ++requestId,
      method: 'tools/call',
      params: { name: 'getBalance', arguments: { accountId } },
    }),
    {
      headers: sessionHeaders(sessionId),
      timeout: REQ_TIMEOUT,
      tags: { mcp: 'tools/call' },
    }
  );

  const msg = parseJsonRpc(res);
  const ok = check(res, {
    'tools/call 200': (r) => r.status === 200,
    'tools/call result ok': () => !!(msg && msg.result && msg.result.isError === false),
  });

  toolCalls.add(1);
  toolCallErrors.add(!ok);
  toolCallDuration.add(res.timings.duration);

  // Session lost (e.g. 404 from server): force a new handshake on next iteration.
  if (res.status === 404 && sessionId) sessionId = null;
}

function fmt(n, digits = 2) {
  return n === undefined || n === null || Number.isNaN(n) ? 'n/a' : Number(n).toFixed(digits);
}

export function handleSummary(data) {
  const m = data.metrics;
  const v = (name, key) => (m[name] && m[name].values ? m[name].values[key] : undefined);
  const summary = {
    label: LABEL,
    mcpUrl: MCP_URL,
    maxVus: v('vus_max', 'max'),
    durationSec: data.state.testRunDurationMs / 1000,
    toolCalls: v('tool_calls', 'count') || 0,
    toolCallsPerSec: v('tool_calls', 'rate') || 0,
    httpReqsPerSec: v('http_reqs', 'rate') || 0,
    p50Ms: v('tool_call_duration', 'med'),
    p95Ms: v('tool_call_duration', 'p(95)'),
    p99Ms: v('tool_call_duration', 'p(99)'),
    maxMs: v('tool_call_duration', 'max'),
    errorPct: (v('tool_call_errors', 'rate') || 0) * 100,
    handshakeErrorPct: (v('handshake_errors', 'rate') || 0) * 100,
  };

  // One markdown table row; the runner script concatenates rows of every run.
  const row =
    `| ${LABEL} | ${fmt(summary.toolCallsPerSec)} | ${fmt(summary.p50Ms, 0)} | ${fmt(summary.p95Ms, 0)} | ` +
    `${fmt(summary.p99Ms, 0)} | ${fmt(summary.errorPct)} | ${fmt(summary.handshakeErrorPct)} | ` +
    `${summary.toolCalls} |\n`;

  const text =
    `\n[${LABEL}] tool_calls=${summary.toolCalls} rps=${fmt(summary.toolCallsPerSec)} ` +
    `p50=${fmt(summary.p50Ms, 0)}ms p95=${fmt(summary.p95Ms, 0)}ms p99=${fmt(summary.p99Ms, 0)}ms ` +
    `errors=${fmt(summary.errorPct)}% handshake_errors=${fmt(summary.handshakeErrorPct)}%\n`;

  return {
    stdout: text,
    [`/results/${OUT_NAME}.summary.json`]: JSON.stringify(summary, null, 2),
    [`/results/${OUT_NAME}.k6.json`]: JSON.stringify(data, null, 2),
    [`/results/${OUT_NAME}.row.md`]: row,
  };
}
