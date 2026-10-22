---
title: "Design"
---

Why the IV layer is a script rather than a custom image, what lives where, and
what "pinned" actually means here. Moved off the landing page 2026-09-15: this is
durable rationale, and it was crowding out any statement of what the repo and its
host are.

## Why a script, not a custom image

**Corrected 2026-08-18.** This page used to claim that a custom Docker image
"silently disables Shelley" and that pinning a custom registry digest "is
exactly what breaks Shelley". That is false, it was retracted in `README.md` on
2026-07-28, and it blocked the slim-base work for months while remaining live on
this — the most-read — page. exe.dev ships an opt-in label
(`ssh exe.dev doc customization`):

> `LABEL exe.dev/install-shelley=true` makes exe.dev automatically install a
> recent Shelley in `/usr/local/bin` on creation and makes the UI assume that
> Shelley is installed.

A custom image loses Shelley only **by default**. IV VMs now in fact run a
custom image — `ghcr.io/kylelundstedt/exeslim-dev`, which sets that label,
supplies its own `shelley.socket`/`shelley.service`, and keeps Shelley fully
working. What remains true is that a custom image is not recognised as
"exeuntu", so anything keying off that (`EXEUNTU=1`) is absent.

The durable reasons this stays a script:

- **Version bumps must not require a fleet recreate.** exe.dev fixes a VM's
  image at creation and offers no way to move a live VM onto a newer one
  (`new`, `rm`, `restart`, `cp`, `resize` — `cp` clones the disk you already
  have). Every bump in the pinned tool list at the top of `provision-iv.sh`
  would become a fleet recreate, whereas today it is a re-run in place
  (`upgrade-vm` Path A, ~23 seconds).
- **Baking buys nothing on disk.** exe.dev bills each VM's own ext4 usage with
  no cross-VM dedup (`ssh exe.dev doc faq/disk-usage`), so moving a binary from
  `~/.local` into an image layer relocates bytes rather than removing them. It
  also goes stale: 2.0 GB of shadowed, superseded duplicates were measured
  fleet-wide on 2026-07-28 from tools baked into a base image.
- **Preinstall.** Provisioning installs DuckDB, Apex, doc-site tooling, agent
  config, and team skills in one pass. Apex handles both document-level
  Markdown and multi-page documentation sites.
- **Reproducible compute for GitLake.** The custom image's only real advantage
  was reproducibility via pinned image digests; that is replaced by the
  recipe-pinning model below (git tag/sha + pinned tools + vendored skills,
  with the base image recorded in a lockfile).

The disk win comes from the **base**, not from baking: exeuntu is ~4 GB and
`exeslim` is ~175 MB. The base carries OS packages; this script carries the
volatile, version-pinned tools.

## Layout

| File               | Role                                                                   |
| ------------------ | ---------------------------------------------------------------------- |
| `provision-iv.sh`  | Provisions the IV layer onto the IV base image (tailscale, agents, Entire, DuckDB, Apex, agent config, skills); writes `~/iv-provision.lock`. |
| `vendor-skills.sh` | Refreshes the vendored skills snapshot in `skills/` (needs node/npx).   |
| `skills/`          | Vendored, pinned team skills — committed to the repo so they are frozen. |
| `bin/`             | `render-site` + `provision-docsite` + `gen-llms-txt` — installed onto PATH. |

## Reproducibility (recipe pinning)

The pinned artifact is the git commit of this repo: check out a specific tag/sha
on the VM, run `provision-iv.sh`, and you get the same result.

- Tool release versions and per-architecture checksums are pinned inside
  `provision-iv.sh`; re-running it repairs or upgrades mismatched versions.
- Skills are vendored into `skills/` (committed = frozen); `provision-iv.sh`
  copies them in with no node/npx needed on the VM.
- The base image **is** pinnable, contrary to what this page said before
  2026-08-18: `ssh exe.dev new --image=ghcr.io/kylelundstedt/exeslim-dev:<build-id>`
  selects an immutable build. Stock `exeuntu` is the unpinnable case — exe.dev
  manages it (floating) with no version/digest selector. Either way,
  `provision-iv.sh` records what it landed on in `~/iv-provision.lock` (base
  image revision, Shelley version, installed DuckDB/Apex/AWS/Tigris/rclone/tailcat/herdr
  versions, skills count, manifest pin, and provisioning Git SHA).
- Prefer the immutable `<date>.<run>.<attempt>` build ID for a fleet VM. The tag
  is read once, at `new`, and never re-pulled, so it is not a pin that keeps
  applying — it only decides which build the VM starts from. What makes the
  immutable ID worth using anyway is that exe.dev caches mutable tags: 1 hour for
  `latest`/`main`/`master` and **24 hours for everything else**, so the tags that
  look most specific (`:<date>`, `:<sha>`) are cached longest and a mutable
  `:<date>` can serve yesterday's image for a full day. See "Picking a tag" in
  the [`exeslim` README](https://github.com/kylelundstedt/exeslim).
