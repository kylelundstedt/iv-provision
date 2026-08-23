---
name: join-tailnet
description: Manually join an exe.dev VM to the Tailscale tailnet. Provisioning does this automatically since 3.0.5 -- use this only when re-provisioning is not an option. SSHes in over *.exe.xyz, ensures tailscaled is running, and runs tailscale up with a one-use key minted via the api-tailscale proxy.
---

# Join Tailnet

Joins an exe.dev VM to the IV Tailscale tailnet. The VM must have
the `api-tailscale` integration attached (attach it per VM; there is no tag).

## Usage

The user provides a VM name (e.g. `iv-gitlake`). The skill SSHes in over
the exe.dev edge and runs two commands on the VM.

## Steps

1. **SSH into the VM over `*.exe.xyz`** (one attempt, `ConnectTimeout=30`).
2. **Run the join commands** on the VM:

```bash
ssh -o ConnectTimeout=30 <vm>.exe.xyz 'bash -s' <<'REMOTE'
set -euo pipefail
# Stock exeuntu may ship tailscaled disabled; enable and start it before joining.
sudo systemctl enable --now tailscaled
# Two-step (OAuth client behind the proxy, 2026-07): exchange for a 1h token
# via the proxy, then mint against the public API (the proxy injects
# Authorization on every request, so only the exchange goes through it).
TOKEN=$(curl -fsSL -X POST -d "grant_type=client_credentials" \
  https://api-tailscale.int.exe.xyz/api/v2/oauth/token | jq -er .access_token)
trap 'rm -f "${auth_config:-}"; unset TOKEN KEY' EXIT
auth_config=$(mktemp)
chmod 600 "$auth_config"
printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" > "$auth_config"
KEY=$(curl --config "$auth_config" -fsSL -X POST \
  https://api.tailscale.com/api/v2/tailnet/-/keys \
  -H "Content-Type: application/json" \
  -d '{"capabilities":{"devices":{"create":{"reusable":false,"ephemeral":true,"preauthorized":true,"tags":["tag:dev"]}}}}' \
  | jq -er .key)
rm -f "$auth_config"
sudo tailscale up --ssh --accept-dns --hostname="$(hostname)" --authkey="$KEY"
tailscale status
REMOTE
```

3. **Verify** the VM appears in `tailscale status` output.

After it joins, use `ssh <vm>` (Tailscale SSH) for everything else.

## Preflight: confirm the integration is actually attached

Do this **first**. The mint fails at the OAuth exchange with an opaque proxy
error when `api-tailscale` is missing, and nothing connects that failure back to
an integration nobody attached.

```bash
ssh -o ConnectTimeout=30 <vm>.exe.xyz \
  "curl -s https://reflection.int.exe.xyz/integrations | jq -r '.integrations[].name' | grep -qx api-tailscale \
     && echo 'api-tailscale: attached' \
     || echo 'api-tailscale: MISSING -- run: ssh exe.dev integrations attach api-tailscale vm:<vm>'"
```

If it is missing, attach it before going further:

```bash
ssh exe.dev integrations attach api-tailscale vm:<vm>
```

Note the name. These docs said `tailscale-api` until 2026-08-19, which matches
nothing: the check above then reports MISSING on a VM that is correctly
configured, which is exactly what happened on `iv-provision`. Always list the
names rather than grepping for one you assume.

`api-tailscale` reaches a VM through the **`tailnet` exe.dev tag**, a tag that
grants this and nothing else. A VM tagged `tailnet` has it; an untagged VM does
not, and "MISSING" on such a VM is the expected steady state rather than a fault.

For a one-off — a canary joining once and never again — per-VM attachment is
still right, and still detached afterwards: `integrations attach api-tailscale
vm:<vm>`, do the work, detach. The tag exists for VMs meant to stay fleet members
across a recreate, because a per-VM attachment dies with the VM and leaves the
replacement unable to rejoin unattended.

(An earlier revision of this file claimed it was attached to nine VMs. That was
misread from a screenshot.)

## Prerequisites

- The `api-tailscale` integration must reach the VM — normally by tagging it
  `ssh exe.dev tag <vm> tailnet`, or per VM for a one-off with
  `ssh exe.dev integrations attach api-tailscale vm:<vm>`. Note `tailnet` here is
  an **exe.dev** tag, unrelated to Tailscale's own `tag:dev`; it never appears in
  `tailscale status`. See `tailnet.md` → "Two tag systems, one word", and confirm
  attachment off-VM with `ssh exe.dev integrations` — `reflection` shows a VM its
  own integrations but never the attachment rules.
- `tailscale` itself is installed by `provision-iv.sh` (since 2026-08-18), which
  also enables `tailscaled`. On a VM that has not been provisioned yet, install
  it first — the `exeslim-dev` base does not carry it, and neither did stock
  exeuntu in a started state.

## SSH discipline

- **One SSH attempt at a time.** Never launch parallel SSH to `*.exe.xyz`.
- If SSH fails, wait 30-60s before one more attempt.
