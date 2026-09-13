#!/usr/bin/env bash
# Validate provision-iv.sh version/checksum selection and command parsing without
# installing packages or modifying the host.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
script="$repo/provision-iv.sh"

bash -n "$script"

# `bash -n` parses but does not analyse: `local` outside a function is a RUNTIME
# error it accepts happily. That shipped in the AgentsView auth_token block and
# fired months later on the first VM where source.env existed, aborting
# provisioning mid-run. shellcheck catches it as SC2168, along with the rest of
# that class, so run it at error severity over every shell file here.
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S error "$script" "$repo"/tests/*.sh "$repo"/vendor-skills.sh || {
    echo "shellcheck reported errors" >&2
    exit 1
  }
else
  echo "note: shellcheck not installed; skipping static analysis" >&2
fi

# The AWS CLI pins are deliberately absent: 307069f moved the AWS CLI out of the
# default provision path and into the on-demand `bin/install-cloud-cli`, where
# AWS_CLI_VERSION now lives. Everything below is still installed by
# provision-iv.sh itself.
required=(
  DUCKDB_VERSION TIGRIS_VERSION RCLONE_VERSION
  HERDR_VERSION AGENTSVIEW_VERSION SHELLEY_VERSION SHELLEY_TAG SHELLEY_COMMIT APEX_VERSION
  DUCKDB_SHA256_AMD64 DUCKDB_SHA256_ARM64
  TIGRIS_SHA256_AMD64 TIGRIS_SHA256_ARM64
  RCLONE_SHA256_AMD64 RCLONE_SHA256_ARM64
  HERDR_SHA256_X86_64 HERDR_SHA256_AARCH64
  AGENTSVIEW_SHA256_AMD64 AGENTSVIEW_SHA256_ARM64
  SHELLEY_SHA256_AMD64 SHELLEY_SHA256_ARM64
  APEX_SHA256_AMD64 APEX_SHA256_ARM64
  ENTIRE_VERSION ENTIRE_PLUGIN_VERSION
  ENTIRE_SHA256_AMD64 ENTIRE_SHA256_ARM64
  CLAUDE_CODE_VERSION CODEX_VERSION UV_VERSION
  CLAUDE_CODE_SHA256_AMD64 CLAUDE_CODE_SHA256_ARM64
  CODEX_SHA256_AMD64 CODEX_SHA256_ARM64
  UV_SHA256_AMD64 UV_SHA256_ARM64
)

# Not in the loop above: these are single-value pins with no _AMD64/_ARM64 pair,
# so they need the 64-hex check applied by name rather than by suffix.
# entire-agent-shelley is a shell/Python polyglot and the AgentsView adapter is
# Python, so both are arch-independent.
for name in ENTIRE_PLUGIN_SHA256 ENTIRE_AGENTSVIEW_SHA256; do
  value=$(sed -nE "s/^${name}=//p" "$script")
  [[ $value =~ ^[0-9a-f]{64}$ ]] || {
    echo "invalid SHA-256 pin: $name=$value" >&2
    exit 1
  }
done

# The vendored adapter must match the pin the provisioner verifies, or every
# provision fails at the checksum instead of at review time.
vendored="$repo/vendor/entire-agent-agentsview/entire-agent-agentsview"
if [[ -f $vendored ]]; then
  want=$(sed -nE 's/^ENTIRE_AGENTSVIEW_SHA256=//p' "$script")
  got=$(sha256sum "$vendored" | awk '{print $1}')
  [[ $want == "$got" ]] || {
    echo "vendored entire-agent-agentsview does not match its pin" >&2
    echo "  pin:  $want" >&2
    echo "  file: $got" >&2
    exit 1
  }
fi

# Entire's CLI pin must stay at a version entire-agent-shelley was qualified
# against. Bumping the CLI without re-qualifying the plugin is the failure this
# guards. Assert the invariant (the pin records a qualification coupling and
# names the version it was qualified against) rather than a literal version
# string, which would go stale on every legitimate bump.
entire_version=$(sed -nE 's/^ENTIRE_VERSION=//p' "$script")
grep -q "qualified against it" "$script" && grep -q "CLI ${entire_version} was qualified" "$script" || {
  echo "provisioner no longer records that Entire CLI ${entire_version} was qualified against the plugin" >&2
  exit 1
}

for name in "${required[@]}"; do
  value=$(sed -nE "s/^${name}=//p" "$script")
  [[ -n $value ]] || { echo "missing provision pin: $name" >&2; exit 1; }
  if [[ $name == *_SHA256_* ]]; then
    [[ $value =~ ^[0-9a-f]{64}$ ]] || {
      echo "invalid SHA-256 pin: $name=$value" >&2
      exit 1
    }
  fi
done

if grep -Eq 'releases/latest|rclone-current|curl[^|]*\|[^|]*(sh|bash)' "$script"; then
  echo "mutable release URL or curl-pipe-shell found in provisioner" >&2
  exit 1
fi

for managed in duckdb aws tigris rclone herdr agentsview shelley apex; do
  grep -q "/usr/local/bin/${managed}" "$script" || {
    echo "managed tool is not probed by absolute path: $managed" >&2
    exit 1
  }
done

grep -q 'run as the VM login user, not with sudo' "$script"

# Claude settings must be MERGED, not overwritten: overwriting silently deleted the
# personal overlay's SessionStart refresh-env hook, and the mitigation (re-run the
# overlay afterwards) both failed in practice and cannot self-heal, since the hook
# that would restore it lives in the clobbered file.
grep -q 'MERGE the team Claude settings' "$script" || {
  echo "provisioner must merge ~/.claude/settings.json, not overwrite it" >&2
  exit 1
}
grep -q 'SHELLEY_SKIP_VERSION_CHECK=true' "$script"

# The restart decision must read systemd's MainPID, not `pgrep`. shelley.service
# uses KillMode=process, so terminal helpers -- also named "shelley" -- survive a
# restart, predate the drop-in and sort first by PID, which made the check report
# "not in effect" on every run and restart Shelley forever.
grep -q "systemctl show shelley.service -p MainPID" "$script" || {
  echo "restart check must use systemd MainPID, not pgrep" >&2
  exit 1
}
# Nothing may wait on or inspect "a process named shelley": KillMode=process means
# terminal helpers outlive the service and share the name.
if grep -vE '^\s*#' "$script" | grep -q 'pgrep -x shelley'; then
  echo "provisioner still matches processes by name; use systemd MainPID/is-active" >&2
  exit 1
fi

# The socket must be stopped BEFORE the service. shelley.service is BindsTo= the
# socket, so stopping only the service leaves the socket able to activate the old
# binary, which then self-upgrades over the pinned install (observed on kgl-songs
# 2026-08-17, where a clean provision silently reverted a minute later).
socket_stop=$(grep -n 'systemctl stop shelley.socket' "$script" | head -1 | cut -d: -f1)
service_stop=$(grep -n 'systemctl stop shelley.service' "$script" | head -1 | cut -d: -f1)
[[ -n $socket_stop && -n $service_stop && $socket_stop -lt $service_stop ]] || {
  echo "shelley.socket must be stopped before shelley.service (socket=$socket_stop service=$service_stop)" >&2
  exit 1
}
grep -q 'Shelley health check failed; restoring prior binary' "$script"
grep -q 'sqlite3.connect(src)' "$script"
grep -q 'unsafe prior skill name' "$script"
grep -q 'ln -sT' "$script"

# The floor-pinned agents must be probed across PATH, not at one absolute path.
# Probing only ~/.local/bin reported "missing" on the pre-exeslim `exe` base,
# which ships them in /usr/local/bin -- so the floor never applied and
# provisioning DOWNGRADED a working agent (kgl-songs 2026-08-19: Claude Code
# 2.1.222 -> the 2.1.220 pin, Codex 0.146.1 -> 0.146.0).
for floor in claude_code codex; do
  grep -q "^${floor}_version_highest()" "$script" || {
    echo "floor-pinned tool must probe every copy on PATH: $floor" >&2
    exit 1
  }
done
grep -q 'version_at_least "$best" "$CLAUDE_CODE_VERSION"' "$script" || {
  echo "Claude Code floor must compare the highest version on PATH" >&2
  exit 1
}
grep -q 'version_at_least "$best" "$CODEX_VERSION"' "$script" || {
  echo "Codex floor must compare the highest version on PATH" >&2
  exit 1
}

# Behavioural check on the resolution helpers, since the grep above only proves
# the shape. Two copies of a fake tool: the newer one NOT in ~/.local/bin.
probe_dir=$(mktemp -d)
trap 'rm -rf "$probe_dir"' EXIT
mkdir -p "$probe_dir/home/.local/bin" "$probe_dir/usr/bin"
printf '#!/bin/sh\necho "2.1.220 (Claude Code)"\n' > "$probe_dir/home/.local/bin/claude"
printf '#!/bin/sh\necho "2.1.222 (Claude Code)"\n' > "$probe_dir/usr/bin/claude"
chmod +x "$probe_dir/home/.local/bin/claude" "$probe_dir/usr/bin/claude"
probe_out=$(
  HOME="$probe_dir/home" PATH="$probe_dir/usr/bin:/usr/bin:/bin" bash -c '
    eval "$(sed -n "/^version_at_least()/,/^}/p" "$0")"
    eval "$(sed -n "/^tool_paths()/,/^codex_version_highest()/p" "$0")"
    printf "%s %s" "$(claude_code_version)" "$(claude_code_version_highest)"
  ' "$script"
)
[[ $probe_out == "2.1.220 2.1.222" ]] || {
  echo "PATH-wide version probe wrong: expected '2.1.220 2.1.222', got '$probe_out'" >&2
  exit 1
}

# The ssh block must key on tailnet membership, not on a hostname prefix. Fleet
# names do not share one -- kgl-songs, kgl-thoughts and telnyx-vm are tailnet
# nodes that `Host iv-* *.ts.net` never matched, so VM-to-VM ssh to them failed
# host-key verification (2026-08-19).
grep -q 'Match exec "tailscale ip -4 %h' "$script" || {
  echo "ssh config must match tailnet membership via tailscale ip, not a name prefix" >&2
  exit 1
}
if grep -q '^Host iv-\* \*\.ts\.net$' "$script"; then
  echo "ssh config still keys on the iv-* hostname prefix" >&2
  exit 1
fi
# ...and it must be REWRITTEN on every provision, not appended once: the
# append-only form made a wrong stanza permanent on already-provisioned VMs.
grep -q 'updated the iv-provision ssh block' "$script" || {
  echo "ssh block must be reconciled on re-provision, not only created once" >&2
  exit 1
}

source_wrapper="$repo/bin/agentsview-source-daemon"
unit="$repo/systemd/agentsview-source.service"
bash -n "$source_wrapper"
grep -q ': "${AGENTSVIEW_AUTH_TOKEN:?' "$source_wrapper"
grep -q -- '--host 127.0.0.1' "$source_wrapper"
! grep -q -- '--require-auth' "$source_wrapper"
! grep -q 'tailscale' "$source_wrapper"
grep -q '^AGENTSVIEW_FLEET_TOKEN=' "$script"
grep -q -- '--public-url "$PUBLIC_URL"' "$source_wrapper"
! grep -q '0\.0\.0\.0' "$source_wrapper"
grep -q '^EnvironmentFile=%h/.config/agentsview/source.env$' "$unit"
grep -q '^UMask=0077$' "$unit"
grep -q '^NoNewPrivileges=true$' "$unit"

# Global AgentsView MCP is deliberately NOT a team-wide manifest row. The
# endpoint registration is host-gated to iv-provision, while the skill may ship
# everywhere because the peer integration is the actual authorization boundary.
setup_mcp="$repo/agent/setup-mcp.sh"
grep -q 'hostname -s) == iv-provision' "$setup_mcp"
grep -q 'https://mcp-agentsview.int.exe.xyz/mcp' "$setup_mcp"
! grep -q '^agentsview[[:space:]]*|' "$repo/provisioning/mcp.manifest"
test -x "$repo/skills-local/agentsview-query/agentsview-mcp.sh"
grep -q 'untrusted historical data' "$repo/skills-local/agentsview-query/SKILL.md"

mcp_tmp=$(mktemp -d)
mkdir -p "$mcp_tmp/bin" "$mcp_tmp/home"
cat > "$mcp_tmp/bin/hostname" <<'EOF'
#!/bin/sh
printf '%s\n' "$TEST_HOSTNAME"
EOF
cat > "$mcp_tmp/bin/codex" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CODEX_TEST_LOG"
EOF
chmod +x "$mcp_tmp/bin/hostname" "$mcp_tmp/bin/codex"
HOME="$mcp_tmp/home" TEST_HOSTNAME=other-vm CODEX_TEST_LOG="$mcp_tmp/codex.log" \
  PATH="$mcp_tmp/bin:$PATH" bash "$setup_mcp"
jq -e '.mcpServers.agentsview == null' "$mcp_tmp/home/.claude.json" >/dev/null
[[ ! -e $mcp_tmp/codex.log ]]
rm -f "$mcp_tmp/home/.claude.json"
HOME="$mcp_tmp/home" TEST_HOSTNAME=iv-provision CODEX_TEST_LOG="$mcp_tmp/codex.log" \
  PATH="$mcp_tmp/bin:$PATH" bash "$setup_mcp"
jq -e '.mcpServers.agentsview.url == "https://mcp-agentsview.int.exe.xyz/mcp"' \
  "$mcp_tmp/home/.claude.json" >/dev/null
grep -qx 'mcp remove agentsview' "$mcp_tmp/codex.log"
grep -qx 'mcp add agentsview --url https://mcp-agentsview.int.exe.xyz/mcp' "$mcp_tmp/codex.log"
rm -f "$mcp_tmp/codex.log" "$mcp_tmp/home/.claude.json" \
  "$mcp_tmp/bin/hostname" "$mcp_tmp/bin/codex"
rmdir "$mcp_tmp/bin" "$mcp_tmp/home" "$mcp_tmp"

# remove_legacy_quarto must NOT strip quarto from a VM that deliberately keeps it
# (lundstedt.us renders with quarto for a Pandoc fenced div apex cannot emit).
# The regression: the fresh exeslim base has no /opt/quarto, and a naive migrate
# would have provisioning delete the kept binary too. Test the keeps_quarto gate
# in isolation, in a throwaway HOME, touching nothing real.
quarto_gate=$(mktemp -d)
trap 'rm -rf "$quarto_gate"' EXIT
# Pull just the keeps_quarto function out of the script and exercise it.
sed -n '/^keeps_quarto() {/,/^}/p' "$script" > "$quarto_gate/fn.sh"
grep -q 'render-with-quarto' "$quarto_gate/fn.sh" || {
  echo "keeps_quarto not found or lost its .render-with-quarto signal" >&2; exit 1; }

HOME="$quarto_gate/empty"; mkdir -p "$HOME"
if ( . "$quarto_gate/fn.sh"; keeps_quarto ); then
  echo "keeps_quarto returned true with no markers present" >&2; exit 1; fi

HOME="$quarto_gate/marker"; mkdir -p "$HOME/thoughts"
touch "$HOME/thoughts/.render-with-quarto"
if ( . "$quarto_gate/fn.sh"; keeps_quarto ); then :; else
  echo "keeps_quarto ignored a .render-with-quarto marker" >&2; exit 1; fi

HOME="$quarto_gate/optout"; mkdir -p "$HOME/.config/iv-provision"
touch "$HOME/.config/iv-provision/keep-quarto"
if ( . "$quarto_gate/fn.sh"; keeps_quarto ); then :; else
  echo "keeps_quarto ignored the keep-quarto opt-out marker" >&2; exit 1; fi

# And remove_legacy_quarto must consult the gate, not delete unconditionally.
grep -q 'if keeps_quarto; then' "$script" || {
  echo "remove_legacy_quarto no longer guards on keeps_quarto" >&2; exit 1; }

# The doc-site python tools are installed to /usr/local/bin but their shebang
# resolves against the CALLER's PATH, and the only interpreter on these VMs is
# ~/.local/bin/python3. `ssh vm 'provision-docsite ~/repo'` therefore died with
# "/usr/bin/env: 'python3': No such file or directory" on a fully-provisioned
# box. Provisioning now rewrites the shebang to the absolute interpreter at
# install time; check the rewrite exists, and that the repo copies still carry
# the portable form (they must stay runnable from a checkout).
grep -q "printf '#!%s\\\\n' \"\$py\"" "$script" || {
  echo "provision no longer pins the interpreter for installed python tools" >&2
  exit 1; }

for tool in render-md-site gen-llms-txt shot; do
  head -1 "$repo/bin/$tool" | grep -qx '#!/usr/bin/env python3' || {
    echo "bin/$tool lost its portable env shebang" >&2; exit 1; }
done

# Exercise the rewrite itself: same transformation the install loop applies.
shebang_dir=$(mktemp -d)
trap 'rm -rf "$quarto_gate" "$shebang_dir"' EXIT
{ printf '#!%s\n' "/opt/py/bin/python3"; tail -n +2 "$repo/bin/render-md-site"; } \
  >"$shebang_dir/render-md-site"
head -1 "$shebang_dir/render-md-site" | grep -qx '#!/opt/py/bin/python3' || {
  echo "shebang rewrite did not produce an absolute interpreter" >&2; exit 1; }
# The body must survive intact -- an off-by-one in tail would silently eat code.
if ! diff -q <(tail -n +2 "$repo/bin/render-md-site") \
             <(tail -n +2 "$shebang_dir/render-md-site") >/dev/null; then
  echo "shebang rewrite altered the script body" >&2; exit 1
fi

printf '%s\n' 'provision script tests passed'
