#!/usr/bin/env bash
# Read-only package validators plus a real, fully isolated file:// APT fixture.
# No host package installation, systemd/Tailscale calls, or network access.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
script="$repo/bin/install-rex"
bash -n "$script"
if command -v shellcheck >/dev/null; then shellcheck -S error "$script" "$0"; fi
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
# shellcheck source=../bin/install-rex
source "$script"
rex_policy="$tmp/release.json"
cp "$repo/provisioning/rex/release.json" "$rex_policy"
passed=0
ok() { ( "$@" ) > "$tmp/output" 2>&1 || { cat "$tmp/output" >&2; exit 1; }; passed=$((passed+1)); }
refused() {
  local message=$1; shift
  if ( "$@" ) > "$tmp/output" 2>&1; then echo "FAIL accepted: $*" >&2; exit 1; fi
  grep -Fq -- "$message" "$tmp/output" || { cat "$tmp/output" >&2; exit 1; }
  passed=$((passed+1))
}
# Mock only local package inspection. Neither platform/owner/network is needed.
dpkg-query() {
  if [[ ${test_absent:-true} == true ]]; then return 1; fi
  printf '%s\t%s\t%s\n' "${test_state:-hi }" "${test_version:-$version}" "${test_maintainer:-Superlogical <hello@superlogical.com>}"
}
dpkg() {
  case "$*" in
    --print-architecture) echo "${test_arch:-amd64}" ;;
    '--verify rex') printf '%s\n' "${test_verify:-}"; return "${test_verify_status:-0}" ;;
    *) echo 'Unexpected package mutation' >&2; return 99 ;;
  esac
}
binary_version() { echo "${test_binary_version:-$version}"; }
curl() { echo 'Forbidden download during plan' >&2; return 99; }
systemctl() { echo 'Forbidden service operation' >&2; return 99; }
tailscale() { echo 'Forbidden network operation' >&2; return 99; }
ok main
ok main --plan
for arch in amd64 arm64; do test_arch=$arch ok main --plan; done
refused 'remote access is separate' main --owner owner@example.test
refused 'remote access is separate' main --latest
if (( EUID != 0 )); then refused '--apply requires sudo' main --apply; fi
load_policy
test_absent=false test_version=9.9-owner-build refused 'existing Rex 9.9-owner-build is preserved' main
# Approval affects the plan only; it does not execute upstream or touch a server.
test_absent=false test_version=9.9-owner-build ok main --allow-version-change --plan
test_absent=false test_maintainer='Debian Perl Group' refused 'unrelated rex package' main
test_absent=false test_state='iU ' refused 'not fully installed' main
test_absent=false test_state='ii ' ok main
test_absent=false test_state='hi ' ok main
test_absent=false ok verify_installed
test_absent=false test_verify='??5?????? c /etc/rex/accounts.jsonc' test_verify_status=1 ok verify_installed
test_absent=false test_verify='??5?????? /usr/bin/rex' test_verify_status=1 refused 'executable differs' verify_installed
test_absent=false test_verify_status=2 refused 'cannot verify installed' verify_installed
test_absent=false test_binary_version=other refused 'version mismatch' verify_installed
jq '.installer.url="https://example.invalid/install.sh"' "$rex_policy" > "$tmp/bad.json"
rex_policy="$tmp/bad.json" refused 'invalid installer/version policy' load_policy
jq '.installer.sha256="not-a-checksum"' "$repo/provisioning/rex/release.json" > "$tmp/bad.json"
rex_policy="$tmp/bad.json" refused 'invalid installer/version policy' load_policy
jq '.channel="floating"' "$repo/provisioning/rex/release.json" > "$tmp/bad.json"
rex_policy="$tmp/bad.json" refused 'invalid installer/version policy' load_policy

# Real APT resolution, with ALL state/config/log paths isolated and host hooks
# disabled before APT reads configuration. The only repository is local fixtures.
root="$tmp/apt"
mkdir -p "$root"/{repo,etc/empty,etc/prefs,state/lists/partial,cache/archives/partial,log}
: > "$root/state/status"
for v in 1.0-fixture 99.0-unapproved 1.14.3-1; do
  printf 'Package: rex\nVersion: %s\nArchitecture: all\nMaintainer: Superlogical <test@example.test>\nFilename: rex.deb\nSize: 1\nDescription: offline fixture\n\n' "$v" >> "$root/repo/Packages"
done
# trusted=yes is ONLY for synthetic local test metadata, never production.
printf 'deb [trusted=yes] file:%s ./\n' "$root/repo" > "$root/etc/sources.list"
cat > "$root/apt.conf" <<CFG
Dir::Etc "$root/etc";
Dir::Etc::parts "$root/etc/empty";
Dir::Etc::main "$root/etc/empty-main.conf";
Dir::Etc::sourcelist "$root/etc/sources.list";
Dir::Etc::sourceparts "$root/etc/empty";
Dir::Etc::preferences "$root/etc/preferences";
Dir::Etc::preferencesparts "$root/etc/prefs";
Dir::State "$root/state";
Dir::State::status "$root/state/status";
Dir::State::lists "$root/state/lists";
Dir::Cache "$root/cache";
Dir::Cache::archives "$root/cache/archives";
Dir::Log "$root/log";
APT::Sandbox::User "$(id -un)";
Acquire::Languages "none";
CFG
APT_CONFIG="$root/apt.conf" apt-config dump > "$tmp/effective.conf"
! grep -q 'Post-Invoke' "$tmp/effective.conf"
LC_ALL=C APT_CONFIG="$root/apt.conf" apt-get update > "$tmp/local-update.log" 2>&1
# This models the origin-priority file written by upstream, separately from
# our command-scoped primary preferences.
printf 'Package: rex\nPin: origin ""\nPin-Priority: 1001\n' > "$root/etc/prefs/rex"
version=1.0-fixture
write_preferences > "$root/etc/preferences"
candidate=$(LC_ALL=C APT_CONFIG="$root/apt.conf" apt-cache policy rex | awk '/Candidate:/ {print $2}')
[[ $candidate == 1.0-fixture ]]
passed=$((passed+1))
version=0.0-missing
write_preferences > "$root/etc/preferences"
candidate=$(LC_ALL=C APT_CONFIG="$root/apt.conf" apt-cache policy rex | awk '/Candidate:/ {print $2}')
[[ $candidate == '(none)' ]]
passed=$((passed+1))

# Refactor does NOT flip defaults. Explicit opt-in can install a package without
# a tailnet/owner profile; an existing explicit owner profile still configures it.
gate=$(sed -n '/^if \[\[ ${IV_INSTALL_REX:-0} == 1 \]\]; then$/,/^fi$/p' "$repo/provision-iv.sh")
[[ -n $gate ]]
sudo() { printf '%s\n' "$*" >> "$tmp/calls"; }
IV_REPO=$repo
unset IV_INSTALL_REX IV_REX_OWNER IV_REX_ALLOW_TAG
eval "$gate"
IV_INSTALL_REX=0 eval "$gate"
[[ ! -e $tmp/calls ]]
IV_INSTALL_REX=1 eval "$gate"
[[ $(wc -l < "$tmp/calls") == 1 ]]
grep -qxF "$repo/bin/install-rex --apply" "$tmp/calls"
: > "$tmp/calls"
IV_INSTALL_REX=1 IV_REX_OWNER=owner@example.test IV_REX_ALLOW_TAG=tag:test-client eval "$gate"
[[ $(wc -l < "$tmp/calls") == 2 ]]
grep -qxF "$repo/bin/configure-rex --apply --owner owner@example.test --allow-tag tag:test-client" "$tmp/calls"
printf 'install-rex tests passed (%s validators; real isolated APT exact/missing-version checks; defaults unchanged)\n' "$passed"
