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

| File               | Role                                                                                                                                          |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `provision-iv.sh`  | Provisions the IV layer onto the IV base image (tailscale, agents, Entire, DuckDB, Apex, agent config, skills); writes `~/iv-provision.lock`. |
| `vendor-skills.sh` | Refreshes the vendored skills snapshot in `skills/` (needs node/npx).                                                                         |
| `skills/`          | Vendored, pinned team skills — committed to the repo so they are frozen.                                                                      |
| `bin/`             | `render-site` + `provision-docsite` + `gen-llms-txt` — installed onto PATH.                                                                   |

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
  image revision, Shelley version, installed DuckDB/Apex/AWS/Tigris/rclone/tailcat/Rex
  versions, skills count, manifest pin, and provisioning Git SHA).
- Prefer the immutable `<date>.<run>.<attempt>` build ID for a fleet VM. The tag
  is read once, at `new`, and never re-pulled, so it is not a pin that keeps
  applying — it only decides which build the VM starts from. What makes the
  immutable ID worth using anyway is that exe.dev caches mutable tags: 1 hour for
  `latest`/`main`/`master` and **24 hours for everything else**, so the tags that
  look most specific (`:<date>`, `:<sha>`) are cached longest and a mutable
  `:<date>` can serve yesterday's image for a full day. See "Picking a tag" in
  the [`exeslim` README](https://github.com/kylelundstedt/exeslim).

## Proposed Rex default for all Linux microVMs

**Proposal only: the refactor does not change `IV_INSTALL_REX` from its current
opt-in default, enable personal persistence, or deploy to more machines.**

### Scope and common entry point

Install Rex by default inside every IV-managed Linux microVM, on both exe.dev
and Apple Container, with an explicit `IV_INSTALL_REX=0` escape hatch. That means
both the amd64 and native ARM64 exeslim-family guests, not the macOS host and not
ordinary disposable application containers. There should be no per-hypervisor
package-selection code or implicit production-host exemption in the installer.

Make the package step part of common convergence, not a binary baked into the
base image. After qualification, change the common provisioner's opt-in gate to
default-on and advance both platform executors to the same pinned IV release.
For bare deployment microVMs that deliberately do not run the development
provisioner, have their bootstrap/executor invoke the same package-only helper
with its small prerequisites. Installing the full development/agent stack is
not a prerequisite. Changing only `provision-iv.sh` would not cover those bare
machines and must not be described as "all microVMs."

### Separate three responsibilities

| Responsibility    | Proposed default                                                                                                                                                                                                                                                                            |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Package           | The verified official Rex installer runs inside the Linux guest and chooses the native package. No beta credential or amd64-only artifact map.                                                                                                                                              |
| Local persistence | After the standard `exedev` account exists, run the installed CLI's `rex server install` **as `exedev`**, using its vendor-managed user units. Do not run it as root or invent another personal-server unit. Validate its coordination with the login broker before enabling it fleet-wide. |
| Remote access     | Configure the existing private login broker only from an approved machine access profile after tailnet enrollment. Without that profile, Rex stays local; installation does not open a network listener or grant access.                                                                    |

Private provisioning supplies the verified human login and any explicitly
approved client tags. Never infer a human owner from a tagged microVM or put
fleet identities in public defaults. Preserve the current `exedev`-only terminal
mapping, private Tailscale transports, and fail-closed handling of conflicting
services/routes. Existing production, controller, and newer-preview hosts need
an explicit migration decision; default-on must not mean silently downgrading
them, replacing their configuration, or widening shared tailnet policy.
Use the global package for the guest; do not layer an upstream `--user` binary
over it and accidentally shadow the managed version on `PATH`.

### Version policy

Keep one approved Rex version/channel and reviewed upstream installer checksum
in the common recipe. Let upstream/APT handle architecture and signed delivery;
keep the exact-version policy and hold rather than making new machines follow
an unqualified floating snapshot. Review an installer checksum change instead
of silently executing changed code. The upstream installer cache and release
process need an immutable retained copy for fresh-VM recovery if its mutable
download changes.

Record the actual installed version, architecture, binary/installer hashes, and
whether an install actually ran. Package updates can leave active account
servers on the old executable; preserving their sessions is intentional, not
proof of an upgraded runtime. Do not stop their work to make version checks pass.

### Acceptance and rollout

1. Qualify the refactor on a fresh amd64 exe.dev guest and an actual ARM64 Apple
   Container microVM using the current exeslim image contract. Mocked ARM64
   selection and upstream documentation are not native runtime qualification.
2. Test install/reapply, unavailable-version refusal, package hold, user-unit
   persistence, reboot, `exedev` UID, and existing-session preservation on both.
   For remote-enabled profiles, repeat authorized/unauthorized/revoked-client
   tests and actual HTTPS readiness. Honor certificate issuer retry windows.
3. Approve the default-on change separately, retain explicit opt-outs during
   adoption, and release one common recipe for both runtimes and bare bootstrap.
   Keep the existing authoring-VM runtime exclusion until explicitly lifted.
4. Roll out in batches without copying agent logins, keys, databases, or user
   configuration between machines. Approval of Codex hooks remains owner-owned.
   A restored Rex layout after reboot is not resumed terminal execution.

Actual host lists, exemptions, image digests, canary evidence, and rollout
decisions stay in the private operational record.
