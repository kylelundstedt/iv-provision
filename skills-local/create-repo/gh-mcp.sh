#!/usr/bin/env bash
# Call one tool on the mcp-github-home MCP server over plain HTTP.
#
#   gh-mcp.sh <tool> '<json-args>'
#
# The credential is injected by exe.dev at the edge; nothing here holds a token.
# Streamable-HTTP MCP needs three round trips (initialize -> initialized ->
# tools/call) and the session id comes back in a *header*, which is the whole
# reason this is a script and not a one-liner.
set -euo pipefail

HOST="${GH_MCP_HOST:-https://mcp-github-home.int.exe.xyz/mcp}"
ACCEPT='Accept: application/json, text/event-stream'
CT='Content-Type: application/json'

[ $# -eq 2 ] || { echo "usage: gh-mcp.sh <tool> '<json-args>'" >&2; exit 2; }

sid=$(curl -sS --max-time 30 -X POST "$HOST" -H "$CT" -H "$ACCEPT" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"iv-create-repo","version":"1"}}}' \
  -D - -o /dev/null | tr -d '\r' | awk 'tolower($1)=="mcp-session-id:"{print $2}')

[ -n "$sid" ] || { echo "gh-mcp: no session id — is mcp-github-home attached to this VM?" >&2; exit 1; }

curl -sS --max-time 30 -X POST "$HOST" -H "Mcp-Session-Id: $sid" -H "$CT" -H "$ACCEPT" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null

# Responses come back as SSE frames; strip the `data: ` prefix and print JSON.
curl -sS --max-time 120 -X POST "$HOST" -H "Mcp-Session-Id: $sid" -H "$CT" -H "$ACCEPT" \
  -d "$(printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":%s,"arguments":%s}}' \
        "$(printf '%s' "$1" | jq -Rs .)" "$2")" \
  | sed -n 's/^data: //p'
