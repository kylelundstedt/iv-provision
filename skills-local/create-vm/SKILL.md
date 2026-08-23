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
itself. Create it with the tailnet tag, then provision over SSH:

```
new --name=<name> --tag=tailnet --image=ghcr.io/kylelundstedt/exeslim-dev:2026-08-19.13.1 --cpu=2 --memory=8GB --disk=15GB
```

`--tag=tailnet` carries the `api-tailscale` integration, which is what lets
`provision-iv.sh` join the tailnet (automatic since 3.0.5). Without the tag,
provisioning prints `not joined: api-tailscale integration not attached` and
carries on regardless -- a quiet no-op, not an error.

### Then provision -- over SSH, not `--prompt`

Wait for the VM to appear on the tailnet, then:

```bash
ssh <name> "git clone https://github.com/kylelundstedt/iv-provision.git ~/iv-provision \
  && git -C ~/iv-provision checkout 3.0.16 \
  && ~/iv-provision/provision-iv.sh"
```

**Always pin the tag.** An unpinned checkout "succeeds, prints nothing alarming,
and provisions an older recipe" (`upgrade-vm` skill).

#### Why not `--prompt`

`new --prompt` hands the provisioning command to the new VM's Shelley as an
*instruction*, not an exec. It is one-shot and bounded by that session's context
window: provisioning takes minutes, and the session can hit `context deadline
exceeded` mid-run, leaving a VM that exists, looks created, and is half
provisioned. Measured on `iv-cli` 2026-08-22 -- the create returned an error, the
VM was fine, and the SSH path finished the job.

SSH has none of that: the command either runs to completion or fails loudly, and
nothing cancels it partway.

`--prompt` remains a reasonable **fallback** when SSH is genuinely unavailable
(no tailnet yet, no key to hand). If used, quote it -- the command contains `&&`
and `~`, which the shell would otherwise eat:

```
--prompt='git clone https://github.com/kylelundstedt/iv-provision.git ~/iv-provision && git -C ~/iv-provision checkout 3.0.16 && ~/iv-provision/provision-iv.sh'
```

Note the `-C` in `git -C ~/iv-provision checkout` is **git's** flag, not curl's.
Dropping it (or letting it reach `curl`) checks out in the wrong directory.

### exeslim -- deployment targets

systemd, TLS roots, curl. **No Shelley, no toolchain.** Image only:

```
new --name=<name> --image=ghcr.io/kylelundstedt/exeslim:2026-08-19.13.1 --cpu=2 --memory=8GB --disk=15GB
```

Do **not** add `--prompt`: `new --prompt` requires an image with Shelley, so it
would silently do nothing. Do not add the provisioning command either -- there is
no `git` to clone with. A deployment target gets its payload pushed to it.

Add `--tag=tailnet` here only if the user asks for tailnet access; nothing on this
image will join on its own, so it is then a manual `join-tailnet`.

## Pins

| What | Value |
| ---- | ----- |
| image build ID (both images) | `2026-08-19.13.1` |
| `iv-provision` tag | `3.0.16` |

Both images publish the same `<date>.<run>.<attempt>` build ID from one pipeline,
so a single verified ID pins both. Bump them here when they move.

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

1. Report the name and URL exe.dev returned.
2. Wait for the tailnet. Poll every ~20s, up to ~4 minutes:

   ```bash
   tailscale status | grep -w <name>
   ```

3. Provision over SSH (command above). Expect it to take several minutes.
4. **Verify, do not assume.** The lock file is written at the *end* of a
   successful run, so its presence is most of the signal -- but check the
   revision, not just that a version string exists:

   ```bash
   ssh <name> 'grep -E "^(provision_repo_sha|apex_version|tailscale_version)=" ~/iv-provision.lock'
   ```

   `provision_repo_sha` must match the tag you pinned. A lock recording some
   *other* sha is the exact failure `upgrade-vm` warns about -- provisioning
   quietly ran an older recipe -- and a bare "is apex_version set?" check passes
   straight through it.

5. Only then report success, naming the sha you verified.

## When something fails

**`context deadline exceeded` is not a failure of the VM.** It is the expected
return when a `--prompt` session outlives its context. Read it as "VM exists,
provisioning unfinished" -- then SSH in and provision, do not recreate.

Anything that leaves a VM half-provisioned is repaired the same way: re-run
`provision-iv.sh`. It is idempotent, and re-provisioning in place is the normal
fix (`upgrade-vm`), not a recreate.
