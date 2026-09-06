#!/usr/bin/env bash
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
WRAPPER="$REPO/bin/agentsview-source-daemon"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home"

cat > "$TMP/bin/hostname" <<'EOF'
#!/bin/sh
echo source-canary
EOF
cat > "$TMP/bin/ss" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$TMP/bin/agentsview" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$AGENTSVIEW_TEST_ARGS"
printf '%s\n' "${ZED_DIR:-unset}" > "$AGENTSVIEW_TEST_ARGS.zed"
EOF
chmod +x "$TMP/bin/"*

# Missing token fails closed.
if HOME="$TMP/home" PATH="$TMP/bin:$PATH" AGENTSVIEW_BIN="$TMP/bin/agentsview" \
    "$WRAPPER" >/dev/null 2>&1; then
  echo "source wrapper accepted a missing token" >&2
  exit 1
fi

ARGS="$TMP/args"
HOME="$TMP/home" PATH="$TMP/bin:$PATH" \
  AGENTSVIEW_AUTH_TOKEN=test-token \
  AGENTSVIEW_BIN="$TMP/bin/agentsview" \
  AGENTSVIEW_TEST_ARGS="$ARGS" \
  "$WRAPPER"

grep -qx 'serve' "$ARGS"
grep -qx '127.0.0.1' "$ARGS"
grep -qx 'https://source-canary.exe.xyz:8080' "$ARGS"
! grep -qx -- '--require-auth' "$ARGS"
! grep -qx '0.0.0.0' "$ARGS"
! grep -q 'ts.net' "$ARGS"
[[ $(stat -c '%a' "$TMP/home/.agentsview") == 700 ]]

# Assertions below use an explicit `|| { ...; exit 1; }` rather than a bare
# `[[ ]]`: bash 3.2 (macOS, the authoring host) does NOT honour `set -e` for a
# failing `[[ ]]`, so bare assertions pass silently there while working on the
# bash 5.x VMs. Local runs would report a false green.
fail() { echo "test-agentsview-source: $1" >&2; exit 1; }

# Zed discovery must be pinned to an empty directory: a VM's ~/.local/share/zed
# is the remote-server payload (node runtime, extensions) and holds no threads,
# so mirroring it costs hundreds of MB per host for zero sessions.
[[ $(cat "$ARGS.zed") == "$TMP/home/.config/agentsview/no-zed" ]] ||
  fail "ZED_DIR was not pinned to the empty default (got $(cat "$ARGS.zed"))"
[[ -d "$TMP/home/.config/agentsview/no-zed" ]] ||
  fail "the empty Zed directory was not created"
[[ -z $(ls -A "$TMP/home/.config/agentsview/no-zed") ]] ||
  fail "the pinned Zed directory is not empty"

# An explicit ZED_DIR still wins, so a host that really does hold Zed threads
# can opt back in without editing this wrapper.
ZED_OVERRIDE="$TMP/home/custom-zed"
HOME="$TMP/home" PATH="$TMP/bin:$PATH" \
  AGENTSVIEW_AUTH_TOKEN=test-token \
  AGENTSVIEW_BIN="$TMP/bin/agentsview" \
  AGENTSVIEW_TEST_ARGS="$ARGS" \
  ZED_DIR="$ZED_OVERRIDE" \
  "$WRAPPER"
[[ $(cat "$ARGS.zed") == "$ZED_OVERRIDE" ]] ||
  fail "an explicit ZED_DIR was overridden by the default"

echo "agentsview source wrapper tests passed"
