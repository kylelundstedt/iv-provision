---
title: "Apple Container Development VM Portability"
---

## Status

Draft design, recorded 2026-09-20.

This project makes Industry Vault development and agent VMs functionally
identical on two runtimes:

- exe.dev VMs built from `exeslim-dev`
- Apple Container VMs built from an Apple-specific `exeslim-dev` derivative

Production VMs remain on exe.dev. This project does not attempt to make Apple
Container a production hosting platform.

The companion [Tailscale in Apple Containers](apple-containers-tailscale.md)
page records the verified Apple Container 1.4.1 kernel TUN configuration. This
page records the broader VM portability design and implementation plan.

## Goal

A developer or agent should find the same environment after connecting to a VM
on either platform:

- user `exedev`, UID/GID 1000, home `/home/exedev`
- Ubuntu 24.04 userspace
- the same shell, PATH, filesystem layout, packages, and systemd services
- the same pinned IV tools, coding agents, skills, MCP configuration, and data
  locations
- the same Tailscale hostname, `tag:dev` identity, MagicDNS behavior, and
  Tailscale SSH access
- the same `iv-provision.lock` contract, apart from explicit platform and
  architecture fields

“Identical” means behavioral parity, not byte identity. Apple hosts run native
`arm64`; current exe.dev VMs run `amd64`. The Linux kernel, virtual hardware,
boot mechanism, and surrounding platform control plane also differ.

## Non-goals

- Running production workloads on Apple Container
- Reproducing exe.dev's public ingress, TLS termination, authenticated edge,
  VM billing, or integration control plane on macOS
- Making the two architectures produce identical binary hashes
- Sharing the macOS home directory with the Linux VM

## Runtime decision: use container machines

Apple development VMs will use `container machine`, not ordinary
`container run` containers.

Container machines match the intended workload:

- persistent writable root filesystem
- an actual init system and long-running systemd services
- interactive shell and command execution as a machine user
- explicit CPU and memory allocation
- stop/start/reboot semantics suitable for a development VM
- first-boot user setup and an option to disable the host-home mount

Ordinary containers remain useful for disposable tests and application-style
workloads, but are not the development VM abstraction. Running systemd inside a
plain container would recreate machine semantics with more flags and less
lifecycle support.

This decision creates one image requirement: Apple container machines boot
through Apple's machine init and then `/sbin/init`; they do not use exeslim's
OCI `CMD ["/usr/local/bin/init"]`. The Apple image must therefore make the work
currently done by that wrapper unnecessary or move it into portable systemd
configuration.

## Architecture

### Repository ownership

Keep the image and provisioning repositories separate. Their boundaries become
clearer, not weaker, when the same guest runs on two platforms:

| Repository | Owns | Does not own |
| --- | --- | --- |
| `kylelundstedt/exeslim` | Bootable OCI images, Ubuntu/systemd baseline, `exedev` identity, architecture publication, and thin exe.dev/Apple runtime adaptations | Volatile coding agents, skills, MCP configuration, personal host applications |
| `kylelundstedt/iv-provision` | Guest convergence, pinned tools, agents, skills, services, tailnet promotion, parity tests, inventory, and `create-dev-vm` orchestration | macOS workstation configuration or production application images |
| `kylelundstedt/dotfiles` | Minimal physical-host configuration for the two Macs and any genuinely host-native services | The Linux development environment now supplied by the container machine |

`exeslim` remains a separate image factory because image boot correctness,
multi-architecture publication, and runtime-specific filesystem/systemd changes
must be resolved before `iv-provision` can run. Folding image construction into
`iv-provision` would combine two independent release cycles: base-image rebuilds
and guest-tool/configuration releases.

### Images

```text
exeslim
└── exeslim-dev                 exe.dev development image
    └── exeslim-dev-apple       thin Apple machine compatibility layer
```

`exeslim-dev-apple` should inherit the exact immutable `exeslim-dev` build used
by the corresponding exe.dev fleet. It should contain only Apple-specific boot,
identity, and service changes; common tools and agent configuration remain in
`iv-provision`.

### Control plane and workers

`create-dev-vm` is a portable orchestration workflow, not a command coupled to
one machine.

Initially it can run from:

- `iv-provision`, operating a Mac worker over Tailscale SSH
- `klundstedt-mini`, operating its local Apple Container runtime directly

The same implementation should support both modes. The only difference is
whether the Apple Container command executor is local or reached over SSH.

```text
create-dev-vm orchestrator
        |
        +-- local executor on macOS
        |
        `-- SSH executor on a macOS worker
                    |
                    `-- Apple container machine
```

`iv-provision` remains the primary provisioning authority and inventory owner.
Allowing `klundstedt-mini` to run the workflow provides recovery and higher
availability when the exe.dev control VM is unavailable.

### macOS host role

Treat `klundstedt-mini` and `klundstedt-mbp` as thin Apple Container hosts, not
as parallel agent workstations. Almost all development CLIs, coding agents,
skills, MCP clients, language runtimes, and project dependencies belong inside
Apple container machines and are installed by `iv-provision`.

The dotfiles repository should gain an explicit minimal host profile, for
example `--profile apple-container-host`. That profile should install and manage
only host responsibilities such as:

- Homebrew
- the official Apple Container CLI, kernel, and system service
- the host Tailscale client, required for remote execution and host-native
  service exposure
- the portable `create-dev-vm` client/executor
- LM Studio, which remains native to use Apple hardware acceleration
- one optional operator interface such as Davit or Orchard
- unavoidable host credential, terminal, backup, and monitoring support

Davit or Orchard may improve interactive management, but automation must target
the official `container` CLI. They are operator interfaces, not dependencies of
the VM lifecycle contract. A headless/remote host such as `klundstedt-mini` may
prefer a CLI-oriented interface; `klundstedt-mbp` may prefer a native GUI.

The minimal host profile should skip installation and configuration of:

- Claude Code, Codex, Shelley, and other coding agents
- agent skills and MCP registrations
- Node, uv/Python, DuckDB, and project toolchains unless required by a
  host-control utility
- AgentsView and Entire guest services
- repositories intended to be edited or built inside development VMs

Host-native LM Studio remains deliberately outside the VM. Apple container
machines consume it through the existing authenticated tailnet/relay path; they
do not attempt to run the macOS GPU workload inside Linux.

### Tailnet enrollment and promotion

The intended sequence is:

> `iv-provision` creates the development VM, uses Aperture to authorize its
> initial tailnet enrollment, and then promotes it to `tag:dev`.

More precisely:

```text
iv-provision / create-dev-vm
    |
    +-- create the Apple container machine on the selected Mac
    +-- request Aperture Tailnet_provision_node
    +-- present the one-time approval URL to the operator
    +-- receive the one-use enrollment key after approval
    +-- pass the key to the new VM
    +-- run tailscale up --ssh --accept-dns
    +-- retrieve the exact Tailscale device ID
    +-- validate the new user-owned device
    +-- apply tag:dev through the Tailscale API
    +-- verify grants, MagicDNS, and Tailscale SSH
    `-- complete IV provisioning and parity checks
```

Aperture authorizes initial enrollment without placing a standing Tailscale
credential on either the Mac or the new VM. Applying `tag:dev` converts the
node to the same tag-owned identity used by exe.dev development VMs.

The existing `api-tailscale` integration is deliberately insufficient for the
promotion step: its OAuth token has only the `auth_keys` scope, and device API
calls return HTTP 403. Do not widen that shared integration. Create a separate
provisioning credential, for example `api-tailscale-provisioner`, with
`devices:core` write authority and permission to apply `tag:dev`. Attach it
directly and exclusively to the `iv-provision` VM.

Promotion must use the exact device ID. Hostname-only matching is unsafe. Before
applying the tag, validate at least:

- the exact device ID reported by the new VM
- expected owner identity
- requested hostname
- recent creation time
- expected Aperture-created attributes, when exposed by the API
- absence of unexpected tags
- a matching in-progress `create-dev-vm` operation

After promotion, `iv-provision` owns node retirement as well as creation.

## High availability

The workflow should be runnable from `klundstedt-mini`, but there are two
levels of availability:

1. **VM creation and Aperture enrollment.** The mini can perform these locally
   without `iv-provision`.
2. **Promotion to `tag:dev`.** Initially this still depends on the privileged
   credential attached to `iv-provision`.

Possible promotion failover designs, to be chosen later:

- allow the new VM to remain temporarily user-owned and promote it when
  `iv-provision` returns
- place a separate, revocable provisioning OAuth client in macOS Keychain on
  `klundstedt-mini`
- operate a second narrowly exposed promotion authority

If a secondary credential is used, it should be independent from the exe.dev
credential for audit and revocation. `devices:core` is broad authority, so the
availability benefit must be weighed against the additional credential and
blast radius.

## Implementation plan

### 1. Define and test the parity contract

Create a machine-readable parity manifest and checks for:

- identity, home, shell, PATH, and environment
- OS and package baseline
- enabled system and user services
- pinned IV tools and coding agents
- skills and MCP configuration
- Shelley, Entire, and AgentsView state locations
- Tailscale state, SSH, DNS, and tags
- reboot persistence

Keep an explicit allowlist for architecture, kernel, image metadata, and other
intentional platform differences.

### 2. Publish multi-architecture exeslim images

Publish both images for:

```text
linux/amd64
linux/arm64
```

Validate all apt dependencies and image build steps on ARM64. exe.dev continues
to use AMD64; Apple selects native ARM64.

### 3. Add `exeslim-dev-apple`

Create a thin image derived from a pinned immutable `exeslim-dev` build. It
should:

- remove or replace the exe.dev-specific `/dev/vda` fstab entry
- account for `/sbin/init` boot instead of the exeslim OCI CMD wrapper
- disable `exe-setup.service`
- disable or replace exe.dev-specific Shelley units
- add Apple container-machine user setup where needed
- ensure `exedev` remains UID/GID 1000 and the operational user
- add a stable platform marker such as `/etc/iv-platform`
- avoid mounting the macOS home directory

### 4. Make `iv-provision` platform-aware

Centralize platform detection and isolate differences behind a small interface:

```text
configure_tailnet
configure_shelley
configure_agentsview
configure_credentials
record_base_provenance
configure_service_exposure
```

Tool installation, checksums, skills, agent configuration, patching, and data
layout remain common.

### 5. Standardize identity and filesystem behavior

Create Apple machines with the host-home mount disabled. Preserve:

```text
exedev:exedev
UID/GID 1000
/home/exedev
```

Do not use host-mounted repositories or dotfiles. The persistent Apple machine
root filesystem is the development VM's authoritative storage.

### Related host work: add a minimal dotfiles profile

Refactor `kylelundstedt/dotfiles` so the two Macs can select an
`apple-container-host` profile. Preserve the current full workstation path for
other uses until the minimal profile is proven. The host profile should install
the small native substrate described above and explicitly skip agent, skill,
MCP, and development-tool setup.

Test this separately on `klundstedt-mini` and `klundstedt-mbp`: the mini is the
always-on remote worker, while the MacBook is a portable worker and recovery
path. Both must expose the same executor contract to `create-dev-vm` even if
they use different optional management interfaces.

### 6. Implement centralized Apple VM creation and tailnet enrollment

Implement the orchestration described above:

1. select the Mac worker and immutable image
2. create the container machine
3. request Aperture enrollment and operator approval
4. inject the one-use key and join the node
5. retrieve and validate its device ID
6. promote it to `tag:dev`
7. verify Tailscale SSH and policy behavior
8. run or complete `iv-provision`
9. record inventory and provenance

### 7. Abstract exe.dev-only credential paths

Inventory each `.int.exe.xyz` dependency and define an Apple equivalent,
including:

- LLM/Codex gateway
- GitHub and private repository access
- MotherDuck and other MCP services
- cloud and object-storage credentials
- AgentsView peer access

Prefer identical client configuration with platform-specific credential
delivery underneath it.

### 8. Make Shelley portable

Use the same pinned Shelley binary and database path on both platforms. For
Apple:

- generate a local Shelley configuration
- replace `/exe.dev/shelley.json`
- keep the listener private
- expose it through authenticated tailnet access
- preserve the same database and agent state layout

### 9. Adapt AgentsView fleet connectivity

Keep the local daemon and archive unchanged. Add a Tailscale source path for
Apple nodes while retaining exe.dev peer integrations for exe.dev nodes. The
central collector should enroll and monitor both kinds of sources.

### 10. Implement the portable `create-dev-vm` workflow

The command should support at least:

```text
create-dev-vm --platform exe ...
create-dev-vm --platform apple --host klundstedt-mini ...
```

For Apple it should pull the pinned image, create the machine, enroll/promote it,
run provisioning, execute parity checks, and print SSH and Shelley access
instructions. Local and remote Mac execution must use the same workflow code.

### 11. Add continuous parity tests

Run the same test suite against exe.dev and Apple canaries. Verify identity,
services, tool versions, tailnet behavior, agent operation, integrations, and
persistence across stop/start and host reboot.

## Open decisions

- Exact location and interface of `create-dev-vm`
- Whether promotion failover on `klundstedt-mini` is worth a second
  `devices:core` credential
- How Apple VMs consume private GitHub and exe.dev-backed MCP services
- Authentication and URL shape for Apple-hosted Shelley
- Inventory format and ownership for Apple machines
- Backup and restore policy for persistent Apple machine root filesystems
- Whether additional Mac workers should be supported from the first release
