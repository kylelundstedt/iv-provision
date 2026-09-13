# iv-provision

The IV provisioning layer for exe.dev VMs: a script (`provision-iv.sh`) plus
vendored skills and doc-site tooling that turn a stock exe.dev VM into an IV
dev box.

> **Renamed from `iv-image` (2026-08-18).** The old name described something
> this repository has never contained: there is no image here, and VMs are not
> created from one built by this repo. It cost real confusion — "why doesn't a
> new VM use our iv-image?" has a different answer depending on whether you
> think `iv-image` is an image (it isn't) or a script (it is). The actual base
> images live in [`kylelundstedt/exeslim`](https://github.com/kylelundstedt/exeslim)
> and are published to GHCR. GitHub redirects clones and pushes from the old
> name, so existing VM checkouts keep working; update their `origin` at the
> next re-provision.

**Full documentation:** the `*.qmd` / `*.md` files in this repo (`consuming.md`,
`building.md`, `bootstrap.md`, `tailnet.md`, …). The hosted doc site was retired
with the `iv-registry` VM (2026-07-14); any IV VM can serve it again with
`provision-docsite ~/iv-provision` (see `registry.md`).

## Quick start

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
skill (see `tailnet.md`). Repo and doc-site provisioning are unchanged (see
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

AgentsView `0.38.1` is installed on every IV VM. Its source daemon binds
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
[kylelundstedt/dotfiles](https://github.com/kylelundstedt/dotfiles) and were
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

## Authoring boundary

GitHub is the canonical source of truth, and changes land on `main` by pull
request with CI green. **Provisioning changes originate on the `iv-provision`
VM**, which is the only host carrying the `repo-iv-provision-rw` and
`repo-exeslim-rw` integrations.

The write integrations _are_ the boundary. This is not a convention asking to be
remembered: a fleet VM without a writable integration cannot push, so "where did
this change come from" has a mechanical answer rather than an honour-system one.

### Why a single writer, when PR + CI already gates merges

Between 2026-08-18 and 2026-08-19 this section said the opposite — _any host may
author_ — on the reasoning that single-workstation authoring had never been
enforced by permissions and PR + CI was the guardrail that actually held. Two
things from the 2026-08-19 fleet refresh argue the other way, and the rule was
restored the same day.

**PR + CI gates what merges, not what gets tried.** `iv-docs` was found carrying
two unpushed commits, one of them a fix for the Shelley socket-activation race
that `main` had _already_ fixed differently and better (`bd5c11f`, shipped as
`3.0.1`). Two hosts independently solved one bug; the fleet VM's version was
never wrong enough to notice and never right enough to merge. It also documented
itself as "fixed in 2.9.1" — a tag that was never cut. That is the specific
failure mode of distributed authoring on a repo whose entire job is to be the one
agreed description of a machine.

**A VM fixing its own provisioner cannot cleanly test the fix.** The provisioner
is the thing under change _and_ the thing running; a defect that only manifests
on older bases (as the 3.0.9 PATH-probe bug did) is invisible from a VM that has
already been re-provisioned. The authoring host is deliberately not a workload
VM, so it can hold a checkout at an arbitrary revision without disrupting work.

The honest counter is that a rule enforced only by attachment gets broken the
moment it is inconvenient — which is exactly what happened on 2026-08-19, when
`repo-iv-provision-rw` was attached to `iv-foundry-stage2` as an expedient and a
dozen commits were pushed from there. The answer is to make compliance cheap
rather than to abandon the rule: the authoring VM exists, `ssh iv-provision`
reaches it from anywhere on the tailnet, and a re-provision there costs ~23
seconds. If an exception is genuinely needed, attach the writer deliberately,
land the change by PR, and **detach it again** — the exception should be an
event, not a new steady state.

### Opening a PR from a VM

The repo integrations proxy git over `https://github.int.exe.xyz/...`, and the
same host serves the **GitHub API** under `/api/v3`. So a PR can be opened from
the VM without `gh` and without a token:

```bash
git push https://github.int.exe.xyz/kylelundstedt/<repo>.git <branch>

curl -fsS -X POST https://github.int.exe.xyz/api/v3/repos/kylelundstedt/<repo>/pulls \
  -H 'Content-Type: application/json' \
  -d '{"title":"...","head":"<branch>","base":"main"}'
```

`api.github.com` is _not_ the endpoint to use here — unauthenticated it can read
public state but cannot create anything, which reads as "the API does not work
from a VM" if that is the only thing tried.

**On a fork, always pass `base`, and check where the PR landed.** GitHub's
web "compare" UI defaults the base to the **upstream parent**, not to your own
`main`. `kylelundstedt/exeslim` is a fork of `ryanlewis/exeslim`, so visiting the
`pull/new/<branch>` link after a push proposes the branch _to upstream_ — which
is how a one-file, +14-line fork-only change became a 10-commit, +319-line PR
against someone else's repository (`ryanlewis/exeslim#13`, 2026-08-19). Every
commit on our `main` that upstream lacks gets swept in, because the diff is
computed against upstream's `main`, and a `FORK.md` edit is by construction
never a merge candidate upstream.

The API form above is not subject to that default: `base` is explicit, and the
URL names the repository the PR is opened _on_. Verify after creating it:

```bash
curl -fsS https://api.github.com/repos/kylelundstedt/<repo>/pulls/<n> \
  | jq '{base: .base.repo.full_name, commits, changed_files}'
```

If `base.repo.full_name` is not the repo you meant, close it and reopen with an
explicit base rather than editing it.

### What else holds

No VM worktree is authoritative, and a checkout on a fleet VM is expected to sit
detached at a release tag (see `consuming.md`). Linux compatibility canaries are
created on demand and stay read-only unless a writer is deliberately attached;
delete the canary after validation.

## Naming exe.dev integrations and tags

The fleet's integrations and tags are a small shared namespace, and it drifts
whenever a name records an incidental fact instead of a function. Two conventions
keep it legible. Both are enforced by review, not code — exe.dev has no schema
for them — so they live here as the standing rule.

### Integrations: `<kind>-<subject>[-<variant>]`, named for function

The **kind** prefix says what the integration _is_, so its purpose is readable
without opening it:

| Prefix    | Meaning                                               | Examples                                        |
| --------- | ----------------------------------------------------- | ----------------------------------------------- |
| `repo-`   | a git repository credential                           | `repo-iv-provision-rw`, `repo-gitlake-ro`       |
| `mcp-`    | an MCP server for agents                              | `mcp-motherduck`, `mcp-github-home`             |
| `api-`    | a plain HTTP API proxy (not MCP)                      | `api-tailscale`, `api-notion`, `api-fannie-sso` |
| `bucket-` | object storage                                        | `bucket-gitlake-examples`                       |
| `svc-`    | a catalog (`integrations catalog`) service credential | `svc-notion-songs`, `svc-telnyx-test`           |

Git-credential integrations additionally carry an access **variant**, `-rw` or
`-ro`, because whether a host can _write_ a repo is the load-bearing fact (see
**Authoring boundary** above). So the full form for repos is
`repo-<repo>-<rw|ro>`.

**Platform integrations are exempt.** `llm`, `notify`, and `reflection` are
provided by exe.dev itself, carry fixed single-word names, and are attached
`auto:all`; the convention governs the integrations _you_ create, not these.

The rule that matters most is **name for function, never for an incidental**:

- `api-github-copilot-home` named the upstream URL's _brand_
  (`api.githubcopilot.com`) and read as "the GitHub Copilot product", which is
  not what it is — it is the GitHub **MCP** server. Renamed to `mcp-github-home`.
  The `mcp-` vs `api-` split exists precisely for this: both are `http-proxy`
  integrations, so the _type_ cannot tell an agent-facing MCP server from a plain
  API — only the name can. The test is **function, not upstream URL**: an MCP
  server is `mcp-` even when its target is `api.motherduck.com`, which is why
  `api-motherduck-mcp` (an MCP server wearing an `api-` name) was renamed
  `mcp-motherduck`.
- The legacy `github-<owner>-<repo>` and `<owner>-<repo>` schemes name the GitHub
  _account_, an incidental. They are migrated to `repo-<repo>-<rw|ro>`. A github
  integration's name is not referenced by any VM config (git addresses the repo
  by URL, `https://github.int.exe.xyz/<owner>/<repo>.git`), so these renames are
  cosmetic — no reconfiguration, no re-provision.

### Tags: capability-grants, or grants-nothing identity labels

A tag is one of two things, never both:

- A **capability tag** is named for the capability it grants, and **applying it
  to a VM is the act of consenting to that grant**. `tailnet` (tailscale
  key-minting), `notion` (the Notion API), `mcp-agent` (the MCP server set),
  `fannie-sflpd` (the Fannie repo) all pass.
- An **identity tag** may exist, but **grants nothing**. The moment an identity
  tag attaches an integration, fleet _membership_ silently governs _access_ —
  which is `auto:all`'s failure mode wearing a friendly name. `tag:iv` failed
  this: it read as "this is an IV VM" while quietly also granting MotherDuck and
  GitHub MCP, so it was retired in favour of the capability tag `mcp-agent`.
  Fleet membership is derived from the intrinsic `iv-*` name prefix instead, so
  no grant-bearing identity tag is needed.

Three sub-rules follow:

1. **One capability tag per coherent capability.** Never widen an existing grant
   tag with a new or stronger grant — mint a new tag, so applying it stays a
   deliberate consent. (This is why the tailnet key-minting credential got its
   own `tailnet` tag rather than being folded into `tag:iv`.)
2. **Never let an identity tag attach an integration.**
3. **A tag that no VM carries but an integration still references is a phantom** —
   detach it. A tag that VMs carry but no integration grants is dead — remove it.

### Control-plane facts are checked off-VM

A VM's `reflection` integration reports that VM's own tags and integrations, but
**never the attachment rules** — effects are visible from inside a VM, the rules
that produce them are not. Confirm attachments with `ssh exe.dev integrations
list` (or the `/exec` HTTPS API with a read-scoped token), not by inference from
a VM. Three consecutive corrections to the tailnet docs came from getting this
wrong.

### Migration status

The git-integration migration (2026-08-19) is **complete**: every git
integration is now `repo-<repo>-rw`, created with `--act-as-user` so commits
attribute to the GitHub account rather than the exe.dev app. The legacy
`github-<owner>-<repo>` / `<owner>-<repo>` names were recreated or deleted, and
`repo-dotfiles` gained its `-rw` variant.

Remaining renames to the convention:

| Current name         | Rename to          | Note                                                                                                                                                                                                                                                                   |
| -------------------- | ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `api-motherduck-mcp` | `mcp-motherduck`   | It is an MCP server; the name referenced the upstream URL. Team integration, so its `/mcp` URL lives in `agent/mcp-servers.json` and both `mcp.manifest` copies — rename is create-new → repoint → delete-old, then re-register the `motherduck` MCP server on IV VMs. |
| `notion-songs`       | `svc-notion-songs` | catalog service credential                                                                                                                                                                                                                                             |
| `telnyx-test`        | `svc-telnyx-test`  | catalog service credential                                                                                                                                                                                                                                             |

## Doing control-plane work from a VM

Two hand-written skills exist so that creating things does not require a laptop,
a terminal, or an SSH key — a request typed into the **Prompt Shelley** box on a
phone reaches a VM, and the VM can act. Both work the same way: an exe.dev
http-proxy integration holds the credential _at the edge_, and the VM sends an
unauthenticated request to an `int.exe.xyz` host.

| Skill         | Integration                                          | Creates                         |
| ------------- | ---------------------------------------------------- | ------------------------------- |
| `create-vm`   | `api-exe-new` (exe.dev CLI over HTTPS, `--cmds=new`) | exe.dev VMs on an IV base image |
| `create-repo` | `mcp-github-home` (GitHub's hosted MCP server)       | GitHub repos, seeded with files |

The shape is worth stating once, because it generalises: **a capability the VM
should have is an integration scoped to exactly that capability, not a token.**
`api-exe-new` can run `new` and nothing else — `ls`, `rm`, `whoami` and
`integrations list` all return 403. That scoping is what makes it safe to attach
to an agent-driven box.

Two asymmetries between them are load-bearing, and both are recorded in the
skills:

- `api-exe-new` cannot **check** anything (no `ls`), so name collisions are
  discovered by submitting. `mcp-github-home` can read freely, so a duplicate
  repo name fails cleanly and is reported verbatim.
- Neither can **undo**. There is no delete-VM permission and no delete-repository
  tool at all, so in both cases a mistyped name is the owner's to clean up.
  Confirm the name back before creating; that is the only guard there is.

`mcp-github-home` also creates a second write path to GitHub that does _not_ go
through the `repo-*-rw` integrations. Read **Authoring boundary** above with that
in mind: the single-writer rule for `iv-provision` and `exeslim` is enforced by
attachment, and MCP writes are not scoped per repo the way git integrations are.
The rule therefore has to be honoured rather than merely relied upon — use the
MCP write path for repos that have no integration _yet_, never to route around
one deliberately withheld.

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
| `provision-iv.sh`  | Provisions the IV layer onto the IV base image (tailscale, uv, claude, codex, Entire + plugins, DuckDB, Apex, tigris/rclone, herdr, AgentsView, doc-site tools, agent config, skills); writes `~/iv-provision.lock`.                                    |
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

- DuckDB, Apex, AWS CLI, Tigris CLI, rclone, herdr, AgentsView, and Shelley
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
