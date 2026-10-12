---
title: "Resident Layer"
---

**Status: design, not implemented.** Decided 2026-10-12 in conversation on
`iv-provision`; recorded here so the design survives the conversation. Nothing
in this page is provisioned yet. The `kgl-hermes` VM — empty, and named for a
framework this design rejects — is to be retired rather than reused; the
resident layer gets a fresh VM once it has a name of its own.

## The problem: episodic agents have no presence

Every agent on this fleet is episodic. A Shelley conversation exists only while
a turn is executing; between turns it is rows in SQLite — nothing runs, nothing
watches, nothing can notice. Scheduled conversations wake on a timer, but each
wakeup is a fresh conversation with no memory of the last one's conclusions:
ten Monday check-ins are ten amnesiacs. Every interaction is initiated by a
human or a cron entry.

The missing capability is a **standing presence**: a process that persists
through time, accumulates a model of what is going on, and can *correctly
initiate contact* — notice something, judge from history that it matters, and
interrupt the owner. That judgment-to-interrupt is the litmus test: if every
exchange starts with the human typing, there is no presence, only a very good
tool.

Concretely, today nothing on this fleet will *tell* anyone that the Monday
Shelley drift-check opened an issue, that an Anthropic refresh token expired on
`iv-docs` (it is discovered when a conversation fails), or that a delegated
job finished. The resident layer is the thing that notices, remembers, routes,
and reports — and does nothing else.

## Where it sits

```
memory / identity / policy      ← the resident layer (this page)
conversation & tool execution   ← per-VM Shelleys, Claude Code, Codex
session / process substrate     ← tmux/herdr today; Rex-class multiplexers later
machine & network fabric        ← microVMs, tailnet, exe.dev integrations
```

The layers below are owned and working. Per-VM Shelley servers are the
execution layer — each sits on its project's actual state, and a management
conversation can already delegate to them over the tailnet
(`ssh <vm> shelley client chat …`), collect with `client read -wait`, and tag
for tracking; the 3.0.28 fleet rollout was run exactly this way. AgentsView is
the fleet-wide episodic archive; Entire is code provenance. The resident layer
adds only what none of them have: continuity, a channel, and policy.

## Specification

Each attribute carries a falsifiable test, in the same spirit as
`tests/test-provision.sh`: an invariant nobody has to remember is an invariant
a check asserts.

### A. Role — what it is

| # | Attribute | Test |
|---|-----------|------|
| 1 | **Manager, not worker.** Verbs: notice, consult, route, record, notify. All real work is delegated to per-VM Shelleys or TUI agents. | Tool surface is exactly: channel I/O, memory read/write, `shelley client` over the tailnet, scheduler. No repo checkouts, no project credentials. |
| 2 | **Standing presence.** Owns an inbound channel and a heartbeat; exists between interactions. | It sometimes initiates contact, correctly — and knows enough history for the interruption to be apt. |

### B. Form — how it is built

| # | Attribute | Test |
|---|-----------|------|
| 3 | **Thin.** A few hundred lines; triage is a rules check or one cheap small-model call; asleep when nothing happens. | LOC budget (~500) enforced in review; triage cost per event is near zero. Growth toward 2,000 lines means it is absorbing work that belongs in another layer. |
| 4 | **Designed for obsolescence.** Interfaces over internals: every function maps to an upstream Shelley feature with a named retirement trigger (see table below). | Each component can be deleted independently; memory is kept in formats a future Shelley could inherit directly (markdown in a git repo, not a bespoke store). |

### C. Governance — what keeps it safe

| # | Attribute | Test |
|---|-----------|------|
| 5 | **Policy-constrained.** A reviewed policy *file* (data, not code): which VMs it may delegate to, auto-run vs. ask-first actions, spend ceilings, quiet hours. Default deny. | Policy changes arrive only as git commits; the layer cannot edit its own policy. |
| 6 | **Disciplined like the fleet, bounded like a project.** The runtime is pinned and provisioned (immutable platform layer); its *knowledge* evolves (project layer); git is the boundary. | Runtime changes go through pin-and-review like every provisioned tool; knowledge changes go through PRs. Nothing changes at runtime outside git. |

### D. State — what it knows

| # | Attribute | Test |
|---|-----------|------|
| 7 | **Owned working memory.** Bounded, curated files (~1–2k tokens: in-flight work, owner preferences, standing decisions) in a git repo. The only store it owns, and the hot path for triage. | Size budget enforced; `git log` of the memory repo reads as a coherent history of its understanding. |
| 8 | **Archives behind it, read-only.** AgentsView for fleet-wide episodic memory, Entire for code provenance — queried on demand, never on the triage hot path. | Read-only access; removing the archives degrades deep questions, not triage. |
| 9 | **Learning by batch distillation.** A scheduled job reads recent AgentsView sessions and proposes updates — to working memory and to per-project `skills/` — **as PRs**, risk-tiered: prose and SQL fast-laned, executables reviewed. | Zero runtime self-modification; every learned thing has a commit, an author trail, and a reviewable diff. |

## Retirement triggers

"Temporary" is a property with triggers, not a mood. Upstream Shelley
(`boldsoftware/shelley`, observed Oct 2026) is assembling the same capabilities:
channels connecting conversations to external chats, a `message_user` tool,
in-place compaction that lets one conversation live indefinitely, and
subagent-supervisor ergonomics. As the `aifoundry-org` fork picks these up and
they pass fleet qualification, the resident layer sheds parts:

| Component | Retired by | Expected order |
|-----------|-----------|----------------|
| Inbound channel | fork ships channel support | first |
| Outbound notification | fork ships `message_user` | second |
| Scheduling / heartbeat | fork ships queued + scheduled runs | third |
| Triage + policy | a Shelley conversation cheap enough to be the triage loop | fourth |
| Working memory / identity | **no upstream trigger yet** | last — possibly never |

The end state is acceptable and small: the layer may shrink to just a memory
repo and a policy file that a long-lived Shelley conversation consults.

## Why not an existing project

Surveyed 2026-10-12. The category splits cleanly into *thick resident agents
that do their own work* and *thin dispatchers without memory or presence*;
nothing found is the thin resident memory-and-policy layer that delegates to
remote durable agent servers — largely because this fleet already owns the
pieces (per-VM workers, archives, provenance) that make thickness unnecessary.

| Project | Verdict |
|---------|---------|
| **Hermes Agent** (Nous Research) | Closest feature match: resident, messaging gateways, bounded curated memory, scheduler. Rejected as-is: a large framework whose signature self-improving skills loop writes its own executable skills at runtime — the opposite of the vendored-and-reviewed skills regime — and it overlaps Shelley as a worker rather than layering above it. Its bounded-memory-file design (small curated memory and user-profile files over a searchable archive) is adopted here. |
| **NanoClaw** | Right size (~500 lines), wrong execution model: its containerized workers do the work themselves, and giving them fleet reach would break the container isolation that is its entire point. Its size discipline is adopted here. |
| **cmesh** | Policy-gated agent delegation over Tailscale — the delegation transport as a dedicated project. Its policy-gating shape informs attribute 5. |
| **sortie** | Thin event→agent-session dispatcher (tracker-driven). Right shape, no memory, no channel, no presence. |
| **Paseo / mission-control UIs** | Human-driven dashboards over parallel agents — the Rex-adjacent niche, not a resident layer. |

The design is therefore: **Hermes's memory conventions, NanoClaw's size,
cmesh's policy gating, Shelley as the execution layer, AgentsView/Entire as the
archives.**

## Relation to the self-improving-loop question

Fleet discipline and per-project self-improvement are not in conflict; they
govern different layers. The discipline protects the *platform* layer (what
provisioning stamps identically on every VM). Self-improvement belongs to the
*project* layer: pipeline-specific knowledge (schema drift fixes, backfill
procedures, vendor quirks) distilled into each repo's `skills/` directory —
proposed as PRs by the batch-distillation job (attribute 9), never written at
runtime. Self-improvement ≠ unreviewed self-mutation: put the loop inside git
and the conflict dissolves. The risk-tiered fast lane exists because a loop
whose every lesson waits a week for review is a dead loop.

## Open decisions

- **Name** (and therefore the VM name — the role is steward/switchboard-shaped;
  `kgl-hermes` is retired, not renamed, so the name never lies about contents).
- **Channel**: which messaging surface the owner actually lives in.
- **First policy file**: delegation allow-list, ask-first set, spend ceiling,
  quiet hours.
- **Memory curation rules**: what earns a line in the bounded working memory,
  and what the distillation job may touch.
