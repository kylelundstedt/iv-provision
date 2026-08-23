#!/usr/bin/env bash
# D1/D2: two VMs, one disk. Driven from the controller (iv-provision) over the
# tailnet, because the interesting cases need two hosts racing in real time.
#
#   ./run_multihost.sh iv-cloud-disk iv-cloud-disk-b
#
# Assumes both VMs have ~/cdbench (see sync.sh) and ~/.cd/creds.
set -uo pipefail
A=${1:?vm-a}
B=${2:?vm-b}
DISK=${DISK:-d-shared}
RUN=${CDBENCH_RUN_ID:-multihost}

run() { # run <vm> <python args...>
  local vm=$1; shift
  ssh "$vm" "cd ~/cdbench && set -a && . ~/.cd/creds && set +a && CDBENCH_RUN_ID=$RUN ~/cdvenv/bin/python -m tests.test_d_concurrency $*"
}

cdcmd() { # cdcmd <vm> <cloud-disk args...>
  local vm=$1; shift
  ssh "$vm" "set -a; . ~/.cd/creds; set +a; sudo --preserve-env=AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY cloud-disk $* 2>&1 | tail -2"
}

echo "### prep on $A"
run "$A" prep "$DISK"

echo
echo "### D1: $A holds rw, $B tries to steal the lease mid-write"
run "$A" rw_hold "$DISK" 120 &
HOLD=$!
sleep 25          # let A acquire and settle; lease TTL is 30s
run "$B" rw_steal "$DISK"
wait $HOLD
cdcmd "$A" umount "$DISK"
cdcmd "$B" umount "$DISK"

echo
echo "### D2: ReadOnlyMany -- both VMs mount read-only and query"
run "$A" ro_mount "$DISK" roA &
PA=$!
run "$B" ro_mount "$DISK" roB &
PB=$!
wait $PA; wait $PB
run "$A" ro_release "$DISK" || true
run "$B" ro_release "$DISK" || true

echo
echo "### collecting results"
for vm in "$A" "$B"; do
  ssh "$vm" 'cat ~/cdbench-results/results.jsonl 2>/dev/null' > "/tmp/results-$vm.jsonl" || true
  echo "$vm: $(wc -l < /tmp/results-$vm.jsonl) rows -> /tmp/results-$vm.jsonl"
done
