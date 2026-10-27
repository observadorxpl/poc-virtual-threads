#!/usr/bin/env bash
# Runs the k6 MCP load test against each app separately (only one app up at a time)
# and writes a comparative markdown summary to results/comparison-<protocol>-<timestamp>.md
# plus per-app details in results/<app>-<protocol>.{k6.json,summary.json,row.md}.
#
# Env vars (all optional):
#   BACKEND_DELAY_MS  WireMock delay for /accounts/{id}/balance (default 500)
#   MAX_VUS, START_VUS, RAMP_UP, HOLD, RAMP_DOWN, REQ_TIMEOUT  -> forwarded to k6
#   TOOL_LOG_LEVEL    log level for the tool logger (default INFO; WARN to silence per-call logs)
#   MCP_PROTOCOL      STATELESS (default) | STREAMABLE
#   APPS              apps to test (default "mcp-webflux-block mcp-mvc-vt")
set -euo pipefail

cd "$(dirname "$0")/.."

BACKEND_DELAY_MS="${BACKEND_DELAY_MS:-500}"
APPS="${APPS:-mcp-webflux-block mcp-mvc-vt}"
export MCP_PROTOCOL="${MCP_PROTOCOL:-STATELESS}"   # read by docker-compose
START_VUS="${START_VUS:-10}"
MAX_VUS="${MAX_VUS:-500}"
RAMP_UP="${RAMP_UP:-2m}"
HOLD="${HOLD:-1m}"
RAMP_DOWN="${RAMP_DOWN:-20s}"
REQ_TIMEOUT="${REQ_TIMEOUT:-30s}"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="results/comparison-${MCP_PROTOCOL,,}-${STAMP}.md"

declare -A HOST_PORT=([mcp-webflux-block]=8081 [mcp-mvc-vt]=8082)

mkdir -p results

echo "==> Building images"
docker compose build

echo "==> Starting WireMock (delay ${BACKEND_DELAY_MS} ms)"
docker compose stop $APPS >/dev/null 2>&1 || true
docker compose up -d --wait wiremock
mapping=$(sed -E "s/\"fixedDelayMilliseconds\": *[0-9]+/\"fixedDelayMilliseconds\": ${BACKEND_DELAY_MS}/" \
  wiremock/mappings/account-balance.json)
mapping_id=$(grep -o '"id": *"[^"]*"' <<<"$mapping" | head -1 | sed -E 's/.*"([^"]*)"$/\1/')
curl -sf -X PUT "http://localhost:8089/__admin/mappings/${mapping_id}" \
  -H 'Content-Type: application/json' -d "$mapping" >/dev/null

out_name() { # out_name <app> -> base name of its result files, e.g. mcp-mvc-vt-stateless
  echo "$1-${MCP_PROTOCOL,,}"
}

metric() { # metric <port> <name> -> first measurement value
  curl -sf "http://localhost:$1/actuator/metrics/$2" | grep -o '"value":[0-9.E+-]*' | head -1 | cut -d: -f2
}

declare -A PEAK_THREADS THREAD_SAMPLE
for app in $APPS; do
  port="${HOST_PORT[$app]}"
  echo
  echo "==> [$app] starting fresh container"
  docker compose up -d --wait --force-recreate "$app"

  echo "==> [$app] MCP smoke test"
  # The host port mapping can lag a few seconds behind the in-container healthcheck.
  for attempt in $(seq 1 10); do
    scripts/smoke-test.sh "http://localhost:${port}" && break
    [ "$attempt" -eq 10 ] && { echo "ERROR: $app does not answer MCP, aborting"; exit 1; }
    sleep 3
  done

  echo "==> [$app] load test ${START_VUS} -> ${MAX_VUS} VUs (ramp ${RAMP_UP}, hold ${HOLD})"
  rm -f "results/$(out_name "$app").row.md"
  # MSYS_NO_PATHCONV: stop Git Bash on Windows from rewriting /paths passed to the container
  MSYS_NO_PATHCONV=1 docker compose run --rm \
    -e MCP_URL="http://${app}:8080/mcp" -e LABEL="$app" -e OUT_NAME="$(out_name "$app")" \
    -e START_VUS="$START_VUS" -e MAX_VUS="$MAX_VUS" -e RAMP_UP="$RAMP_UP" \
    -e HOLD="$HOLD" -e RAMP_DOWN="$RAMP_DOWN" -e REQ_TIMEOUT="$REQ_TIMEOUT" \
    k6 run --quiet mcp-load.js || echo "WARN: k6 exited non-zero for $app"

  PEAK_THREADS[$app]="$(metric "$port" jvm.threads.peak || echo n/a)"
  THREAD_SAMPLE[$app]="$(docker compose logs --no-log-prefix "$app" 2>/dev/null \
    | grep -o 'thread=.* virtual=[a-z]*' | tail -1 || true)"

  echo "==> [$app] stopping"
  docker compose stop "$app"
done

{
  echo "# MCP server: WebFlux + block() vs WebMVC + Virtual Threads"
  echo
  echo "- Fecha: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "- Carga: k6 ramping-vus ${START_VUS} → ${MAX_VUS} VUs (ramp ${RAMP_UP}, hold ${HOLD}, ramp-down ${RAMP_DOWN}), sin think time"
  echo "- Flujo por VU: \`initialize\` + \`notifications/initialized\` una vez, luego \`tools/call getBalance\` en bucle"
  echo "- Backend: WireMock \`GET /accounts/{id}/balance\` con delay fijo de ${BACKEND_DELAY_MS} ms"
  echo "- MCP: \`type: SYNC\`, \`protocol: ${MCP_PROTOCOL}\`, \`streamable-http.keep-alive-interval: 30s\`"
  echo "- Límites por app: 2 CPUs, 1 GB RAM; cada app probada sola"
  echo
  echo "## Resultados (\`tools/call\`)"
  echo
  echo "| App | req/s | p50 (ms) | p95 (ms) | p99 (ms) | % errores | % errores handshake | total calls |"
  echo "|---|---:|---:|---:|---:|---:|---:|---:|"
  for app in $APPS; do
    row="results/$(out_name "$app").row.md"
    if [ -f "$row" ]; then cat "$row"; else echo "| $app | sin datos | | | | | | |"; fi
  done
  echo
  echo "## Threads"
  echo
  echo "| App | jvm.threads.peak (platform) | thread de la tool (último log) |"
  echo "|---|---:|---|"
  for app in $APPS; do
    echo "| $app | ${PEAK_THREADS[$app]} | \`${THREAD_SAMPLE[$app]}\` |"
  done
  echo
  echo "Detalle completo de k6 en \`results/<app>-${MCP_PROTOCOL,,}.k6.json\` y \`results/<app>-${MCP_PROTOCOL,,}.summary.json\`."
} > "$REPORT"

echo
echo "==> Report: $REPORT"
cat "$REPORT"
