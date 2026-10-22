#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
guard="$repo/agent/ssh-guard.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/ps" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_PS:-}"
SCRIPT
chmod +x "$tmp/ps"

run_guard() {
  local command=$1
  printf '{"tool_input":{"command":%s}}' "$(jq -Rn --arg value "$command" '$value')" \
    | PATH="$tmp:$PATH" FAKE_PS="${FAKE_PS:-}" "$guard"
}

# The resident sshd listener must never count as a client session.
FAKE_PS='245 sshd sshd: /exe.dev/bin/sshd -D -f /exe.dev/etc/ssh/sshd_config' \
  output=$(run_guard 'ssh demo.exe.xyz true')
[[ -z "$output" ]]

# A running exe.xyz SSH client must block another exe.dev-edge SSH command.
FAKE_PS='101 ssh ssh -o ConnectTimeout=30 first.exe.xyz true' \
  output=$(run_guard 'ssh second.exe.xyz true')
grep -q '"permissionDecision":"deny"' <<<"$output"

# An unrelated SSH client must not block an exe.dev command.
FAKE_PS='102 ssh ssh github.com' output=$(run_guard 'ssh second.exe.xyz true')
[[ -z "$output" ]]

# A non-exe.dev command must bypass the guard even when such a client exists.
FAKE_PS='103 ssh ssh first.exe.xyz true' output=$(run_guard 'git status')
[[ -z "$output" ]]

printf '%s\n' 'ssh-guard tests passed'
