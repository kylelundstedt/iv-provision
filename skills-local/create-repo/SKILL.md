---
name: create-repo
description: Create a new GitHub repository and seed it with files from this VM, without a laptop, a `gh` login, or a token. Use when asked to create/make/start a new repo, or to publish a directory of work as a repo. Runs through the mcp-github-home HTTP-proxy integration, whose credential lives at the exe.dev edge.
---

# Create Repo

The sibling of `create-vm`: the same "do it from the Prompt Shelley box on a
phone" property, applied to repositories. Requests it answers:

- "create a private repo called iv-thing"
- "publish this directory as kylelundstedt/iv-notes"
- "start a repo for the pipeline I just wrote, push what's in ~/work"

Do **not** answer such a request with "run `gh repo create` on your Mac". There
is no `gh` login here and there never will be — the point of the integration is
that no token touches the VM.

## Where the authority comes from, and where it stops

`mcp-github-home` is an exe.dev **http-proxy** integration pointed at GitHub's
hosted MCP server (`api.githubcopilot.com/mcp`). exe.dev injects the GitHub
credential at its edge; it is not readable from the VM. Verified 2026-08-23 from
`iv-provision`: `get_me` returns `kylelundstedt`, and `create_repository`,
`push_files`, `create_branch`, `create_pull_request` all succeed.

Check it is attached before promising anything:

```bash
curl -s https://reflection.int.exe.xyz/integrations | grep mcp-github-home
```

The 47-tool surface is wide (issues, PRs, releases, search, reviews). What it
does **not** contain is the thing you will reach for when a probe goes wrong:

- **There is no delete-repository tool.** `delete_file` exists; nothing deletes a
  repo, and the git proxy refuses `DELETE /repos/...` for a repo with no
  integration (403) — so a mistyped name is the user's to clean up in GitHub's
  settings UI. **Confirm the name back before creating.** This is the same
  discipline `create-vm` needs, for the same reason.
- **Org repos are blocked by SAML.** `organization: IndustryVault` fails with
  "Access to the requested organization is blocked by SAML single sign-on" — the
  edge credential has no SSO-authorized session. Personal account (`kylelundstedt`)
  only. Do not retry; it is a property of the credential, not a transient error.
- **Duplicate names fail cleanly** (`name already exists on this account`), so
  unlike VM creation you do not have to guess — just submit and report the error.

## The call

Two scripts ship with this skill, next to `SKILL.md` in
`~/.agents/skills/create-repo/`:

```bash
S=~/.agents/skills/create-repo

# 1. Create. private defaults to TRUE when omitted -- pass it explicitly anyway,
#    so the diff of what you did says which you meant.
$S/gh-mcp.sh create_repository \
  '{"name":"iv-thing","private":true,"autoInit":true,"description":"..."}'

# 2. Seed it: every file in a directory, one commit.
$S/push-tree.sh kylelundstedt iv-thing main "Initial commit" ~/work
```

`gh-mcp.sh <tool> '<json>'` is the general escape hatch — any of the 47 tools,
same shape. It exists because streamable-HTTP MCP is three round trips and
returns its session id in a *header*; that is not a curl one-liner worth
retyping. `push-tree.sh` wraps `push_files`, taking the file list from
`git ls-files` when the directory is a worktree (so `.gitignore` is honoured)
and refusing binaries — `push_files` carries content as a JSON string, not
base64.

`autoInit:true` matters: `push_files` updates a branch ref, so `main` must
already exist. Without it the first push has nothing to build on.

## Why you cannot just `git push` the new repo

This is the trap, and it does not look like a permissions problem.

exe.dev's git proxy `https://github.int.exe.xyz/<owner>/<repo>.git` is served by
the **per-repo `repo-*` integrations** attached to the VM. A repo created a
second ago has none. So:

- a **private** new repo answers `remote: Repository not found` — which reads
  like the create silently failed, when in fact the repo exists and is fine;
- a **public** new repo clones (public reads pass through) but pushes are
  `remote: integration is read-only: git push is not allowed`.

Both are the absence of an integration, not a broken repo. The MCP path is the
write path for a repo this VM has no integration for. That is the whole division
of labour:

| Want | Use |
| ---- | --- |
| create a repo | `create_repository` (MCP) |
| seed / commit to a repo with no `repo-*` integration | `push_files` (MCP) |
| ordinary day-to-day git on a repo the VM owns | `git`, over `github.int.exe.xyz` |

If the repo is going to see real work from this VM, tell the user the one thing
only they can do — mint the integration, which also fixes clone and push:

```
ssh exe.dev integrations add github --name repo-<repo>-rw \
  --repository kylelundstedt/<repo> --act-as-user --attach vm:<vm>
```

`--act-as-user` is not optional in practice: without it commits attribute to
`exe-dev-github-integration[bot]`. (MCP-path commits already attribute to the
account — verified: `push_files` commits show author `kylelundstedt`.)

Offer the ready-made link rather than making them compose it:
`https://exe.dev/suggest?command=<url-encoded-command>`.

## Note on the authoring boundary

The README's single-writer rule is about **`iv-provision` and `exeslim`** — the
repos that describe the fleet's machines. It says provisioning changes originate
on the VM holding `repo-iv-provision-rw`. It is not a rule that only one VM may
ever create a repository, and this skill does not weaken it: `mcp-github-home`
cannot push to `iv-provision` any more than a `repo-*-ro` integration can... but
it *could* if someone pointed it there, since MCP writes are not scoped per repo
the way the git integrations are. So: **do not use `push_files` to route around
a missing `-rw` integration on a fleet repo.** For those, open a PR the
documented way. The MCP write path is for repos that have no integration *yet*,
not for repos deliberately denied one.

## After creating

`create_repository` returns `{"id": "...", "url": "https://github.com/..."}`.
Unlike `new`, there is no asynchronous provisioning behind it — the repo exists
when the call returns. Verify by reading back what you wrote rather than by
trusting the ref response:

```bash
$S/gh-mcp.sh get_file_contents '{"owner":"kylelundstedt","repo":"<repo>","path":"README.md"}'
```

Then report the URL, whether it is private, and — if the user will work in it
from a VM — the integration command they still need to run.
