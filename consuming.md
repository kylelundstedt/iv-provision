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
DuckDB/Apex/AWS/Tigris/rclone/tailcat/herdr versions, skills count, manifest pin, and
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
for a one-off. See `tailnet.md` for the full flow and why the tag grants nothing
else.

## Upgrading to a new revision

To move a VM to a newer provisioning recipe, update `~/iv-provision` to the target
tag/sha and re-run `provision-iv.sh`. This is normally an in-place operation: it
preserves the disk and tailnet identity while refreshing pinned tools, vendored
skills, agent configuration, and `~/iv-provision.lock`.

The `upgrade-vm` skill also documents the exceptional destroy/recreate path for
cases that genuinely require a fresh disk or newer exe.dev-managed base. That
path wipes the VM; see `tailnet.md`.

### Documentation ships with the tag

A VM's `~/iv-provision` sits **detached at a release tag**, and the `*.md` /
`*.qmd` files are part of that checkout. So the docs a VM shows — to a person or
to an agent reading `README.md` on the box — are the docs as of its tag, not as
of `main`.

That makes a documentation correction a *release*, not a merge. When `main`
changes a rule the fleet is meant to follow, cut a patch tag; otherwise every VM
keeps presenting the superseded text as current, and confidently. This is not
hypothetical: the "Authoring boundary" section was corrected on 2026-08-19 and
merged after `3.0.9` was tagged, leaving all eleven checkouts advertising the
rule that had just been reversed. `3.0.10` exists to ship that text.

Doc-only patch releases are cheap and expected — `2.5.1` and `3.0.10` are both
of that kind. Re-provisioning to pick one up is the same ~23-second in-place
re-run as any other upgrade, since nothing else in the recipe changed.

## Agent config (installed by provision-iv.sh)

Every provisioned VM gets team agent defaults — no manual setup required:

- **AGENTS.md** — team-wide instructions for Claude Code and Codex (data work
  conventions, exe.dev SSH discipline, skill usage rules)
- **Claude Code settings** — SSH guard hook (blocks parallel SSH to exe.dev) and
  `DISABLE_NON_ESSENTIAL_MODEL_CALLS`
- **MCP servers** — MotherDuck and GitHub (work) pre-registered via exe.dev proxy
  (no secrets on the VM)
- **Skills** — mviz, duckdb-skills, motherduck agent-skills,
  quarto-authoring, brand-yml, marimo-notebook, marimo-batch, find-skills,
  archil-guide

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
