---
title: "Tailnet Join"
---

## Contract

A newly created VM starts off the tailnet, and joins during provisioning **iff the
`api-tailscale` integration is attached to it**. Nothing is baked in and no
credential ever reaches the VM: exe.dev injects the Tailscale OAuth credential at
the network edge, so the proxy is reachable only from a VM the control plane
deliberately attached it to.

That attachment *is* the consent signal. Least authority means it is normally
attached to nothing — attach it, provision, detach. An unattached VM simply stays
off the tailnet, and `provision-iv.sh` says so and carries on.

> **Corrected 2026-08-19.** This section previously said there was "no automatic
> join" and that a VM stays off the tailnet until someone runs the `join-tailnet`
> workflow by hand. That has never been how fleet VMs actually joined: the personal
> dotfiles `install.sh` has always performed the join automatically, by exactly the
> mechanism now in `provision-iv.sh`. Moving the tailscale *install* into the
> provisioner in 3.0.x without the *join* converted a one-command bring-up into a
> hand-run OAuth dance — a regression that stayed hidden because every existing VM
> had already joined via dotfiles.

> **Resolved 2026-08-18.** `provision-iv.sh` now installs `tailscale` from
> Tailscale's signed apt repository and enables `tailscaled`. Until then the
> client was not provided by this repo *or* the `exeslim-dev` base — it arrived
> via the personal dotfiles `install.sh` — so `join-tailnet` could not succeed on
> a freshly provisioned VM at all. Enabling the daemon does not join the tailnet;
> membership stays the explicit decision described below.

The v2.0.0 objection still holds, and this satisfies it. What was removed then was
**auto-join-on-boot**: it put every VM on the tailnet whether or not it belonged
there, and the logic had to live in a per-account setup hook or baked-in image
code, both of which drifted and coupled unrelated things together.

Joining during provisioning, gated on an integration the control plane attaches,
is not that. A VM is still just a VM until someone decides it should be a tailnet
node — the decision is the attachment, made off-VM, rather than a command typed on
the box. Nothing is baked in, nothing runs on boot, and the credential stays at
the edge.

## The vendor's `tailscale` skill, and what it does not know

Since 2026-09-02 the fleet also carries Tailscale's own agent skill
(`tailscale/tailscale-skill`, vendored as a team row like every other). It is
reference material for Tailscale *the product*: policy-file syntax, `tagOwners`,
OAuth client scopes, `tailscale status`/`netcheck` diagnostics, the API. That is
exactly the material whose absence cost most of a debugging cycle on 2026-08-23,
when a `tag:dev` mint failed with `requested tags [tag:dev] are invalid or not
permitted` and two people re-verified the OAuth scope twice before the answer
turned out to be tag *ownership* -- `tagOwners` must list a tag as an owner of
itself.

It would have helped, though not by itself. `enterprise.md` frames OAuth scopes
the right way ("the client can only operate on tags it owns"), which is the turn
the debugging never made, and routes to
`tailscale.com/docs/features/oauth-clients` -- which does carry the worked
tag-owns-tag example. The skill's own `access-control.md` shows only the ordinary
`tag -> group` form, so an agent has to follow the link. That is the skill's
design (thin inline, canonical URL, fetch on demand) and it means **the skill is
only as good as the VM's ability to fetch tailscale.com** -- worth knowing before
trusting it in a network-broken state, which is precisely when tailnet questions
get asked.

**It is upstream's model of Tailscale, not this fleet's.** It knows nothing about
`api-tailscale`, the edge-injected credential, or the join path in
`provision-iv.sh`, and its generic advice -- `tailscale up --auth-key=tskey-...`
from a key pasted out of the admin console -- is the thing this document exists to
prevent. No credential is ever meant to reach a VM.

So the boundary is:

| Question | Authority |
| --- | --- |
| What does this policy-file stanza mean? Why did Tailscale reject this key/tag? What is `netcheck` telling me? | the `tailscale` skill |
| How does *this fleet's* VM get onto the tailnet, and who decided it may? | this document, `join-tailnet`, `provision-iv.sh` |

The two are kept adjacent rather than merged, deliberately. Folding fleet
specifics into a vendored skill would be overwritten by the next re-vendor
(`vendor-skills.sh` `rm -rf`s `skills/`), and folding vendor reference into
`join-tailnet` would be a copy that silently ages.

## Joining a VM by hand (the `join-tailnet` skill)

Provisioning joins automatically. This skill remains for the cases it cannot
cover: a VM that was provisioned before the integration was attached and should
not be re-provisioned right now, or one being re-joined after a node was deleted.

A fresh VM is reachable over the exe.dev edge (`ssh <vm>.exe.xyz`) before it is
on the tailnet. The `join-tailnet` agent skill uses that edge path to bootstrap
the tailnet:

1. SSH into the VM over `*.exe.xyz` (no tailnet required).
2. Mint a one-use, ephemeral, preauthorized `tag:dev` auth key by POSTing to the
   `api-tailscale` HTTP proxy (`https://api-tailscale.int.exe.xyz`). exe.dev
   injects the real API credential at the proxy layer, so the VM never sees the
   secret.
3. Run `tailscale up --ssh --accept-dns --hostname=$(hostname)` with that key.

By hand it is two commands on the VM:

```bash
ssh -o ConnectTimeout=30 <vm>.exe.xyz 'bash -s' <<'REMOTE'
set -euo pipefail
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

After it joins, use `ssh <vm>` (Tailscale SSH) for everything else.

## Required exe.dev integration

The join step needs the `api-tailscale` integration attached to the VM so it can
mint the key. It attaches via the **`tailnet` tag** — a tag that grants this and
nothing else (see "The `tailnet` tag" below):

```bash
ssh exe.dev new --name=<vm> --tag=tailnet     # joins on first provision
ssh exe.dev tag <vm> tailnet                  # or tag an existing VM, then re-provision
```

Per-VM attachment (`integrations attach api-tailscale vm:<vm>`) still works and
is the right tool for a one-off — a canary that should join once and never again.
The tag is for VMs that are meant to stay fleet members across a recreate, since
a per-VM attachment dies with the VM.

> **Corrected 2026-08-19.** This section previously named the integration
> `tailscale-api` and said to attach it via a `tag:iv`. The name was wrong — it is
> `api-tailscale`, matching the `api-<service>` convention used by
> `api-motherduck-mcp` and friends. Tag-based attachment turned out to be the
> right shape after all, but through a dedicated `tailnet` tag rather than `iv`,
> which already carries the MCP integrations.
>
> So the `join-tailnet` procedure as documented could never have worked; every node
> on the tailnet joined through the personal dotfiles `install.sh`, which uses the
> correct hostname, and nothing surfaced the discrepancy until a VM was created
> that had no dotfiles overlay to fall back on.
>
> A first correction on the same day also claimed "no fleet VM carries an `iv` tag
> at all." That is false: `iv-provision` carries the exe.dev tag `iv`, set when it
> was created. Checking `tailscale status` — where the tag does not and cannot
> appear — is what made it look absent. See "Two tag systems" below, which is the
> confusion that produced both errors.

## Two tag systems, one word

The fleet is subject to two unrelated tagging systems, and the earlier drafts of
this document silently conflated them. They do not interact at all.

| | **Tailscale tags** | **exe.dev VM tags** |
| --- | --- | --- |
| Written | `tag:dev`, `tag:iv-aperture-pilot` | `iv`, `mcp-agent`, `fannie-sflpd` |
| Set by | the auth key used at `tailscale up`, or the Tailscale admin console | `ssh exe.dev tag <vm> <name>`, or `--tag` at creation |
| Governs | network reachability and the SSH policy | which integrations a VM receives |
| Read with | `tailscale status --json` | `curl reflection.int.exe.xyz/tags` |
| Lives in | the tailnet | the exe.dev control plane |

The trap is that exe.dev's *attachment syntax* borrows Tailscale's `tag:` prefix
— `integrations attach api-tailscale tag:iv` refers to the **exe.dev** tag `iv`,
not to anything Tailscale knows about. A reader who has just been thinking about
`tag:dev` will read that as a Tailscale tag every time.

Both documented errors came from this. "Attach it via a `tag:iv`" was written as
though exe.dev tags were Tailscale tags; "no fleet VM carries an `iv` tag" was
written after checking the Tailscale side, where an exe.dev tag can never appear.

### Where each stands today (2026-08-19)

**Tailscale `tag:dev` — uniform, and already automatic.** `provision-iv.sh` mints
every join key with `"tags":["tag:dev"]` hardcoded, so any VM this repo joins is
tagged correctly by construction. The SSH policy keys on `tag:dev`, which is what
makes `ssh <vm>` work fleet-wide.

The one gap is a node that joined by some *other* path. `iv-entire-agent-shelley`
joined via the old dotfiles `install.sh` carrying only `tag:iv-aperture-pilot`,
so SSH to it timed out — not refused, *timed out*, which is indistinguishable at
a glance from a dead host. It went unnoticed for weeks and was fixed by adding
`tag:dev` in the console (2026-08-19). Purpose tags and `tag:dev` coexist fine:
`iv-docs` carries `tag:dev` **and** `tag:iv-aperture-admin`.

**exe.dev `iv` — a live attachment target already, carrying two integrations.**
`tag:iv` attaches `api-motherduck-mcp` and `api-github-copilot-home`. The
evidence is `iv-provision` itself: it carries the tag `iv` and **not**
`mcp-agent`, yet receives both — while `kgl-songs`, tagged
`kylelundstedt-songs`, receives neither. Tag-based attachment is not a
hypothetical for this fleet; it is how the MCP integrations already arrive.

> **Corrected 2026-08-19 (third time in this section).** The text here said `iv`
> was "unused for attachment", which was wrong, and wrong in a way worth naming:
> it was *inferred* rather than checked. From inside a VM, `reflection` reports
> that VM's own tags and its own integrations — it does not report attachment
> *rules*, so no VM can see whether an integration arrived by `vm:`, by `tag:`,
> or by `auto:all`. Seeing "only `iv-provision` carries `iv`" and concluding
> "therefore nothing attaches by it" does not follow.
>
> Worse, the disproof was already in the data collected: `iv-provision` has `iv`
> and no `mcp-agent`, and has both MCP integrations. Read properly, that single
> row shows `tag:iv` attaching things. Three successive corrections in this one
> section have all been the same mistake — reasoning about the exe.dev control
> plane from inside a VM, which can see effects but not rules. **Confirm
> attachment from `ssh exe.dev integrations`, off-VM.**

### The `tailnet` tag

`api-tailscale` attaches to a **dedicated exe.dev tag that grants nothing else**:

```bash
ssh exe.dev integrations attach api-tailscale tag:tailnet   # once
ssh exe.dev tag <vm> tailnet                                # per VM that should join
ssh exe.dev new --name=<vm> --tag=tailnet ...               # new VMs inherit it
```

**Not `tag:iv`**, though that was the obvious candidate and the earlier proposal
here. `iv` already means "gets the MCP integrations"; adding `api-tailscale`
would have made one tag mean two unrelated things, the second far stronger than
the first. The whole argument against `auto:all` below is about not widening who
can mint auth keys — quietly folding that capability into a tag handed out for
MCP access is the same mistake at smaller scale, and harder to notice because it
looks like reuse rather than expansion.

A tag named for the capability also survives contact with people. `tag:iv` reads
as "our VMs", so tagging a new box `iv` looks like housekeeping; `tag:tailnet`
reads as "this VM may join the tailnet", which is the decision actually being
made. Tag names are the only documentation an operator sees at the moment they
act.

**What it buys.** A recreated VM rejoins on its own. Today a fresh VM is inert
until someone attaches the integration by hand — and it cannot be reached from
another VM to fix, because it is not on the tailnet yet and `*.exe.xyz` needs an
exe.dev SSH key that no VM holds. The bootstrap is breakable only from a
workstation. `--tag=tailnet` at creation closes that hole without weakening
anything else.

It keeps the consent property this document is built on. The decision moves from
"attach an integration after creation" to "create it with `--tag=tailnet`" —
still deliberate, still made off-VM, but now durable across a recreate instead of
being lost with the disk. An untagged VM stays off the tailnet exactly as before.

> Durable across a recreate **done deliberately**: `ssh exe.dev new --tag=tailnet`
> carries the tag, and `cp` inherits tags from the source VM. A replacement
> created without the flag is a fresh, untagged VM — the tag is not attached to
> the *name*. That is the correct behaviour (a new VM should not silently inherit
> a grant), but it means the win is "one flag at creation" rather than "nothing to
> remember".

### Re-provisioning an already-joined VM does not re-join it

Tagging the existing fleet is safe to do at any time, including immediately.
`install_tailscale` returns early when `tailscale status` succeeds — it only
ensures `RunSSH` is set — and never reaches the key-minting path. That matters
because the join path *deletes any node sharing this hostname* before joining, to
avoid Tailscale's `-1` suffix. On an already-joined VM that would delete the node
out from under the connection running the provisioner.

So the tag changes nothing for a VM that is already a member; it takes effect the
next time one is created or genuinely needs to re-join.

**The cost, stated plainly.** Every `tailnet`-tagged VM can mint `tag:dev` auth
keys, and the proxy does not restrict which Tailscale API paths an attached VM
may call — including deleting other nodes. That is a real widening from
"attached to nothing", and the tag should be applied to VMs that genuinely belong
on the tailnet rather than as a default. It should be weighed against the actual
alternative, which is not "nobody holds it" but "somebody attaches it under time
pressure and forgets to detach" — which is what happened to
`repo-iv-provision-rw` on 2026-08-19. If hard enforcement is wanted, the broker
described at the end of this section is the answer, and it is orthogonal to how
the integration is attached.

`tag:iv` and `mcp-agent` are left alone. They overlap — both effectively mean
"an IV fleet VM that gets the MCP integrations", and consolidating them is worth
doing — but that is a separate cleanup with its own blast radius, and doing it in
the same motion as a security-relevant grant is how one of the two ends up
unreviewed.

### Why not `auto:all`

exe.dev also offers `integrations attach <name> auto:all`, which attaches to
every VM in the account **including every VM created in the future**. For
`api-tailscale` that is the wrong shape, and specifically it discards the
property the top of this document is built on: the attachment *is* the consent
signal.

Under `auto:all` there is no signal left — a throwaway sandbox, a client canary,
or a VM running untrusted generated code would all be able to mint preauthorized
`tag:dev` keys against the tailnet, and to call any other Tailscale API endpoint
the backing credential permits, up to and including deleting other nodes. "Least
authority means it is normally attached to nothing" and `auto:all` cannot both be
true.

The two integrations exe.dev ships with `auto:all` by default — `reflection` and
`llm` — are the contrast that makes the rule legible: both are read-mostly and
scoped to the VM asking, so a new VM having them harms nothing. Tailnet
membership is not in that class. `tag:iv` is the smallest change that fixes the
recreate problem without giving that up.

The integration must proxy to the Tailscale API base URL `https://api.tailscale.com`;
the VM-side endpoint that matters is `https://api-tailscale.int.exe.xyz/api/v2/oauth/token`
(the only call that needs the injected credentials — everything after uses the
returned 1h Bearer token against the public API).

A direct HTTP proxy integration does not restrict which Tailscale API paths an
attached VM can call — code on the VM can hit any endpoint the backing
credential permits. The skill only mints an auth key, but if you need hard
server-side enforcement of "create exactly one key for this VM," put a small
broker in front instead of attaching the raw proxy.

### What a `tailnet`-tagged VM can actually do (measured 2026-08-19)

Worth stating concretely, because "no credentials on the VM" is true and easy to
misread as "no authority from the VM". Both hold at once: the secret stays at the
edge, and the VM wields what it protects.

From a tagged VM, with nothing on disk and no login:

```bash
TOKEN=$(curl -sS -X POST -d grant_type=client_credentials \
  https://api-tailscale.int.exe.xyz/api/v2/oauth/token | jq -r .access_token)
# -> a 1-hour Tailscale API bearer token
```

The token is **tailnet-wide, not VM-scoped**: it is the same credential for every
tagged VM, so what one tagged VM can do, all of them can. What that amounts to is
fixed by the scopes on the backing OAuth client, and since 2026-08-19 that is
**`auth_keys` on `tag:dev`, and nothing else** — the token endpoint echoes it:

```json
{"token_type":"Bearer","expires_in":3600,"scope":"auth_keys","tags":"tag:dev"}
```

Measured from a tagged VM after the narrowing:

| Operation | Result |
| --- | --- |
| Mint a preauthorized `tag:dev` auth key | **200** — the join works |
| Mint a key for `tag:iv-aperture-admin` | refused — *"requested tags are invalid or not permitted"* |
| `GET /tailnet/-/devices` (enumerate the tailnet) | **403** |
| `GET /device/<id>`, `/device/<id>/routes` | **403** |
| `GET /acl` (policy file), `/dns/nameservers` | **403** |

So the accurate summary of the tag is: **a tagged VM can join or rejoin the
tailnet unattended, and can do nothing else.** It cannot enumerate the tailnet,
cannot delete or rename a node, and cannot mint its way into a more privileged
tag.

Before the narrowing this was materially worse — the same token listed all 17
nodes and could delete any of them, workstations and phones included. Recorded
because the reasoning generalises: the exe.dev proxy prevents credential *theft*
(the secret never reaches the VM, cannot be exfiltrated, rotates centrally) but
it does not bound *authority*. Only the scopes do that, and they are easy to
leave at whatever the client was first created with.

That is the trade the tag makes, and why it is a tag of its own rather than a
capability folded into `tag:iv`: applying it should feel like a decision.

### How the grant was narrowed (done 2026-08-19)

A broker was **not** the first move, and turned out not to be needed. Tailscale's
own OAuth scopes did the job declaratively, on the credential behind the proxy,
with no code to write or operate — one change in the admin console narrowed every
tagged VM at once.

The client previously held `auth_keys` **and** `devices:core`. Only `auth_keys`
is required to join; `devices:core` was what allowed deleting other people's
nodes:

| Scope | Grants | Needed for |
| --- | --- | --- |
| `auth_keys` | create/delete auth keys for the named tags | joining — the whole point |
| `devices:core` | list devices; delete, rename, re-tag any of them | *only* stale-node cleanup |

In the current admin console the scopes are a Read/Write grid rather than a list
of scope names, which does not resemble the API documentation. **Settings → Trust
credentials → Generate**, then under **Keys → Auth Keys** check **Read** and
**Write**, leave every other row unchecked, and select **`tag:dev`** in the tag
selector that appears (mandatory once Auth Keys Write is set). OAuth clients are
immutable, so this is create-and-swap, not an edit.

The credential reaches the VM through exe.dev's `api-tailscale` HTTP-proxy
integration, in the **Authentication** field as **basic auth** — username =
client ID, password = client secret. That is not a workaround: Tailscale's token
endpoint accepts client credentials as HTTP Basic (`client_secret_basic`), which
is why the VM can POST `grant_type=client_credentials` with no secret in the body
and get a token back.

Order matters, because one thing cannot be tested in advance. Swap the credential
first, verify a preauthorized `tag:dev` key still mints, and revoke the old client
only after that passes — whether `preauthorized: true` falls inside Auth Keys
Write is not documented anywhere. (It does; verified 2026-08-19.)

**The accepted cost.** `provision-iv.sh` deletes a stale node sharing the VM's
hostname before joining, or Tailscale appends a `-1` suffix. That cleanup needs
`devices:core`, so it can no longer run: a recreated VM reusing a hostname now
comes back as `<name>-1` — precisely the `-1` problem documented at the end of
this file. Since 3.0.14 provisioning detects the 403 and says what it skipped,
so the consequence is announced rather than discovered later as a hostname nobody
can account for. The fix when it happens is to delete the stale node from the
admin console.

So the ordering is: **scopes first, broker only if scopes are insufficient.** A
broker is the right answer to "create exactly one key, for exactly this VM,
once" — a per-VM bound that Tailscale's scope model does not express, since every
tagged VM shares one credential. That is a real gap, but it is a smaller one than
it looked before measuring, and it costs a service to run and keep available.

## Upgrading a VM to a new revision

The normal upgrade is an in-place re-provision: check out a newer `iv-provision`
tag/sha in `~/iv-provision` and run `provision-iv.sh` again. This updates the team
software/configuration layer and rewrites `~/iv-provision.lock` without wiping
the VM or changing its tailnet identity. The `upgrade-vm` skill documents this
as Path A.

A full destroy/recreate is only needed for a fresh disk or an exe.dev-managed
base change that re-provisioning cannot address. In that exceptional path,
destroy the VM, delete the stale tailnet node from a trusted workstation,
recreate from the pinned base image, rejoin, and re-provision. It **wipes the VM's local
disk**.

## Security boundary

The VM never receives the long-lived Tailscale API token or OAuth client secret.
It receives only the one-use auth key it presents to `tailscale up` — short-lived,
non-reusable, preauthorized, and tagged. Do not bake Tailscale credentials into
the image, a setup script, environment variables, dotfiles, or repo files.

## Alternatives considered

Two simpler-looking paths exist. Both were evaluated 2026-07-28 and rejected;
the two-step mint above is the minimum shape that keeps the long-lived
credential off the VM while still producing a **tag-owned** node.

**OAuth client secret used directly as the auth key.** Tailscale accepts an
OAuth client secret in place of an auth key
(`tailscale up --auth-key='$SECRET?ephemeral=true&preauthorized=true'
--advertise-tags=tag:dev`), and such devices stay tag-owned. This would collapse
the mint to zero API calls — but it puts the raw client secret in the VM's
process arguments, which is exactly what the exe.dev proxy exists to prevent.
Two `curl` calls is the price of the security boundary above.

**OAuth device provisioning**
(<https://tailscale.com/docs/features/oauth-apps/device-provisioning>, alpha as
of 2026-06). An authorization-code flow where the access token _is_ the auth
key — no separate key-creation call. It does not fit:

- It requires a **human consent click per device**, with no refresh tokens. The
  join path is unattended by design; an agent runs it and the VM comes up.
- Devices are **user-owned, not tag-owned**. The dotfiles ssh_config dispatches
  on `tag:dev` via `Match host *.ts.net exec "ssh-tailnet-tagged %h tag:dev"`,
  which is what lets a new VM work without re-running `install.sh`. Untagged
  user devices would need a hand-written stanza each, and any ACL keyed on
  `tag:dev` would miss them.
- "Only users in the same tailnet as the OAuth app can authorize devices
  through it" — at odds with the per-client-tailnet multi-tenant direction.

It is aimed at internal tools provisioning devices on behalf of named users (an
IT self-service portal), not at machine-to-machine fleet enrollment. Revisit
only if the shape of the fleet changes to want user-attributed nodes.

## Stale-node `-1` suffix

Tailscale MagicDNS names are sticky per node. If you rebuild a VM with a hostname
that an old, not-yet-reaped ephemeral node still holds, the **new** VM registers
as `<name>-1`. Because the join path holds no device-delete authority, it does
not clean up the old node.

For the common case, re-provisioning in place keeps the existing node and name.
If a full rebuild with a reused hostname collides, delete the stale node from a
trusted admin context (the Tailscale admin console, or the API from a workstation
holding the real credential) — not from the freshly created VM. Or wait for the
ephemeral node to be reaped. The `upgrade-vm` skill documents both paths.

## Operational notes

- A VM that is never joined simply stays reachable over `ssh <vm>.exe.xyz`.
- Override the proxy URL, tag, or hostname by editing the join command
  (`api-tailscale.int.exe.xyz`, `tag:dev`, `$(hostname)`).
- If the `api-tailscale` integration is backed by a Tailscale API access token,
  that token has the normal API-token expiry and must be rotated in exe.dev
  before it expires.
