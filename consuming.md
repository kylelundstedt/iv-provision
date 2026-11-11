---
title: "Consuming"
---

## Creating a VM

VMs are created from the IV dev base image, then provisioned by running
`provision-iv.sh` from this repo at a pinned tag/sha:

```bash
# 1. Create a VM from the IV dev base. Pin the immutable build ID, never
#    the immutable build ID rather than a mutable tag.
ssh exe.dev new --name=<vm> \
  --image=ghcr.io/kylelundstedt/exeslim-dev:<date>.<run>.<attempt>
ssh exe.dev integrations attach api-tailscale vm:<vm>

# 2. Clone at a pinned tag/sha and provision. This repo is public: no
#    integration, no credential, no proxy host.
ssh <vm>.exe.xyz "git clone https://github.com/kylelundstedt/iv-provision.git ~/iv-provision \
  && git -C ~/iv-provision checkout <tag-or-sha> && ~/iv-provision/provision-iv.sh"
```

For reproducibility, pin by checking out a Git tag/sha of this repo before
running `provision-iv.sh`. Tool releases and checksums are pinned in the script,
and team skills are vendored in the repo. `~/iv-provision.lock` records the
exeuntu image revision, Shelley version, installed
DuckDB/Apex/AWS/Tigris/rclone/tailcat/Rex versions, skills count, manifest pin, and
provisioning repository SHA.

## Joining the tailnet (on demand)

The image does **not** auto-join the tailnet. A fresh VM is reachable only over
the exe.dev edge (`ssh <vm>.exe.xyz`). To put it on IV's tailnet, run the
`join-tailnet` agent skill (or the equivalent commands by hand) — it SSHes in
over `*.exe.xyz` and runs `tailscale up` with a one-use key minted through the
`api-tailscale` proxy. After it joins, use `ssh <vm>` (Tailscale) for the rest.

The join step needs the `api-tailscale` integration, which reaches a VM through
the **`tailnet` exe.dev tag** — `ssh exe.dev new --name=<vm> --tag=tailnet`, or
`ssh exe.dev tag <vm> tailnet` for an existing one. Per-VM attachment still works
for a one-off. See iv-infra `tailscale/tailnet.md` for the full flow and why the tag grants nothing
else.

## Upgrading to a new revision

To move a VM to a newer provisioning recipe, update `~/iv-provision` to the target
tag/sha and re-run `provision-iv.sh`. This is normally an in-place operation: it
preserves the disk and tailnet identity while refreshing pinned tools, vendored
skills, agent configuration, and `~/iv-provision.lock`.

The `upgrade-vm` skill also documents the exceptional destroy/recreate path for
cases that genuinely require a fresh disk or newer exe.dev-managed base. That
path wipes the VM; see iv-infra `tailscale/tailnet.md`.

### Documentation ships with the tag

A VM's `~/iv-provision` sits **detached at a release tag**, and the `*.md` /
`*.qmd` files are part of that checkout. So the docs a VM shows — to a person or
to an agent reading `README.md` on the box — are the docs as of its tag, not as
of `main`.

That makes a documentation correction a _release_, not a merge. When `main`
changes a rule the fleet is meant to follow, cut a patch tag; otherwise every VM
keeps presenting the superseded text as current, and confidently. This is not
hypothetical: the "Authoring boundary" section was corrected on 2026-08-19 and
merged after `3.0.9` was tagged, leaving every fleet checkout advertising the
rule that had just been reversed. `3.0.10` exists to ship that text.

Doc-only patch releases are cheap and expected — `2.5.1` and `3.0.10` are both
of that kind. Re-provisioning to pick one up is the same ~23-second in-place
re-run as any other upgrade, since nothing else in the recipe changed.

## Rex (explicit opt-in)

Rex is not installed by default. On a private Ubuntu 24.04 amd64 development
VM already joined to Tailscale, validate and explicitly install the qualified
public Linux package:

```bash
sudo bin/install-rex --plan --owner owner@example.com
sudo bin/install-rex --apply --owner owner@example.com
```

For a tagged client, add an explicitly approved `--allow-tag tag:trusted-client`.
Tags identify devices, not individual people; every process on a device carrying
an allowed tag can use the `exedev` account. The server being tagged does not
give it a personal owner. No wildcard, anonymous, or root-account grants are
created.

Alternatively, opt in while running the normal provisioner as the VM login user:

```bash
IV_INSTALL_REX=1 IV_REX_OWNER=owner@example.com ./provision-iv.sh
```

Use `IV_REX_ALLOW_TAG` for an explicitly approved tagged client. The standalone
installer accepts repeated `--allow-tag` arguments. Owner mappings are supplied
at deployment time and are not stored in this public repository.

`provisioning/rex/release.json` pins the official package URL, version, package
checksum, and executable checksum. Installation requires no beta token. A missing
or mismatched artifact fails closed; there is no fallback to a floating release.
The verified package is cached locally and Rex is held against ordinary apt
upgrades. OS security patching remains enabled. Changing the Rex version requires
`--allow-version-change` and requalification, including checking the running
account server: package upgrades preserve existing account servers and sessions,
so they can still be running the previous executable. The standalone installer
records its hashes in `/var/lib/iv-rex/provisioning.lock` and updates only the Rex
version in an existing `~/iv-provision.lock`; it does not claim that the entire
provisioner ran again.

The always-on `rex-login-server.service` starts at boot. Its root PAM broker
hands authorized clients to an `exedev` server; terminal programs do not run as
root. Shared-server and socket-activation units are disabled. HTTPS on the
machine's private Tailscale name forwards to a root-only Serve socket; tagged
clients use `http://<machine>.<tailnet>.ts.net:7297`, encrypted by Tailscale.
No Funnel, public listener, or shared tailnet policy change is made. Existing
incompatible Rex or Serve configuration is refused rather than overwritten.
An active login socket also requires an explicit operator migration; the
installer does not stop working socket-activated access before a package install
that might fail.

The normal provisioner sets up Rex's agent skill and hooks after installation.
For a standalone deployment, run
`rex skill setup --agent claude --agent codex --autostart=false` as `exedev`,
not root. Review any Codex hook approval in `/hooks`; do not change the owner's
existing permissions or provider configuration.

To stop remote access on a host configured by this recipe:

```bash
sudo tailscale serve --https=443 off
sudo systemctl disable --now rex-login-server.socket rex-login-server.service
```

Account servers and terminal programs deliberately survive stopping the broker.
To end those too, run `rex --autostart=false server stop` as `exedev`. A host
reboot ends terminal processes. Rex may restore saved session layouts into new
shells; this does not resume the programs that were running before reboot.
Fleet approvals, host selection, and qualification evidence belong in the
private operational record, not this public repository.

## Agent config (installed by provision-iv.sh)

Every provisioned VM gets team agent defaults — no manual setup required:

- **AGENTS.md** — team-wide instructions for Claude Code and Codex (data work
  conventions, exe.dev SSH discipline, skill usage rules)
- **Claude Code settings** — SSH guard hook (blocks parallel SSH to exe.dev) and
  `DISABLE_NON_ESSENTIAL_MODEL_CALLS`
- **MCP servers** — MotherDuck and GitHub (work) pre-registered via exe.dev proxy
  (no secrets on the VM)
- **Skills** — mviz, duckdb-skills, motherduck agent-skills,
  marimo-notebook, marimo-batch, tailscale, archil-guide; the Rex skill and
  hook where Rex is installed

Personal dotfiles layer on top. Running your own `install.sh` will overlay
`AGENTS.md`, add personal MCP servers (github-home, tigris, readwise), and
install additional skills.

## Cloning a repo (integration)

The image bakes in no repo credentials. To pull a private repo onto a VM, attach
a GitHub integration and clone over the exe.dev proxy — the credential stays in
exe.dev's proxy layer and never lands on the VM.

```bash
# Attach the integration to the VM (or to the `iv` tag, once, for all iv VMs)
ssh exe.dev integrations attach github-<owner>-<repo> <vm>

# Clone over the proxy host: https://<integration>.int.exe.xyz/<org>/<repo>.git
ssh <vm>.exe.xyz "git clone https://github.int.exe.xyz/<org>/<repo>.git ~/<repo>"
```

The `.int.exe.xyz` host is the VM-side proxy endpoint; exe.dev injects the real
GitHub token at the proxy, so no PAT or SSH key is stored on the VM. The
integration name and the `int.exe.xyz` subdomain match (e.g. integration
`repo-gitlake-rw` → `repo-gitlake-rw.int.exe.xyz`. A generic
`github.int.exe.xyz` also works and routes by repo path across whatever github
integrations are attached — prefer it, since it survives an integration rename).

This applies to **private** repos only. The two repos a VM needs to provision
itself — this one and `dotfiles` — are public and clone straight from
github.com, so a fresh dev VM needs no repo integration at creation.

## Provisioning a doc site

Each repo-VM serves its rendered site on `:8000` (the exe.dev HTTPS proxy port).
After cloning a repo (see above):

```bash
ssh <vm>.exe.xyz "provision-docsite ~/<repo>"
```

`provision-docsite` renders the Markdown project with Apex and serves a
**published release** on `:8000` with **nginx** (gzip + immutable cache headers).
The build tree (`_site`) is rebuilt destructively on each render, so nginx serves
from `<repo>/.docsite/current` (a symlink to a timestamped release) instead — a
failed or in-flight render never touches the live site. To refresh after edits,
re-run `provision-docsite ~/<repo>` (not bare `render-site`); the content swaps
atomically with no restart.
