---
name: create-vm
description: Create a new exe.dev VM on an IV base image from plain English, without leaving this VM. Use when asked to create/spin up/make a new VM on exeslim-dev (dev/agent box) or exeslim (deployment target). Runs `new` through the api-exe-new HTTP proxy, which carries a token scoped to that one command.
---

# Create VM

Creates an exe.dev VM on an IV base image, in response to a plain-English
request like:

- "create a new VM called iv-cli using exeslim-dev"
- "create iv-prodthing on exeslim, 2 CPU, 8GB, 40GB disk"
- "create iv-bigbox on exeslim-dev with 8 CPUs and 32GB RAM"

This exists so VM creation works from the **Prompt Shelley** box on exe.dev --
phone, iPad, any browser -- with no terminal, no SSH key, and no laptop. That is
the whole point: do not answer such a request with "run this on your Mac".

## Authority, and its limits

`api-exe-new` is an http-proxy integration attached to **this VM only**. exe.dev
injects a bearer token at its edge; the token never touches this VM and cannot be
read from it. It is scoped `--cmds=new`, enforced server-side.

Verified 2026-08-22 from `iv-provision`: `rm`, `ssh-key list`,
`integrations list`, `share set-public` and even `whoami` all return
**403 `command not allowed by token permissions`**. Only `new` returns 200.

Consequences to design around, not fight:

- **You cannot check whether a name is taken** (`ls` is 403). Just submit; exe.dev
  rejects duplicates itself. Report its error verbatim rather than guessing.
- **You cannot attach integrations or tag afterwards.** Everything the VM will
  ever need must be on the `new` line -- exe.dev fixes image, tags and
  integrations at creation.
- **You cannot delete a VM.** A typo'd name is the user's to clean up in the
  lobby. So confirm the name back before creating.

## The call

Post the lobby command as the request body:

```bash
curl -s --max-time 120 -X POST https://api-exe-new.int.exe.xyz/exec -d '<command>'
```

**Use `https://` explicitly.** The proxy answers plain `http://` with a 301, and
curl silently drops the POST body across a redirect -- the request then returns a
bare `301` and looks broken for no visible reason. (`-L --post301` also works, but
https direct is one less thing to get wrong.)

## Two images, two shapes

The shapes are deliberately **not** symmetric.

### exeslim-dev -- dev / agent boxes (the common case)

Carries Shelley plus `git jq nginx-light openssh-client`, so it can provision
itself. Create and provision in **one call**. Copy this verbatim, substituting
only the name and sizes:

```bash
curl -s --max-time 300 -X POST https://api-exe-new.int.exe.xyz/exec -d "new --name=<name> --tag=tailnet --image=ghcr.io/kylelundstedt/exeslim-dev:2026-08-28.24.1 --cpu=2 --memory=8GB --disk=15GB --prompt='sudo systemd-run --unit=iv-provision --collect --property=Type=oneshot --property=TimeoutStartSec=3600 --uid=exedev --setenv=HOME=/home/exedev /bin/bash -lc \"git clone https://github.com/kylelundstedt/iv-provision.git ~/iv-provision && git -C ~/iv-provision checkout 3.0.20 && ~/iv-provision/provision-iv.sh\"'"
```

`--tag=tailnet` carries the `api-tailscale` integration, which is what lets
`provision-iv.sh` join the tailnet (automatic since 3.0.5). Without the tag,
provisioning prints `not joined: api-tailscale integration not attached` and
carries on regardless -- a quiet no-op, not an error. Tag and prompt are a pair.

**Always pin the tag.** An unpinned checkout "succeeds, prints nothing alarming,
and provisions an older recipe" (`upgrade-vm` skill).

#### `systemd-run` is load-bearing -- do not simplify it away

The obvious prompt -- `git clone ... && provision-iv.sh` on its own -- **cannot
work**, and fails in a way that looks like something else.

`provision-iv.sh` installs IV's pinned Shelley, and to swap the binary it runs
`systemctl stop shelley.socket` / `stop shelley.service`. A `--prompt` command
*is* that service. So the script kills the session executing it, partway through:
the agent reports `Tool did not stop within the grace period after cancellation;
its output was discarded`, and the VM is left provisioned up to `install_shelley`
with no lock file. Measured on `iv-canary-f` and `iv-canary-g`, 2026-08-22.

`systemd-run` hands the work to systemd, so nothing in `provision-iv.sh` can kill
it. It also returns immediately, letting the prompt session end cleanly. Verified
on `iv-canary-h` and `iv-canary-j`: `unit Result: success`, `shelley: active`,
smoke PASS, **one pass, no repair step**.

The reflex fix for the truncation -- "provision over SSH instead" -- is worse: a
brand-new VM is not on the tailnet (so `ssh <name>` does not resolve) and the
exe.dev edge `ssh <name>.exe.xyz` requires the *account owner's* key, which a
fleet VM deliberately does not have (`Permission denied (publickey)`). That is a
closed loop, confirmed on `iv-canary-e`, which had to be deleted unprovisioned.
`--prompt` is the only way into a VM that does not exist yet.

#### Quoting

Three levels, and all three matter:

- **double** quotes around the whole `-d` payload;
- **single** quotes around the `--prompt` value (it contains `&&` and `~`);
- **escaped double** quotes (`\"`) around the `bash -lc` payload.

Also: the `-C` in `git -C ~/iv-provision checkout` is **git's** flag. It must stay
attached to `git` and never drift onto `curl`, or the checkout lands in the wrong
directory.

#### `context deadline exceeded` is NOT a failure

The call returns:

```
"error":"Error running Shelley prompt: context deadline exceeded"
```

**with HTTP 200, on a run that succeeded.** exe.dev is reporting that the prompt
session ended before it got a reply -- which is exactly what happens when
`provision-iv.sh` restarts Shelley. It says nothing about the outcome.

Measured on `iv-canary-j`: provisioning **completed at +28s** and the API returned
that error at **+30s**. The error arrived two seconds *after* the work was
finished.

So never report it as a failure, never recreate on it, and never "repair" a VM
because of it. The lock file is the only verdict.

### exeslim -- deployment targets

systemd, TLS roots, curl. **No Shelley, no toolchain.** Image only:

```
new --name=<name> --image=ghcr.io/kylelundstedt/exeslim:2026-08-28.24.1 --cpu=2 --memory=8GB --disk=15GB
```

Do **not** add `--prompt`: `new --prompt` requires an image with Shelley, so it
would silently do nothing. Do not add the provisioning command either -- there is
no `git` to clone with. A deployment target gets its payload pushed to it.

Add `--tag=tailnet` here only if the user asks for tailnet access; nothing on this
image will join on its own, so it is then a manual `join-tailnet`.

## Pins

| What | Value |
| ---- | ----- |
| image build ID (both images) | `2026-08-28.24.1` |
| `iv-provision` tag | `3.0.20` |

Both images publish the same `<date>.<run>.<attempt>` build ID from one pipeline,
so a single verified ID pins both. Bump them here when they move.

**Do not pin below `2026-08-28.24.1`.** Earlier builds append the `~/.local/bin`
PATH export to the END of `~/.bashrc`, below Ubuntu skel's
`case $- in *i*) ;; *) return;; esac` guard -- so the export is dead code for
every non-interactive shell. `ssh <vm> '<cmd>'` is exactly that, which is how a
fully-provisioned VM came to fail with `/usr/bin/env: 'python3': No such file or
directory` while python3 worked fine interactively. The bug was invisible for
months because the older base shipped zsh (`.zshenv` is read on every
invocation); it only became reachable when the shell became bash. Fixed in
exeslim#6 and verified in the published image.

## Defaults

`--cpu=2 --memory=8GB --disk=15GB` unless the user says otherwise. These match
`new-dev-vm`'s long-standing defaults.

Parse sizes from plain English ("4 CPUs and 16GB" -> `--cpu=4 --memory=16GB`;
"50GB disk" -> `--disk=50GB`). The API accepts arbitrary combinations -- it is
less restrictive than the web form, which welds CPU/RAM into fixed pairs
(2x4, 2x8, 4x16, 8x32, 16x64) and offers only 20/40/80/160/320 GB disks. Plan
tier still caps the top end; exe.dev refuses what the plan disallows.

## Names

exe.dev **rejects names ending in `-<digits>`** (`test-123` fails, `test-abc`
works). Catch that before submitting -- it is a confusing error otherwise.

## After creating

A 200 from `new` means **the VM was created**. It does not mean the VM is ready,
and it says nothing about provisioning. Do not report success yet.

1. Report the name and URL exe.dev returned. Ignore any `context deadline
   exceeded` in the response.
2. **Wait for the tailnet.** The VM joins partway through `provision-iv.sh`
   (`install_tailscale` runs first, `install_shelley` last), so its appearance
   proves the prompt was received and the run is under way. Poll every 10s:

   ```bash
   tailscale status | grep -w <name>
   ```

   Note this is a *progress* signal, not a completion one -- a VM can be on the
   tailnet with provisioning still running, or (without `systemd-run`) dead.

3. **Verify completion.** Once on the tailnet, `ssh <name>` works (Tailscale SSH,
   keyless). Poll for the lock, which is written at the very end of a successful
   run:

   ```bash
   ssh <name> 'grep -E "^(provision_repo_sha|shelley_version|apex_version)=" ~/iv-provision.lock'
   ```

   `provision_repo_sha` must match the tag you pinned. A lock recording some
   *other* sha is the exact failure `upgrade-vm` warns about -- provisioning
   quietly ran an older recipe -- and a bare "is apex_version set?" check passes
   straight through it.

4. Corroborate with the unit itself, which is the cleanest single check:

   ```bash
   ssh <name> 'systemctl show iv-provision -p Result --value; systemctl is-active shelley.service'
   ```

   Expect `success` and `active`.

5. Only then report success, naming the sha you verified.

**On timing:** a full provision has been measured at **~28 seconds** from `new`
to lock (`iv-canary-j`, 2026-08-23) -- fast because it is ~10 pinned release
binaries pulled at data-center bandwidth. Do not hard-code that as an
expectation; poll for the lock rather than sleeping a fixed interval. But do not
assume minutes either: if nothing has happened after ~2 minutes, something is
wrong.

## When something fails

**`context deadline exceeded` is not a failure.** See above -- it has been
observed on a run that completed two seconds earlier. Go verify; do not recreate.

**If the lock exists but records the wrong sha**, provisioning ran an older
recipe. Re-provision at the right tag over the tailnet:

```bash
ssh <name> 'cd ~/iv-provision && git fetch --tags --quiet && git checkout --detach 3.0.20 && ~/iv-provision/provision-iv.sh'
```

**If the VM is on the tailnet but the lock never appears**, provisioning started
and died. The usual cause is the Shelley self-kill -- check whether the prompt
actually used `systemd-run`. Diagnose and finish over the tailnet:

```bash
ssh <name> 'sudo journalctl -u iv-provision --no-pager | tail -30'
ssh <name> '~/iv-provision/provision-iv.sh'
```

**If the VM never joins the tailnet**, provisioning did not run at all.
Recovery depends on who is asking:

- **From this VM there is no way in.** Not on the tailnet, and the exe.dev edge
  refuses a fleet VM's key by design. Report the situation honestly and hand it
  back -- do not claim a usable VM.
- **From a laptop with the account's exe.dev key**, the edge works:

  ```bash
  ssh <name>.exe.xyz "git clone https://github.com/kylelundstedt/iv-provision.git ~/iv-provision \
    && git -C ~/iv-provision checkout 3.0.20 \
    && ~/iv-provision/provision-iv.sh"
  ```

- Or re-send the prompt from the **Prompt Shelley** box on exe.dev, which reaches
  the VM's Shelley the same way `--prompt` did.

Anything that leaves a VM half-provisioned is repaired the same way: re-run
`provision-iv.sh`. It is idempotent, and re-provisioning in place is the normal
fix (`upgrade-vm`), not a recreate.
