#!/usr/bin/env bash
# Claude Code PreToolUse hook: reject a new exe.dev SSH command while another
# client SSH process to exe.dev/exe.xyz is already running.
set -euo pipefail

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')

if ! grep -qE '\bssh\b.*exe\.(dev|xyz)' <<<"$cmd"; then
  exit 0
fi

# Match the process name exactly. Searching argv for `/ssh` also matches the
# resident `/exe.dev/bin/sshd` listener and misses clients shown simply as
# `ssh host`, which made the old inline guard deny or allow the wrong commands.
active=$(ps -eo pid=,comm=,args= | awk '
  $2 == "ssh" && $0 ~ /exe\.(dev|xyz)/ && $0 !~ /zed-ssh-session/ { print }
')

if [[ -n "$active" ]]; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: SSH to exe.dev/exe.xyz already in progress. One at a time — wait for it to finish before retrying."}}'
fi
