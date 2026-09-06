# Vendored: `entire-agent-agentsview`

Entire external-agent adapter backed by AgentsView's normalized archive. It
attaches sessions produced by **Shelley, Claude Code, Codex, or any other
AgentsView provider** to an Entire checkpoint. Attach-only: it installs no live
lifecycle hooks and never writes restored sessions back into AgentsView or a
native agent store.

This adapter is the reviewed **attach/import bridge** from AgentsView's
session-centric observability archive into Entire's change-centric repository
provenance. Live source-native capture for Shelley is `entire-agent-shelley`;
native Entire integrations cover Claude Code and Codex.

The bridge is useful for historical attachment, unsupported-agent import, and
native-versus-normalized reconciliation. It is not independent capture
redundancy when both readers depend on the same native agent store, and it does
not automatically promote every observed fleet session into Entire.

## Provenance

| | |
| --- | --- |
| Canonical source | `kylelundstedt/iv-docs`, `spikes/23-harness/entire-agent-agentsview` |
| Vendored from | iv-docs commit `3ccde3119423f73a47175668e3b4270c82be4621` |
| SHA-256 | `c75d5459537d208b0ad674f97cd8a1814376f23b2a23a52d3e6fd97c634529a7` |
| Entire external-agent protocol | `v1` |
| Vendored on | 2026-09-06 |

`provision-iv.sh` verifies that SHA-256 before installing, so a silent edit
to the vendored copy fails provisioning rather than shipping.

## Why vendored rather than symlinked

It was on `iv-foundry-stage2`'s `PATH` as
`~/.local/bin/entire-agent-agentsview` -> a **spike worktree**
(`~/worktrees/iv-docs-fannie-memory/spikes/23-harness/`). A fleet capability must
not depend on a branch-specific worktree that can be pruned at any time, and it
was not provisioned at all, so it did not survive a VM recreate.

## Keeping it current

iv-docs remains canonical: edit it there, then re-copy here and bump the pin in
`provision-iv.sh` (`ENTIRE_AGENTSVIEW_SHA256`) in the same commit. If this
adapter accumulates its own qualification record it should graduate to a
standalone repository, as `entire-agent-shelley` did.

Tests (`test.sh`, `test-real.sh`) stay with the canonical copy in iv-docs; only
the executable is vendored.
