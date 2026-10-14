---
title: "CMG Concierge Publication Contract"
---

**Status: agreed design / implementation handoff, 2026-10-14. Not a completed
publication qualification.** This contract belongs with the Concierge service
implementation. A read-only inspection on 2026-10-14 found NanoClaw and
iv-provision checkouts, but no Concierge service repository on
`iv-cmg-concierge`. It is recorded here pending that repository's approved
bootstrap; this is not a claim that the private remote repository does not exist.

When the service repo is available, move the implementation-specific contract,
tests, and deployment details there and leave a reference here. Do not maintain
two divergent copies. The generic
[Agent Group Operating Model](agent-group-operating-model.md) remains canonical
for group boundaries; [Project Manager Agent](resident-layer.md) defines Manager
responsibilities.

## Scope and current state

The client-level Concierge provides approved published information across CMG's
IV Datasets. Its groups are **Manager / Curate / Audit / Publish / Test**, each
with separate memory, conversation history, workspace, and scoped authority.

The current workshop remains **synthetic-only**, initially in the ServicerVault
namespace. The ability to add other dataset namespaces is a design property,
not authorization to access their sources or serve their real content. No real
CMG catalog, borrower records, SQL execution, observed values/profiles,
real-data-derived samples, or detailed column-level lineage is authorized here.
Existing production pipelines remain unchanged.

The runtime currently has a group named **Write**, seeded for the earlier
synthetic workshop. This documentation does not rename it, rewrite its standing
instructions, migrate its memory, or change its permissions. Role alignment to
**Curate** needs a separately approved plan covering identity, memory disposition,
workspace, allowed sources, tools, and message routes. Do not mechanically reuse
private Write context as a different role's context.

## What Publish changes

**Publish updates the approved information and indexes available to the MCP
server.** The deterministic publication service—not agent memory—is the authority
for which release is active.

Publish may request activation of an exact approved collection and obtain a
receipt. It must not rewrite audited bytes, grant entitlements, change MCP server
code or policy, or obtain generic deployment/host access. Its group owns release
requests, receipts, and rollback references in its own isolated context.

The MCP server is a separate restricted serving process. Authorize each request
before retrieval, including discovery, search/index results, and cited content.
A per-client VM does not make all client users equally entitled. Consumer calls
must neither dispatch agent tasks nor expose agent state, drafts, credentials,
management queues, source repositories, or host controls.

## Candidate and acceptance records

Curate proposes a frozen collection of approved upstream publications plus any
clearly identified, source-linked concierge navigation or summaries. An upstream
publication is authoritative for dataset meaning; unresolved contradictions go
back to its Dataset Manager rather than being silently reconciled by Curate.

The candidate manifest must cover:

- Client, dataset namespace(s), target, and candidate/release identifiers.
- Exact approved upstream package versions and digests, with provenance references.
- Every served content file, generated index, navigation artifact, summary, and
  distributable asset. Prefer relative paths and reject traversal/unlisted files.
- Content classification and references to the already-approved entitlement
  policy against which exposure is audited. These are not grants to change it.
- A deterministic digest covering the complete candidate and manifest; changes
  to any served byte invalidate the previous acceptance.

Keep the following as separately attributable records, bound to the same
candidate and target:

| Record               | Authority / required evidence                                                                                                             |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Audit receipt        | Independent Audit; candidate digest, protected-check version, findings and pass/fail results                                              |
| Human approval       | Kyle or explicitly designated approver; exact candidate digest and intended activation target                                             |
| Promotion receipt    | Deterministic publication authority; candidate digest, active release, previous release, request identity and runtime-generated timestamp |
| Consumer test report | Test group; actual served release, scoped test identity references and positive/negative results, without credentials                     |

Manager and Curate cannot edit authoritative checks or Audit receipts. Publish
cannot issue its own human approval. A phase label such as `awaiting_owner` or a
successful model response is not an authorization artifact.

## Promotion, rollback, and serving

1. Curate produces the candidate; Audit independently assesses the frozen bytes.
2. The owner approves the exact candidate and target, after Audit passes.
3. Publish requests the narrow promotion operation. The gate verifies identity,
   scope, digest, required receipts, current policy compatibility, and approval.
4. Activate the complete candidate atomically; readers must not see a mixture
   of old content and new indexes. On failure, preserve the previous valid release.
5. Persist an authoritative receipt and previous release reference. Resolve
   uncertain responses against actual release state before retrying.
6. Test through the consumer interface. A publication may be active while
   consumer verification is still pending; do not conflate the states.

Reject unauthorized direct promotion, changed candidates, and stale approvals.
Duplicate requests must be rejected or safely idempotent without a second
publication or approval bypass. Gate/check definitions are protected from the
requesting agents.

Rollback is a separately authorized narrow operation against a known prior
release. Recheck current policy/revocation compatibility: an old release is not
permission to restore revoked access. Preserve the receipt and incident history.
Do not regenerate unreviewed indexes or silently repair content during promotion
or rollback.

## Synthetic acceptance suite still required

- Correct entitled consumer receives only the approved synthetic collection.
- Unauthorized, revoked, wrong-audience, and cross-entitlement requests fail,
  including indirect disclosures through discovery/index results.
- Group cross-reads, credential access, receipt forgery, and protected-test edits
  are denied; Manager's request to bypass a gate fails.
- MCP serving cannot reach internal agent dispatch or private state.
- Direct promotion and post-audit mutation fail; replay is rejected or safely
  idempotent; generated assets are covered by the accepted digest.
- Publication failure preserves the prior release; concurrent readers do not
  observe a partial update; rollback obeys current authorization.
- Restart during a handoff recovers from durable authoritative state without
  claiming an unperformed publication or repeating an uncertain side effect.
- Actual Claude Code MCP transport and scoped consumer authentication work on
  the approved route. A mocked identity or owner VM credential is not a pass.

The [core-loop experiment](nanoclaw-core-loop-test.md) passed only the bounded
resident wake/state/reconnect mechanism. It did not run this publication suite,
exercise human release approval, or validate this MCP consumer path.

## Remaining implementation handoff

- Establish the approved service repository; place this contract and its tests
  there, retaining links rather than a second editable copy here.
- Approve and implement the live Write-to-Curate role alignment without weakening
  group isolation or carrying over inappropriate private context.
- Implement/protect the candidate, audit, approval, promotion and serving paths;
  then record a PASS/FAIL/BLOCKED matrix with authorized evidence locations.
- Keep raw runtime histories and credentials out of source control. Commit only
  reviewed code/docs and sanitized results; actual runtime evidence stays in its
  authorized store with a tested backup/recovery plan.

No source access, client onboarding, ingress expansion, new credentials, live
publication, or runtime changes are authorized by this documentation update.
