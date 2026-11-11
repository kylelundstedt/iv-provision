#!/usr/bin/env bash
# Offline validators only: never invokes --apply, SSH, Rex, or a real daemon.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
script="$repo/bin/install-rex"
bash -n "$script"
if command -v shellcheck >/dev/null; then
  shellcheck -S error "$script" "$0"
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# shellcheck source=../bin/install-rex
source "$script"
rex_root="$tmp/root"
mkdir -p "$rex_root"/{etc,run/systemd/system,proc,usr/bin}
printf 'ID=ubuntu\nVERSION_ID=24.04\n' > "$rex_root/etc/os-release"
cat > "$tmp/status.json" <<'EOF'
{"BackendState":"Running","Self":{"Tags":["tag:dev"],"DNSName":"fixture.test.ts.net."},"CertDomains":["fixture.test.ts.net"]}
EOF
printf '{}\n' > "$tmp/serve.json"
mutation_log="$tmp/unexpected-mutations"

# Whitelist read-only invocations: a new mutating command fails, not a no-op.
dpkg() {
  [[ $* == --print-architecture ]] || { echo dpkg >> "$mutation_log"; return 99; }
  echo "${test_arch:-amd64}"
}
getent() { [[ $* == 'passwd exedev' ]]; echo "exedev:x:${test_uid:-1000}:1000::/home/exedev:/bin/bash"; }
tailscale() {
  case "$*" in
    'status --json') cat "$tmp/status.json" ;;
    'serve status --json') cat "$tmp/serve.json" ;;
    *) echo tailscale >> "$mutation_log"; return 99 ;;
  esac
}
dpkg-query() {
  [[ $* == '-W -f=${db:Status-Abbrev}\t${Version}\t${Architecture} rex' ]] ||
    { echo dpkg-query >> "$mutation_log"; return 99; }
  if [[ ${test_query_error:-false} == true ]]; then return 2; fi
  if [[ -n ${test_installed:-} ]]; then printf '%s\t%s\tamd64' "${test_package_state:-ii }" "$test_installed"; else return 1; fi
}
systemctl() {
  [[ $1 == show && $3 == -p && $5 == --value ]] ||
    { echo systemctl >> "$mutation_log"; return 99; }
  if [[ -f $tmp/$2.$4 ]]; then cat "$tmp/$2.$4"; return; fi
  case "$4" in
    ActiveState) echo inactive ;;
    MainPID) echo 0 ;;
    FragmentPath|DropInPaths) echo '' ;;
    KillMode) echo process ;;
    RuntimeDirectoryPreserve) echo yes ;;
    *) return 99 ;;
  esac
}
ss() { [[ $* == '-Hlnpt sport = :7297' ]]; printf '%s' "${test_listeners:-}"; }
curl() { echo curl >> "$mutation_log"; return 99; }
sudo() { echo sudo >> "$mutation_log"; return 99; }
apt-mark() { echo apt-mark >> "$mutation_log"; return 99; }

passed=0
ok() {
  ( "$@" ) > "$tmp/output" 2>&1 || { cat "$tmp/output" >&2; echo "FAIL: $*" >&2; exit 1; }
  passed=$((passed + 1))
}
refused() {
  local expected=$1
  shift
  if ( "$@" ) > "$tmp/output" 2>&1; then echo "FAIL: accepted $*" >&2; exit 1; fi
  grep -Fq -- "$expected" "$tmp/output" || { cat "$tmp/output" >&2; echo "FAIL: expected $expected" >&2; exit 1; }
  passed=$((passed + 1))
}
fixture_snapshot() {
  find "$rex_root" -type f -exec sha256sum {} + | sort
  find "$rex_root" -printf '%p %m %u %l\n' | sort
}
generate_policy owner@example.test tag:test-client
printf '%s\n' "$approved_policy" > "$tmp/approved.json"
plan() { main --owner owner@example.test --allow-tag tag:test-client "$@"; }
fixture_snapshot > "$tmp/before"
ok plan
grep -q 'ARTIFACT PENDING' "$tmp/output"
grep -q 'PLAN ONLY' "$tmp/output"
fixture_snapshot > "$tmp/after"
cmp "$tmp/before" "$tmp/after"
ok plan --plan
refused 'explicit --owner LOGIN is required' main --plan
refused '--owner requires one LOGIN' main --owner
refused '--allow-tag requires tag:NAME' main --owner owner@example.test --allow-tag
refused 'explicit person login' main --owner 'tag:test-client'
refused 'explicit person login' main --owner '*@example.test'
refused 'explicit tag:NAME' plan --allow-tag 'tag:*'
refused 'explicit tag:NAME' plan --allow-tag 'anonymous'
ok main --owner owner@example.test
generate_policy owner@example.test
jq -e '. == {"version":1,"accounts":{"exedev":{"principals":["tailscale:owner@example.test"]}},"defaults":{"tailscale:owner@example.test":"exedev"}}' <<<"$approved_policy" >/dev/null
generate_policy owner@example.test tag:test-client tag:second-client tag:test-client
jq -e '.accounts.exedev.principals == ["tailscale:owner@example.test","tailscale:tag:second-client","tailscale:tag:test-client"]' <<<"$approved_policy" >/dev/null
generate_policy owner@example.test tag:test-client
refused 'unknown argument' plan --latest
test_arch=arm64 refused 'only on amd64' plan
test_uid=0 refused 'exedev must be UID 1000' plan
sed -i 's/24.04/22.04/' "$rex_root/etc/os-release"
refused 'only on Ubuntu 24.04' plan
sed -i 's/22.04/24.04/' "$rex_root/etc/os-release"
cp "$tmp/status.json" "$tmp/good-status"
jq '.Self.Tags += ["tag:pilot"]' "$tmp/good-status" > "$tmp/status.json"
ok plan
for tags in '[]' '["tag:prod"]' '["tag:dev","tag:prod"]'; do
  jq --argjson tags "$tags" '.Self.Tags=$tags' "$tmp/good-status" > "$tmp/status.json"
  refused 'requires tag:dev, no tag:prod' plan
done
jq '.CertDomains=[]' "$tmp/good-status" > "$tmp/status.json"
refused 'already-enabled tailnet HTTPS' plan
cp "$tmp/good-status" "$tmp/status.json"

# Unrelated private background ports are retained; no reset/set-config is used.
cat > "$tmp/serve.json" <<'EOF'
{"TCP":{"8443":{"HTTPS":true}},"Web":{"fixture.test.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://localhost:8080"}}}}}
EOF
ok plan
cat > "$tmp/good-serve" <<'EOF'
{"TCP":{"443":{"HTTPS":true}},"Web":{"fixture.test.ts.net:443":{"Handlers":{"/":{"Proxy":"unix:/run/rex/serve.sock"}}}},"AllowFunnel":{"fixture.test.ts.net:443":false}}
EOF
cp "$tmp/good-serve" "$tmp/serve.json"
ok plan
jq '.Web["fixture.test.ts.net:443"].Handlers["/"].Proxy="http://localhost:9999"' "$tmp/good-serve" > "$tmp/serve.json"
refused 'Serve conflict' plan
jq '.Web["fixture.test.ts.net:443"].Handlers["/other"]={"Text":"foreign"}' "$tmp/good-serve" > "$tmp/serve.json"
refused 'Serve conflict' plan
jq '.AllowFunnel["fixture.test.ts.net:443"]=true' "$tmp/good-serve" > "$tmp/serve.json"
refused 'Serve conflict' plan
jq '.TCP["7297"]={"HTTPS":true}' "$tmp/good-serve" > "$tmp/serve.json"
refused 'Serve conflict' plan
echo '{"Foreground":{"123":{}}}' > "$tmp/serve.json"
refused 'Serve conflict' plan
echo '{}' > "$tmp/serve.json"

for unit in rex.service rex.socket; do
  echo active > "$tmp/$unit.ActiveState"
  refused "shared $unit is active" plan
  rm "$tmp/$unit.ActiveState"
done
echo '/etc/systemd/system/rex-login-server.service' > "$tmp/rex-login-server.service.FragmentPath"
refused 'foreign/masked unit' plan
rm "$tmp/rex-login-server.service.FragmentPath"
echo '/etc/systemd/system/rex-login-server.service.d/foreign.conf' > "$tmp/rex-login-server.service.DropInPaths"
refused 'foreign login service drop-ins' plan
rm "$tmp/rex-login-server.service.DropInPaths"
test_listeners='LISTEN 0 4096 *:7297 *:* users:(("other",pid=17,fd=3))' refused 'listener on 7297' plan

mkdir -p "$rex_root/etc/rex"
echo '{"version":1,"accounts":{"root":{"principals":["anonymous"]}}}' > "$rex_root/etc/rex/accounts.jsonc"
refused 'foreign Rex account policy' plan
cp "$tmp/approved.json" "$rex_root/etc/rex/accounts.jsonc"
ok plan
refused 'foreign Rex account policy' main --owner other@example.test --allow-tag tag:test-client
refused 'foreign Rex account policy' main --owner owner@example.test
echo active > "$tmp/rex-login-server.service.ActiveState"
refused 'active foreign Rex login' plan
mkdir -p "$rex_root/etc/systemd/system/rex-login-server.service.d"
cp "$repo/provisioning/rex/10-tailnet.conf" "$rex_root/etc/systemd/system/rex-login-server.service.d/"
mkdir -p "$rex_root/proc/123"
validate_bundle
printf '%s\0' $expected_command > "$rex_root/proc/123/cmdline"
echo 123 > "$tmp/rex-login-server.service.MainPID"
ok plan
echo control-group > "$tmp/rex-login-server.service.KillMode"
refused 'must preserve account servers' plan
rm "$tmp/rex-login-server.service.KillMode"
printf 'foreign\0login-server\0' > "$rex_root/proc/123/cmdline"
refused 'foreign running login command' plan
rm "$tmp/rex-login-server.service.ActiveState" "$tmp/rex-login-server.service.MainPID"
echo active > "$tmp/rex-login-server.socket.ActiveState"
refused 'active login socket requires explicit operator migration' plan
rm "$tmp/rex-login-server.socket.ActiveState"
echo 'ExecStart=/usr/bin/foreign' >> "$rex_root/etc/systemd/system/rex-login-server.service.d/10-tailnet.conf"
refused 'foreign login service configuration' plan
cp "$repo/provisioning/rex/10-tailnet.conf" "$rex_root/etc/systemd/system/rex-login-server.service.d/"
test_installed=0.0.1 refused 'use --allow-version-change' plan
test_installed=0.0.1 ok plan --allow-version-change
test_query_error=true refused 'cannot inspect installed Rex package' plan
test_installed=$(jq -r .version "$repo/provisioning/rex/release.json") refused 'installed binary differs' plan
rm "$rex_root/etc/rex/accounts.jsonc"
ln -s "$tmp/approved.json" "$rex_root/etc/rex/accounts.jsonc"
refused 'foreign symlinked Rex policy' plan
rm "$rex_root/etc/rex/accounts.jsonc"
cp "$tmp/approved.json" "$rex_root/etc/rex/accounts.jsonc"
mkdir -p "$rex_root/var/cache"
ln -s "$tmp/no-such-directory" "$rex_root/var/cache/iv-rex"
refused 'cache must be root-owned' plan
rm "$rex_root/var/cache/iv-rex"

# Package checks use a locally built dummy .deb, never a download or execution.
mkdir -p "$tmp/package/DEBIAN" "$tmp/package/usr/bin" "$tmp/bundle"
printf 'not executable fixture bytes\n' > "$tmp/package/usr/bin/rex"
cat > "$tmp/package/DEBIAN/control" <<'EOF'
Package: rex
Version: 0.0.1
Architecture: amd64
Maintainer: Offline Test <test@example.invalid>
Description: Offline fixture, never installed
EOF
dpkg-deb --build "$tmp/package" "$tmp/fixture.deb" >/dev/null
cp "$repo/provisioning/rex/"* "$tmp/bundle/"
rex_bundle="$tmp/bundle"
jq --arg sha "$(hash "$tmp/fixture.deb")" --arg binary "$(hash "$tmp/package/usr/bin/rex")" \
  '.version="0.0.1" | .artifact="rex_0.0.1_amd64.deb" |
   .url="https://pkgs.superlogical.com/rex/apt/pool/main/r/rex/rex_0.0.1_amd64.deb" |
   .sha256=$sha | .binary_sha256=$binary' "$rex_bundle/release.json" > "$tmp/manifest"
cp "$tmp/manifest" "$rex_bundle/release.json"
validate_bundle
ok validate_artifact "$tmp/fixture.deb"
cp "$tmp/package/usr/bin/rex" "$rex_root/usr/bin/rex"
fixture_snapshot > "$tmp/before"
test_installed=0.0.1 ok plan
test_installed=0.0.1 test_package_state='hi ' ok plan
test_installed=0.0.1 test_package_state='hiR' refused 'not fully installed' plan
fixture_snapshot > "$tmp/after"
cmp "$tmp/before" "$tmp/after"
expected_sha=0000000000000000000000000000000000000000000000000000000000000000 refused 'package SHA256 mismatch' validate_artifact "$tmp/fixture.deb"
version=0.0.2 refused 'package version mismatch' validate_artifact "$tmp/fixture.deb"
expected_binary=0000000000000000000000000000000000000000000000000000000000000000 refused 'packaged binary SHA256 mismatch' validate_artifact "$tmp/fixture.deb"
sed -i 's/Architecture: amd64/Architecture: arm64/' "$tmp/package/DEBIAN/control"
dpkg-deb --build "$tmp/package" "$tmp/arm64.deb" >/dev/null
expected_sha=$(hash "$tmp/arm64.deb") refused 'package architecture mismatch' validate_artifact "$tmp/arm64.deb"
sed -i 's/Package: rex/Package: other/' "$tmp/package/DEBIAN/control"
dpkg-deb --build "$tmp/package" "$tmp/other.deb" >/dev/null
expected_sha=$(hash "$tmp/other.deb") refused 'wrong package' validate_artifact "$tmp/other.deb"
ln -s "$tmp/fixture.deb" "$tmp/link.deb"
refused 'missing/unsafe cached package' validate_artifact "$tmp/link.deb"
refused 'missing/unsafe cached package' validate_artifact "$tmp/missing.deb"
echo 'corrupt' > "$tmp/corrupt.deb"
refused 'package SHA256 mismatch' validate_artifact "$tmp/corrupt.deb"

# /proc inspection reports old account binaries, without running Rex or stopping
# their servers. A root/shared process other than MainPID must be refused.
mkdir -p "$rex_root/proc/345"
ln -s "$tmp/package/usr/bin/rex" "$rex_root/proc/345/exe"
login_pid=0
stat() {
  if [[ $* == "-c %u $rex_root/proc/345" ]]; then
    echo "${test_proc_uid:-1000}"
  else
    command stat "$@"
  fi
}
expected_binary=0000000000000000000000000000000000000000000000000000000000000000 ok runtime_report
grep -q 'WARNING: running Rex PID 345.*sessions left intact' "$tmp/output"
test_proc_uid=0
refused 'foreign Rex process PID 345 UID 0' runtime_report
printf '%s\0' /usr/bin/rex login-server session --account exedev --pam-service rex-login-server > "$rex_root/proc/345/cmdline"
ok runtime_report
printf '%s\0' rex login-server session --account exedev > "$rex_root/proc/345/cmdline"
ok runtime_report
printf '%s\0' /usr/bin/rex login-server session --account root > "$rex_root/proc/345/cmdline"
refused 'foreign Rex process' runtime_report
printf '%s\0' /usr/bin/rex server run --account exedev > "$rex_root/proc/345/cmdline"
refused 'foreign Rex process' runtime_report
printf '%s\0' /usr/bin/rex login-server session --account exedev --account=root > "$rex_root/proc/345/cmdline"
refused 'foreign Rex process' runtime_report
unset -f stat
unset test_proc_uid

jq '.url="https://example.invalid/rex.deb"' "$tmp/manifest" > "$rex_bundle/release.json"
refused 'invalid pinned public release manifest' validate_bundle
cp "$tmp/manifest" "$rex_bundle/release.json"
jq '.accounts.exedev.principals += ["anonymous"]' "$tmp/approved.json" > "$rex_root/etc/rex/accounts.jsonc"
refused 'foreign Rex account policy' plan
cp "$tmp/approved.json" "$rex_root/etc/rex/accounts.jsonc"
echo 'Environment=REX_EXTRA=foreign' >> "$rex_bundle/10-tailnet.conf"
refused 'service configuration SHA256 mismatch' validate_bundle
jq --arg sha "$(hash "$rex_bundle/10-tailnet.conf")" '.unit_sha256=$sha' "$tmp/manifest" > "$rex_bundle/release.json"
refused 'unqualified service command/directives' validate_bundle

# Target only the existing Rex field; never invent a full provisioning record.
provision_lock="$tmp/iv-provision.lock"
ok update_provision_lock
[[ ! -e $provision_lock ]]
printf 'provision_repo_sha=unchanged-fixture\nrex_version=\nshelley_version=keep-exact\nother=value=with=equals\n' > "$provision_lock"
chmod 0640 "$provision_lock"
original_metadata=$(stat -c '%u:%g:%a' "$provision_lock")
grep -v '^rex_version=' "$provision_lock" > "$tmp/other-fields"
ok update_provision_lock
grep -qxF "rex_version=$version" "$provision_lock"
grep -v '^rex_version=' "$provision_lock" > "$tmp/other-fields-after"
cmp "$tmp/other-fields" "$tmp/other-fields-after"
[[ $(stat -c '%u:%g:%a' "$provision_lock") == "$original_metadata" ]]
inode=$(stat -c %i "$provision_lock")
ok update_provision_lock
[[ $(stat -c %i "$provision_lock") == "$inode" ]]
mv "$provision_lock" "$tmp/regular-lock"
ln -s "$tmp/regular-lock" "$provision_lock"
refused 'regular file, not a symlink' update_provision_lock
rm "$provision_lock"
ln -s "$tmp/missing-lock" "$provision_lock"
refused 'regular file, not a symlink' update_provision_lock
rm "$provision_lock"
printf 'provision_repo_sha=unchanged\n' > "$provision_lock"
ok update_provision_lock
grep -qxF 'provision_repo_sha=unchanged' "$provision_lock"
grep -qxF "rex_version=$version" "$provision_lock"
printf 'rex_version=one\nrex_version=two\n' > "$provision_lock"
refused 'duplicate rex_version fields' update_provision_lock

# Default provisioning must never call the installer; check just the small gate.
gate=$(sed -n '/^if \[\[ ${IV_INSTALL_REX:-0} == 1 \]\]; then$/,/^fi$/p' "$repo/provision-iv.sh")
[[ -n $gate ]]
[[ ! -e $repo/provisioning/rex/accounts.jsonc ]]
grep -Fq '${IV_REX_OWNER:?IV_INSTALL_REX=1 requires IV_REX_OWNER}' <<<"$gate"
grep -Fq 'rex_args=(--apply --owner "$IV_REX_OWNER")' <<<"$gate"
grep -Fq 'rex_args+=(--allow-tag "$IV_REX_ALLOW_TAG")' <<<"$gate"
grep -Fq 'sudo "$IV_REPO/bin/install-rex" "${rex_args[@]}"' <<<"$gate"
unset IV_INSTALL_REX
eval "$gate"
IV_INSTALL_REX=0 eval "$gate"
[[ ! -e $mutation_log ]] || { cat "$mutation_log" >&2; exit 1; }
printf 'install-rex offline tests passed (%s checks; no apply/download/daemon calls)\n' "$passed"
