#!/usr/bin/env bash
# Fully offline: source validators; all daemon/app commands are allowlisted mocks.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
script="$repo/bin/configure-rex"
bash -n "$script"
if command -v shellcheck >/dev/null; then shellcheck -S error "$script" "$0"; fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# shellcheck source=../bin/configure-rex
source "$script"
# Assigned by the sourced configurator.
# shellcheck disable=SC2154
: "$expected_command"
rex_root="$tmp/root"
mkdir -p "$rex_root"/{etc/rex,run/systemd/system,proc,usr/bin,bin,var/lib/iv-rex}
printf 'ID=ubuntu\nVERSION_ID=24.04\n' > "$rex_root/etc/os-release"
for shell in bin/bash bin/zsh usr/bin/bash usr/bin/zsh usr/bin/rex; do
  printf '#!/bin/sh\nexit 99\n' > "$rex_root/$shell"; chmod 0755 "$rex_root/$shell"
done
printf 'package provenance must survive\n' > "$rex_root/var/lib/iv-rex/install.lock"
printf '{"BackendState":"Running","Self":{"Tags":["tag:dev"],"DNSName":"fixture.test.ts.net."},"CertDomains":["fixture.test.ts.net"]}\n' > "$tmp/status"
echo '{}' > "$tmp/serve"
mutations="$tmp/mutations"
forbidden="$tmp/forbidden"
stat() {
  # UID assertions must not depend on whether the runner is root/exedev/CI.
  if [[ $1 == -c && $2 == %u ]]; then
    case "$3" in
      "$rex_root/proc/345") echo "${test_proc_uid:-1000}" ;;
      "$rex_root"*) echo "${test_path_uid:-0}" ;;
      *) command stat "$@" ;;
    esac
  else command stat "$@"; fi
}
getent() { [[ $* == 'passwd exedev' ]]; echo "exedev:x:${test_uid:-1000}:1000::/home/exedev:${test_shell:-/bin/bash}"; }
dpkg-query() {
  case "$*" in
    '-W -f=${db:Status-Abbrev}\t${Version}\t${Maintainer} rex')
      [[ ${test_package_present:-true} == true ]] || return 1
      printf '%s\t%s\t%s\n' "${test_package_state:-ii }" "${test_version:-0.0.1-gfixture}" "${test_maintainer:-Superlogical <hello@superlogical.com>}" ;;
    '-S /usr/bin/rex') echo "${test_binary_package:-rex}: /usr/bin/rex" ;;
    '-S /usr/lib/systemd/system/'*) echo "${test_unit_package:-rex}: ${2}" ;;
    *) echo "dpkg-query $*" >> "$forbidden"; return 99 ;;
  esac
}
version_report() {
  [[ ${test_report_fail:-false} == false ]] || return 1
  printf '%s\n' "${test_report:-rex 0.0.1-gfixture}" 'build fixture'
}
tailscale() {
  case "$*" in
    'status --json') cat "$tmp/status" ;;
    'serve status --json') cat "$tmp/serve" ;;
    'serve --bg --https=443 unix:/run/rex/serve.sock')
      [[ ${test_apply:-false} == true ]] || { echo tailscale >> "$forbidden"; return 99; }
      echo 'serve private443' >> "$mutations"
      jq '.TCP["443"]={"HTTPS":true} | .Web["fixture.test.ts.net:443"]={"Handlers":{"/":{"Proxy":"unix:/run/rex/serve.sock"}}}' \
        "$tmp/serve" > "$tmp/new-serve"
      mv "$tmp/new-serve" "$tmp/serve" ;;
    *) echo "tailscale $*" >> "$forbidden"; return 99 ;;
  esac
}
systemctl() {
  if [[ $1 == show && $3 == -p && $5 == --value ]]; then
    if [[ -f $tmp/$2.$4 ]]; then cat "$tmp/$2.$4"; return; fi
    case "$4" in
      ActiveState) echo inactive ;;
      MainPID) echo 0 ;;
      FragmentPath) echo "/usr/lib/systemd/system/$2" ;;
      DropInPaths) echo '' ;;
      KillMode) echo process ;;
      RuntimeDirectoryPreserve) echo yes ;;
      *) echo "systemctl $*" >> "$forbidden"; return 99 ;;
    esac
    return
  fi
  [[ ${test_apply:-false} == true ]] || { echo "systemctl $*" >> "$forbidden"; return 99; }
  case "$*" in
    'daemon-reload'|'disable rex.service rex.socket rex-login-server.socket'|'enable rex-login-server.service') ;;
    'start rex-login-server.service')
      activate_login ;;
    *) echo "systemctl $*" >> "$forbidden"; return 99 ;;
  esac
  echo "systemctl $*" >> "$mutations"
}
activate_login() {
  echo active > "$tmp/rex-login-server.service.ActiveState"
  echo 123 > "$tmp/rex-login-server.service.MainPID"
  mkdir -p "$rex_root/proc/123"
  # Deliberately split the exact command into /proc argv, not shell evaluation.
  read -ra argv <<< "$expected_command"
  printf '%s\0' "${argv[@]}" > "$rex_root/proc/123/cmdline"
}
ss() { [[ $* == '-Hlnpt sport = :7297' ]]; printf '%s' "${test_listeners:-}"; }
timeout() { [[ $1 == 30 ]]; shift; "$@"; }
curl() { echo curl >> "$forbidden"; return 99; }
sudo() { echo sudo >> "$forbidden"; return 99; }
dpkg() { echo dpkg >> "$forbidden"; return 99; }
apt-get() { echo apt-get >> "$forbidden"; return 99; }
apt-mark() { echo apt-mark >> "$forbidden"; return 99; }
passed=0
ok() {
  ( "$@" ) > "$tmp/output" 2>&1 || { cat "$tmp/output" >&2; echo "FAIL: $*" >&2; exit 1; }
  passed=$((passed+1))
}
refused() {
  local expected=$1; shift
  if ( "$@" ) > "$tmp/output" 2>&1; then echo "FAIL: accepted $*" >&2; exit 1; fi
  grep -Fq -- "$expected" "$tmp/output" || { cat "$tmp/output" >&2; echo "FAIL: expected $expected" >&2; exit 1; }
  passed=$((passed+1))
}
plan() { main --owner owner@example.test --allow-tag tag:test-client "$@"; }
snapshot() { find "$rex_root" -type f -exec sha256sum {} + | sort; find "$rex_root" -printf '%p %m %u %l\n' | sort; }
snapshot > "$tmp/before"
ok plan
grep -q 'PLAN ONLY' "$tmp/output"
ok plan --plan
# Neither dpkg architecture nor CPU model is queried; both upstream package architectures qualify.
for arch in amd64 arm64; do test_arch=$arch ok plan; done
for shell in /bin/bash /bin/zsh /usr/bin/bash /usr/bin/zsh; do test_shell=$shell ok plan; done
test_shell=/bin/false refused 'requires Bash or Zsh' plan
chmod 0644 "$rex_root/bin/zsh"
test_shell=/bin/zsh refused 'shell is not executable' plan
chmod 0755 "$rex_root/bin/zsh"
snapshot > "$tmp/after"; cmp "$tmp/before" "$tmp/after"
refused 'explicit --owner LOGIN' main
refused '--owner requires one LOGIN' main --owner
refused '--owner requires one LOGIN' plan --owner other@example.test
refused '--allow-tag requires tag:NAME' plan --allow-tag
refused 'explicit person login' main --owner 'tag:test-client'
refused 'explicit person login' main --owner '*@example.test'
refused 'explicit tag:NAME' plan --allow-tag 'tag:*'
refused 'explicit tag:NAME' plan --allow-tag anonymous
refused 'unknown argument' plan --allow-version-change
refused 'unknown argument' plan --latest
if (( EUID == 0 )); then refused 'apply cannot target a fixture root' plan --apply
else refused '--apply requires root' plan --apply; fi
generate_policy owner@example.test
# shellcheck disable=SC2154
jq -e '.=={version:1,accounts:{exedev:{principals:["tailscale:owner@example.test"]}},defaults:{"tailscale:owner@example.test":"exedev"}}' <<< "$approved_policy" >/dev/null
generate_policy owner@example.test tag:test-client tag:second-client tag:test-client
jq -e '.accounts.exedev.principals==["tailscale:owner@example.test","tailscale:tag:second-client","tailscale:tag:test-client"]' <<< "$approved_policy" >/dev/null
generate_policy owner@example.test tag:test-client
test_uid=0 refused 'exedev must be UID 1000' plan
test_path_uid=1000 refused 'unsafe ownership/mode' plan
sed -i 's/24.04/22.04/' "$rex_root/etc/os-release"
refused 'requires Ubuntu 24.04' plan
sed -i 's/22.04/24.04/' "$rex_root/etc/os-release"
test_package_present=false refused 'installed Superlogical Rex package required' plan
test_maintainer='Other <other@example.test>' refused 'genuine Superlogical' plan
test_package_state='rc ' refused 'genuine Superlogical' plan
test_package_state='hiR' refused 'genuine Superlogical' plan
test_package_state='hi ' ok plan
test_binary_package=other refused 'binary must belong' plan
test_unit_package=other refused 'foreign unit package' plan
test_report_fail=true refused 'cannot read Rex version report' plan
test_report='rex 0.0.2' refused 'version report differs' plan
test_report='unrelated 0.0.1-gfixture' refused 'version report differs' plan
chmod 0777 "$rex_root/usr/bin/rex"
refused 'unsafe ownership/mode' plan
chmod 0755 "$rex_root/usr/bin/rex"
mv "$rex_root/run/systemd/system" "$rex_root/run/systemd/not-running"
refused 'systemd must be running' plan
mv "$rex_root/run/systemd/not-running" "$rex_root/run/systemd/system"
cp "$tmp/status" "$tmp/good-status"
for tags in '[]' '["tag:prod"]' '["tag:dev","tag:prod"]'; do
  jq --argjson tags "$tags" '.Self.Tags=$tags' "$tmp/good-status" > "$tmp/status"
  refused 'requires tag:dev' plan
done
jq '.CertDomains=[]' "$tmp/good-status" > "$tmp/status"
refused 'already-enabled tailnet HTTPS' plan
cp "$tmp/good-status" "$tmp/status"
echo '{"TCP":{"8443":{"HTTPS":true}},"Web":{"fixture.test.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://localhost:8080"}}}}}' > "$tmp/serve"
ok plan
for conflict in \
  '{"TCP":{"443":{"HTTPS":true}},"Web":{"fixture.test.ts.net:443":{"Handlers":{"/":{"Proxy":"http://localhost:8080"}}}}}' \
  '{"AllowFunnel":{"fixture.test.ts.net:443":true}}' \
  '{"TCP":{"7297":{"HTTPS":true}}}' \
  '{"Foreground":{"123":{}}}' '{"Services":{"foreign":{}}}'; do
  echo "$conflict" > "$tmp/serve"; refused 'Serve conflict' plan
done
echo '{}' > "$tmp/serve"
for unit in rex.service rex.socket rex-login-server.socket; do
  echo active > "$tmp/$unit.ActiveState"; refused "active $unit" plan; rm "$tmp/$unit.ActiveState"
done
echo '/etc/systemd/system/rex-login-server.service' > "$tmp/rex-login-server.service.FragmentPath"
refused 'foreign/masked unit' plan
rm "$tmp/rex-login-server.service.FragmentPath"
echo '' > "$tmp/rex-login-server.service.FragmentPath"
refused 'vendor login service is missing' plan
rm "$tmp/rex-login-server.service.FragmentPath"
echo '/etc/systemd/system/rex-login-server.service.d/foreign.conf' > "$tmp/rex-login-server.service.DropInPaths"
refused 'foreign unit drop-ins' plan
rm "$tmp/rex-login-server.service.DropInPaths"
test_listeners='LISTEN 0 4096 *:7297 *:* users:(("other",pid=17,fd=3))' refused 'listener on 7297' plan
mkdir -p "$rex_root/run/rex"
touch "$rex_root/run/rex/server.sock"; refused 'shared Rex runtime socket' plan; rm "$rex_root/run/rex/server.sock"
touch "$rex_root/run/rex/login-server.sock"; refused 'unmanaged login/Serve socket' plan; rm "$rex_root/run/rex/login-server.sock"
printf '// Vendor empty policy\n{"version":1,"accounts":{},}\n' > "$rex_root/etc/rex/accounts.jsonc"
ok plan
printf '{"version":1,"accounts":{"root":{"principals":["anonymous"]}}}\n' > "$rex_root/etc/rex/accounts.jsonc"
refused 'foreign Rex account policy' plan
printf '%s\n' "$approved_policy" > "$rex_root/etc/rex/accounts.jsonc"
ok plan
refused 'foreign Rex account policy' main --owner other@example.test --allow-tag tag:test-client
refused 'foreign Rex account policy' main --owner owner@example.test
ln -s "$tmp/absent" "$rex_root/var/lib/iv-rex/configuration.lock"
refused 'symlinked configuration' plan
rm "$rex_root/var/lib/iv-rex/configuration.lock"
mkdir "$rex_root/var/lib/iv-rex/configuration.lock"
refused 'configuration must be a regular file' plan
rmdir "$rex_root/var/lib/iv-rex/configuration.lock"
mv "$rex_root/etc/rex" "$tmp/rex-policy-directory"
ln -s "$tmp/rex-policy-directory" "$rex_root/etc/rex"
refused 'symlinked configuration' plan
rm "$rex_root/etc/rex"
mv "$tmp/rex-policy-directory" "$rex_root/etc/rex"
mkdir -p "$rex_root/etc/systemd/system/rex-login-server.service.d"
cp "$repo/provisioning/rex/10-tailnet.conf" "$rex_root/etc/systemd/system/rex-login-server.service.d/"
echo 'Environment=FOREIGN=yes' >> "$rex_root/etc/systemd/system/rex-login-server.service.d/10-tailnet.conf"
refused 'foreign login service configuration' plan
cp "$repo/provisioning/rex/10-tailnet.conf" "$rex_root/etc/systemd/system/rex-login-server.service.d/"
activate_login
ok plan
test_listeners='LISTEN 0 4096 *:7297 *:* users:(("rex",pid=123,fd=3))' ok plan
echo control-group > "$tmp/rex-login-server.service.KillMode"
refused 'must preserve account servers' plan
rm "$tmp/rex-login-server.service.KillMode"
printf 'foreign\0login-server\0' > "$rex_root/proc/123/cmdline"
refused 'foreign running login command' plan
activate_login
# Local exedev servers and old/deleted binaries are left alone; root PAM helpers are narrow exceptions.
mkdir -p "$rex_root/proc/345"
ln -s "$tmp/old/rex (deleted)" "$rex_root/proc/345/exe"
printf '%s\0' /usr/bin/rex server run > "$rex_root/proc/345/cmdline"
ok plan
test_proc_uid=0 refused 'foreign/shared Rex process' plan
printf '%s\0' /usr/bin/rex login-server session --account exedev > "$rex_root/proc/345/cmdline"
test_proc_uid=0 ok plan
printf '%s\0' /usr/bin/rex login-server session --account exedev --account=root > "$rex_root/proc/345/cmdline"
test_proc_uid=0 refused 'foreign/shared Rex process' plan
rm "$tmp/rex-login-server.service.ActiveState" "$tmp/rex-login-server.service.MainPID"
ok plan # inactive login server does not forbid a running local exedev server.
# Exercise configuration writes only in fixtures; never call main --apply on this host.
rm "$rex_root/etc/rex/accounts.jsonc" "$rex_root/etc/systemd/system/rex-login-server.service.d/10-tailnet.conf"
printf '// Vendor default\n{"version":1,"accounts":{},}\n' > "$rex_root/etc/rex/accounts.jsonc"
echo '{"TCP":{"8443":{"HTTPS":true}},"Web":{"fixture.test.ts.net:8443":{"Handlers":{"/":{"Text":"other workload"}}}}}' > "$tmp/serve"
test_apply=true ok apply_configuration
jq -e '.configuration_version==1 and .reported_rex_version=="0.0.1-gfixture"' "$rex_root/var/lib/iv-rex/configuration.lock" >/dev/null
cmp "$repo/provisioning/rex/10-tailnet.conf" "$rex_root/etc/systemd/system/rex-login-server.service.d/10-tailnet.conf"
grep -qxF 'package provenance must survive' "$rex_root/var/lib/iv-rex/install.lock"
grep -qxF 'systemctl start rex-login-server.service' "$mutations"
grep -qxF 'serve private443' "$mutations"
jq -e '.TCP["8443"]=={"HTTPS":true} and .Web["fixture.test.ts.net:8443"].Handlers["/"].Text=="other workload"' "$tmp/serve" >/dev/null
: > "$mutations"
policy_inode=$(command stat -c %i "$rex_root/etc/rex/accounts.jsonc")
test_apply=true ok apply_configuration
[[ $(command stat -c %i "$rex_root/etc/rex/accounts.jsonc") == "$policy_inode" ]]
! grep -Eq 'start|restart|stop|serve|reload' "$mutations"
snapshot > "$tmp/before"; ok plan; snapshot > "$tmp/after"; cmp "$tmp/before" "$tmp/after"
[[ ! -e $forbidden ]] || { cat "$forbidden" >&2; exit 1; }
printf 'configure-rex offline tests passed (%s checks; mocked daemons/apps and UID stat)\n' "$passed"
