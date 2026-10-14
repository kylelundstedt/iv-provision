---
title: "Project Manager Agent"
---

**Status: agreed design, revised 2026-10-14; partially demonstrated, not fully
qualified.** The stable filename `resident-layer.md` is retained for existing
links. The [NanoClaw core-loop test](nanoclaw-core-loop-test.md) demonstrates the
basic resident mechanism without Rex, not the complete project-manager role.

The manager is **accountable for moving the project toward agreed outcomes and
keeping its plans, status, decisions, and documentation accurate**. It delegates
specialist work within explicit authority. The
[Agent Group Operating Model](agent-group-operating-model.md) defines the
isolated groups; [Rex-Based Project Management](rex-based-project-management.md)
defines how the owner accesses them.

## 1. Mission and authority

Use one resident **Manager group per project**, beside that project's specialist
groups and state. For an IV Dataset this is the Dataset Manager; for a client
Concierge it is the client-level coordinator. No fleet-wide manager-of-managers
is required initially. Cross-project access is explicit, not inherited from
network reachability or a shared provider account.

The owner retains authority over objectives, material scope/budget changes,
capability grants, and required release approvals. Manager may coordinate the
approved plan within reviewed permissions. It cannot approve for the owner,
override independent Audit, publish, or read all specialist memories by default.

**Own management artifacts; delegate specialist implementation and independent
review.** This replaces the overly restrictive "notice, route, notify only"
description. Producing a project brief, assignment, decision record, or status
update is management work, not a forbidden implementation task.

The runtime must remain responsible when terminals disconnect. It may use
supervised services and short-lived agent turns rather than one permanently
running model conversation. The Mac workspace is a collection of clients to
these managers, not another coordinating agent.

## 2. Responsibilities and owned artifacts

| Responsibility                 | Owned artifact or observable result                                          |
| ------------------------------ | ---------------------------------------------------------------------------- |
| Maintain intent                | Approved objectives, scope/non-goals, requirements, acceptance criteria      |
| Plan delivery                  | Versioned plan, milestones, dependencies, prioritized backlog                |
| Assign and supervise           | Bounded assignments, owners, results, blockers, pending approvals            |
| Allocate effort                | Concurrency/retry/budget limits, stop conditions, escalation recommendations |
| Coordinate independent review  | Exact revision/candidate under review, findings and disposition              |
| Keep decisions explicit        | Rationale, alternatives, owner decisions, unresolved assumptions             |
| Maintain project documentation | Current overview, technical docs, runbooks, release notes and evidence links |
| Report honestly                | Distinct configured, observed, tested, blocked, and unverified states        |

Manager detects stalled work, conflicting assignments, repeated failed attempts,
and scope changes. It brings the owner a concise account and recommendation
rather than silently expanding authority or retrying indefinitely. Specialist
reports carry enough evidence for coordination without exposing private scratch
context or credentials.

## 3. Delivery lifecycle and definition of done

Manager establishes approved scope, commissions specialist planning/challenge
where useful, sequences assignments, routes review findings, and coordinates
acceptance. For dataset and concierge publication, the canonical path is the
[isolated group handoff](agent-group-operating-model.md#handoff-and-release-contract),
not a generic "integrator may deploy" workflow.

Worker success means **ready for verification**, not automatically done. The
assignment's completion contract identifies the exact artifacts/revisions,
required independent review, tests, documentation/runbook updates, publication
or deployment state if relevant, and disclosed limitations. Keep implemented,
merged, audited, approved, published, and consumer-verified separate.

Record decisions and results as they happen. Periodic retrospectives propose
reusable memory/skill improvements; weekly distillation is not the only way a
manager may learn that a task completed or the owner changed a priority.

### Resident lifecycle: remember, wait, wake, act, record

1. **Remember:** persist approved commitments, task identities, state, and pending
   decisions, with pointers to authoritative artifacts.
2. **Wait:** do not invoke a model continuously merely to remain present.
3. **Wake:** accept an owner message, worker event, or scheduled reconciliation.
4. **Act:** inspect actual state and take a bounded authorized next step, ask for
   a decision, or do nothing. Never infer permission from the wake-up itself.
5. **Record:** persist the outcome and next responsibility, then wait again.

A reconnect must address the existing manager, not create another owner of its
assignments. On restart, reconcile workers, receipts, and pending approvals
before resuming; do not blindly repeat uncertain side effects. The scheduler
and ledger must retain responsibility across turns even if each turn uses a
fresh model context. Conversation persistence alone is not this lifecycle.

## 4. Project website and communication

**Every project manager owns keeping its project documentation website current.**
It can write management documentation and delegate specialist pages, builds, and
publication. Ownership does not grant deployment privileges or waive review.

| Website section         | Reader's question                                                   |
| ----------------------- | ------------------------------------------------------------------- |
| Overview                | What is the project for, and what is out of scope?                  |
| Status                  | What is underway, blocked, completed, or awaiting a decision?       |
| Plan and milestones     | What happens next, with which dependencies and acceptance criteria? |
| Decisions               | What was decided, why, and what remains unresolved?                 |
| Technical documentation | How do interfaces, schemas, and important assumptions work?         |
| Operations              | How do we run, test, deploy, recover, and troubleshoot?             |
| Releases and evidence   | What actually shipped, with which checks and known limitations?     |

Generate status from the operational ledger where possible; render authored
content from versioned files. The site is a **published view**, not a second
manually synchronized task database. Show observation times and source/release
revisions; stale or unavailable inputs must not appear current and healthy.
Use runtime-generated evidence timestamps rather than model-invented times.

Classify audiences before publication. Do not expose private group memory,
transcripts, credentials, drafts, or cross-entitlement content. Internal project
status publication may be preauthorized by reviewed policy; authoritative client
content must still follow its Audit/approval/Publish path. A "docs update" must
not bypass that path or broaden access. Validate builds/links/content scope and
preserve the prior working release on failure.

The three interfaces have different jobs: **conversation** directs work,
**Rex** exposes permitted running activity, and the **website** explains the
project without requiring an agent interrogation. Select a separate notification
channel for owner decisions when no terminal is connected; recorded delivery is
not proof that a human received a notification.

## 5. State and sources of truth

| State                | Purpose and boundary                                                                         |
| -------------------- | -------------------------------------------------------------------------------------------- |
| Project knowledge    | Approved charter, plans, decisions, technical docs and runbooks in versioned artifacts       |
| Operational ledger   | Durable assignments, dependencies, worker IDs, results, approvals and delivery state         |
| Group working memory | Small curated orientation and pointers; private to that group, not a shared fleet scratchpad |
| Archives             | Authorized session history and code provenance; evidence, not control authority              |
| Website              | Audience-appropriate published presentation of selected knowledge and status                 |

A ~1–2k-token working-memory budget is an orientation target, not a ceiling on
project knowledge. Runtime conversations and task state need not be committed or
reviewed per message. Secrets and raw private histories do not belong in public
project Git history. Version approved reusable guidance; keep runtime evidence
in its authorized store, with backup and retention rules.

AgentsView and Entire remain optional history/provenance sources, with access
scoped so archive searches cannot bypass group isolation. Recall can supply
learning candidates; it does not grant permission to alter skills or policy.
Event feeds and health hints must be qualified for freshness/replay and checked
against authoritative worker state. No archive, issue tracker, or forge is a
prerequisite for the basic resident mechanism demonstrated by the core test.

## 6. Delegation, permissions, and recovery

Use the [group model](agent-group-operating-model.md) for responsibilities and
handoffs rather than sharing private conversations. The worker interface should
support start, resume, inspect, cancel, collect results, and surface/deliver
approval decisions. Bind decisions to assignment, requested action, and revision;
reject stale decisions and prevent repeated delivery from duplicating actions.
Keep task, artifact, conversation, group, and Rex object identities distinct.

Policy enforcement belongs outside manager/worker write authority. Neither
Manager nor a delegated agent can change effective permissions, protected
checks, or approval requirements. Fleet runtime changes remain pinned/reviewed;
no unreviewed executable self-modification. Assess risk by effect, not extension:
mutating SQL is not a prose-only fast lane.

Manual owner intervention must be reconciled with the ledger before manager
control resumes, without bypassing the group's boundaries. Use finite retries,
concurrency limits, and explicit failure states. Treat human absence, archive
outage, failed credential access, and ambiguous worker completion as conditions
to handle—not permissions to guess, retry forever, or change providers silently.

## 7. Runtime and replacement requirements

Use an existing runtime where it meets the contract; do not build an artificial
500-line manager. Keep custom integration glue small. Cheap checks can handle
routine supervision; substantial judgment may need a capable model, invoked only
when useful.

Runtime, model, and access/billing are separate choices. The manager and workers
must use qualified, supported subscription access; no automatic paid-API
fallback. The design must be portable across frontier providers, not dependent
on Shelley, Claude, Codex, or one vendor portal becoming the entire manager.
A working login alone is not a billing/authorization qualification.

Provider handover must preserve approved artifacts, assignments, pending
approvals, and recoverable project context. It need not transfer a proprietary
native conversation verbatim. Retire components when a supported replacement
preserves those contracts, not according to an assumed product roadmap.

### Decided, configured, tested, outstanding

- **Decided:** project-local Manager groups, specialist isolation, management and
  website ownership, wait–wake–act behavior, and replaceable interfaces.
- **Configured:** NanoClaw Manager exists on `iv-cmg-concierge`; that does not
  imply a qualified fleet-wide project-manager rollout.
- **Tested:** [one bounded synthetic scheduled wake and read-only reconnect](nanoclaw-core-loop-test.md),
  without Rex. No automatic terminal replay or absent-user notification was proved.
- **Outstanding:** specialist-reply wake-up, protected release/approval gates,
  restart recovery, supported multi-provider access and exhaustion behavior,
  website maintenance/publication, and the Rex interaction paths. The
  [Concierge contract](cmg-concierge-publication-contract.md) records its narrower
  implementation handoff; no live roles or permissions change in this revision.
