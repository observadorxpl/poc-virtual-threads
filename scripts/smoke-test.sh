#!/usr/bin/env bash
# Verifies that an MCP server answers the full flow:
# initialize -> notifications/initialized -> tools/call getBalance.
# Usage: scripts/smoke-test.sh [base_url ...]   (default: both apps on 8081 and 8082)
set -euo pipefail

PROTOCOL_VERSION="2025-06-18"
urls=("$@")
[ ${#urls[@]} -eq 0 ] && urls=("http://localhost:8081" "http://localhost:8082")

smoke() {
  local base="$1" headers sid body
  headers=$(mktemp)
  trap 'rm -f "$headers"' RETURN

  curl -sf -D "$headers" -o /dev/null "$base/mcp" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"$PROTOCOL_VERSION\",\"capabilities\":{},\"clientInfo\":{\"name\":\"smoke\",\"version\":\"1.0\"}}}" \
    || { echo "FAIL $base: initialize"; return 1; }
  # STREAMABLE returns Mcp-Session-Id; STATELESS returns none.
  sid=$(tr -d '\r' < "$headers" | awk 'tolower($1)=="mcp-session-id:" {print $2}')
  local session_header=()
  [ -n "$sid" ] && session_header=(-H "Mcp-Session-Id: $sid")

  curl -sf -o /dev/null "$base/mcp" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    "${session_header[@]}" -H "MCP-Protocol-Version: $PROTOCOL_VERSION" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    || { echo "FAIL $base: notifications/initialized"; return 1; }

  body=$(curl -sf --max-time 15 "$base/mcp" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    "${session_header[@]}" -H "MCP-Protocol-Version: $PROTOCOL_VERSION" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"getBalance","arguments":{"accountId":"ACC-0001"}}}') \
    || { echo "FAIL $base: tools/call"; return 1; }

  if grep -q '"isError":false' <<<"$body" && grep -q 'ACC-0001' <<<"$body"; then
    echo "OK   $base -> $(grep -o '\\"balance\\":[0-9.]*' <<<"$body" | tr -d '\\"' | head -1) (session ${sid:-none, stateless})"
  else
    echo "FAIL $base: unexpected tools/call response: $body"; return 1
  fi
}

rc=0
for u in "${urls[@]}"; do smoke "$u" || rc=1; done
exit $rc
