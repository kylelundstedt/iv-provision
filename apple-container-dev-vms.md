---
title: "Apple Container Development VMs"
---

## Status

Draft Apple runtime design, recorded 2026-09-20 and revised 2026-09-23.

This page describes the Apple-specific adapter for the broader
[IV Development Platform](development-platform.md). The platform page owns
lifecycle orchestration, Aperture, tailnet promotion, remote MCP, cloud models,
credentials, inventory, and high availability. This page owns the decisions
required to make an Apple container machine behave like an exe.dev development
VM.

Production application VMs remain on exe.dev.

The companion [Tailscale in Apple Containers](apple-containers-tailscale.md)
page records the verified Apple Container 1.4.1 kernel TUN configuration.

## Apple parity goal

An Apple development VM should converge on the platform contract:

- user `exedev`, UID/GID 1000, home `/home/exedev`
- Ubuntu 24.04 userspace
- the same shell, PATH, packages, systemd services, tools, agents, and skills as
  an exe.dev development VM
- persistent guest-owned repositories and agent state
- native `arm64` binaries where available
- `tag:dev`, MagicDNS, and Tailscale SSH after platform enrollment
- the same model, MCP, and lifecycle interfaces defined by the development
  platform

Expected differences are limited to architecture, kernel, virtual hardware,
boot mechanism, and physical-host services.

## Apple-specific non-goals

- Running production application workloads on Apple Container
- Reproducing exe.dev ingress, TLS/auth edge, billing, or integration attachment
  semantics on macOS
- Sharing the macOS home directory with the guest
- Making ARM64 and AMD64 image contents byte-identical
- Replacing the platform's provider-neutral lifecycle, credential, model, or MCP
  policy with Mac-specific logic

## Runtime decision: use container machines

Apple development VMs use `container machine`, not ordinary `container run`
containers.

Container machines provide the semantics this workload needs:

- persistent writable root filesystem
- the image's init system and long-running systemd services
- interactive shell and command execution as a machine user
- explicit CPU and memory allocation
- stop/start/reboot behavior suitable for a development VM
- first-boot user setup and an option to disable host-home sharing

Ordinary containers remain available for disposable tests, application stacks,
and Compose projects. They are not the development VM abstraction.

This decision creates an image requirement: Apple container machines boot
through Apple's machine init and then `/sbin/init`; they do not use exeslim's
OCI `CMD ["/usr/local/bin/init"]`. The Apple image must make that wrapper's work
unnecessary or move it into portable systemd configuration.

## Image architecture

Keep `kylelundstedt/exeslim` separate from `iv-provision`. Image construction
and guest convergence have independent release cycles.

A short-term image graph can be:

```text
exeslim
└── exeslim-dev
    └── exeslim-dev-apple
```

The Apple image for a release must derive from the exact immutable
`exeslim-dev` build used by the corresponding exe.dev fleet. Record both the
common build ID and platform image digest in inventory and parity output; never
pair an Apple `latest` with an independently resolved exe.dev `latest`.

If the Apple layer starts undoing substantial exe.dev configuration, refactor
into sibling outputs from a common stage:

```text
exeslim-common
├── exeslim                 exe.dev production
├── exeslim-dev             exe.dev development
└── exeslim-dev-apple       Apple development
```

The Apple image remains thin. Common tools, agents, skills, and services belong
in `iv-provision`, not in another image layer.

## Multi-architecture publication

Publish the relevant exeslim images for:

```text
linux/amd64
linux/arm64
```

exe.dev continues to select AMD64. Apple selects native ARM64. Validate every
apt dependency and image build step on both architectures. The existing
`iv-provision` binary downloads and checksums are already architecture-aware;
the image workflow is the current publication gap.

## Apple image adaptations

`exeslim-dev-apple` should:

- remove or replace the exe.dev-specific `/dev/vda` root filesystem entry
- account for `/sbin/init` boot instead of the OCI CMD wrapper
- verify cgroup, proc/sys, and systemd startup under machine mode
- disable `exe-setup.service`
- disable or replace exe.dev-specific Shelley units and `/exe.dev` paths
- add Apple machine user setup where required
- preserve `exedev` as UID/GID 1000 and the operational user
- add a stable platform marker such as `/etc/iv-platform`
- preserve journald and normal systemd service behavior
- avoid mounting or depending on the macOS home directory

The image should boot to a healthy multi-user system before `iv-provision` runs.

## Identity and storage

Create machines with host-home sharing disabled. Preserve:

```text
exedev:exedev
UID/GID 1000
/home/exedev
```

Do not use host-mounted repositories, dotfiles, agent databases, or tool state.
The persistent container-machine root filesystem is authoritative. This avoids
macOS UID ownership differences and keeps the VM's behavior aligned with
exe.dev.

Image-derived state and user state have different lifecycles:

- base-image changes normally recreate the machine
- tools and configuration can converge in place through `iv-provision`
- subscription logins and repository state persist with the machine filesystem
- backup/restore must be designed before machines hold irreplaceable work

## Apple Shelley adapter

Use the same pinned Shelley binary, database path, and agent state layout as an
exe.dev development VM. The Apple adapter must:

- generate a local Shelley configuration instead of reading
  `/exe.dev/shelley.json`
- replace the exe.dev-specific socket/service assumptions without changing the
  database location
- keep the listener private to the machine or an authenticated host/tailnet
  proxy
- expose browser access through an authenticated tailnet path, not a public bind
- point model and remote MCP traffic at the platform endpoints
- preserve Shelley state across machine stop/start and host reboot

The final URL and authentication mechanism remain a platform open decision, but
an Apple VM is not parity-complete merely because the Shelley binary starts.

## macOS host profile

Treat `klundstedt-mini` and `klundstedt-mbp` as thin Apple Container hosts, not
parallel agent workstations. Almost all development CLIs, agents, skills, MCP
clients, language runtimes, and project dependencies belong inside container
machines.

The dotfiles repository should provide a common minimal profile such as:

```text
install.sh --profile apple-container-host
```

The profile should install and manage:

- Homebrew
- the official Apple Container CLI, kernel, and system service
- the `container compose` plugin from `compose.andon.dev`
- Orchard as the common optional UI
- the host's selected Tailscale client
- the portable `create-dev-vm` executor
- LM Studio
- unavoidable host credential, terminal, backup, and monitoring support

It should skip:

- Claude Code, Codex, Shelley, and other coding agents
- agent skills and MCP registrations
- Node, uv/Python, DuckDB, and project toolchains unless a host-control utility
  requires them
- AgentsView, which is retired from the target platform
- Entire on the physical host; Entire remains part of each development VM's Git
  provenance path
- repositories intended to be edited or built inside development VMs

Preserve the current full workstation path until the minimal profile is proven
on both hosts.

## Official CLI, Compose, and Orchard

Automation targets the official `container` and `container machine` CLI
surfaces.

Responsibility is explicit:

```text
Development VM lifecycle       container machine
Application/auxiliary stacks   container compose
Interactive management         Orchard
```

The Compose plugin orchestrates ordinary containers, not container machines.
It is useful for auxiliary stacks, disposable services, and other multi-service
workloads. Orchard and the plugin share the same Compose planning
implementation, and Orchard also manages container machines, so Orchard is the
preferred optional UI rather than Davit.

The host profile should verify or reinstall the Compose plugin after Apple
Container upgrades because the Apple installer currently clears the plugin
directory.

## Host roles

Keep the two Macs as similar as practical while preserving their deliberate
Tailscale difference.

### `klundstedt-mini`

- always-on primary Apple VM worker
- open-source `tailscaled` system daemon
- accepts Tailscale SSH
- can run `create-dev-vm` locally
- can be driven remotely by `iv-provision` or an approved gateway tool
- runs LM Studio as the durable fleet-local model host

### `klundstedt-mbp`

- portable Apple VM worker and recovery path
- standard Tailscale app
- does not accept Tailscale SSH
- runs `create-dev-vm` locally
- is not initially a remote worker
- runs LM Studio locally; 128 GB RAM supports larger independent models

Do not switch the MacBook to open-source `tailscaled` merely for symmetry. If
remote orchestration later matters, add a narrow authenticated worker service
rather than broad host access.

Both Macs should otherwise receive the same host profile, Apple Container
configuration, Compose plugin, Orchard, LM Studio, and VM workflow.

## Host-local LM Studio

LM Studio remains native to use Apple hardware acceleration. Each Mac exposes
its loopback-only server through a tailnet-only `/lmstudio` Serve path, and
Aperture registers the mini and MacBook as separate self-hosted providers. This
puts local-model inference into the same centralized session ledger as cloud
models while keeping LM Studio off the LAN.

Provider-qualified model names select a physical host deterministically. Before
making Aperture the default, run latency, time-to-first-token, streaming, and
large-context canaries across the Frankfurt round trip. Preserve the direct
host-local endpoint as an explicitly unlogged performance/outage break-glass
path.

## Apple executor

The platform's `create-dev-vm` workflow uses the same Apple executor interface in
two modes:

```text
local executor
    `-- container machine ...

remote executor
    `-- approved command path to Mac
            `-- container machine ...
```

`klundstedt-mini` supports both modes because it accepts Tailscale SSH.
`klundstedt-mbp` supports local execution only until a narrow worker service is
added.

The executor is responsible only for host operations:

- ensure the Apple Container system is running
- pull/select the immutable image
- create the machine with CPU, memory, and `home-mount=none`
- run commands as root or `exedev` when directed by the management plane
- stop, start, inspect, and delete the machine
- return structured results

Enrollment, promotion, desired-state provisioning, and inventory policy remain
in the [development platform](development-platform.md).

## Apple tailnet enrollment

The Apple executor and management plane cooperate in this sequence:

```text
create-dev-vm
    |
    +-- create the container machine on the selected Mac
    +-- request Aperture Tailnet_provision_node
    +-- present the one-time approval URL
    +-- receive the one-use enrollment key
    +-- pass the key to the new machine
    +-- run tailscale up --ssh --accept-dns
    +-- retrieve the exact Tailscale device ID
    +-- ask iv-provision to validate and apply tag:dev
    +-- verify grants, MagicDNS, and Tailscale SSH
    `-- complete guest provisioning and parity checks
```

Aperture supplies initial user-approved enrollment without leaving a standing
credential on the Mac or guest. If `iv-provision` is unavailable, either Mac may
still create and enroll the machine locally; the node remains temporarily
user-owned and is not parity-complete. Promotion to `tag:dev`, final access
verification, and authoritative inventory resume when the management authority
returns. The platform management plane owns promotion and retirement. The
low-level TUN and persistence requirements are in
[Tailscale in Apple Containers](apple-containers-tailscale.md).

## Apple implementation plan

### 1. Publish multi-architecture exeslim images

Add ARM64 builds, retain immutable build IDs, and validate both image variants.

### 2. Add `exeslim-dev-apple`

Implement the machine-mode boot, identity, filesystem, and service adaptations
listed above. Require a healthy systemd boot before provisioning.

### 3. Make `iv-provision` platform-aware

Centralize platform detection and isolate Apple differences behind functions
such as:

```text
configure_shelley
record_base_provenance
configure_service_exposure
```

Tool installation, checksums, skills, agent configuration, patching, and data
layout remain common.

### 4. Add the minimal dotfiles host profile

Install the same core package set on both Macs, with host-specific Tailscale
implementation and role-specific services. Stop installing the Linux guest
environment directly on macOS.

### 5. Implement the Apple executor

Support local execution on both Macs and remote execution on the mini. Use
structured output and idempotent commands so the platform workflow can retry
safely.

### 6. Run parity and persistence canaries

Verify identity, services, tool versions, agents, skills, tailnet behavior,
model/MCP configuration, Aperture session capture/export, Entire Git provenance,
and state across machine stop/start and host reboot.

## Open Apple-specific decisions

- Backup and restore format for persistent container-machine root filesystems
- Whether and how the MacBook gains a narrow remote worker service
- CPU, memory, and disk defaults for development machines
- How host-local LM Studio endpoints are discovered by each machine
- Whether additional Mac workers are supported in the first release
