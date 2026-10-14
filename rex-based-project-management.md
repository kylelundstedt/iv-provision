---
title: "Rex-Based Project Management"
---

**Status: proposed interface, revised 2026-10-14; not deployed or qualified.**
Define isolated agent groups first, then use Rex to expose their conversations
and permitted activity. Rex does not supply the manager's memory, authority,
or wait–wake–act lifecycle.

Read [Agent Group Operating Model](agent-group-operating-model.md) for group
boundaries and [Project Manager Agent](resident-layer.md) for responsibilities,
project website ownership, and persistence. The
[NanoClaw core-loop test](nanoclaw-core-loop-test.md) passed without Rex; it did
not qualify remote interactive access to all specialists.

## Two workspaces

| Workspace          | Location                 | Purpose                                                               |
| ------------------ | ------------------------ | --------------------------------------------------------------------- |
| Project session    | Project-specific VM      | Expose that project's isolated groups through group-aligned windows   |
| Management session | A Mac's local Rex server | Arrange conversation clients to Manager groups on several project VMs |

Our convention is **one project VM → one Rex server → one project session →
group-aligned windows → conversation/task blocks**. It is a proposed convention,
not a Rex restriction. It introduces neither a second manager above NanoClaw's
Manager nor a fleet-wide manager-of-managers.

The [Rex CLI taxonomy](https://www.superlogical.com/rex/docs/automate/cli)
distinguishes server-owned sessions, windows, application blocks, and connected
clients. A Rex workspace is not an LLM conversation or an isolation boundary.
Preserve durable group/conversation/task identities separately from Rex object
IDs; a changeable tab label must not determine authority.

## Group-aligned project windows

| IV Dataset window | Client Concierge window | What the blocks expose                                                                  |
| ----------------- | ----------------------- | --------------------------------------------------------------------------------------- |
| **Manager**       | **Manager**             | Existing manager conversation, approved plan, reported status and decisions             |
| **Write**         | **Curate**              | Assignments and permitted workspace/log views within the producing group                |
| **Audit**         | **Audit**               | Independent review conversations, protected checks, findings and receipts               |
| **Publish**       | **Publish**             | Approved release requests, narrow promotion interface, receipts and rollback references |
| **Test**          | **Test**                | Scoped consumer scenarios and actual test results                                       |

Every window refers to a distinct group's persistent context. Seeing windows
side by side does not make their memories available to one another. The human
owner's ability to inspect multiple groups is not blanket tool access for
Manager or for the other agents.

Task blocks may come and go inside a group. Name them for assignments rather
than models; a new block does not necessarily mean a new agent group. Where
concurrent code writers need separate worktrees, arrange those within authorized
workspace boundaries. Worktrees and terminal panes are not substitutes for
isolating Audit from Write/Curate.

### Why the previous generic layout changed

"Manager / Plan / Challenge / Tasks / Integrate" mixed persistent identities,
activities, and temporary assignments. It is no longer the default group layout.
Planning, challenging, and integrating are activities assigned to an appropriate
group or explicitly approved specialist. A model offering advisory criticism
is not automatically the independent Audit authority for a frozen publication.

For other software projects, decide which contexts must remain independent
before choosing group names and windows. Do not flatten an established dataset
or concierge topology to fit a universal terminal template.

Fable, Astra, Opus, Sonnet, and Sol describe preferred reasoning assignments,
not group names or permissions. Model availability and subscription access must
be qualified; replacing a model cannot broaden a group's authority or cause
another group to inherit its private memory.

## Mac management session

| Local window      | Local block connects to                           |
| ----------------- | ------------------------------------------------- |
| **Project A**     | Existing Manager group on VM A                    |
| **Project B**     | Existing Manager group on VM B                    |
| **CMG Concierge** | Existing Manager group on the client Concierge VM |

Alternatively, put several manager clients side by side in one local window.
These are ordinary local terminal clients with remote connections, not remote
Rex blocks transplanted into a local session. No cross-server block composition
is required, and opening a client must not start a duplicate Manager.

A long-running connection is convenient, not a lifecycle requirement. Sleeping
or disconnecting the Mac must leave remote responsibilities intact. Another Mac
may arrange its own clients to the same managers; identical layouts, focus, and
simultaneous input behavior are not assumed.

Rex provides convenient human access, not a prerequisite for persistence. A
functional basic conversation client is sufficient; a polished TUI is not the
criterion that selects the resident runtime.

## Drill into a group without bypassing its boundary

Connect to the remote project session to inspect a particular group's work.
Every block must use an approved interaction path to the existing group/session.
**Do not launch a replacement host-side CLI with broader credentials simply to
make a containerized worker convenient to access.** A shell adjacent to an Audit
conversation is not automatically authorized to modify its workspace or tests.

The NanoClaw-to-Rex conversation/status path is still unqualified. We must prove
that inspection and intervention address the same governed work, not duplicate
workers or a parallel ungoverned execution system.

Read-only inspection needs no coordination handoff. Before changing an assignment,
issuing instructions, approving an action, or cancelling work, put the affected
assignment into owner-controlled mode. Record the intervention and reconcile
actual worker state before Manager resumes control. Any required approval and
group isolation still apply during manual intervention.

**Management workspace = across projects. Project session = inside one project.
Group window = one isolated context.** Zed remains an optional editing/review
workbench; neither Zed integration nor a vendor portal listing every VM is a
precondition for this organization.

## Publication and documentation access

The group workflow is specified in the
[operating model](agent-group-operating-model.md#handoff-and-release-contract).
Rex exposes its progress; it does not grant publishing authority. For CMG,
Publish changes approved information available to the restricted MCP service,
not its entitlement policy or executable code.

The project website is the manager-maintained published account of status,
plans, decisions, technical documentation, operations, and results. Link to it
from the workspace when convenient. It must not expose private group context
or act as a second independent task ledger.

## Qualification gates

This design depends on a qualified Linux Rex server and approved per-group
interaction clients. The installation documentation reviewed on 2026-10-13
limited public testing to macOS; that historical observation is not a current
release guarantee. Check the official installation documentation when qualifying
an actual release rather than assuming availability from this design.

Before rollout:

1. **Server:** qualify installation, supervised startup, authenticated remote
   access, resource limits, and disconnect behavior on exe.dev; qualify any
   Ubuntu-based Apple Container target separately.
2. **Group interfaces:** verify the same governed conversations/workers are
   reached; no memory, filesystem, archive, or credential boundary is bypassed.
3. **Manager continuity:** verify durable history, missed-result recovery,
   concurrent-client command handling, pending approvals, and no duplicate work.
4. **Resident lifecycle:** qualify worker-event wake-up and separately approved
   restart recovery. Do not confuse Rex attachment with agent recovery.
5. **Canary:** exercise one synthetic group handoff, independent audit, protected
   approval, publication, and consumer test; disconnect and reconnect from another
   Mac. Record configured controls separately from observed passes.
6. **Rollout:** pin only qualified components and distribute shared policy without
   granting managers blanket authority over sibling projects.

This is documentation only: no runtime upgrades, new permissions, agent-group
renaming, VM changes, or automatic adoption of another agent framework.
