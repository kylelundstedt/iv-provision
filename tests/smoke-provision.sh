#!/usr/bin/env bash
# Validate an installed IV provisioning layer and its provenance lock.
set -euo pipefail

repo=${1:-$(cd "$(dirname "$0")/.." && pwd)}
lock=${2:-$HOME/iv-provision.lock}

expected_value() {
  sed -nE "s/^$1=//p" "$repo/provision-iv.sh" | head -1
}

# On-demand cloud CLIs are pinned in bin/install-cloud-cli, not provision-iv.sh,
# and in `${VAR:-default}` form so the caller can override. Unwrap the default.
expected_cloud_value() {
  sed -nE "s/^$1=\\\$\\{$1:-([^}]+)\\}.*/\\1/p" "$repo/bin/install-cloud-cli" | head -1
}

actual_duckdb=$(/usr/local/bin/duckdb --version | awk '{sub(/^v/, "", $1); print $1}')
actual_aws=$(/usr/local/bin/aws --version 2>&1 | sed -nE 's#aws-cli/([^ ]+).*#\1#p' || true)
actual_tigris=$(/usr/local/bin/tigris --version | head -1 | sed 's/^v//')
actual_rclone=$(/usr/local/bin/rclone version 2>/dev/null | sed -nE '1s/^rclone v?//p' || true)
actual_herdr=$(/usr/local/bin/herdr --version | awk '{print $2}')
actual_agentsview=$(/usr/local/bin/agentsview version --format json | jq -r '.version' | sed 's/^v//')
actual_shelley=$(/usr/local/bin/shelley version | jq -r '.version')
actual_shelley_commit=$(/usr/local/bin/shelley version | jq -r '.commit')
actual_shelley_sha256=$(sha256sum /usr/local/bin/shelley | awk '{print $1}')
actual_apex=$(/usr/local/bin/apex --version | awk 'NR == 1 {print $2}')

[[ $actual_duckdb == "$(expected_value DUCKDB_VERSION)" ]]
# aws is ON-DEMAND (`install-cloud-cli aws`, 2026-07-28), so it is absent on most
# VMs and its pin lives in that script rather than provision-iv.sh. This line
# used to read `expected_value AWS_CLI_VERSION` against provision-iv.sh, where
# the pin no longer exists -- so it compared the installed version against the
# empty string. That passes on a VM without aws (both sides empty) and FAILS on
# any VM where someone ran `install-cloud-cli aws`: green on fresh canaries,
# broken on iv-provision itself. Check it only when installed, like rclone below.
if [[ -n $actual_aws ]]; then
  [[ $actual_aws == "$(expected_cloud_value AWS_CLI_VERSION)" ]]
fi
[[ $actual_tigris == "$(expected_value TIGRIS_VERSION)" ]]
if [[ -n $actual_rclone ]]; then
  [[ $actual_rclone == "$(expected_value RCLONE_VERSION)" ]]
fi
[[ $actual_herdr == "$(expected_value HERDR_VERSION)" ]]
[[ $actual_agentsview == "$(expected_value AGENTSVIEW_VERSION)" ]]
[[ $actual_shelley == "$(expected_value SHELLEY_VERSION)" ]]
[[ $actual_shelley_commit == "$(expected_value SHELLEY_COMMIT)" ]]
[[ $actual_shelley_sha256 == "$(expected_value "SHELLEY_SHA256_$(dpkg --print-architecture | tr '[:lower:]' '[:upper:]')")" ]]
[[ $actual_apex == "$(expected_value APEX_VERSION)" ]]

# Apex 1.1.16 fixes silent 1024-character truncation in unified mode
# (ApexMarkdown/apex#31). Keep a fleet smoke check so a future bump cannot
# reintroduce content loss while still exiting successfully.
# Built with awk, not python3. This line aborted the whole smoke suite on the
# freshly provisioned iv-provision VM (2026-08-18) because the minimal base has no
# system interpreter -- and a smoke test that dies on its own fixture generator
# reports nothing about the 20-odd checks after it. provision-iv.sh now installs a
# uv-managed python3, but the fixture does not need one.
long_line=$(awk 'BEGIN { s = sprintf("%4096s", ""); gsub(/ /, "a", s); print s "END-OF-LONG-LINE" }')
rendered_long_line=$(printf '%s\n' "$long_line" | /usr/local/bin/apex -m unified)
grep -q 'END-OF-LONG-LINE' <<<"$rendered_long_line"

for tool in render-site provision-docsite gen-llms-txt shot install-cloud-cli agentsview-source-daemon; do
  test -x "/usr/local/bin/$tool"
done

test -x "$HOME/.agents/ssh-guard.sh"
test -f "$HOME/.agents/AGENTS.md"
test -f "$HOME/.claude/settings.json"
test -f "$HOME/.codex/config.toml"
test -f "$HOME/.claude.json"
test -f "$HOME/.agents/iv-team-skills.list"
test -f "$HOME/.config/systemd/user/agentsview-source.service"

while IFS= read -r name; do
  test -f "$HOME/.agents/skills/$name/SKILL.md"
  test -L "$HOME/.claude/skills/$name"
  test -L "$HOME/.codex/skills/$name"
done < "$HOME/.agents/iv-team-skills.list"

# The hand-written skills specifically. The loop above only checks that whatever
# is LISTED got installed, so it passes vacuously if skills-local/ stops being
# copied at all -- which is precisely the regression to catch, since these are
# the skills that are not recoverable from the manifest.
for name in join-tailnet upgrade-vm create-vm create-repo; do
  test -f "$HOME/.agents/skills/$name/SKILL.md"
  grep -qx "$name" "$HOME/.agents/iv-team-skills.list"
done

# create-repo ships executables, not just prose. `cp -a` preserves the mode, but
# only if the mode was committed -- a skill whose scripts arrive non-executable
# fails at use time with a bare "Permission denied" and no hint of why.
for s in gh-mcp.sh push-tree.sh; do
  test -x "$HOME/.agents/skills/create-repo/$s"
done

test -f "$lock"
grep -qx "duckdb_version=$actual_duckdb" "$lock"
grep -qx "aws_cli_version=$actual_aws" "$lock"
grep -qx "tigris_version=$actual_tigris" "$lock"
grep -qx "rclone_version=$actual_rclone" "$lock"
grep -qx "herdr_version=$actual_herdr" "$lock"
grep -qx "agentsview_version=$actual_agentsview" "$lock"
grep -qx "shelley_version=$actual_shelley" "$lock"
grep -qx "shelley_tag=$(expected_value SHELLEY_TAG)" "$lock"
grep -qx "shelley_commit=$actual_shelley_commit" "$lock"
grep -qx "shelley_sha256=$actual_shelley_sha256" "$lock"
grep -qx "apex_version=$actual_apex" "$lock"

printf 'smoke-provision: IV layer is healthy (%s)\n' "$lock"
