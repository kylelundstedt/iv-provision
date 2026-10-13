---
title: "Rex-Based Project Management"
---

**Status: proposed organization, not deployed.** Recorded 2026-10-13. Rex Linux
server availability and qualification, and a reconnectable resident-manager
client, are implementation dependencies—not capabilities installed by this
repository today.

**One manager per project. Multiple workers beneath each manager. One convenient
workspace for the owner to talk to them all.**

The [Resident Layer](resident-layer.md) specification defines manager behavior,
policy, state, and replacement criteria. This page defines where that layer
runs and how humans access it; Rex organizes sessions, not project decisions.

## Two workspaces, different purposes

| Workspace          | Runs where                  | Purpose                                                           |
| ------------------ | --------------------------- | ----------------------------------------------------------------- |
| Project session    | Project-specific exe.dev VM | Access one project's manager, planning, review, workers, and logs |
| Management session | A Mac's local Rex server    | Arrange clients connected to managers on several project VMs      |

Our convention is **one project VM → one Rex server → one project session →
multiple windows and blocks**. This is an organizational choice, not a Rex
restriction. It does not introduce a central manager-of-managers.

## Rex vocabulary

The [Rex CLI guide](https://www.superlogical.com/rex/docs/automate/cli) describes
sessions as related work retained by a server, windows as tabs holding block
layouts, and blocks as applications (currently terminals). Clients connect to
the server. Objects have stable IDs and changeable labels; automation should
save IDs rather than depend on labels or tab positions.

For this design, a **Rex session is a workspace**, not an LLM conversation. A
block can host a CLI agent or a client to a resident manager; neither the model
nor its conversation identity is defined by the block's name.

## Each project VM

The VM owns:

- One resident project-manager service, independent of terminal connections.
- Planning, review, execution, and integration agents.
- The repository and an isolated Git worktree/branch for each concurrent writer.
- Durable conversations, task/approval records, and bounded working memory.
- The proposed Rex server and project session.

| Window                    | Blocks                               | Responsibility                                       |
| ------------------------- | ------------------------------------ | ---------------------------------------------------- |
| **Manager**               | Resident-manager conversation client | Assign priorities, discuss status, resolve decisions |
| **Plan**                  | Fable + shell                        | Develop and revise the plan                          |
| **Challenge**             | Astra + shell                        | Adversarial review of plans and changes              |
| **Task: ingestion**       | Opus + tests/logs                    | Execute a bounded assignment                         |
| **Task: transformations** | Sonnet + tests/logs                  | Execute another independent assignment               |
| **Task: validation**      | Sol + tests/logs                     | Execute another independent assignment               |
| **Integrate**             | Designated integrator + test shell   | Combine reviewed changes and verify the result       |

Model names express the owner's preferred role assignments, not a claim that
every CLI/subscription offers each model. Qualify model access through supported
authentication; changing a worker does not change the task's identity.

Keep planning/review windows across work cycles; create and close task windows
as assignments change. Name execution windows for **tasks, not models**.

The Manager block connects to an independently supervised service. Closing it
must not terminate that manager. Conversely, closing an execution block may
terminate its foreground worker: collect results and stop workers deliberately,
not by treating window cleanup as harmless disconnection.

## Plan, challenge, execute, review, integrate

1. **Plan:** the owner and Fable establish scope, dependencies, task boundaries,
   and acceptance criteria in a versioned plan.
2. **Challenge:** Astra reads the plan and relevant project context, identifies
   failure cases and missing tests, and returns findings. Fable revises; the
   owner approves the execution scope.
3. **Execute:** assign independent tasks to workers, each with a plan revision,
   worktree/branch, scope, and completion contract: commits, tests, unresolved
   issues. Dependent tasks wait for their prerequisites.
4. **Review:** Astra examines explicit commits/diffs against acceptance criteria;
   findings return to the responsible worker.
5. **Integrate:** one designated integrator combines approved changes and runs
   cross-task tests before the owner's final approval.

Initially the owner can coordinate this manually. The resident manager later
tracks and routes the same workflow within policy; it does not become the
planner, reviewer, and implementer itself.

**Files and commits are handoffs; terminal scrollback is not.** Separate blocks
do not isolate filesystem changes. Use worktrees for concurrent writers and
identify the exact plan revision or commit under discussion. Keep plan/task
IDs, worker conversations, and Rex object IDs separately mapped.

## The Mac management session

A local Rex management session contains ordinary terminal clients with
long-running connections to the remote managers:

| Local window  | Local block connects to  |
| ------------- | ------------------------ |
| **Project A** | Resident manager on VM A |
| **Project B** | Resident manager on VM B |
| **Project C** | Resident manager on VM C |

Alternatively, place several manager blocks side by side in one local window.
The layout is a preference, not part of the resident protocol.

These are **local blocks with remote connections**, not blocks transplanted from
remote Rex servers. This design needs neither cross-server block composition
nor a tmux-style Rex attachment command inside another terminal. It does need
a selected or purpose-built resident conversation client and authenticated
transport to each manager.

This is the primary workspace for assigning work, setting priorities, approving
plans, checking progress, and answering questions across projects. Opening a
client must connect to the existing manager, not start another copy.

## Drill into a project

For direct work with a planner, reviewer, executor, or logs, use a Rex client to
connect to that VM's project session, subject to remote-access qualification.
Do not start duplicate workers merely to inspect existing work.

Direct intervention must not compete with manager instructions. Put an affected
assignment into owner-controlled mode before changing scope, approving an action,
or cancelling work; record the outcome in the task ledger and reconcile worker
state before returning control to the manager. Read-only observation needs no
handoff.

**Management workspace = across projects. Project session = inside one project.**

Zed remains an editing and code-review workbench. Neither Zed/Rex integration
nor an exe.dev/Shelley portal listing every host is a prerequisite for this
organization. Mobile access is optional and needs its own qualification.

## Continuity and recovery contract

These are requirements for the resident implementation, not claims that Rex
implements an agent protocol:

- Disconnecting or sleeping the Mac does not stop remote managers or workers.
- Reconnection resumes the same manager conversation and replays missed output.
- A second Mac can connect without creating a duplicate manager. Serialize or
  deduplicate concurrent commands and approvals explicitly.
- Authoritative conversation and task state stays on the project VM, not in a
  local terminal's scrollback. A local layout can be recreated without losing it.
- Unanswered approvals remain pending while disconnected; do not silently grant
  them. Choose an out-of-band notification channel for time-sensitive decisions.
- VM/service restart recovery is separate from client-disconnect persistence:
  restore the ledger, reconcile worker state, and avoid blindly rerunning tasks.
- Shared preferences and policies are distributed consistently; each manager's
  authority stays project-local unless cross-project access is explicitly granted.

Identical local layouts across Macs, shared focus, and simultaneous input are
not assumed. Each Mac can arrange its own clients to the same remote managers.

## Implementation and qualification gates

The [Rex installation guide](https://www.superlogical.com/rex/docs/installation),
checked 2026-10-13, limits public testing to macOS and describes Linux servers
as internal. Do not treat the proposed VM layout as currently deployable.

Before rollout:

1. **Linux Rex:** qualify a released server on exe.dev and separately on any
   Ubuntu-based Apple Container target: install, supervised startup, resource
   requirements, authenticated remote access, and disconnect/reconnect behavior.
2. **Resident service and client:** implement or select durable identity,
   history, task state, multi-client consistency, approval routing, recovery,
   and a supported inference/authentication path.
3. **Worker adapters:** qualify start/resume/status/cancel/results/approvals,
   available models, worktree isolation, and plan-to-task handoffs.
4. **Canary:** run one project end to end; sleep/disconnect the Mac, reconnect
   from another Mac, recover a pending approval, and verify no duplicate work.
   Test service restart recovery separately.
5. **Fleet rollout:** pin and provision the qualified components; keep shared
   policy/preferences consistent without granting managers fleet-wide authority.

No automatic VM retirement, model pin bump, or resident deployment is included
in this documentation change.
