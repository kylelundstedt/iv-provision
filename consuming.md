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

## Rex: upstream installation, separate private access

**Installation is still opt-in.** The default-on design in
[Design](design.md#proposed-rex-default-for-all-linux-microvms) is a proposal,
not a changed provisioning default.

### Install the package

```bash
sudo bin/install-rex --plan
sudo bin/install-rex --apply
```

This delegates package installation, distribution/architecture selection,
repository setup, and signed-package verification to Rex's official installer.
The IV version policy targets our APT-based Ubuntu guests; it does not
reimplement upstream's installers for unrelated distributions.
There is no amd64-only package URL or IV architecture whitelist. A tailnet
connection and an owner profile are not needed to install the package.
Native Apple ARM64 qualification is separate from upstream ARM64 support.

`provisioning/rex/release.json` records the reviewed upstream installer checksum,
channel, and exact Rex version. The installer is downloaded to a root-owned
cache and verified **before** execution, not piped unchecked into a shell.
IV supplies a command-scoped APT version policy because upstream has no
exact-version flag: a missing approved version fails rather than selecting a
newer snapshot or Ubuntu's unrelated Perl `rex` package.

Rex remains held against ordinary apt upgrades; OS security patching is unchanged.
An existing different version is preserved unless `--allow-version-change` is
explicitly approved. Package upgrades can restart already-running vendor
services, while account servers and their programs can remain on the old binary.
Check both `rex version` and `rex server status` when qualifying an upgrade.
Installation alone does not enable a server, run `rex server install`, or
configure network access. It records actual provenance in
`/var/lib/iv-rex/installation.lock`, distinguishing a verified existing package
from an executed installer, and updates only Rex's field in an existing IV lock.

### Configure private remote access

On a private Ubuntu 24.04 development microVM with systemd, the standard
UID-1000 `exedev` account, and an already-joined tailnet:

```bash
sudo bin/configure-rex --plan --owner owner@example.com
sudo bin/configure-rex --apply --owner owner@example.com \
  --allow-tag tag:trusted-client
```

The configurator remains development-only. Proposed default package installation
on a production microVM would not automatically enable this remote profile.

The owner and optional tagged clients are explicit private provisioning inputs,
not identities stored in this public repository. A tag authorizes every process
on each tagged device, not an individual person. Tagged servers have no personal
owner fallback. Only `exedev` is admitted; no anonymous, wildcard, or root grants.

The configurator uses the vendor's always-on `rex-login-server.service` and a
small documented drop-in. Its root PAM broker delegates terminals to `exedev`.
HTTPS on the private Tailscale name forwards to a root-only Serve socket;
tagged clients use `http://<machine>.<tailnet>.ts.net:7297` inside WireGuard.
No Funnel, public listener, or shared tailnet policy change is made.
Conflicting profiles, services, sockets, or HTTPS routes are refused rather than
overwritten. Configuration provenance is separate in
`/var/lib/iv-rex/configuration.lock`.

To retain the opted-in provisioning workflow:

```bash
# Package only; no owner or tailnet required.
IV_INSTALL_REX=1 ./provision-iv.sh

# Package plus explicitly approved private remote profile.
IV_INSTALL_REX=1 IV_REX_OWNER=owner@example.com \
  IV_REX_ALLOW_TAG=tag:trusted-client ./provision-iv.sh
```

The old standalone `install-rex --owner ...` interface is replaced by
`configure-rex`; the existing opted-in provisioner environment remains supported.

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
