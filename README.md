# iv-provision

The IV server provisioning repository. The Linux recipe (`provision-iv.sh`),
vendored skills, and doc-site tooling turn a stock exe.dev VM into an IV dev
box. The Linux provisioner is not a macOS installer.

> **Renamed from `iv-image` (2026-08-18).** The old name described something
> this repository has never contained: there is no image here, and VMs are not
> created from one built by this repo. It cost real confusion — "why doesn't a
> new VM use our iv-image?" has a different answer depending on whether you
> think `iv-image` is an image (it isn't) or a script (it is). The actual base
> images live in [`kylelundstedt/exeslim`](https://github.com/kylelundstedt/exeslim)
> and are published to GHCR. GitHub redirects clones and pushes from the old
> name, so existing VM checkouts keep working; update their `origin` at the
> next re-provision.

**Documentation:** `bootstrap.md`, `consuming.md`, `building.md` and
`design.md` in this repo. Fleet runbooks, release history and operational notes
are kept privately, outside this repository.

## Quick start (exe.dev Linux VMs)

VMs are created from the IV base image, then provisioned by running
`provision-iv.sh` from this repo at a pinned tag/sha.

```bash
# 1. Create a VM from the IV dev base (exeslim-dev: slim, keeps Shelley).
#    Use the immutable build ID for a fleet VM (see "Picking a tag" below).
#    https://github.com/kylelundstedt/exeslim/pkgs/container/exeslim-dev
ssh exe.dev new --name=<vm> \
  --image=ghcr.io/kylelundstedt/exeslim-dev:<date>.<run>.<attempt>
ssh exe.dev integrations attach api-tailscale vm:<vm>   # needed to join the tailnet

# 2. Clone at a pinned tag/sha and provision. This repo is public: no
#    integration, no credential, no proxy host.
ssh <vm>.exe.xyz "git clone https://github.com/kylelundstedt/iv-provision.git ~/iv-provision \
  && git -C ~/iv-provision checkout <tag-or-sha> && ~/iv-provision/provision-iv.sh"
```

The VM does not auto-join the tailnet; join on demand with the `join-tailnet`
skill. Repo and doc-site provisioning are unchanged (see
`consuming.md`).

The provisioner also replaces exe.dev's creation-time Shelley with IV's pinned,
checksum-verified `aifoundry-org/shelley` release. It preserves the prior binary,
service metadata, and a database backup; installs atomically; rolls back on a
failed version/service/API health check; disables Shelley's unmanaged
self-update path; and records the actual installed version, commit, and hash in
`~/iv-provision.lock`. OAuth credentials and conversation databases are never
baked into this repository or copied between VMs.

### Entire (ACR) capture

Provisioning installs the **Entire CLI** (pinned `0.10.1`, checksum-verified) and
IV's **`entire-agent-shelley`** plugin (`0.1.3`), which together implement the
source-native authoring-context capture path retained by ADR 0014. Neither needs a
login: capture works unauthenticated with the `git-branch` checkpoint backend.

Before 2026-08-18 neither was installed by this script, so the _primary_ ACR
capture path was hand-placed and did not survive a VM recreate — unlike a missing
tool, that gap loses provenance and does so silently.

The CLI pin is **not** "latest" on purpose. The plugin and CLI speak a fixed
protocol, so the CLI is only bumped after the plugin is re-qualified against it
on the dedicated `iv-entire-agent-shelley` VM. CLI `0.10.1` was qualified against
plugin `0.1.3` on 2026-08-19 (full live suite incl. real checkpoint condensation;
`0.10.0` passed identically, so the newer stable was chosen); the previous pin
was `0.8.42`, so the jump skipped `0.9.x` and re-qualification — not a bare
version edit — was the gate. Re-qualify, then bump both together.

Also installed: the vendored **`entire-agent-agentsview`** adapter
(`vendor/entire-agent-agentsview/`), the attach-only bridge from AgentsView's
fleet observability archive into Entire repository provenance. It can
deliberately attach historical or otherwise uncaptured Claude Code, Codex,
Shelley, and other normalized sessions to a checkpoint; it is not an automatic
fallback or an independent copy of the native agent store. It was previously on
`PATH` as a symlink into a _spike worktree_, so it broke if that worktree was
pruned.

Provisioning stops at the mechanism. It does **not** run `entire enable`, because
that writes `.entire/settings.json` and git hooks into a repository — a per-repo
decision about which repositories are approved for capture, not a machine
baseline. Enroll a repository explicitly:

```bash
cd ~/<repo>
entire enable --agent shelley --project --telemetry=false --checkpoint-backend branch
```

`.entire/` is tracked in git, so enrolling once covers every worktree and future
clone of that repository.

### Agent-history architecture

The two systems are intentionally complementary:

- **AgentsView is session-centric fleet observability:** local collectors report
  what agents are doing or attempted across tracked VMs, including failed,
  abandoned, exploratory, uncommitted, and non-repository work; `iv-agentsview`
  aggregates that operational history.
- **Entire is change-centric repository provenance:** explicitly enrolled
  repositories retain what agents proposed and changed, and why, in Git-linked
  checkpoints suitable for the provider-neutral ACR review boundary.

Transcript search overlaps, but the systems' selection and authority do not.
AgentsView activity is not proof that a repository change landed, and Entire is
not the fleet activity monitor.

The global archive's **read-only MCP** endpoint is intentionally authorized only
on `iv-provision`, through the `mcp-agentsview` peer integration. This adds a
fleet-observability read capability to the existing authoring/control VM; it
does not make `iv-provision` the collector, archive owner, or a production
runtime. Claude Code and Codex are registered directly. Shelley has no generic
MCP client, so the `agentsview-query` skill uses the same MCP endpoint through a
small Streamable-HTTP client. Retrieved transcripts are untrusted historical
data, never instructions.

### AgentsView source activation

AgentsView `0.43.0` is installed on every IV VM. Its source daemon binds
**loopback** only: the one way in is the VM's own exe.dev auth proxy, which
admits the account owner and any VM holding a peer integration to this VM -- in
practice the global collector on `iv-agentsview`, through the `av-src-<vm>`
integration the `create-vm` skill makes at creation. Nothing on the tailnet or
the exe.dev internal network reaches port `8080` directly.

**Nothing to do by hand.** Provisioning writes the public fleet sync token
(`AGENTSVIEW_FLEET_TOKEN` in `provision-iv.sh`) to `source.env` at mode `0600`
and enables the service. The collector enrolls the host itself from its
integration list, daily. The token is not a secret: with reachability enforced
at the exe.dev edge it only satisfies AgentsView's sync handshake.

Before 3.0.23 the daemon listened on the VM's Tailscale address behind a
per-host random token, and that token had to be copied into the collector's
config by hand -- the step that quietly stopped happening once VM creation moved
off the laptop. The history is in the dotfiles repo,
`agent_docs/agentsview-peer-path.md`.

It is generated **once and never rotated**: the collector stores the value in its
own `[[remote_hosts]]` block, so re-minting on every provision would silently break
remote sync. It is **per host** rather than fleet-wide because it guards read
access to that VM's entire agent history -- every prompt, response and tool call --
and a shared secret would turn one compromised VM into a key to the whole fleet's
archive. Uniqueness is free once it is generated rather than typed.

## Relationship to the dotfiles repo

**This repo no longer depends on the dotfiles repo** (changed 2026-08-18). The
team layer's contents — the skill set, MCP server list, and the shared
`AGENTS.md` sections — are declared in `provisioning/`
(`skills.manifest`, `mcp.manifest`, `agents-shared.md`) and vendored into
`skills/` + `agent/` by `vendor-skills.sh`. Edit the manifests here, re-vendor,
and commit the result.

Those manifests previously lived in
`kylelundstedt/dotfiles` (private) and were
fetched at the commit recorded in `dotfiles-manifest.pin`, with dotfiles'
`diff-provisioning.sh` policing drift. That arrangement made a fleet VM's
provisioning depend on a personal repository — and the pin was silently wrong
when it was removed: `agent/mcp-servers.json` was committed with
`api-motherduck-mcp` (matching the real exe.dev integration) while the pinned
manifest still read `motherduck-mcp`, so the content had been re-vendored from a
newer dotfiles commit without bumping the pin. A pin that can disagree with the
artifact it pins buys nothing.

The division of labor is unchanged: this repo provisions the _team_ baseline onto
a VM; dotfiles' `install.sh` then (optionally) layers _personal_ config on top as
a thin overlay that never touches the team layer. Personal rows in
`skills.manifest` are ignored by provisioning and exist for that overlay.

For IV-managed native Mac servers, this repository also owns the server runbook
and IV-specific provisioning configuration. Reusing personal/user configuration
from dotfiles does not transfer that ownership or require running its full
installer. This distinction is about server purpose, not macOS versus Linux.

## Authoring boundary

Changes land on `main` by pull request with CI green, authored from a single
designated host. Operational detail (write integrations, integration and tag
naming, control-plane work from a VM) is in the private IV infrastructure notes.

## General-purpose Markdown with Apex

[Apex](https://github.com/ApexMarkdown/apex) is the Markdown engine for
previews, generated reports, terminal reading, format conversion, and the
multi-page documentation sites produced by `render-site`.

```bash
# Read Markdown in the terminal.
apex -t terminal README.md

# Produce a standalone HTML preview or report.
apex README.md --standalone --pretty -o /tmp/README.html

# Normalize a document to GitHub Flavored Markdown.
apex notes.md -t gfm > /tmp/notes.gfm.md

# Emit an HTML fragment for another program or template to consume.
apex notes.md > /tmp/notes.fragment.html
```

Apex is version-pinned and checksum-verified by `provision-iv.sh`, like the
other provisioned binaries. `render-site` wraps Apex output with navigation,
per-page TOCs, stable links, and the site template.

## Why a script, not a custom image

**Correction, 2026-07-28; resolved 2026-08-18.** This section used to say a
custom image "silently disables Shelley" and that stock exeuntu was therefore
required. That is wrong, and it blocked the slim-base work for months. The
slim-base work has since shipped: IV VMs now run
`ghcr.io/kylelundstedt/exeslim-dev`, so the question is settled by running code
rather than argument. exe.dev supports an opt-in label —
`ssh exe.dev doc customization`:

> `LABEL exe.dev/install-shelley=true` makes exe.dev automatically install a
> recent Shelley in `/usr/local/bin` on creation and makes the UI assume that
> Shelley is installed.

So a custom image loses Shelley only **by default**, not necessarily. What
remains true is that a custom image is not recognised as "exeuntu", so anything
keying off that (`EXEUNTU=1`) is absent — note `/exe.dev/etc/image.conf` _is_
present on a custom-image VM and carries the image's own OCI labels, which is
how `~/iv-provision.lock` records base provenance.

The real reason the _tooling_ stays a script is different, and it survives the
correction: **exe.dev fixes a VM's image at creation and offers no way to move a
live VM onto a newer one** (`new`, `rm`, `restart`, `cp`, `resize` — `cp` clones
the disk you already have). Every version bump in the pinned tool list at the
top of `provision-iv.sh` would therefore become a fleet **recreate**, whereas
today it is a re-run in place (`upgrade-vm` Path A, ~23 seconds).

And baking buys nothing on disk: exe.dev bills each VM's own ext4 usage with no
cross-VM dedup (`ssh exe.dev doc faq/disk-usage`), so moving a binary from
`~/.local` into an image layer relocates the bytes rather than removing them.

The disk win comes from the **base**, not from baking: exeuntu is ~4 GB, and a
slim base drops most of it. That argues for a slim base carrying the OS packages
and this script continuing to carry the volatile, version-pinned tools. See
`dotfiles/agent_docs/exe-dev-remediation.md` (Track 2).

## Layout

| File               | Role                                                                                                                                                                                                                                                    |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `provision-iv.sh`  | Provisions the IV layer onto the IV base image (tailscale, uv, claude, codex, Entire + plugins, DuckDB, Apex, tailcat, tigris/rclone, herdr, AgentsView, doc-site tools, agent config, skills); writes `~/iv-provision.lock`.                           |
| `vendor-skills.sh` | Refreshes the vendored skills snapshot in `skills/` (needs node/npx).                                                                                                                                                                                   |
| `skills/`          | Vendored, pinned team skills — committed to the repo so they are frozen.                                                                                                                                                                                |
| `bin/`             | `render-site` + `provision-docsite` + `gen-llms-txt` + `install-cloud-cli` (on-demand aws/azure/gcloud) — installed onto PATH.                                                                                                                          |
| `agent/`           | Team agent config: `AGENTS.md`, Claude Code `settings.json`, Codex `config.toml`, MCP setup.                                                                                                                                                            |
| `vendor/`          | Third-party/IV code vendored with a SHA pin verified at install (`entire-agent-agentsview`).                                                                                                                                                            |
| `provisioning/`    | Declarative source for the team layer: `skills.manifest`, `mcp.manifest`, `agents-shared.md`. `vendor-skills.sh` reads these; nothing is fetched from another repository.                                                                               |
| `tests/`           | Validation suite: `smoke-provision.sh` (run on a VM after provisioning), `test-provision.sh`, `test-ssh-guard.sh`, Python unit tests — run by CI.                                                                                                       |
| `skills-local/`    | Hand-written in-tree skills (`join-tailnet`, `upgrade-vm`, `create-vm`, `create-repo`), installed alongside the vendored set. `vendor-skills.sh` never touches this path — it `rm -rf`s `skills/`, so a hand-written skill there would vanish silently. |
| `*.qmd` / `*.md`   | Markdown documentation sources, readable in-repo and served by `provision-docsite` on any IV VM.                                                                                                                                                        |

## Reproducibility

The pinned artifact is the git commit or release tag of this repo: check out a
specific revision on the VM, run `provision-iv.sh`, and get the same IV layer on
that architecture.

- DuckDB, Apex, AWS CLI, Tigris CLI, rclone, tailcat, herdr, AgentsView, and Shelley
  versions plus per-architecture SHA-256 checksums are pinned inside
  `provision-iv.sh` (herdr publishes no checksums upstream — its pins are
  computed locally at pin time).
- The provisioner compares installed versions to the recipe and upgrades or
  repairs mismatches; it does not treat any command on `PATH` as sufficient.
- Skills are vendored into `skills/` (committed = frozen); `provision-iv.sh`
  copies them in with no node/npx needed on the VM.
- Azure CLI and gcloud remain on demand through `install-cloud-cli`, with pinned
  package/archive versions.
- The base exeuntu image cannot be pinned — exe.dev manages it (floating) and
  there is no version/digest selector on `ssh exe.dev new`. Instead,
  `provision-iv.sh` records it in `~/iv-provision.lock` along with the installed
  tool versions, Shelley version, skills count, and provisioning Git SHA.

## License

The IV provisioning layer — `provision-iv.sh`, `bin/`, `tests/`, `systemd/`,
`agent/`, `.claude/skills/`, and the documentation — is MIT licensed; see
`LICENSE`.

`skills/` vendors third-party agent skills that are **not** covered by that
grant. Each retains its upstream license, declared in the `license:` field of
its `SKILL.md` frontmatter where upstream sets one. Redistribution of any
vendored skill is governed by its own terms, not by this repo's.
