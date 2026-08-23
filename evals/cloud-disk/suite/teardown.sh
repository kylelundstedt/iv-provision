#!/usr/bin/env bash
# Remove every cloud-disk volume this suite created on a VM, plus local state.
#   ./teardown.sh iv-cloud-disk [iv-cloud-disk-b ...]
#
# `cloud-disk delete` refuses without -force when it cannot prompt.
# Never kill daemons with `pkill -f cloud-disk`: that pattern also matches the
# ssh command line running it and will cut your own session (learned the hard
# way). Kill by pid, or let `umount` do it.
set -uo pipefail

for VM in "$@"; do
  echo "### $VM"
  ssh "$VM" 'set -a; [ -f ~/.cd/creds ] && . ~/.cd/creds; set +a
    S="sudo --preserve-env=AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY"
    for u in $(systemctl list-unit-files "cloud-disk@*" --no-legend 2>/dev/null | awk "{print \$1}"); do
      sudo systemctl disable --now "$u" 2>&1 | tail -1
    done
    disks=$(sudo grep -oP "^\[\K[^]]+" /etc/cloud-disk/disks 2>/dev/null || true)
    for d in $disks; do
      echo "-- $d"
      $S cloud-disk umount "$d" 2>&1 | tail -1
      $S cloud-disk delete "$d" -force 2>&1 | tail -1
    done
    for m in /mnt/cloud-disk/* /mnt/cd-ro /mnt/ro-test; do
      [ -d "$m" ] && sudo umount -l "$m" 2>/dev/null
    done
    sudo rm -f /etc/cloud-disk/disks /run/cloud-disk/*.lock
    sudo rm -rf /var/lib/cloud-disk/* /mnt/cloud-disk/*
    echo "nbd mounts left: $(df -h 2>/dev/null | grep -c nbd)"'
done

cat <<'EOF'

Control-plane teardown is deliberately NOT automated (it deletes shared
resources). Run from a box with an authenticated `tigris` CLI:

  tigris buckets delete cloud-disk-test --yes
  tigris buckets delete <each cloud-disk-test-fork-*> --yes
  tigris access-keys delete <cloud-disk-test-key id>

Note: Tigris refuses to re-create a recently deleted bucket name
(BucketInaccessible), so pick fresh names on the next run.
EOF
