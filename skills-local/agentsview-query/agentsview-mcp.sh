#!/usr/bin/env bash
# Call one read-only tool on the global AgentsView MCP server.
#
#   agentsview-mcp.sh <tool> '<json-args>'
#
# The endpoint is reachable only through an exe.dev peer integration attached to
# iv-provision. No archive credential is stored on this VM.
set -euo pipefail

HOST=${AGENTSVIEW_MCP_HOST:-https://mcp-agentsview.int.exe.xyz/mcp}
ACCEPT='Accept: application/json, text/event-stream'
CT='Content-Type: application/json'

[[ $# -eq 2 ]] || { echo "usage: agentsview-mcp.sh <tool> '<json-args>'" >&2; exit 2; }
jq -e 'type == "object"' <<<"$2" >/dev/null || {
  echo "agentsview-mcp: arguments must be a JSON object" >&2
  exit 2
}

headers=$(mktemp)
trap 'rm -f "$headers"' EXIT
curl -fsS --max-time 30 -X POST "$HOST" -H "$CT" -H "$ACCEPT" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"iv-agentsview-query","version":"1"}}}' \
  -D "$headers" -o /dev/null
sid=$(tr -d '\r' < "$headers" | awk 'tolower($1)=="mcp-session-id:"{print $2}')
[[ -n $sid ]] || {
  echo "agentsview-mcp: no session id; is mcp-agentsview attached to this VM?" >&2
  exit 1
}

curl -fsS --max-time 30 -X POST "$HOST" -H "Mcp-Session-Id: $sid" \
  -H "$CT" -H "$ACCEPT" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null

curl -fsS --max-time 120 -X POST "$HOST" -H "Mcp-Session-Id: $sid" \
  -H "$CT" -H "$ACCEPT" \
  -d "$(printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":%s,"arguments":%s}}' \
    "$(printf '%s' "$1" | jq -Rs .)" "$2")" \
  | sed -n 's/^data: //p'
