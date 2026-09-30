---
title: "IV Development Platform"
---

## Purpose and status

This is the target architecture for one Linux development-VM platform that can
run on either exe.dev or Apple Container. It is a decision document, not a
provisioning runbook.

As of 2026-09-30:

- `iv-provision` already manages the exe.dev development fleet.
- The Apple runtime adapter is designed but not yet at provider parity.
- Aperture is the planned shared gateway for models, remote MCP, Tailscale tools,
  and AI-session capture.
- Production application VMs remain on exe.dev and are outside this redesign.

Apple-specific host and VM details live in
[Apple Container Development VMs](apple-container-dev-vms.md). Current exe.dev
provisioning mechanics live in the rest of this repository.

## Decisions at a glance

1. **One guest contract, two compute providers.** A development VM should behave
   the same whether it runs on exe.dev or Apple Container.
2. **`iv-provision` owns policy.** Provider APIs, CLIs, and MCP servers are
   transports. They do not own image selection, release pins, enrollment rules,
   verification, or retirement.
3. **Tailscale is the common access network.** Every completed development VM is
   a persistent, tag-owned `tag:dev` node with Tailscale SSH enabled.
4. **Aperture is the shared gateway.** Ordinary VMs use it for approved remote
   MCP tools and model traffic. Administrative tools are restricted to the
   control tier.
5. **Interactive and unattended paths remain separate.** Native MCP is preferred
   for attended work; narrowly scoped APIs remain available for automation.
6. **Credentials are never image content.** OAuth state and provider credentials
   are created after provisioning and stored only at their intended trust
   boundary.
7. **Aperture and Entire have different audit jobs.** Aperture records routed AI
   activity; Entire records Git-linked authoring provenance.

## Platform contract

A developer or agent should find the following after connecting to a development
VM on either provider:

- user `exedev`, UID/GID 1000, home `/home/exedev`
- Ubuntu 24.04 userspace
- the same shell, PATH, filesystem layout, packages, and systemd services
- the same pinned IV tools, coding agents, skills, and data locations
- the same Tailscale hostname, `tag:dev` identity, MagicDNS, and Tailscale SSH
- the same model and common remote-MCP endpoints
- the same Aperture session-capture policy
- the same Entire Git-provenance behavior
- the same `iv-provision.lock` contract, apart from explicit provider and
  architecture fields

Parity is behavioral, not byte-for-byte. CPU architecture, kernel, boot process,
virtual hardware, and provider control planes may differ.

The platform does **not** attempt to reproduce exe.dev ingress, billing, or its
complete integration control plane on macOS. It also does not move production
workloads to Apple Container or turn Aperture into a general service mesh.

## System map

```text
Operator or agent
       |
       | lifecycle policy
       v
iv-provision control tier
       |
       | provider adapter
       +----------------------+----------------------+
       |                                             |
       v                                             v
exe.dev control plane                        Apple Container host
       |                                             |
       +------------------ creates VM ---------------+
                              |
                              v
                    pinned iv-provision release
                              |
                              v
                  verified VM, Tailscale tag:dev
                              |
                  +-----------+-----------+
                  |                       |
                  v                       v
        local project state       Aperture gateway
      code, skills, Entire       models, MCP, audit
```

### Responsibilities

| Component                 | Responsibility                                                                                                                 |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `iv-provision` repository | Desired guest state, pinned tools, lifecycle policy, enrollment rules, inventory schema, parity tests, and retirement workflow |
| `iv-provision` control VM | Executes or coordinates privileged lifecycle operations and scheduled fleet checks                                             |
| `exeslim`                 | Bootable OCI images and the minimal Ubuntu/systemd baseline                                                                    |
| exe.dev                   | exe.dev compute, provider lifecycle, authenticated edge access, and provider-specific integrations                             |
| Apple hosts               | Apple Container compute and host-local services such as LM Studio                                                              |
| Aperture                  | Shared model gateway, remote MCP catalog, Tailscale/Tailscale SSH tools, grants, and routed-session audit                      |
| Tailscale                 | Common private network, device identity, access rules, MagicDNS, and SSH policy                                                |
| Entire                    | Git-linked agent checkpoints and authoring provenance                                                                          |
| Project repositories      | Project code, tests, instructions, and project-specific skills                                                                 |
| Dotfiles                  | Minimal physical-Mac configuration and genuinely host-native services                                                          |

## VM lifecycle

The portable lifecycle is one workflow with provider-specific creation adapters.
The planned interface is:

```text
create-dev-vm --platform exe ...
create-dev-vm --platform apple --host klundstedt-mini ...
create-dev-vm --platform apple --host klundstedt-mbp ...
```

### 1. Create the machine

| Provider        | Attended path                            | Unattended path                               |
| --------------- | ---------------------------------------- | --------------------------------------------- |
| exe.dev         | Native exe.dev MCP                       | Command-scoped exe.dev HTTPS API              |
| Apple Container | Local container CLI on the selected host | Approved remote worker or host-execution path |

The native exe.dev MCP offers either full-lobby authority, including SSH into
all VMs, or authority over one selected VM. Use the one-VM grant for isolated
work. Reserve the full-lobby grant for explicit fleet administration on a
trusted control client.

### 2. Converge the guest

Run a pinned `iv-provision` release inside the new VM. This step installs the
fleet tools and services, applies agent configuration, and writes
`~/iv-provision.lock`.

Provider creation success is not platform success. The VM is incomplete until
convergence and verification pass.

### 3. Enroll it in Tailscale

The final identity is a persistent, tag-owned `tag:dev` node with Tailscale SSH
enabled.

There are two enrollment modes:

- **Attended:** Aperture's Tailscale MCP proposes the node and a person approves
  it. This is the preferred interactive path when its exact tagging behavior has
  been qualified.
- **Unattended:** the existing `api-tailscale` integration mints a narrowly
  scoped auth key. It remains intentionally incapable of broad device
  administration.

Promotion or retirement must target an immutable device ID, never hostname
alone. Before applying `tag:dev`, validate the owner, hostname, creation time,
expected attributes, current tags, and matching lifecycle operation.

### 4. Verify and record

Run the provider-neutral parity suite and record:

- provider and host
- image and architecture
- `iv-provision` release and lock data
- immutable Tailscale device identity and tags
- agent, MCP, model, service, and persistence checks
- operation result and any required cleanup

A VM that has not passed verification must not be treated as a normal `tag:dev`
node.

### 5. Operate and retire

Use Tailscale SSH as the normal cross-provider shell path. Retirement removes
provider compute, Tailscale identity, integration attachments, inventory state,
and any per-VM credentials as one recorded operation.

## Access and tool paths

| Need                             | Preferred path             | Fallback or automation path                 | Boundary                                                |
| -------------------------------- | -------------------------- | ------------------------------------------- | ------------------------------------------------------- |
| exe.dev lifecycle                | Native exe.dev MCP         | Scoped exe.dev HTTPS API                    | Full lobby or one VM for MCP; command allowlist for API |
| exe.dev bootstrap/recovery shell | exe.dev MCP `ssh`          | Owner SSH or scoped HTTPS execution         | Works before Tailscale is healthy                       |
| Normal VM shell                  | Aperture Tailscale SSH MCP | Direct Tailscale SSH                        | Tailscale access rules are authoritative                |
| Tailnet enrollment               | Aperture Tailscale MCP     | Scoped `api-tailscale` auth-key integration | Interactive approval versus unattended key minting      |
| Common SaaS/data tools           | Aperture MCP endpoint      | Explicit direct exception                   | Aperture connector and tool grants                      |
| VM-local or repository tools     | Direct stdio/local MCP     | None                                        | Local filesystem and process boundary                   |

The two remote-shell paths are intentionally complementary:

- exe.dev SSH is provider-specific and remains useful for bootstrap and recovery;
- Tailscale SSH is the provider-neutral steady-state path for exe.dev and Apple
  VMs.

`klundstedt-mbp` does not accept Tailscale SSH. It remains a local executor
unless a narrow authenticated worker is added deliberately.

## MCP layout

Every ordinary development VM registers one shared Aperture endpoint:

```text
http://ai.dojo-sun.ts.net/v1/mcp
```

The endpoint is HTTP because it is tailnet-only and already protected by
WireGuard. It can move to HTTPS later without changing the architecture.

```text
ordinary development VM
       |
       `-- Aperture
             |-- common data and SaaS connectors
             |-- personal connectors where authorized
             `-- no fleet administration tools

iv-provision control tier
       |
       |-- Aperture control project
       |     |-- Tailscale
       |     `-- Tailscale SSH
       `-- direct exe.dev MCP
```

The control project is available only to the `iv-provision` control identity,
preferably enforced with a distinct caller tag such as `tag:iv-control`.
Aperture Projects should restrict both tools and relevant tailnet nodes. Projects
are an additional control layer; Tailscale access rules remain the hard network
boundary.

Current `.int.exe.xyz` MCP URLs are exe.dev edge integrations, not portable
Aperture upstreams. Migrate each service to its direct upstream, an Aperture
built-in, or a tailnet-accessible relay. The common catalog is expected to cover
services such as MotherDuck, GitHub, Tigris, and Readwise, but the final catalog
remains an explicit deployment decision.

Direct MCP registration is reserved for:

- stdio or repository-local tools
- temporary MCP servers started by a project
- tools that require the local filesystem
- a provider control plane on its designated operator client, such as the
  exe.dev MCP on `iv-provision`

Do not place full exe.dev lobby authority or Tailscale administration tools in
the common fleet connector set. Do not build a custom MCP merely to duplicate
native node enrollment or SSH. Add a narrow IV workflow only when it enforces a
cross-provider invariant the native tools cannot express.

## Credential placement

| Credential or state                 | Location                                                       | Rule                                                                         |
| ----------------------------------- | -------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| exe.dev MCP OAuth                   | Designated operator client                                     | One-VM grant by default; full lobby only for deliberate fleet administration |
| exe.dev HTTPS token                 | exe.dev edge integration or protected control-host state       | Short-lived and command-scoped for unattended work                           |
| Tailscale auth-key authority        | exe.dev edge integration or protected control-host state       | Keep unattended bootstrap narrow; do not widen the shared integration        |
| Aperture connector credentials      | Aperture                                                       | Never distribute upstream credentials to ordinary VMs                        |
| Claude and Codex subscription OAuth | Individual VM user's persistent home                           | Interactive login after provisioning; never bake or copy                     |
| Shelley model credential            | Aperture-managed API provider                                  | Do not reuse subscription OAuth in a third-party harness                     |
| Git transport credentials           | Provider-specific Git integration or approved portable adapter | MCP/API access does not replace clone and push authentication                |
| Object-storage credentials          | Signed or short-lived storage-specific path                    | Generic HTTP proxying does not replace S3 signing                            |

No OAuth database, broad provider token, or connector secret belongs in an OCI
image, Git repository, copied home directory, or `iv-provision.lock`.

## Models and agent sessions

Aperture is the common model endpoint:

- Claude Code and Codex retain their official subscription login state in the
  VM while inference traverses Aperture.
- Shelley uses an API-based provider configured through Aperture.
- LM Studio on either Mac is exposed through a tailnet-only path and registered
  as an approved self-hosted provider.

Provider-qualified LM Studio model names should be used until health and failover
behavior are proven. Frankfurt latency and streaming quality must pass a canary
before local models depend on this route. A direct host-local endpoint remains a
performance and outage fallback, with the explicit cost that those requests are
not present in Aperture's central log.

Aperture is the authoritative record for routed AI requests, tool calls, model
usage, and session identity. Entire remains authoritative for decision context
and checkpoints linked to Git history. Where possible, both systems should store
the same native agent session identifier.

AgentsView can be retired only after nonzero Aperture retention and required
S3-compatible export are enabled, representative Claude, Codex, Shelley,
remote-MCP, and local-model sessions have been compared against the exported
records, and the historical archive has been preserved.

## Failure behavior

- Loss of `iv-provision` pauses privileged promotion and coordinated retirement,
  but should not stop already-provisioned VMs.
- Loss of Aperture removes shared remote MCP, model governance, and central
  routed-session logging. Local repositories, local skills, direct provider
  recovery paths, and explicitly documented local-model fallbacks continue.
- Loss of Tailscale removes the common steady-state access path. exe.dev edge SSH
  remains available for exe.dev bootstrap and recovery.
- An Apple VM may exist temporarily with a user-owned Tailscale identity during a
  control-plane outage, but it is not parity-complete and must not be treated as
  `tag:dev`.

Break-glass credentials must be independent, narrowly scoped, documented, and
revocable. Persistent VM-to-VM application traffic stays directly on the
tailnet rather than traversing Aperture.

## Implementation sequence

1. **Define the machine-readable contract.** Specify inventory, lock fields,
   parity checks, lifecycle states, and allowed provider differences.
2. **Build `create-dev-vm`.** Implement exe.dev and Apple creation adapters,
   pinned convergence, idempotent verification, and recorded cleanup.
3. **Qualify the native control tools.** Test exe.dev full-lobby and one-VM
   grants; test Tailscale node approval, immutable identity, tag assignment,
   retirement, project restrictions, audited SSH, and long-running commands.
4. **Deploy the shared gateway contract.** Register the common Aperture MCP and
   model endpoints; restrict Tailscale administration to the control project;
   document one-time user logins.
5. **Complete credential portability.** Define Git clone/push and object-storage
   signing paths without broad secrets in guests.
6. **Prove audit replacement.** Validate Aperture export and Entire correlation,
   preserve the AgentsView archive, then remove AgentsView-specific services and
   integrations.
7. **Test failure and parity continuously.** Exercise both providers, both shell
   paths, stop/start persistence, provider outages, Aperture outages, and
   retirement.

## Open decisions

- Exact inventory schema and lifecycle-state format
- Whether Tailscale MCP can assign or promote an exact device to `tag:dev` and
  retire it safely
- Which native-tool gaps require narrow IV control workflows
- Portable Git clone/push authentication
- Portable S3-compatible signing and short-lived credentials
- Apple remote-worker design, especially for `klundstedt-mbp`
- Common versus personal Aperture connector catalog
- LM Studio latency, streaming, and failover behavior through Frankfurt
- Session-ID equivalence across Aperture, Claude, Codex, Shelley, and Entire
- Authoritative backup location for inventory and audit exports
