---
title: "Agent Group Operating Model"
---

**Status: design decision, 2026-10-14; not a declaration of deployed controls.**
This is the canonical group-boundary and handoff model for the two patterns
below. Runtime configuration and qualification must be recorded separately.

**Define isolated agent groups first; have Rex expose them; move work between
them through explicit handoffs.**

| Project type     | Isolated agent groups                     |
| ---------------- | ----------------------------------------- |
| IV Dataset       | Manager / Write / Audit / Publish / Test  |
| Client Concierge | Manager / Curate / Audit / Publish / Test |

[Project Manager Agent](resident-layer.md) defines the manager's lifecycle and
accountability. [Rex-Based Project Management](rex-based-project-management.md)
defines the human workspace. The
[CMG Concierge Publication Contract](cmg-concierge-publication-contract.md)
specializes the client-serving handoff and records outstanding implementation.

## Groups are isolation boundaries

A group has its own persistent memory, conversation history, workspace, tools,
and authority. It is not just a role label, workflow stage, terminal window, or
model selection. Multiple workers in one group do not automatically get
independent memory or access boundaries merely because their sessions differ.

- Audit does not inherit Write's or Curate's private working context. It receives
  the frozen candidate, approved requirements, and explicit source/evidence
  references needed for independent assessment.
- Manager coordinates through assignments, status reports, findings, and receipts;
  it has no implied access to every specialist's private memory or credentials.
- Approved common facts may be supplied as versioned, read-only artifacts. This
  is not blanket shared conversational memory.
- Task blocks, model changes, and Rex window creation do not grant capabilities.
- Group isolation must also cover archives and tools: a search interface that
  exposes another group's private transcripts would defeat the boundary.
- Enforce access outside agent-editable instructions, with scoped mounts,
  credentials, message destinations, and protected gate/test definitions.
  Instructions describe the contract; they are not sufficient enforcement.

A separate group is warranted when persistent context or authority must differ.
Separate worktrees can prevent concurrent code-edit collisions, but do not by
themselves provide group-level isolation or independent review.

## Common responsibilities

| Group       | Owns                                                                                           | Permitted handoffs                                                                                 | Must not do                                                                                                                                  |
| ----------- | ---------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| **Manager** | Objectives, commitments, plans, assignments, decisions, project documentation, reported status | Bounded assignments and approved specifications out; specialist reports and evidence references in | Approve for the human, alter authoritative audit findings, grant itself capabilities, publish, or browse private specialist state by default |
| **Audit**   | Independent assessment context, protected-check results, findings and audit receipts           | Frozen candidate and authorized evidence in; digest-bound findings/receipt out                     | Rewrite candidate bytes, let producers edit its checks/receipts, self-approve publication, or promote content                                |
| **Publish** | Approved release requests, activation history, receipts and rollback references                | Exact audited candidate, receipt and human approval in; verified promotion receipt out             | Rewrite audited bytes, grant entitlements, change server code/policy, self-approve, or use generic deployment authority                      |
| **Test**    | Consumer scenarios, scoped test identities, observations and regression history                | Published release reference and approved expectations in; consumer-test evidence out               | Use administrator identity as a consumer substitute, alter audit receipts, or silently repair live content                                   |

Each row describes a separate context in **each** project. A dataset Audit group
and CMG Concierge Audit are not one shared fleet-wide audit agent.

## IV Dataset: Write produces authoritative information

**Write** owns drafting context, working materials, implementation reasoning, and
candidate history. It receives approved requirements and only explicitly
authorized sources. It produces candidate dataset publications, not live ones.
It cannot edit authoritative Audit checks/receipts, approve for the owner, or
publish directly.

For the current metadata-oriented scope, a publication contains approved dataset
Metadata, Register, and Rules. Neither this model nor the existence of a Write
group authorizes source-repository access, borrower records, real-data samples,
or a wider data product. Each project's scope and source grants remain explicit.

Dataset Audit asks: **is this exact dataset publication acceptable against the
approved requirements and checks?** Dataset Publish activates that publication
only after the required audit and human approval.

## Client Concierge: Curate assembles published information

**Curate** owns collection proposals, package/version inventory, navigation,
source references, coverage gaps, and update history. It receives only approved
published dataset packages and approved client requirements. It proposes the
information the client should be able to retrieve across its datasets.

Curate is not a second dataset Write group. It must not invent dataset rules,
silently resolve conflicting definitions, change authoritative source meaning,
include unpublished drafts, or grant new entitlements. Coverage gaps and source
contradictions return as explicit requests to the relevant Dataset Manager.
Any concierge-authored summaries/navigation must be distinguishable from source
content and carry versioned references.

Concierge Audit asks: **are the correct approved publications exposed to the
correct audience, faithfully, under the existing approved entitlement policy?**
It verifies the proposed collection rather than substituting for upstream
dataset Audit.

**Concierge Publish updates the approved information and indexes available to
the MCP server.** It requests a narrow deterministic activation of the exact
candidate that passed Audit and human approval. It does not change authorization
policy, server executable code, or the underlying dataset truth.

## Handoff and release contract

Manager coordinates this sequence; it is not a content-transformation stage:

1. **Write or Curate:** prepare an immutable candidate and a manifest covering
   every served byte, generated index, and distributable artifact.
2. **Audit:** assess that frozen candidate against protected checks and approved
   requirements; issue a receipt bound to the candidate digest and check version.
3. **Human approval:** the designated owner approves that exact candidate for its
   intended target. An agent cannot approve on the owner's behalf.
4. **Publish:** request the deterministic gate to activate the approved candidate
   atomically. Record the authority's receipt and previous release reference.
5. **Test:** exercise the activated release through the consumer interface,
   including entitlement denials; report actual observations.

An assignment/handoff records its ID, scope, sender/recipient group, artifact
references/digests, allowed actions, acceptance criteria, and expected reply.
Transfer only what the receiving role needs, not another group's private
reasoning. Findings return to the producer through explicit messages/artifacts.
Changed candidate bytes require renewed audit and renewed human approval.

Pending approvals remain pending when the owner disconnects. A repeated promotion
request must be rejected or safely idempotent; a successful conversation is not
proof of a successful publication. Distinguish drafted, audited, approved,
published, and consumer-verified states. Post-publication test failure is a
reported incident, not silent acceptance; rollback follows the approved
release-control path and preserves evidence.

## Serving is not an agent group

The MCP server is a separate restricted service. It authorizes before retrieval
and reads only the activated collection. It cannot read group workspaces,
credentials, drafts, conversations, management queues, or host controls. Consumer
requests must not dispatch work to resident agents.

A client's users may have different entitlements. A per-client VM or agent-group
boundary is not a substitute for per-request consumer authorization. Client
Claude Code sessions consume the published MCP information; a concierge-hosted
Answer agent is not part of this design.

## State of implementation

- **Decided:** these two group patterns, context isolation, explicit handoffs,
  publication boundaries, and restricted serving.
- **Observed configuration:** the concierge bootstrap and 2026-10-14 core-loop
  preflight record Manager / Write / Audit / Publish / Test on
  `iv-cmg-concierge`. The live `Write` group has **not** become `Curate` merely
  because this design names it differently.
- **Tested:** the [NanoClaw core-loop experiment](nanoclaw-core-loop-test.md)
  passed a bounded scheduled wake, state recovery, and read-only reconnect.
  It did not qualify inter-group handoffs, gate enforcement, publication,
  consumer authentication, or restart recovery.
- **Outstanding:** approve and implement Concierge role alignment, protect and
  test the publication contract, qualify per-role access including archives,
  and qualify the proposed Rex interfaces. No live groups are changed here.
