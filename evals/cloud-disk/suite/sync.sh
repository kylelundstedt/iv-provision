#!/usr/bin/env bash
# Ship the suite to a test VM and (optionally) run a module there.
#   ./sync.sh iv-cloud-disk                      # copy only
#   ./sync.sh iv-cloud-disk tests.test_a_durability
set -euo pipefail
VM=${1:?usage: sync.sh <vm> [module]}
MOD=${2:-}
HERE=$(cd "$(dirname "$0")" && pwd)
tar cf - -C "$HERE" --exclude=__pycache__ . | ssh "$VM" 'mkdir -p ~/cdbench && tar xf - -C ~/cdbench'
if [ -n "$MOD" ]; then
  ssh "$VM" "cd ~/cdbench && set -a && . ~/.cd/creds && set +a && ~/cdvenv/bin/python -m $MOD"
fi
