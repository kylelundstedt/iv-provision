---
title: "Resident Layer"
---

**Status: design, not implemented.** Revised 2026-10-13: one resident
project-manager agent per project VM, with consolidated human access from the
Macs. This supersedes the earlier single-host placement and the assumption
that Shelley would eventually absorb the whole layer. No VM is created,
renamed, or retired by this design; `kgl-hermes` is not its deployment target.

This page defines the manager's responsibilities, memory, policy, and lifecycle.
[Rex-Based Project Management](rex-based-project-management.md) defines the
proposed session layout, execution workflow, and multi-project Mac workspace.

## Purpose and placement

The missing capability is continuity between work sessions: remembering agreed
priorities, tracking delegated work, noticing a blocked task, and asking the
owner for a decision without waiting for another prompt.

Deploy **one resident manager on each project-specific VM**, beside that
project's workers and state. It runs as an independent systemd service, not as
a foreground process whose lifetime depends on an open terminal. A conversation
client in a Rex block is an interface to that service, not the service itself.

| Layer                     | Responsibility                                                         |
| ------------------------- | ---------------------------------------------------------------------- |
| Resident project manager  | Policy, routing, working memory, task tracking, notifications          |
| Execution agents          | Planning, adversarial review, implementation, integration              |
| Session interface         | Rex project session remotely; manager conversation clients on the Macs |
| Project and machine state | Repository, worktrees, durable runtime records, VM and network         |

The Mac management workspace aggregates conversations with these managers. It
is **not another coordinating agent**. No fleet-wide manager-of-managers is
required initially; cross-project delegation needs explicit permission.

## Specification

### A. Role — what it is

| #   | Attribute                                                                                                                   | Acceptance test                                                                                                                |
| --- | --------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| 1   | **Manager, not worker.** Notice, consult, route, record, notify. Delegate planning and project changes to execution agents. | The manager's interface manages assignments and approvals; it does not implement tasks in worker checkouts.                    |
| 2   | **Standing presence.** Accept conversations and heartbeat events; maintain continuity between interactions.                 | Closing every client leaves the manager and assigned work running; the manager can notify the owner when a decision is needed. |

### B. Form — how it is built

| #   | Attribute                                                                                                                                                                | Acceptance test                                                                                                    |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------ |
| 3   | **Thin.** Aim for a few hundred lines of coordination code (~500 as a design budget, not a reason to omit recovery or safety). Prefer rules or a cheap model for triage. | Idle operation is inexpensive; growth triggers review for duplicated worker, storage, or transport functionality.  |
| 4   | **Replaceable and worker-independent.** Stable interfaces over product internals; no dependency on Shelley becoming the resident layer.                                  | Replace a worker or conversation client without losing project identity, memory, assignments, or approval history. |

### C. Governance — what keeps it safe

| #   | Attribute                                                                                                                                                           | Acceptance test                                                                                                                            |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| 5   | **Policy-constrained.** Reviewed policy data defines local worker permissions, ask-first actions, budgets, quiet hours, and any cross-project grants. Default deny. | The manager cannot modify its effective policy or authorize its own exceptions; sibling VMs are not implicitly trusted delegation targets. |
| 6   | **Pinned runtime, reviewable learning.** Platform changes use normal pin-and-review; durable knowledge and skills evolve through reviewed changes.                  | No runtime self-modification or unreviewed executable skills. Ordinary conversation and task-state writes remain allowed.                  |

### D. State — what it knows

| #   | Attribute                                                                                                                                                                                        | Acceptance test                                                                                                                        |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------- |
| 7   | **Project-local working memory.** Bounded curated files (~1–2k tokens) hold priorities, decisions, preferences, and pointers to active tasks. Distribute shared policy/preferences consistently. | Triage needs only small local context; memory changes have provenance; a client reconnect does not create a new manager.               |
| 8   | **Archives behind it.** Read AgentsView for session history and Entire for code provenance. Qualified event and health interfaces may supply triage hints.                                       | Archive failure does not erase active task state or prevent local coordination; hints are checked against authoritative worker status. |
| 9   | **Learning by batch distillation.** Recall is a candidate source, subject to qualification. Owner-approved candidates become risk-tiered PRs for project memory and skills.                      | Candidate approval and PR approval are separate gates; executable or mutating changes require explicit review.                         |

## Execution and authentication boundaries

Claude Code and Codex are the proposed subscription-backed workers, through
provider-supported interfaces and authentication. Shelley remains an optional
worker/workbench where its inference access and deployment are qualified. A
product running on a host does not by itself establish subscription entitlement
or inclusion in a mobile app or portal.

The design must not depend on copying CLI/Keychain tokens into another product,
or assume that an independent OAuth flow establishes provider authorization.
Validate each provider/product combination separately. This is a design gate,
not a legal determination about the existing fork. It applies to the resident
manager's own inference access as well as its workers.

Define a small worker-adapter contract: **start, resume, inspect, cancel,
collect results, and surface approval requests**. Keep assignment IDs distinct
from conversation IDs and Rex object IDs. Mark manager-owned assignments so
workers do not recursively create managers or duplicate delegations.

The contract also delivers approval or rejection, bound to the assignment,
requested action, and revision. Reject stale decisions; duplicate delivery must
not execute an action twice. Enforce policy outside manager and worker write
authority: prompt instructions alone are not a permission boundary, and a
manager cannot delegate a policy change it may not make itself.

Coordination is local by default. Fleet inventory and human access must not
depend on a vendor portal discovering every host. Rex and Zed are replaceable
interfaces, not the authority for project existence or task completion.

## Memory, operational state, and archives

The earlier phrase "the only store it owns" was too restrictive. Separate:

- **Curated working memory:** small, portable, git-versioned knowledge, updated
  through the review process.
- **Operational state:** durable conversations, task/worker identifiers,
  statuses, pending approvals, and delivery/reconnect cursors. Updated during
  operation, without requiring a PR per message. Storage format and recovery
  implementation remain open; neither terminal scrollback nor an archive
  search is the authoritative task ledger.
- **Archives:** AgentsView and Entire, consulted with project-appropriate
  read access. They provide history and evidence, not control authority.

The [AgentsView guide](https://www.agentsview.io/guide/) for v0.45.0 describes
experimental Recall with evidence and approval, live-message SSE, session-health
analysis, and Claude Code/Codex memory plugins. Proposed integration:

1. Use Recall for candidate lessons; owner approval is the first gate, followed
   by PR review for changes to memory or skills. The manager's archive access
   remains read-only; approval belongs to the owner.
2. Treat streamed messages and health analysis as optional triage inputs. They
   are **not yet qualified as reliable worker-completion events**, and the guide
   does not establish that health scores are pushed over SSE. Validate event
   semantics, freshness, reconnect/replay, and cost before relying on them.
3. Let qualified worker memory plugins retrieve relevant history. Assignments
   must still carry their scope, plan revision, and acceptance criteria.

The repository currently pins AgentsView 0.43.0. Qualify the required interfaces
and any pin bump separately; the guide alone does not establish when each
feature first shipped. Periodic reconciliation against worker status remains
necessary even if an event feed is adopted.

## Replacement criteria

Retire components when a supported alternative meets their requirements, not
according to an assumed Shelley roadmap or release order.

| Component                   | Replacement must preserve                                        |
| --------------------------- | ---------------------------------------------------------------- |
| Conversation client         | Remote identity, durable history, reconnect, approval handling   |
| Notifications and heartbeat | Delivery state, quiet hours, recovery after downtime             |
| Worker adapters             | Supported authentication, task identity, results, cancellation   |
| Coordination and policy     | Project scope, enforced permissions, owner approval gates        |
| Memory and runtime storage  | Portable knowledge, exportable history, recoverable active tasks |

A future Shelley enhancement could replace a component, but so could another
implementation. The aim is less custom code without surrendering continuity or
policy enforcement.

## Design influences and learning boundary

The earlier discussion borrowed bounded-memory conventions from Hermes, size
discipline from NanoClaw, and policy-gating ideas from cmesh. These are design
influences, not dependencies or commitments to deploy those projects.

Fleet discipline protects the platform layer; project-specific learning belongs
in reviewed memory and `skills/` changes. Batch distillation is delegated work,
not permission for a manager to rewrite itself. Risk-tier review concerns what
a change can do, not its extension: SQL that mutates data is not a prose-only
fast-lane change.

## Open decisions

- **Manager runtime and inference:** choose an implementation and a supported
  authentication path without assuming a Shelley dependency.
- **Conversation client:** select or build durable remote reconnect, consistent
  multi-client history, approval routing, and duplicate-command protection.
- **Policy:** define local permissions, cross-project opt-ins, review tiers,
  budgets, notification channels, and quiet hours.
- **State:** specify operational persistence, backup/restart recovery, and
  bounded-memory curation rules.
- **Qualification:** validate AgentsView integrations and the Rex deployment
  gates in [Rex-Based Project Management](rex-based-project-management.md).
