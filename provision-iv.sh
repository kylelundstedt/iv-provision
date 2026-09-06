#!/usr/bin/env bash
# Provision the IV layer onto a stock exeuntu VM.
#
# This script layers IV tooling on top. Tool releases are version-pinned and
# checksum-verified; skills and agent configuration are vendored in this repo.
# It needs no Node runtime. Arch-aware (amd64 + arm64) and safe to re-run.
set -euo pipefail

DUCKDB_VERSION=1.5.3
TIGRIS_VERSION=3.6.1
RCLONE_VERSION=1.74.3
HERDR_VERSION=0.7.4
AGENTSVIEW_VERSION=0.38.1
SHELLEY_VERSION=0.959.914757635
SHELLEY_TAG=v0.959.914757635
SHELLEY_COMMIT=33df9d893b0de54d32942c7541841cb0e626baa2
APEX_VERSION=1.1.16
# Entire (ACR provider, ADR 0014) and IV's Shelley external-agent plugin.
# Pinned deliberately, NOT floating: entire-agent-shelley 0.1.3 speaks a fixed
# plugin<->CLI protocol (the `info` hook-name set and lifecycle JSON), so the
# CLI version is only bumped after the plugin is re-qualified against it on the
# dedicated iv-entire-agent-shelley VM. CLI 0.10.1 was qualified against plugin
# 0.1.3 on 2026-08-19 -- the full live suite (test-shelley-live.sh, incl. real
# checkpoint condensation and the entire/checkpoints/v1 ref) passed; 0.10.0
# passed identically, so 0.10.1 was chosen as the newer stable. The prior pin was
# 0.8.42; the jump skips 0.9.x entirely, which is why re-qualification (not just a
# version-and-checksum edit) was the gate. Re-qualify, then bump both together.
ENTIRE_VERSION=0.10.1
ENTIRE_PLUGIN_VERSION=0.1.3
# Coding agents. Owned here rather than by the personal dotfiles so a fleet VM is
# self-sufficient, and deliberately NOT baked into the base image: agents release
# constantly, and baked copies went stale and sat shadowed by ~/.local/bin --
# 2.0 GB of superseded duplicates measured fleet-wide 2026-07-28.
#
# Installed from each project's signed/checksummed release assets rather than the
# unverified pipe-to-shell installers dotfiles used, so versions are pinned and
# checksum-verified.
#
# Both agents self-update. Like Shelley, a pinned install can therefore drift;
# unlike Shelley there is no IV requirement for a specific build, so drift is
# accepted and re-provisioning simply restores the pin.
CLAUDE_CODE_VERSION=2.1.220
CODEX_VERSION=0.146.0
UV_VERSION=0.12.0

DUCKDB_SHA256_AMD64=35caef1fecbc8d7e2c07de4fd2cdefc5189ec9ba9e1cca228fb1a1c48cc52a8a
DUCKDB_SHA256_ARM64=5e2399428793642e994f1584c47d49f4c58b7b4ec2297ea4a522353a6c553835
TIGRIS_SHA256_AMD64=3038796d9a6ef9f9c0fdfdc7846d516d88b8775a2b34110d9d5813a4b7da57dd
TIGRIS_SHA256_ARM64=38a4ca3e94e09c22fca08896f12ec8abf5ead731dd7fc07d56e9d3c98b5be4ba
RCLONE_SHA256_AMD64=dbee7ccd7a5d617e4ed4cd4555c16669b511abfe8d31164f61be35ac9e999bd2
RCLONE_SHA256_ARM64=8f8d47446e061f80c3256659fe8e21f56d72d96aaefe1275d088ea5eb6b42aa7
# herdr publishes no checksum files — these are sha256sums of the release
# assets, computed locally at pin time. Version bumps must recompute them.
HERDR_SHA256_X86_64=bc0fc02d4ba500f9cac2353a43e67fe036785ecca6eb55378e050fac3c103059
HERDR_SHA256_AARCH64=544e0002de42806d1ab64ccdef3a7e7414f24717b0b6b022bc9e57d2eefd26a2
AGENTSVIEW_SHA256_AMD64=3b3f7098ab855571df8e6d6c99efdf307be3407d32197816f0c4c698fac4f997
AGENTSVIEW_SHA256_ARM64=aace4bea2f6b8626fb9aaecf28b4ffaf93d510550e3468231de81f741266d037
SHELLEY_SHA256_AMD64=6f1aff50a7890d397c3da32aa4d6fddf06ed6aa8aebaa987adbb527bb3db1dff
SHELLEY_SHA256_ARM64=e89091075ae2732b6e073bdb75896be9ce8ef524d23b8c916b036c4c73dd53d3
APEX_SHA256_AMD64=d19c99148cf1d3cd3302c1ff13b893c09f5b3575b00c67f183b0b9ddb7000ac1
APEX_SHA256_ARM64=dbf306f515301b6c2b91988d142da2e95b89c3efbcc359c03975fb12a811a2d9
# From the release's own checksums.txt.
ENTIRE_SHA256_AMD64=eb669fde314a70e5b4bbad21c1c145324816431f125fd2ec01c9e163506f2881
ENTIRE_SHA256_ARM64=e512b66d238d3cfb858f66c6a362f210d120ac7151c7c0c2f6d3d9e7345bf394
# Arch-independent: the plugin is a shell/Python polyglot, not a compiled binary.
# Matches SHA256SUMS at tag v0.1.3 and the hash recorded in its README.
ENTIRE_PLUGIN_SHA256=1541c304ce86e7b80b74d91a01348daa6a38dd53e068c856c3d832880a55f64e
# Vendored AgentsView adapter (see vendor/entire-agent-agentsview/README.md).
ENTIRE_AGENTSVIEW_SHA256=c75d5459537d208b0ad674f97cd8a1814376f23b2a23a52d3e6fd97c634529a7
# claude: from the release's SHASUMS256.txt. codex: computed at pin time (the
# release publishes .sigstore attestations, not a plain checksum file).
# uv: from the asset's own .sha256 file.
CLAUDE_CODE_SHA256_AMD64=e69e7f72d784c243bcc377a578ad9ff8e65ae14da672fbbf9f2ba7bf47eca7ec
CLAUDE_CODE_SHA256_ARM64=a4f2e93621b1521731d1f132c83f8266384403ab29e14986d67e3b4a805bf454
CODEX_SHA256_AMD64=5ba3b9405543953081f661d0854d266f76e2abbe51d41349355a36de7673776a
CODEX_SHA256_ARM64=975bac91562abeedeb8f79636d51a86649b31f34a9de6a3bcb059565b6cf1f87
UV_SHA256_AMD64=eaf842262aa1c418d8ecc5605f02ee1ebfd369124fa48548e85f9481a47831a9
UV_SHA256_ARM64=2c5d6e3092cc5223b10ff403880cc75121bf64e84644e7a0c69f643b0d89ac95

if [[ $EUID -eq 0 ]]; then
  echo "provision-iv: run as the VM login user, not with sudo" >&2
  exit 1
fi

IV_REPO="$(cd "$(dirname "$0")" && pwd)"

# Say which revision is being provisioned, up front. The lock file records this at
# the END, which is too late to notice you ran the wrong one: on iv-provision
# 2026-08-18 a `git checkout --detach main` landed on a stale LOCAL main, four
# commits behind origin, and silently re-provisioned an older recipe -- removing a
# skill and un-recording python3. Git's own "your branch is behind" notice scrolled
# past in the fetch output.
#
# Warn on the two states that mean "this is probably not the recipe you think":
# a checkout that is behind its upstream, and uncommitted changes.
if git -C "$IV_REPO" rev-parse --git-dir >/dev/null 2>&1; then
  iv_head=$(git -C "$IV_REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)
  iv_desc=$(git -C "$IV_REPO" describe --tags --exact-match HEAD 2>/dev/null \
    || git -C "$IV_REPO" describe --tags HEAD 2>/dev/null \
    || echo 'no tag')
  echo "== provisioning from $IV_REPO @ $iv_head ($iv_desc) =="
  if iv_upstream=$(git -C "$IV_REPO" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null); then
    iv_behind=$(git -C "$IV_REPO" rev-list --count "HEAD..$iv_upstream" 2>/dev/null || echo 0)
    [[ ${iv_behind:-0} -eq 0 ]] \
      || echo "  [!] $iv_behind commit(s) behind $iv_upstream -- check out a release tag instead" >&2
  fi
  [[ -z $(git -C "$IV_REPO" status --porcelain 2>/dev/null) ]] \
    || echo "  [!] working tree has uncommitted changes" >&2
fi
DPKG_ARCH="$(dpkg --print-architecture)"
UNAME_ARCH="$(uname -m)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

case "$DPKG_ARCH" in
  amd64)
    DUCKDB_SHA256=$DUCKDB_SHA256_AMD64
    TIGRIS_SHA256=$TIGRIS_SHA256_AMD64
    TIGRIS_ASSET_ARCH=x64
    RCLONE_SHA256=$RCLONE_SHA256_AMD64
    AGENTSVIEW_SHA256=$AGENTSVIEW_SHA256_AMD64
    SHELLEY_SHA256=$SHELLEY_SHA256_AMD64
    APEX_SHA256=$APEX_SHA256_AMD64
    APEX_ASSET_ARCH=x86_64
    ENTIRE_SHA256=$ENTIRE_SHA256_AMD64
    CLAUDE_CODE_SHA256=$CLAUDE_CODE_SHA256_AMD64
    CLAUDE_CODE_ASSET_ARCH=x64
    CODEX_SHA256=$CODEX_SHA256_AMD64
    CODEX_ASSET_ARCH=x86_64
    UV_SHA256=$UV_SHA256_AMD64
    UV_ASSET_ARCH=x86_64
    ;;
  arm64)
    DUCKDB_SHA256=$DUCKDB_SHA256_ARM64
    TIGRIS_SHA256=$TIGRIS_SHA256_ARM64
    TIGRIS_ASSET_ARCH=arm64
    RCLONE_SHA256=$RCLONE_SHA256_ARM64
    AGENTSVIEW_SHA256=$AGENTSVIEW_SHA256_ARM64
    SHELLEY_SHA256=$SHELLEY_SHA256_ARM64
    APEX_SHA256=$APEX_SHA256_ARM64
    APEX_ASSET_ARCH=aarch64
    ENTIRE_SHA256=$ENTIRE_SHA256_ARM64
    CLAUDE_CODE_SHA256=$CLAUDE_CODE_SHA256_ARM64
    CLAUDE_CODE_ASSET_ARCH=arm64
    CODEX_SHA256=$CODEX_SHA256_ARM64
    CODEX_ASSET_ARCH=aarch64
    UV_SHA256=$UV_SHA256_ARM64
    UV_ASSET_ARCH=aarch64
    ;;
  *) echo "provision-iv: unsupported dpkg architecture: $DPKG_ARCH" >&2; exit 1 ;;
esac

case "$UNAME_ARCH" in
  x86_64) HERDR_SHA256=$HERDR_SHA256_X86_64 ;;
  aarch64) HERDR_SHA256=$HERDR_SHA256_AARCH64 ;;
  *) echo "provision-iv: unsupported uname architecture: $UNAME_ARCH" >&2; exit 1 ;;
esac

download_verified() {
  local url=$1 sha256=$2 output=$3
  curl -fsSL "$url" -o "$output"
  printf '%s  %s\n' "$sha256" "$output" | sha256sum -c -
}

# True when $1 is at least $2. Used for the coding-agent pins, which are FLOORS
# rather than exact versions: see install_claude_code.
version_at_least() {
  local have=$1 want=$2
  [[ -n $have ]] || return 1
  [[ $have == "$want" ]] && return 0
  [[ $(printf '%s\n%s\n' "$have" "$want" | sort -V | head -1) == "$want" ]]
}

keeps_quarto() {
  # A VM opts out of quarto removal when it still renders with quarto. Two
  # signals, either sufficient:
  #   * an explicit fleet marker, ~/.config/iv-provision/keep-quarto, or
  #   * any repo in ~ carrying the per-repo `.render-with-quarto` marker, the
  #     convention lundstedt.us uses to stay on quarto for a Pandoc fenced div
  #     that the lightweight (apex) renderer cannot produce.
  [[ -f $HOME/.config/iv-provision/keep-quarto ]] && return 0
  local m
  while IFS= read -r m; do
    [[ -n $m ]] && return 0
  done < <(find "$HOME" -maxdepth 3 -name '.render-with-quarto' -print 2>/dev/null)
  return 1
}

remove_legacy_quarto() {
  # Reclaim installations created by older iv-provision releases. Do not touch a
  # user-managed quarto binary unless it resolves into the old /opt/quarto tree.
  # A VM that still renders with quarto (see keeps_quarto) is left untouched --
  # removing its /usr/local/bin/quarto symlink strands the binary off PATH and
  # breaks the site's own `quarto render` publish path.
  if keeps_quarto; then
    echo "  quarto retained (.render-with-quarto or keep-quarto marker present)"
    return 0
  fi
  local target dir
  if [[ -L /usr/local/bin/quarto ]]; then
    target=$(readlink -f /usr/local/bin/quarto || true)
    [[ $target == /opt/quarto/* ]] && sudo rm -f /usr/local/bin/quarto
  fi
  [[ ! -L /opt/quarto ]] || sudo rm -f /opt/quarto
  while IFS= read -r dir; do
    sudo rm -rf -- "$dir"
  done < <(find /opt -maxdepth 1 -type d -name 'quarto-*' -print)
}

duckdb_version() { /usr/local/bin/duckdb --version 2>/dev/null | awk '{sub(/^v/, "", $1); print $1}' || true; }
# aws is on-demand (install-cloud-cli aws); empty in the lock file when absent.
aws_version() { /usr/local/bin/aws --version 2>&1 | sed -nE 's#aws-cli/([^ ]+).*#\1#p' || true; }
tigris_version() { /usr/local/bin/tigris --version 2>/dev/null | head -1 | sed 's/^v//' || true; }
rclone_version() { /usr/local/bin/rclone version 2>/dev/null | sed -nE '1s/^rclone v?//p' || true; }
herdr_version() { /usr/local/bin/herdr --version 2>/dev/null | awk '{print $2}' || true; }
agentsview_version() { /usr/local/bin/agentsview version --format json 2>/dev/null | jq -r '.version' | sed 's/^v//' || true; }
shelley_info() { /usr/local/bin/shelley version 2>/dev/null || true; }
shelley_version() { shelley_info | jq -r '.version // empty' 2>/dev/null || true; }
shelley_commit() { shelley_info | jq -r '.commit // empty' 2>/dev/null || true; }
apex_version() { /usr/local/bin/apex --version 2>/dev/null | awk 'NR == 1 {print $2}' || true; }
tailscale_version() { tailscale version 2>/dev/null | head -1 || true; }
entire_version() { "$HOME/.local/bin/entire" --version 2>/dev/null | sed -nE '1s/^Entire CLI //p' || true; }
uv_version() { "$HOME/.local/bin/uv" --version 2>/dev/null | awk '{print $2}' || true; }
# The FLOOR-pinned agents (claude, codex) must be probed across every copy on
# PATH, not just at "$HOME/.local/bin/<tool>".
#
# WHY. Found 2026-08-19 while refreshing the fleet to 3.0.8. kgl-songs and
# telnyx-vm predate the exeslim base and run exe.dev's older `exe` image, which
# ships claude, codex and uv in /usr/local/bin -- a location the exeslim bases do
# not use. Probing only ~/.local/bin therefore reported "missing" on those VMs
# while a perfectly good, newer Claude Code was installed and in use. The floor
# check never ran, and provisioning installed the pin into ~/.local/bin, which
# ~/.profile prepends to PATH. Measured on kgl-songs: Claude Code 2.1.222 -> the
# 2.1.220 pin, Codex 0.146.1 -> 0.146.0, plus ~290 MB of shadowed duplicate that
# the install_claude_code comment below exists specifically to avoid.
#
# A floor that cannot see the installed version is not a floor -- it is an exact
# pin with extra steps, and it downgrades working tools. So resolve like a shell
# does, with ~/.local/bin prepended exactly as ~/.profile does it:
#
#   *_version()          the copy that WINS PATH resolution -- what a user
#                        actually runs. Recorded in the lock file, because the
#                        lock must describe the VM rather than the recipe.
#   *_version_highest()  the newest copy anywhere on PATH. This is what the floor
#                        compares against: the pin exists to guarantee a known-good
#                        minimum is PRESENT, so finding one already installed --
#                        wherever the base image put it -- means there is nothing
#                        to do and no bytes to duplicate.
#
# uv and the Entire CLI stay probed at their absolute paths on purpose: they are
# exact pins carrying reproducibility, not floors, so "a newer one exists" is not
# a reason to skip installing the pinned one.
tool_paths() {
  local tool=$1
  {
    printf '%s\n' "$HOME/.local/bin/$tool"
    PATH="$HOME/.local/bin:$PATH" type -aP "$tool" 2>/dev/null || true
  } | awk 'NF && !seen[$0]++'
}

# Version of one specific copy. `claude --version` prints e.g.
# "2.1.220 (Claude Code)"; `codex --version` prints e.g. "codex-cli 0.146.0".
claude_code_version_at() { [[ -x $1 ]] && "$1" --version 2>/dev/null | awk '{print $1}' || true; }
codex_version_at() { [[ -x $1 ]] && "$1" --version 2>/dev/null | awk '{print $NF}' || true; }

tool_effective_version() {
  local tool=$1 probe=$2 path
  while IFS= read -r path; do
    [[ -x $path ]] || continue
    "$probe" "$path"
    return
  done < <(tool_paths "$tool")
}

tool_highest_version() {
  local tool=$1 probe=$2 path found best=
  while IFS= read -r path; do
    [[ -x $path ]] || continue
    found=$("$probe" "$path")
    [[ -n $found ]] || continue
    if [[ -z $best ]] || version_at_least "$found" "$best"; then
      best=$found
    fi
  done < <(tool_paths "$tool")
  printf '%s' "$best"
}

claude_code_version() { tool_effective_version claude claude_code_version_at; }
claude_code_version_highest() { tool_highest_version claude claude_code_version_at; }
codex_version() { tool_effective_version codex codex_version_at; }
codex_version_highest() { tool_highest_version codex codex_version_at; }
entire_plugin_version() {
  local p="$HOME/.config/entire/shelley-hooks/bin/entire-agent-shelley"
  [[ -x $p ]] || return 0
  local got
  got=$(sha256sum "$p" 2>/dev/null | awk '{print $1}')
  if [[ $got == "$ENTIRE_PLUGIN_SHA256" ]]; then
    printf '%s' "$ENTIRE_PLUGIN_VERSION"
  else
    printf 'unknown(%s)' "${got:0:12}"
  fi
}

install_duckdb() {
  local actual
  actual=$(duckdb_version)
  echo "== DuckDB $DUCKDB_VERSION ($DPKG_ARCH; installed: ${actual:-missing}) =="
  [[ $actual == "$DUCKDB_VERSION" ]] && return
  download_verified \
    "https://github.com/duckdb/duckdb/releases/download/v${DUCKDB_VERSION}/duckdb_cli-linux-${DPKG_ARCH}.zip" \
    "$DUCKDB_SHA256" "$TMP/duckdb.zip"
  unzip -q -o "$TMP/duckdb.zip" -d "$TMP/duckdb"
  sudo install -m 0755 "$TMP/duckdb/duckdb" /usr/local/bin/duckdb
  [[ $(duckdb_version) == "$DUCKDB_VERSION" ]]
}

# AWS CLI moved to on-demand 2026-07-28: `install-cloud-cli aws`.
#
# It was a default install costing 267-533 MB per VM (~2.9 GB fleet-wide) while
# NOT ONE VM had ~/.aws/config or ~/.aws/credentials — installed everywhere,
# configured nowhere. S3 work here targets Tigris over S3-compatible endpoints
# via the tigris CLI, boto3 and duckdb httpfs, none of which use this CLI.
#
# The pins and the installer live in bin/install-cloud-cli alongside azure and
# gcloud, which were already on-demand for exactly this reason. tigris and
# rclone stay default: used, and far smaller.

install_tigris() {
  local actual
  actual=$(tigris_version)
  echo "== Tigris CLI $TIGRIS_VERSION ($DPKG_ARCH; installed: ${actual:-missing}) =="
  [[ $actual == "$TIGRIS_VERSION" ]] && return
  # tigrisdata/cli is deprecated and its releases froze without
  # TIGRIS_FORCE_PATH_STYLE (required by exe.dev Object Storage integrations).
  # The live repo is tigrisdata/storage, which tags releases @tigrisdata/cli@X.Y.Z
  # (not vX.Y.Z) — hence the @-prefixed path segment below.
  download_verified \
    "https://github.com/tigrisdata/storage/releases/download/@tigrisdata/cli@${TIGRIS_VERSION}/tigris-linux-${TIGRIS_ASSET_ARCH}.tar.gz" \
    "$TIGRIS_SHA256" "$TMP/tigris.tar.gz"
  tar -xzf "$TMP/tigris.tar.gz" -C "$TMP"
  sudo install -m 0755 "$TMP/tigris-linux-${TIGRIS_ASSET_ARCH}" /usr/local/bin/tigris
  [[ $(tigris_version) == "$TIGRIS_VERSION" ]]
}

# rclone moved to on-demand 2026-07-29 (`install-cloud-cli rclone`): 75 MB per
# VM, used only by the Tigris backup, which runs on klundstedt-mini. No dev VM
# had ~/.config/rclone/rclone.conf. tigris stays a default install — 18 vendored
# agent skills depend on it.

# herdr releases bare binaries named with uname-style arch (x86_64/aarch64)
install_herdr() {
  local actual
  actual=$(herdr_version)
  echo "== herdr $HERDR_VERSION ($UNAME_ARCH; installed: ${actual:-missing}) =="
  [[ $actual == "$HERDR_VERSION" ]] && return
  download_verified \
    "https://github.com/ogulcancelik/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-${UNAME_ARCH}" \
    "$HERDR_SHA256" "$TMP/herdr"
  sudo install -m 0755 "$TMP/herdr" /usr/local/bin/herdr
  [[ $(herdr_version) == "$HERDR_VERSION" ]]
}

install_agentsview() {
  local actual
  actual=$(agentsview_version)
  echo "== AgentsView $AGENTSVIEW_VERSION ($DPKG_ARCH; installed: ${actual:-missing}) =="
  [[ $actual == "$AGENTSVIEW_VERSION" ]] && return
  download_verified \
    "https://github.com/kenn-io/agentsview/releases/download/v${AGENTSVIEW_VERSION}/agentsview_${AGENTSVIEW_VERSION}_linux_${DPKG_ARCH}.tar.gz" \
    "$AGENTSVIEW_SHA256" "$TMP/agentsview.tar.gz"
  mkdir -p "$TMP/agentsview"
  tar -xzf "$TMP/agentsview.tar.gz" -C "$TMP/agentsview"
  sudo install -m 0755 "$TMP/agentsview/agentsview" /usr/local/bin/agentsview
  [[ $(agentsview_version) == "$AGENTSVIEW_VERSION" ]]
}

install_shelley() {
  local actual_version actual_commit backup_dir backup_bin db_backup
  actual_version=$(shelley_version)
  actual_commit=$(shelley_commit)
  echo "== Shelley $SHELLEY_VERSION ($DPKG_ARCH; installed: ${actual_version:-missing} ${actual_commit:+@$actual_commit}) =="

  # The pin is both release and source identity. A matching version built from a
  # different commit is not accepted.
  if [[ $actual_version == "$SHELLEY_VERSION" && $actual_commit == "$SHELLEY_COMMIT" ]]; then
    sudo mkdir -p /etc/systemd/system/shelley.service.d
    printf '%s\n' '[Service]' 'Environment=SHELLEY_SKIP_VERSION_CHECK=true' \
      | sudo tee /etc/systemd/system/shelley.service.d/10-iv-managed.conf >/dev/null
    sudo systemctl daemon-reload

    # Restart ONLY if the drop-in is not already in effect in the running process.
    #
    # A restart kills every in-flight conversation on the VM, so doing it
    # unconditionally means a fleet refresh interrupts ten VMs for no reason -- and
    # kills the very conversation driving the refresh, if it is being driven from
    # Shelley. This block previously restarted even when the binary and the drop-in
    # were both already correct, reasoning that a newly written drop-in does not
    # reach a running process. True, but only relevant when it is actually missing
    # from that process.
    #
    # Ask the process, do not infer: a drop-in on disk says nothing about the
    # environment of a process that started before it was written.
    # Ask systemd for the service's MainPID. NOT `pgrep -x shelley | head -1`:
    # shelley.service sets KillMode=process, so a restart kills only the main
    # process and its terminal helpers survive -- and those helpers are also named
    # "shelley". They predate the drop-in, so they never carry
    # SHELLEY_SKIP_VERSION_CHECK, and being older they sort first by PID. Reading
    # their environ made this check report "not in effect" on every run forever,
    # turning the unconditional restart this was meant to remove into a permanent
    # one. Observed on iv-provision 2026-08-19, where the surviving helper's
    # environ showed SHELLEY_CONVERSATION_ID/SHELLEY_TERMINAL_ID -- the giveaway
    # that it was a child session, not the server.
    local shelley_pid running_env=""
    shelley_pid=$(systemctl show shelley.service -p MainPID --value 2>/dev/null || true)
    if [[ -n $shelley_pid && $shelley_pid != 0 && -r /proc/$shelley_pid/environ ]]; then
      running_env=$(tr '\0' '\n' < "/proc/$shelley_pid/environ" 2>/dev/null \
        | grep -c '^SHELLEY_SKIP_VERSION_CHECK=true$' || true)
    fi
    if [[ ${running_env:-0} -ge 1 ]]; then
      echo "  pin and self-update override already in effect; not restarting"
    else
      echo "  self-update override not active in the running process; restarting"
      sudo systemctl restart shelley.service
    fi
    return
  fi

  download_verified \
    "https://github.com/aifoundry-org/shelley/releases/download/${SHELLEY_TAG}/shelley_linux_${DPKG_ARCH}" \
    "$SHELLEY_SHA256" "$TMP/shelley"
  chmod 0755 "$TMP/shelley"
  [[ $("$TMP/shelley" version | jq -r '.version') == "$SHELLEY_VERSION" ]]
  [[ $("$TMP/shelley" version | jq -r '.commit') == "$SHELLEY_COMMIT" ]]

  backup_dir="$HOME/.local/state/iv-provision/shelley/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$backup_dir"
  chmod 700 "$HOME/.local/state/iv-provision" "$HOME/.local/state/iv-provision/shelley" "$backup_dir"
  if [[ -x /usr/local/bin/shelley ]]; then
    sudo cp -a /usr/local/bin/shelley "$backup_dir/shelley.prior"
    sudo chown "$USER:$(id -gn)" "$backup_dir/shelley.prior"
    sha256sum "$backup_dir/shelley.prior" > "$backup_dir/shelley.prior.sha256"
    /usr/local/bin/shelley version > "$backup_dir/shelley.prior.version.json" 2>/dev/null || true
  fi
  [[ ! -f /etc/systemd/system/shelley.service ]] || sudo cp -a /etc/systemd/system/shelley.service "$backup_dir/shelley.service.prior"
  [[ ! -f /etc/systemd/system/shelley.socket ]] || sudo cp -a /etc/systemd/system/shelley.socket "$backup_dir/shelley.socket.prior"

  # Stop the SOCKET FIRST, then the service. shelley.service is BindsTo= the
  # socket, so stopping only the service leaves the socket listening and the next
  # touch of it socket-activates the binary that is on disk at that instant --
  # which, mid-install, is the OLD one, predating the SHELLEY_SKIP_VERSION_CHECK
  # drop-in, so it then auto-upgrades over the pinned install. Observed on
  # kgl-songs 2026-08-17: provisioning reported 0.959.914757635 installed and one
  # minute later the VM was serving 0.956.955465414 again, needing a manual
  # repair. A clean provision log is therefore not proof the pin stuck.
  #
  # Wait for the process to actually exit: `systemctl stop` returns when systemd
  # considers the unit stopped, which can precede the last write to shelley.db.
  #
  # Use SQLite's backup API when Python is available, otherwise copy the
  # stopped/checkpointed database.
  sudo systemctl stop shelley.socket 2>/dev/null || true
  sudo systemctl stop shelley.service 2>/dev/null || true
  # Wait on the SERVICE, not on any process named "shelley". KillMode=process
  # leaves terminal helpers running after a stop, and they are named "shelley"
  # too -- so a `pgrep -x shelley` loop never breaks and burns its full timeout on
  # every binary swap while the thing it is waiting for has already exited.
  for _ in $(seq 1 20); do
    sudo systemctl is-active --quiet shelley.service || break
    sleep 0.5
  done
  local main_pid
  main_pid=$(systemctl show shelley.service -p MainPID --value 2>/dev/null || echo 0)
  for _ in $(seq 1 20); do
    [[ -z $main_pid || $main_pid == 0 || ! -d /proc/$main_pid ]] && break
    sleep 0.5
  done
  if [[ -f $HOME/.config/shelley/shelley.db ]]; then
    db_backup="$backup_dir/shelley.db.prior"
    if command -v python3 >/dev/null 2>&1; then
      python3 - "$HOME/.config/shelley/shelley.db" "$db_backup" <<'PY'
import sqlite3, sys
src, dst = sys.argv[1:]
a = sqlite3.connect(src)
b = sqlite3.connect(dst)
a.backup(b)
assert b.execute("pragma integrity_check").fetchone()[0] == "ok"
b.close(); a.close()
PY
    else
      cp -a "$HOME/.config/shelley/shelley.db" "$db_backup"
    fi
    chmod 600 "$db_backup"
  fi

  rollback_shelley() {
    echo "provision-iv: Shelley health check failed; restoring prior binary" >&2
    if [[ -x $backup_dir/shelley.prior ]]; then
      sudo install -o root -g root -m 0755 "$backup_dir/shelley.prior" /usr/local/bin/shelley.rollback-new
      sudo mv /usr/local/bin/shelley.rollback-new /usr/local/bin/shelley
      sudo systemctl start shelley.socket 2>/dev/null || true
      sudo systemctl restart shelley.service || true
    fi
  }
  trap rollback_shelley ERR

  sudo install -o root -g root -m 0755 "$TMP/shelley" /usr/local/bin/shelley.new
  sudo mv /usr/local/bin/shelley.new /usr/local/bin/shelley
  sudo mkdir -p /etc/systemd/system/shelley.service.d
  printf '%s\n' '[Service]' 'Environment=SHELLEY_SKIP_VERSION_CHECK=true' \
    | sudo tee /etc/systemd/system/shelley.service.d/10-iv-managed.conf >/dev/null
  sudo systemctl daemon-reload
  # Socket back first, so an activation that races the service start reaches the
  # NEW binary, which now carries the drop-in that disables self-upgrade.
  sudo systemctl start shelley.socket 2>/dev/null || true
  sudo systemctl start shelley.service

  local healthy=false
  for _ in $(seq 1 20); do
    if sudo systemctl is-active --quiet shelley.service \
        && [[ $(shelley_version) == "$SHELLEY_VERSION" ]] \
        && [[ $(shelley_commit) == "$SHELLEY_COMMIT" ]]; then
      healthy=true
      break
    fi
    sleep 1
  done
  [[ $healthy == true ]]
  if [[ -S $HOME/.config/shelley/shelley.sock ]]; then
    curl -fsS -H 'X-Exedev-Userid: iv-provision-health' \
      --unix-socket "$HOME/.config/shelley/shelley.sock" \
      http://localhost/api/conversations >/dev/null

    # Compare the SERVING version against the pin, not just the binary on disk.
    # The checks above ask `shelley version`, which executes the file at
    # /usr/local/bin/shelley -- so they pass even when the running process is a
    # different, older build (exactly the kgl-songs failure). Ask the socket what
    # is actually answering.
    local serving
    serving=$(curl -fsS -H 'X-Exedev-Userid: iv-provision-health' \
      --unix-socket "$HOME/.config/shelley/shelley.sock" \
      http://localhost/version 2>/dev/null | jq -r '.version // empty' || true)
    if [[ -n $serving && $serving != "$SHELLEY_VERSION" ]]; then
      echo "provision-iv: Shelley on disk is $SHELLEY_VERSION but the socket is serving $serving" >&2
      false
    fi
  fi
  trap - ERR
  printf '%s\n' "$backup_dir" > "$HOME/.local/state/iv-provision/shelley/current"
}

install_apex() {
  local actual
  actual=$(apex_version)
  echo "== Apex $APEX_VERSION ($APEX_ASSET_ARCH; installed: ${actual:-missing}) =="
  [[ $actual == "$APEX_VERSION" ]] && return
  download_verified \
    "https://github.com/ApexMarkdown/apex/releases/download/v${APEX_VERSION}/apex-${APEX_VERSION}-linux-${APEX_ASSET_ARCH}.tar.gz" \
    "$APEX_SHA256" "$TMP/apex.tar.gz"
  mkdir -p "$TMP/apex"
  tar -xzf "$TMP/apex.tar.gz" -C "$TMP/apex"
  sudo install -m 0755 \
    "$TMP/apex/apex-${APEX_VERSION}-linux-${APEX_ASSET_ARCH}/apex" \
    /usr/local/bin/apex
  [[ $(apex_version) == "$APEX_VERSION" ]]
}

# Tailscale. Installed here rather than in the base image because it releases
# frequently and exe.dev fixes a VM's image at creation: in the image, every bump
# would be a fleet recreate; here it is a re-provision.
#
# Installed from Tailscale's own signed apt repository rather than
# the vendor's pipe-to-shell install script (what the personal dotfiles used, and
# the reason a fleet VM could not join the tailnet without them). The
# repo gives dpkg-managed upgrades, a signed index, and `iv-apt-upgrade.timer`
# picks up security updates for free -- none of which piping a script provides.
# No version pin: an out-of-date tailscaled loses tailnet connectivity, which is
# worse than the drift a pin would prevent, and the client is not part of the
# reproducible-build surface the way duckdb/apex/shelley are.
install_tailscale() {
  local actual
  actual=$(tailscale_version)
  echo "== Tailscale (installed: ${actual:-missing}) =="
  if ! command -v tailscale >/dev/null 2>&1; then
    if [[ ! -f /usr/share/keyrings/tailscale-archive-keyring.gpg ]]; then
      local codename
      codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
      curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.noarmor.gpg" \
        | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
      printf 'deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu %s main\n' \
        "$codename" | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
    fi
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tailscale
  fi

  # The daemon must be running before `join-tailnet` can authenticate. Enabling
  # it does NOT join the tailnet or touch state: membership stays an explicit
  # decision (see tailnet.md), this only makes the join possible.
  sudo systemctl enable --now tailscaled

  # Ensure Tailscale SSH on a node that is already up. kgl-songs joined without
  # --ssh and then refused connections with `Permission denied (publickey)`
  # despite correct tags, because Tailscale was not brokering auth at all.
  # `set --ssh` is non-disruptive and needs no re-auth; on a node that has never
  # joined this is skipped, and `join-tailnet` passes --ssh itself.
  #
  # Read the LOCAL pref (`tailscale debug prefs` -> RunSSH), not sshHostKeys from
  # `tailscale status --json`: sshHostKeys is what a *peer* advertises and is
  # absent from .Self entirely, so testing it here always reports "off" and
  # re-runs set --ssh on every provision (measured on iv-foundry-stage2, whose
  # RunSSH was already true). sshHostKeys remains the right check when
  # diagnosing a *remote* node from another machine.
  if tailscale status >/dev/null 2>&1; then
    local run_ssh
    run_ssh=$(tailscale debug prefs 2>/dev/null | jq -r '.RunSSH // false' 2>/dev/null || echo false)
    if [[ $run_ssh != true ]]; then
      echo "Tailscale SSH disabled (RunSSH=$run_ssh); enabling with 'tailscale set --ssh'"
      sudo tailscale set --ssh || true
    fi
    return
  fi

  # Not joined. Join automatically IF the api-tailscale integration is attached.
  #
  # The attachment is the consent signal, and it is a good one: exe.dev injects the
  # Tailscale OAuth credential at the network edge, so the proxy is reachable only
  # from a VM the control plane deliberately attached it to. Least authority means
  # it is normally attached to nothing -- you attach it, provision, and detach.
  # Nothing is baked in, no credential touches the VM, and an unattached VM simply
  # stays off the tailnet. That satisfies what tailnet.md wanted from "on-demand
  # join" without making a human hand-run an OAuth dance.
  #
  # This is what the personal dotfiles install.sh has always done. Moving the
  # tailscale *install* here in 3.0.x without the *join* silently converted a
  # one-command bring-up into a manual 12-line procedure -- a regression nobody
  # asked for, hidden because every existing VM had already joined via dotfiles.
  #
  # Set IV_NO_TAILNET=1 to skip even when the integration is attached.
  if [[ ${IV_NO_TAILNET:-0} == 1 ]]; then
    echo "  IV_NO_TAILNET=1; not joining the tailnet"
    return
  fi

  local ts_api="https://api.tailscale.com" ts_token ts_key ts_host
  ts_host=$(hostname)
  # The exchange doubles as the reachability probe: an unattached proxy answers
  # with a non-JSON error page, so jq needs its own redirect (in a pipeline the
  # 2>/dev/null binds to curl alone).
  ts_token=$(curl -sL --connect-timeout 2 --max-time 15 -X POST \
    -d "grant_type=client_credentials" \
    https://api-tailscale.int.exe.xyz/api/v2/oauth/token 2>/dev/null \
    | jq -r '.access_token // empty' 2>/dev/null || true)
  if [[ -z $ts_token ]]; then
    echo "  not joined: api-tailscale integration not attached (attach it and re-run to join)"
    return
  fi

  # Remove a stale node with this hostname first, or Tailscale appends -2.
  #
  # This needs devices:core (write) on the backing credential, and it is the ONLY
  # part of provisioning that does -- joining itself needs just auth_keys. If the
  # credential is ever narrowed to auth_keys alone (a reasonable hardening: it
  # removes a tagged VM's ability to delete other people's nodes), the listing
  # 403s, jq yields nothing, the loop body never runs, and the VM joins as
  # <hostname>-1 with no error anywhere. Say so instead, because the symptom
  # otherwise appears days later as a name nobody can explain.
  local did ts_devices ts_devices_code
  ts_devices=$(curl -sL --max-time 15 -w '\n%{http_code}' \
    -H "Authorization: Bearer $ts_token" \
    "$ts_api/api/v2/tailnet/-/devices" 2>/dev/null || true)
  ts_devices_code=$(printf '%s' "$ts_devices" | tail -n1)
  if [[ $ts_devices_code == 403 ]]; then
    echo "  note: credential cannot list devices (devices:core absent); skipping" \
         "stale-node cleanup -- a name collision would join as ${ts_host}-1" >&2
  else
    for did in $(printf '%s' "$ts_devices" | sed '$d' \
        | jq -r --arg h "$ts_host" '.devices[]? | select(.hostname == $h) | .id' 2>/dev/null); do
      curl -sL --max-time 15 -X DELETE -H "Authorization: Bearer $ts_token" \
        "$ts_api/api/v2/device/$did" >/dev/null 2>&1 || true
    done
  fi

  # One-use, preauthorized, tag:dev. Non-ephemeral: an ephemeral node is reaped
  # when it goes offline, which is wrong for a VM that is expected to persist.
  ts_key=$(curl -sL --max-time 15 -X POST -H "Authorization: Bearer $ts_token" \
    -H "Content-Type: application/json" "$ts_api/api/v2/tailnet/-/keys" \
    -d '{"capabilities":{"devices":{"create":{"reusable":false,"ephemeral":false,"preauthorized":true,"tags":["tag:dev"]}}}}' 2>/dev/null \
    | jq -r '.key // empty' 2>/dev/null || true)
  unset ts_token
  if [[ -z $ts_key ]]; then
    echo "  [!] api-tailscale reachable but key generation failed; not joined" >&2
    return
  fi

  # --ssh is not optional: without it a node is reachable only over the exe.dev
  # edge, and `ssh <vm>` fails with Permission denied (publickey) even when tags
  # are correct (kgl-songs, 2026-08-17).
  sudo tailscale up --ssh --accept-dns --accept-routes \
    --hostname="$ts_host" --authkey="$ts_key" \
    && echo "  joined the tailnet as $ts_host (Tailscale SSH enabled)" \
    || echo "  [!] tailscale up failed" >&2
  unset ts_key
}

# Entire CLI: the ACR provider retained by ADR 0014. Absent from this script until
# 2026-08-18, which meant the *primary* authoring-context capture path was
# hand-installed and silently did not survive a VM recreate -- the one gap here
# that loses provenance rather than convenience.
#
# Installed under ~/.local/bin (not /usr/local/bin) to match where the vendor's
# own installer puts it, so a user-run `entire update` does not end up shadowed
# by a root-owned copy earlier on PATH.
#
# No credential is involved: capture works unauthenticated with the git-branch
# checkpoint backend (`entire auth status` reports "Not logged in" on VMs that are
# actively capturing). Telemetry stays off, per ADR 0014.
install_entire() {
  local actual
  actual=$(entire_version)
  echo "== Entire CLI $ENTIRE_VERSION ($DPKG_ARCH; installed: ${actual:-missing}) =="
  if [[ $actual != "$ENTIRE_VERSION" ]]; then
    download_verified \
      "https://github.com/entireio/cli/releases/download/v${ENTIRE_VERSION}/entire_linux_${DPKG_ARCH}.tar.gz" \
      "$ENTIRE_SHA256" "$TMP/entire.tar.gz"
    mkdir -p "$TMP/entire" "$HOME/.local/bin"
    tar -xzf "$TMP/entire.tar.gz" -C "$TMP/entire"
    # git-remote-entire ships in the same tarball and must land beside the CLI:
    # git resolves remote helpers by PATH lookup of git-remote-<transport>, so a
    # missing helper only fails later, at push time, on an entire:// remote.
    install -m 0755 "$TMP/entire/entire" "$HOME/.local/bin/entire"
    [[ ! -f $TMP/entire/git-remote-entire ]] \
      || install -m 0755 "$TMP/entire/git-remote-entire" "$HOME/.local/bin/git-remote-entire"
    [[ $(entire_version) == "$ENTIRE_VERSION" ]]
  fi
}

# entire-agent-shelley: IV's Entire external-agent plugin for Shelley. Public and
# MIT as of 2026-08-18, so this needs no integration, credential, or proxy host --
# the same property that lets this script clone itself from GitHub.
#
# Deliberately does NOT run `entire enable`. That writes .entire/settings.json and
# git hooks into a repository, which is a per-repo governance decision (which
# repositories are approved for capture), not a machine baseline. Provisioning
# installs the mechanism; enrolling a repository stays explicit.
install_entire_plugin() {
  local dest_dir="$HOME/.config/entire/shelley-hooks/bin"
  local dest="$dest_dir/entire-agent-shelley"
  local actual=""
  [[ ! -x $dest ]] || actual=$(sha256sum "$dest" | awk '{print $1}')
  echo "== Entire Shelley plugin $ENTIRE_PLUGIN_VERSION (installed: ${actual:0:12}${actual:+...}) =="
  [[ $actual == "$ENTIRE_PLUGIN_SHA256" ]] && return

  local src="$TMP/eas"
  git clone -q --depth 1 --branch "v${ENTIRE_PLUGIN_VERSION}" \
    https://github.com/kylelundstedt/entire-agent-shelley.git "$src"
  printf '%s  %s\n' "$ENTIRE_PLUGIN_SHA256" "$src/entire-agent-shelley" | sha256sum -c -

  # The upstream install.sh refuses to overwrite an executable it does not own
  # (it keeps a SHA receipt) and needs python3 for that check. Call it when it is
  # usable, so its safety behaviour is preserved rather than reimplemented.
  if command -v python3 >/dev/null 2>&1; then
    ( cd "$src" && ./install.sh >/dev/null )
  else
    mkdir -p "$HOME/.local/bin"
    install -m 0755 "$src/entire-agent-shelley" "$HOME/.local/bin/entire-agent-shelley"
  fi

  # Runtime copy, decoupled from any git checkout: the Shelley hooks exec this
  # path directly, so it must not depend on a clone that may be moved or deleted.
  mkdir -p "$dest_dir"
  install -m 0700 "$src/entire-agent-shelley" "$dest"
  [[ $(sha256sum "$dest" | awk '{print $1}') == "$ENTIRE_PLUGIN_SHA256" ]]
}

# entire-agent-agentsview: the attach-only bridge from AgentsView's normalized
# fleet-observability archive into Entire repository provenance. It can attach
# historical or otherwise uncaptured sessions across agents after review; it is
# not automatic live capture or independent protection against loss of a native
# agent store.
#
# Vendored (vendor/entire-agent-agentsview/) rather than symlinked. It was on
# PATH pointing into a *spike worktree*
# (~/worktrees/iv-docs-fannie-memory/spikes/23-harness/), so it broke if that
# branch's worktree was pruned and did not survive a recreate at all. iv-docs
# stays canonical; the pin here fails provisioning if the vendored copy drifts.
install_entire_agentsview_adapter() {
  local src="$IV_REPO/vendor/entire-agent-agentsview/entire-agent-agentsview"
  local dest="$HOME/.local/bin/entire-agent-agentsview"
  local actual=""
  [[ ! -f $src ]] && { echo "== Entire AgentsView adapter (vendored copy missing; skipped) =="; return; }
  [[ ! -x $dest ]] || actual=$(sha256sum "$dest" | awk '{print $1}')
  echo "== Entire AgentsView adapter (installed: ${actual:0:12}${actual:+...}) =="
  [[ $actual == "$ENTIRE_AGENTSVIEW_SHA256" ]] && return
  printf '%s  %s\n' "$ENTIRE_AGENTSVIEW_SHA256" "$src" | sha256sum -c -
  mkdir -p "$HOME/.local/bin"
  # Replace a symlink into a checkout with a real file.
  [[ ! -L $dest ]] || rm -f "$dest"
  install -m 0755 "$src" "$dest"
}

# uv. Not merely a convenience: ~/.local/bin/python3 on these VMs is uv-managed,
# and entire-agent-shelley's launcher resolves ENTIRE_SHELLEY_PYTHON, then
# ~/.local/bin/python3, then python3 on PATH -- precisely because the minimal base
# has no system interpreter and Shelley's service PATH excludes user paths. The
# ACR capture path therefore depends on this.
install_uv() {
  local actual
  actual=$(uv_version)
  echo "== uv $UV_VERSION ($UV_ASSET_ARCH; installed: ${actual:-missing}) =="
  [[ $actual == "$UV_VERSION" ]] && return
  local dir="uv-${UV_ASSET_ARCH}-unknown-linux-gnu"
  download_verified \
    "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${dir}.tar.gz" \
    "$UV_SHA256" "$TMP/uv.tar.gz"
  mkdir -p "$TMP/uv" "$HOME/.local/bin"
  tar -xzf "$TMP/uv.tar.gz" -C "$TMP/uv"
  install -m 0755 "$TMP/uv/$dir/uv" "$HOME/.local/bin/uv"
  install -m 0755 "$TMP/uv/$dir/uvx" "$HOME/.local/bin/uvx"
  [[ $(uv_version) == "$UV_VERSION" ]]
}

# A python3 interpreter, via uv. The minimal base has none, and several things
# that matter degrade SILENTLY without one rather than failing loudly:
#
#   - entire-agent-shelley execs ENTIRE_SHELLEY_PYTHON, then ~/.local/bin/python3,
#     then python3 on PATH. With none of them, the ACR capture path is dead while
#     Shelley's hooks still exit 0, so provenance simply stops being recorded.
#   - install_shelley() uses SQLite's backup API through python3 for a consistent
#     database copy, falling back to a plain file copy.
#   - tests/smoke-provision.sh line 42 generates its long-line Apex regression
#     fixture with python3 and dies without it (observed on the iv-provision VM,
#     2026-08-18: the whole smoke suite aborted at that line).
#
# This was previously supplied by the personal dotfiles overlay, which is exactly
# the kind of hidden dependency the 3.0.x decoupling exists to remove.
#
# Cheap: uv already downloads a managed CPython for its own tools, so --default
# mostly adds the python/python3 shims to ~/.local/bin.
install_python() {
  local actual
  actual=$("$HOME/.local/bin/python3" --version 2>/dev/null | awk '{print $2}' || true)
  echo "== python3 (uv-managed; installed: ${actual:-missing}) =="
  [[ -n $actual ]] && return
  "$HOME/.local/bin/uv" python install --default
  [[ -x $HOME/.local/bin/python3 ]]
}

# Claude Code manages its own layout: the real binary lives at
# ~/.local/share/claude/versions/<version> with ~/.local/bin/claude a symlink to
# it, and its self-update adds versions there and repoints the link. Installing a
# plain file over the symlink would work but is wrong twice over: it strands the
# 263 MB versioned copy as orphaned bytes (exactly the shadowed-duplicate waste
# that keeps agents out of the base image) and leaves self-update managing a
# directory nothing points at. So mirror the native layout instead.
# The claude and codex pins are FLOORS, not exact versions.
#
# Both agents self-update, and unlike Shelley there is no IV requirement for a
# specific build -- the pin exists to guarantee a known-good minimum on a fresh VM,
# not to hold a particular version. Treating it as an exact match made
# re-provisioning *downgrade* a working agent: observed on iv-provision 2026-08-18,
# where Claude Code had self-updated to 2.1.235 (then the latest) and provisioning
# put 2.1.220 back, discarding upstream fixes for no benefit and guaranteeing the
# next self-update would immediately undo it.
#
# The version-pinned tools that carry reproducibility -- duckdb, apex, tigris and
# friends -- stay exact matches, and so does Shelley, where the exact commit is the
# whole point.
install_claude_code() {
  local actual best
  actual=$(claude_code_version)
  best=$(claude_code_version_highest)
  echo "== Claude Code >=$CLAUDE_CODE_VERSION ($CLAUDE_CODE_ASSET_ARCH; installed: ${actual:-missing}) =="
  if version_at_least "$best" "$CLAUDE_CODE_VERSION"; then
    [[ $best == "$CLAUDE_CODE_VERSION" ]] || echo "  keeping newer self-updated $best (pin is a floor)"
    return
  fi
  download_verified \
    "https://github.com/anthropics/claude-code/releases/download/v${CLAUDE_CODE_VERSION}/claude-linux-${CLAUDE_CODE_ASSET_ARCH}.tar.gz" \
    "$CLAUDE_CODE_SHA256" "$TMP/claude.tar.gz"
  mkdir -p "$TMP/claude" "$HOME/.local/bin" "$HOME/.local/share/claude/versions"
  tar -xzf "$TMP/claude.tar.gz" -C "$TMP/claude"
  install -m 0755 "$TMP/claude/claude" \
    "$HOME/.local/share/claude/versions/$CLAUDE_CODE_VERSION"
  ln -sfn "$HOME/.local/share/claude/versions/$CLAUDE_CODE_VERSION" \
    "$HOME/.local/bin/claude"
  [[ $(claude_code_version) == "$CLAUDE_CODE_VERSION" ]]
}

# Floor, not an exact version -- see install_claude_code.
install_codex() {
  local actual best
  actual=$(codex_version)
  best=$(codex_version_highest)
  echo "== Codex >=$CODEX_VERSION ($CODEX_ASSET_ARCH; installed: ${actual:-missing}) =="
  if version_at_least "$best" "$CODEX_VERSION"; then
    [[ $best == "$CODEX_VERSION" ]] || echo "  keeping newer self-updated $best (pin is a floor)"
    return
  fi
  # musl build: static, so it does not care what libc the base image ships.
  download_verified \
    "https://github.com/openai/codex/releases/download/rust-v${CODEX_VERSION}/codex-${CODEX_ASSET_ARCH}-unknown-linux-musl.tar.gz" \
    "$CODEX_SHA256" "$TMP/codex.tar.gz"
  mkdir -p "$TMP/codex" "$HOME/.local/bin"
  tar -xzf "$TMP/codex.tar.gz" -C "$TMP/codex"
  install -m 0755 "$TMP/codex/codex-${CODEX_ASSET_ARCH}-unknown-linux-musl" "$HOME/.local/bin/codex"
  [[ $(codex_version) == "$CODEX_VERSION" ]]
}

remove_legacy_quarto
install_tailscale
install_uv
install_python
install_claude_code
install_codex
install_entire
install_entire_plugin
install_entire_agentsview_adapter
install_duckdb
install_tigris
install_herdr
install_agentsview
install_shelley
install_apex

# The python3 tools among these are installed to /usr/local/bin -- on every
# PATH, including root's and systemd's -- but ship `#!/usr/bin/env python3`,
# which resolves against the CALLER's PATH. The only interpreter on these VMs is
# ~/.local/bin/python3 (uv-managed; the minimal base has no system python), so a
# system-PATH tool depended on a user-PATH interpreter.
#
# That gap is not theoretical. `ssh vm 'provision-docsite ~/repo'` failed with
#
#     /usr/bin/env: 'python3': No such file or directory
#
# on a fully-provisioned VM, because a non-interactive shell never reaches the
# PATH export in Ubuntu's skel .bashrc (fixed in exeslim; older images keep the
# bug until recreated). The same gap applies to any system-context caller --
# systemd units, cron, `sudo` with secure_path -- none of which have
# ~/.local/bin regardless of that fix.
#
# So bake the absolute interpreter in at install time. The repo keeps the
# portable `env` shebang for editing and for running from a checkout; the
# INSTALLED copy is pinned to the interpreter provisioning just guaranteed. This
# matches how entire-agent-shelley's launcher already resolves python (see
# install_python), rather than inventing a second convention.
echo "== doc-site and cloud helpers =="
py="$HOME/.local/bin/python3"
[[ -x $py ]] || { echo "provision: no interpreter at $py" >&2; exit 1; }
for tool in render-site render-md-site provision-docsite gen-llms-txt shot install-cloud-cli; do
  src="$IV_REPO/bin/$tool"
  if [[ $(head -c 2 "$src") == '#!' ]] && head -1 "$src" | grep -q 'env python3$'; then
    tmp="$TMP/$tool"
    { printf '#!%s\n' "$py"; tail -n +2 "$src"; } >"$tmp"
    sudo install -m 0755 "$tmp" "/usr/local/bin/$tool"
  else
    sudo install -m 0755 "$src" "/usr/local/bin/$tool"
  fi
done
sudo install -m 0755 "$IV_REPO/bin/agentsview-source-daemon" /usr/local/bin/agentsview-source-daemon

# Install the source-daemon template unconditionally, but activate only after
# the separate network-identity and local-secret prerequisites are explicit.
# `systemctl --user` over a non-interactive SSH needs to be told where the user
# bus is. exeuntu sets DBUS_SESSION_BUS_ADDRESS as an image ENV so it is
# inherited and this Just Works; a minimal base need not, and then EVERY
# `systemctl --user` call fails with "Failed to connect to bus: No medium
# found". Because the disable branch below had a guarded `disable` followed by
# an UNGUARDED `daemon-reload`, `set -e` aborted the whole provision there —
# after the binaries were installed but before the agent config, MCP servers,
# skills and the lock file. A partial provision that reported success only in
# the exit code, which nothing was reading. Found 2026-07-29 on an exeslim-dev
# canary; latent on any first provision where the user manager has no bus in
# the environment.
#
# uctl: supply the address if it is missing, and never let a user-bus problem
# take down a provision run — this whole section is fail-closed by design, so
# failing to disable an already-absent unit must not be fatal.
uctl() {
  local rc=0
  XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
  DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}" \
    systemctl --user "$@" || rc=$?
  if (( rc != 0 )); then
    echo "  note: systemctl --user $1 failed (rc=$rc); user bus unavailable" >&2
  fi
  return 0
}

echo "== AgentsView source service =="
mkdir -p "$HOME/.config/systemd/user"
install -m 0644 "$IV_REPO/systemd/agentsview-source.service" \
  "$HOME/.config/systemd/user/agentsview-source.service"
SOURCE_ENV="$HOME/.config/agentsview/source.env"

# Mint the per-host token if it is absent. It is a self-chosen random secret --
# nothing issues it, nothing validates it beyond matching what the collector was
# told -- so requiring a human to invent one and paste it in was pure ceremony,
# and it made the AgentsView daemon the one part of provisioning that could not
# complete unattended.
#
# Generated ONCE and never rotated: the collector stores this value in its own
# [[remote_hosts]] block, so overwriting it here would silently break remote sync
# on the next provision. Absent means new; present means leave it alone.
#
# Per-host rather than fleet-wide because the token guards READ access to the
# whole normalized archive -- every prompt, response and tool call this VM has
# seen. A shared secret would make one compromised VM a key to the entire fleet's
# history. Uniqueness costs nothing once it is generated rather than typed.
if [[ ! -s $SOURCE_ENV ]]; then
  mkdir -p "$(dirname "$SOURCE_ENV")"
  ( umask 077
    printf 'AGENTSVIEW_AUTH_TOKEN=%s\n' "$(head -c 32 /dev/urandom | base64 | tr -d '\n')" \
      > "$SOURCE_ENV" )
  chmod 600 "$SOURCE_ENV"
  echo "  generated a per-host AgentsView token ($SOURCE_ENV)"
fi

if [[ -s $SOURCE_ENV ]] \
    && grep -qE '^AGENTSVIEW_AUTH_TOKEN=.+$' "$SOURCE_ENV" \
    && tailscale ip -4 >/dev/null 2>&1; then
  chmod 600 "$SOURCE_ENV"

  # Give the *CLI* the same token the daemon requires. The service runs
  # `--require-auth`, but `agentsview projects|health|sync` send no Authorization
  # header, so the authenticated endpoints answer 401 and the CLI reports it as
  #   fatal: ... local daemon owns the SQLite archive but is not responding
  # which reads like database corruption and sends you looking at SQLite. It is
  # a 401. Measured on iv-foundry-stage2 2026-08-18: /api/v1/health returned 401
  # without the token and 200 with it, while /health (unauthenticated) returned
  # 200 the whole time and the daemon was healthy throughout. Every VM running
  # this service has had an unusable CLI since --require-auth was introduced.
  av_token=$(sed -n 's/^AGENTSVIEW_AUTH_TOKEN=//p' "$SOURCE_ENV" | head -1)
  av_config="$HOME/.agentsview/config.toml"
  if [[ -n $av_token ]]; then
    mkdir -p "$HOME/.agentsview"
    touch "$av_config"
    chmod 600 "$av_config"
    if grep -qE '^auth_token[[:space:]]*=' "$av_config"; then
      sed -i "s|^auth_token[[:space:]]*=.*|auth_token = \"$av_token\"|" "$av_config"
    else
      printf 'auth_token = "%s"\n' "$av_token" >> "$av_config"
    fi
  fi

  # Rotate agentsview's debug log. It is unbounded: every Shelley write to
  # shelley.db-wal retriggers a full reprojection and logs it, which reached
  # 10 MB on iv-foundry-stage2 (~15s cadence while an agent is active).
  # copytruncate because the long-lived daemon holds the fd and will not reopen
  # on rename -- a plain rotate would leave it writing to an unlinked inode.
  if command -v logrotate >/dev/null 2>&1; then
    sudo tee /etc/logrotate.d/iv-agentsview >/dev/null <<ROTATE
$HOME/.agentsview/debug.log {
    size 8M
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    su $USER $(id -gn)
}
ROTATE
  fi

  sudo loginctl enable-linger "$USER"
  uctl daemon-reload
  uctl enable --now agentsview-source.service
  echo "AgentsView source enabled (tailnet + per-host token present)"
else
  uctl disable --now agentsview-source.service >/dev/null 2>&1 || true
  uctl daemon-reload
  echo "AgentsView source disabled; requires tailnet reachability and $SOURCE_ENV"
fi

echo "== agent config =="
mkdir -p "$HOME/.agents" "$HOME/.claude" "$HOME/.codex"
install -m 0644 "$IV_REPO/agent/AGENTS.md" "$HOME/.agents/AGENTS.md"
install -m 0755 "$IV_REPO/agent/ssh-guard.sh" "$HOME/.agents/ssh-guard.sh"
# MERGE the team Claude settings rather than overwriting them.
#
# Overwriting silently deleted hooks that a personal dotfiles overlay had spliced
# in -- notably its SessionStart refresh-env hook, whose whole job is keeping
# agent instructions current. The failure is invisible: the hook *script* survives
# at ~/.agents/refresh-env.sh, so nothing looks missing; only the entry that calls
# it is gone. Measured on iv-foundry-stage2 2026-08-18: settings.json mtime equal
# to provisioned_utc to the second, .hooks.SessionStart absent, overlay present.
#
# The upgrade-vm skill mitigated this procedurally ("re-run the overlay after
# provisioning"), which failed in practice -- and cannot self-heal, because a
# refresh hook that lives in the clobbered file is exactly what would have
# restored it.
#
# Merge rules: team keys win (this repo owns DISABLE_NON_ESSENTIAL_MODEL_CALLS and
# the PreToolUse SSH guard), and any hook event the team file does not define is
# kept verbatim. Events the team DOES define are replaced wholesale rather than
# appended, so the guard cannot be duplicated. Without jq, fall back to the old
# overwrite: provisioning must not fail on a minimal box, and jq is present on
# every image we ship.
if command -v jq >/dev/null 2>&1 && [[ -s $HOME/.claude/settings.json ]] \
    && jq -e . "$HOME/.claude/settings.json" >/dev/null 2>&1; then
  jq -s '(.[0]) as $existing | (.[1]) as $team
    | ($existing * $team)
    | .hooks = (($existing.hooks // {}) + ($team.hooks // {}))' \
    "$HOME/.claude/settings.json" "$IV_REPO/agent/settings.json" \
    > "$TMP/claude-settings.json"
  if jq -e . "$TMP/claude-settings.json" >/dev/null 2>&1; then
    install -m 0644 "$TMP/claude-settings.json" "$HOME/.claude/settings.json"
    echo "  merged ~/.claude/settings.json (hook events: $(jq -r '(.hooks // {}) | keys | join(",")' "$HOME/.claude/settings.json"))"
  else
    echo "  [!] settings merge produced invalid JSON; wrote team defaults" >&2
    install -m 0644 "$IV_REPO/agent/settings.json" "$HOME/.claude/settings.json"
  fi
else
  install -m 0644 "$IV_REPO/agent/settings.json" "$HOME/.claude/settings.json"
fi
install -m 0644 "$IV_REPO/agent/codex-config.toml" "$HOME/.codex/config.toml"
ln -sfn ../.agents/AGENTS.md "$HOME/.claude/CLAUDE.md"
ln -sfn ../.agents/AGENTS.md "$HOME/.codex/AGENTS.md"

echo "== MCP servers =="
bash "$IV_REPO/agent/setup-mcp.sh"

echo "== skills (vendored; no node needed) =="
mkdir -p "$HOME/.agents/skills" "$HOME/.claude/skills" "$HOME/.codex/skills"
TEAM_SKILLS="$HOME/.agents/iv-team-skills.list"
NEW_SKILLS="$TMP/team-skills"
mkdir -p "$NEW_SKILLS"
cp -a "$IV_REPO/skills/." "$NEW_SKILLS/"

# TWO sources, deliberately kept apart on disk:
#
#   skills/        VENDORED from provisioning/skills.manifest by vendor-skills.sh,
#                  which `rm -rf`s that directory and repopulates it from
#                  upstream. Nothing hand-written can live there -- it would be
#                  deleted by the next re-vendor, silently, with no diff that
#                  explains why.
#   skills-local/  HAND-WRITTEN, in-tree, reviewed alongside the code they
#                  describe (join-tailnet, upgrade-vm, create-vm).
#                  vendor-skills.sh never touches this path.
#
# Both install identically and both are recorded in the team-skills list, so a
# skill dropped from either source is still cleaned up on the next run.
if [[ -d $IV_REPO/skills-local ]]; then
  cp -a "$IV_REPO/skills-local/." "$NEW_SKILLS/"
fi
find "$NEW_SKILLS" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort > "$TMP/team-skills.list"

if [[ -f $TEAM_SKILLS ]]; then
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    [[ $name =~ ^[A-Za-z0-9._-]+$ && $name != . && $name != .. ]] || {
      echo "provision-iv: unsafe prior skill name: $name" >&2
      exit 1
    }
    rm -rf "$HOME/.agents/skills/$name"
    rm -rf "$HOME/.claude/skills/$name" "$HOME/.codex/skills/$name"
  done < "$TEAM_SKILLS"
fi

while IFS= read -r name; do
  [[ $name =~ ^[A-Za-z0-9._-]+$ && $name != . && $name != .. ]] || {
    echo "provision-iv: unsafe vendored skill name: $name" >&2
    exit 1
  }
  rm -rf "$HOME/.agents/skills/$name"
  cp -a "$NEW_SKILLS/$name" "$HOME/.agents/skills/$name"
  rm -rf "$HOME/.claude/skills/$name" "$HOME/.codex/skills/$name"
  ln -sT "../../.agents/skills/$name" "$HOME/.claude/skills/$name"
  ln -sT "../../.agents/skills/$name" "$HOME/.codex/skills/$name"
done < "$TMP/team-skills.list"
install -m 0644 "$TMP/team-skills.list" "$TEAM_SKILLS"

echo "== ssh config (VM-to-VM short names) =="
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
SSH_CFG="$HOME/.ssh/config"
touch "$SSH_CFG"
chmod 600 "$SSH_CFG"
# Match on tailnet MEMBERSHIP, not on the hostname looking like one.
#
# This block used to read `Host iv-* *.ts.net`, which is a guess about naming
# dressed up as a rule, and the fleet does not obey it: kgl-songs, kgl-thoughts
# and telnyx-vm are tailnet nodes whose names start with neither. Refreshing the
# fleet on 2026-08-19 hit "Host key verification failed" on exactly those three,
# and every documented workaround -- including the upgrade-vm skill's
# `ssh <vm>.exe.xyz` -- routes around the tailnet instead of fixing it.
#
# `tailscale ip -4 %h` answers the question the pattern was trying to ask, in
# ~7 ms against local state: it exits 0 for a peer in this tailnet and non-zero
# for anything else, so exe.dev and the public internet are untouched and keep
# StrictHostKeyChecking's default prompt. If tailscaled is not running the
# command fails and the match simply does not apply -- fails closed, which is the
# right direction for a host-key policy.
#
# Rewritten in place on every provision rather than appended once. The previous
# form could only ever be created, never corrected, so a wrong stanza was
# permanent on an already-provisioned VM and the fix would reach only new ones.
ssh_block=$(cat <<'EOF'
# >>> iv-provision ssh >>>
# VM-to-VM tailnet SSH: accept new host keys, default user exedev.
# Keyed on actual tailnet membership -- fleet names do not share a prefix.
Match exec "tailscale ip -4 %h >/dev/null 2>&1"
  StrictHostKeyChecking accept-new
  User exedev
# <<< iv-provision ssh <<<
EOF
)
if grep -q "# >>> iv-provision ssh >>>" "$SSH_CFG"; then
  if ! diff -q <(sed -n '/# >>> iv-provision ssh >>>/,/# <<< iv-provision ssh <<</p' "$SSH_CFG") \
       <(printf '%s\n' "$ssh_block") >/dev/null; then
    ssh_tmp=$(mktemp)
    awk -v block="$ssh_block" '
      /# >>> iv-provision ssh >>>/ { print block; skip = 1; next }
      /# <<< iv-provision ssh <<</ { skip = 0; next }
      !skip
    ' "$SSH_CFG" > "$ssh_tmp"
    cat "$ssh_tmp" > "$SSH_CFG"
    rm -f "$ssh_tmp"
    echo "  updated the iv-provision ssh block"
  fi
else
  printf '\n%s\n' "$ssh_block" >> "$SSH_CFG"
fi
chmod 600 "$SSH_CFG"

echo "== OS security patching (in-place) =="
# WHY IN-PLACE, not recreate. Recreating a VM was the original patching plan,
# and it is a poor one: a VM built from the current image already carried 3
# pending security updates the next day, because the image is rebuilt weekly
# and a VM freezes whatever build existed the day it was created. Recreate buys
# point-in-time freshness that decays immediately — and pays for it by
# destroying whatever working state the box holds. Patching in place is
# continuous and risks nothing.
#
# OUR OWN TIMER, not apt-daily. Both exeuntu and exeslim mask apt-daily.timer
# and apt-daily-upgrade.timer on purpose: those units hang or fight the
# platform in a container-as-VM. Unmasking them would undo a deliberate
# platform decision, so this ships a separate unit instead.
#
# NOT unattended-upgrades: it is python-based and there is no system python3
# here (uv's lives in ~/.local/bin, not on root's PATH), so installing it would
# pull ~30-50 MB of interpreter into every VM to run three apt commands.
#
# No automatic reboot. The kernel belongs to the host on a container-as-VM, so
# kernel packages are not the point; userspace CVEs are, and those take effect
# on the next process start.
sudo tee /etc/systemd/system/iv-apt-upgrade.service >/dev/null <<'UNIT'
[Unit]
Description=IV: apt update + upgrade (in-place OS patching)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=DEBIAN_FRONTEND=noninteractive
# --force-confold/confdef: never prompt, and never silently replace a config we
# manage. An interactive prompt in a timer unit hangs forever.
ExecStart=/usr/bin/apt-get update -qq
ExecStart=/usr/bin/apt-get -y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef upgrade
ExecStart=/usr/bin/apt-get -y autoremove
UNIT

sudo tee /etc/systemd/system/iv-apt-upgrade.timer >/dev/null <<'UNIT'
[Unit]
Description=IV: daily in-place OS patching

[Timer]
OnCalendar=daily
# Persistent so a VM that was stopped catches up on next boot rather than
# silently skipping its window; randomised so the fleet does not hit the
# mirrors in lockstep.
Persistent=true
RandomizedDelaySec=2h

[Install]
WantedBy=timers.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now iv-apt-upgrade.timer >/dev/null 2>&1 \
  && echo "  iv-apt-upgrade.timer enabled (daily, persistent)" \
  || echo "  [!] could not enable iv-apt-upgrade.timer"

echo "== provenance lockfile =="
LOCK="$HOME/iv-provision.lock"
{
  echo "provisioned_utc=$(date -u +%FT%TZ)"
  echo "provision_repo_sha=$(git -C "$IV_REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "arch=$DPKG_ARCH"
  # These were named exeuntu_* until 2026-08-18, which was actively misleading:
  # IV VMs run ghcr.io/kylelundstedt/exeslim-dev, so the field labelled "exeuntu"
  # had been silently recording an exeslim revision. Record the title and
  # version too, so a lock file says WHICH image, not just which commit.
  echo "base_image_title=$(jq -r '.Labels["org.opencontainers.image.title"] // "unknown"' /exe.dev/etc/image.conf 2>/dev/null || echo unknown)"
  echo "base_image_version=$(jq -r '.Labels["org.opencontainers.image.version"] // "unknown"' /exe.dev/etc/image.conf 2>/dev/null || echo unknown)"
  echo "base_image_revision=$(jq -r '.Labels["org.opencontainers.image.revision"] // "unknown"' /exe.dev/etc/image.conf 2>/dev/null || echo unknown)"
  echo "base_image_created=$(jq -r '.Labels["org.opencontainers.image.created"] // "unknown"' /exe.dev/etc/image.conf 2>/dev/null || echo unknown)"
  echo "shelley_version=$(shelley_version)"
  echo "shelley_tag=$SHELLEY_TAG"
  echo "shelley_commit=$(shelley_commit)"
  echo "shelley_sha256=$(sha256sum /usr/local/bin/shelley 2>/dev/null | awk '{print $1}')"
  echo "duckdb_version=$(duckdb_version)"
  echo "aws_cli_version=$(aws_version)"
  echo "tigris_version=$(tigris_version)"
  echo "rclone_version=$(rclone_version)"
  echo "herdr_version=$(herdr_version)"
  echo "agentsview_version=$(agentsview_version)"
  echo "apex_version=$(apex_version)"
  echo "tailscale_version=$(tailscale_version)"
  echo "entire_version=$(entire_version)"
  echo "entire_plugin_version=$(entire_plugin_version)"
  echo "uv_version=$(uv_version)"
  echo "python3_version=$("$HOME/.local/bin/python3" --version 2>/dev/null | awk '{print $2}')"
  echo "claude_code_version=$(claude_code_version)"
  echo "codex_version=$(codex_version)"
  echo "skills_count=$(wc -l < "$TEAM_SKILLS" | tr -d ' ')"
} | tee "$LOCK"

echo "== IV layer provisioned (see $LOCK) =="
