---
title: "Retiring a VM"
---

How to retire a VM that has been replaced. **Order matters**, and most of the
steps here exist because skipping them broke something real -- each one names
what.

This is a runbook, not a script. The tooling that used to automate it
(`new-dev-vm`, `retire-vm` in the personal dotfiles repo) is being retired
itself: deletion is the one fleet operation where a mistake is unrecoverable, so
it stays a deliberate human sequence. What was worth keeping is the knowledge,
not the automation.

## Before anything: is the replacement actually doing the job?

"Running" is not evidence. "Healthy" is not evidence either -- a doc-site VM was
once retired in favour of a replacement that rendered correctly and served
nothing, because nobody checked the port.

Check that the replacement does the OLD one's job:

```bash
ssh <new> 'systemctl is-active <the-service>; curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8000/'
```

For anything that serves content, capture the old VM's output BEFORE cutover and
diff it after. Byte-for-byte, every endpoint, not just `/`:

```bash
curl -s https://<old>.exe.xyz/          -o /tmp/before-index.html
curl -s https://<old>.exe.xyz/<path>    -o /tmp/before-path.xml
# ... after cutover, the same URLs against the replacement, then diff.
```

## 1. Check for work that exists only on that VM

The VM is about to be deleted. Anything not pushed is gone.

```bash
ssh <old> 'for d in ~/*/ ~/*/*/ ~/*/*/*/; do
    [ -e "$d/.git" ] || continue
    u=$(git -C "$d" config --get remote.origin.url 2>/dev/null) || continue
    s=$(git -C "$d" status --porcelain 2>/dev/null | wc -l)
    n=$(git -C "$d" rev-list --count --branches HEAD --not --remotes 2>/dev/null)
    [ "$s" != 0 -o "$n" != 0 ] && echo "$d dirty=$s unpushed=$n"
  done; true'
```

Three traps, all found the hard way:

- **A worktree's `.git` is a FILE, not a directory.** `[ -d .git ]` misses them
  entirely. `iv-home` held `~/iv-home-dataset-mcp`, a worktree on a branch that
  existed nowhere else. Hence `-e` above.
- **Depth 3.** Work lives at `~/repo`, `~/worktrees/<name>`, and
  `~/github/<owner>/<repo>`. A depth-1 scan reported `iv-foundry-stage2` as
  clean when its entire working set was one level down.
- **`--branches HEAD --not --remotes`**, not just the current branch. A stale
  side branch is still work. `iv-docs` was one render-verification away from
  deletion with 3 unpushed commits, two of them on a checkpoint ref.

### Directories that are not repos at all

The question is not "does this have a `.git`" but "is this content committed
_somewhere_". `iv-foundry-stage2`'s retirement was held moot most of a day over
~31 MB judged unique because no repo of that name existed on GitHub -- while
every file in it was byte-identical to a branch in a _different_ repo. Hash the
files and look for them, rather than trusting the directory layout.

## 2. Remove the VM's AgentsView peer integration FIRST

Before deleting the VM, not after. The collector polls on a timer; delete the VM
first and it spends the gap pulling a host that no longer exists, which pages as
a real outage.

The collector runs on `iv-agentsview` and enrolls sources from its own attached
`av-src-*` peer integrations (daily reconcile), so retiring is one lobby command:

```
integrations remove av-src-<old>
```

The next reconcile drops the `[[remote_hosts]]` block and restarts the
collector; to not wait, `ssh iv-agentsview.exe.xyz ~/.local/bin/agentsview-reconcile`.
A VM that was never enrolled has no integration; that is fine and not an error.
(Hosts still on the tailnet path -- today only `klundstedt-mini` -- keep a
hand-written block; edit it on the collector.)

## 3. Delete the VM

```
rm <old>
```

From the lobby. Deliberately not available to any fleet VM's API token: `create-vm`
is scoped `--cmds=new,ls,whoami,"integrations list","integrations add"` precisely so an agent cannot
reach this step.

## 4. Restore the canonical name -- and the three things `rename` does NOT touch

If the replacement was built as `<old>-next` or `<old>-v2`, rename it back.
Otherwise the fleet accretes suffixes and anything pinned to a hostname drifts
every cycle.

```
rename <new> <old>
```

`rename` changes the exe.dev name and **nothing else**. Three things move
separately, and all three have caused silent breakage:

### a. `vm:` integration attachments do not follow a rename

exe.dev attaches by VM name. After a rename, every `vm:<new-name>` attachment is
stranded: the VM keeps running, looks healthy, and every git operation fails with
"integration not found or not attached to this VM". **Six VMs were renamed before
anyone noticed, all six unable to fetch or push.**

```bash
# for each integration attached as vm:<new>, attach to vm:<old> and detach the old ref
```

A `tag:` attachment is immune -- it follows the tag, not the name. `api-tailscale`
is attached via `tag:tailnet` for exactly this reason.

### b. The OS hostname does not change

```bash
ssh <old>.exe.xyz 'sudo hostnamectl set-hostname <old>'
```

### c. The Tailscale node keeps its REGISTERED name

`tailscale set --hostname` is **not** enough: Tailscale keeps the device name
assigned at registration, so the node stays `<new>` even after a tailscaled
restart. Measured on `iv-ave-adapters`. The node must **re-register**:

```bash
# over the *.exe.xyz edge, NOT over the tailnet -- `tailscale logout` would cut
# a tailnet SSH mid-command
ssh <old>.exe.xyz 'sudo tailscale logout'
# then re-run the join (provision-iv.sh, or systemctl start iv-tailnet-join on
# a prod-lane VM)
```

## 5. Delete the stale Tailscale node

The old VM's node lingers in the admin console as an offline peer. Left there, a
future VM reusing that name joins as `<name>-1` instead -- silently.

Delete it in the Tailscale admin console. **Not** automated, and deliberately so:
doing it from a VM would need `devices:core` on the shared credential, which
would give every tagged VM the ability to delete any node in the tailnet. The
credential is scoped to `auth_keys` only, and `provision-iv.sh` prints a warning
naming this exact consequence when it cannot list devices.

Audit for orphans -- offline peers with no backing VM:

```bash
tailscale status | grep -i offline
```

## 6. Things that do not survive, and are nobody's job to remember

- **Custom domains.** `kgl-thoughts`' `lundstedt.us` had to be re-added with
  `domain add <vm> <domain>` after its recreate. Cloudflare DNS must stay
  DNS-only (grey cloud) pointing at `<name>.exe.xyz`.
- **Untracked service data.** `telnyx-vm` held ~2.2 MB of irreplaceable
  voicemails, signed PDFs and a secrets env file -- none of it in git. It is now
  backed up nightly to Tigris by a committed timer, which is the durable answer;
  a one-off copy before deletion is the minimum.
- **`public_proxy` / sharing settings.** Set at creation or by `share`, not
  inherited by a replacement.
- **exe.dev tags.** Pass them at `new` time -- tags govern which integrations a
  VM receives, and a missing one is a capability the replacement silently lacks.

## The failure shape to watch for

Every item above shares one shape: **the VM comes up healthy, every check passes,
and something simply never happens.** A replacement with no work checked out. A
renamed VM that cannot authenticate. A node named `<name>-1`. A doc site that
renders and serves nothing.

None of these announce themselves. Verify the thing you actually want, not the
thing that is easy to check.
