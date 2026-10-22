---
title: "Bootstrap"
---

The canonical end-to-end bring-up for an IV VM. Each step is a distinct layer with
its own ownership — they are orchestrated in order, not merged into one script:

| Step | What                                                   | Owned by                                                      |
| ---- | ------------------------------------------------------ | ------------------------------------------------------------- |
| 1    | Create a VM from the **IV base image** (keeps Shelley) | `exeslim` repo + exe.dev                                      |
| 2    | Join the tailnet                                       | `provision-iv.sh` (automatic, if `api-tailscale` is attached) |
| 3    | Install the **team software layer**                    | `provision-iv.sh` (this repo, public)                         |
| 4    | Clone the work repo + serve its doc site               | repo integration + `provision-docsite`                        |
| 5    | _(optional)_ Personal overlay                          | your dotfiles `install.sh` (separate repo)                    |

The base image is a **custom** image, and that is deliberate. Earlier revisions
of these docs said IV had to use stock `exeuntu` because a custom image loses
Shelley; it loses Shelley only by default, and
`LABEL exe.dev/install-shelley=true` opts back in
(`ssh exe.dev doc customization`). The IV bases set that label and supply their
own `shelley.socket`/`shelley.service`.

What stays true is the split of responsibilities: the **image** carries the OS
layer, and **`provision-iv.sh`** carries the volatile, version-pinned tools.
exe.dev fixes a VM's image at creation with no way to move a live VM onto a
newer one, so baking the pinned tools would turn every bump into a fleet
recreate. See "Why a script, not a custom image" in `README.md`.

Two bases, one per lane
([`kylelundstedt/exeslim`](https://github.com/kylelundstedt/exeslim)):

| Base                                | For                | Carries                                                                         |
| ----------------------------------- | ------------------ | ------------------------------------------------------------------------------- |
| `ghcr.io/kylelundstedt/exeslim-dev` | agent/dev VMs      | exeslim + `git jq unzip nginx-light openssh-client libyaml-0-2` + Shelley units |
| `ghcr.io/kylelundstedt/exeslim`     | deployment targets | systemd, TLS roots, curl — no toolchain, no Shelley                             |

Stock `boldsoftware/exeuntu` remains available (omit `--image`) for a
batteries-included box that is not part of the IV fleet.

## 1. Create the VM (IV dev base)

```bash
# Use the immutable <date>.<run>.<attempt> build ID, from the package page.
# --tag=tailnet carries the api-tailscale integration that step 2 needs, and
# survives a later recreate; see iv-infra tailnet.md for why it grants nothing else.
ssh exe.dev new --name=<vm> --tag=tailnet \
  --image=ghcr.io/kylelundstedt/exeslim-dev:<date>.<run>.<attempt>
```

## 2. Join the tailnet (automatic, during step 3)

Nothing to run, if the VM was created with `--tag=tailnet` in step 1. That tag
carries the `api-tailscale` integration, and `provision-iv.sh` installs tailscale
and joins during step 3.

To tag a VM that already exists, or to attach for a single join without tagging:

```bash
ssh exe.dev tag <vm> tailnet                            # durable across recreate
ssh exe.dev integrations attach api-tailscale vm:<vm>   # one-off; detach after
```

Either way the grant is the consent signal, and an untagged, unattached VM simply
stays off the tailnet — provisioning says so and carries on rather than failing.
Until it joins, a VM is reachable only over the exe.dev edge. The `tailnet` tag
grants this and nothing else, deliberately; see iv-infra `tailnet.md`.

## 3. Provision the team software layer

Pin by checking out a tag/sha of this repo before running the script.

```bash
ssh <vm>.exe.xyz "git clone https://github.com/kylelundstedt/iv-provision.git ~/iv-provision \
  && git -C ~/iv-provision checkout <tag-or-sha> \
  && ~/iv-provision/provision-iv.sh"
```

`provision-iv.sh` installs DuckDB, Apex (the Markdown and documentation-site
renderer), the cloud CLIs (tigris/rclone; aws/azure/gcloud on demand,
via the `install-cloud-cli` helper), herdr, the
doc-site tools, the team agent config (AGENTS.md, Claude settings, Codex config, MCP
servers), and the vendored skills — no node required — and writes
`~/iv-provision.lock` recording exactly what landed.

## 4. Clone a repo + serve its doc site

```bash
ssh exe.dev integrations attach github-<owner>-<repo> vm:<vm>
ssh <vm>.exe.xyz "git clone https://github-<owner>-<repo>.int.exe.xyz/<org>/<repo>.git ~/<repo> \
  && provision-docsite ~/<repo>"
```

See `consuming.md` for repo-integration and doc-site details.

## 5. Personal overlay (optional)

The dotfiles repo is private, so the VM needs read access to it first:

```bash
ssh exe.dev integrations attach repo-dotfiles-ro vm:<vm>
ssh <vm>.exe.xyz "git clone https://github.int.exe.xyz/kylelundstedt/dotfiles.git ~/dotfiles \
  && ~/dotfiles/install.sh"
```

Personal dotfiles layer on top of the team defaults — they overlay `AGENTS.md`,
add personal MCP servers, and install additional skills. This stays in the
personal dotfiles repo, not here, so the team layer remains user-neutral.

## Upgrading later

To update an existing VM's software layer, re-provision in place — no recreate
needed. See the `upgrade-vm` skill.
