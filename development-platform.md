---
title: "IV Development Platform"
---

## Status

Draft architecture, recorded 2026-09-20 and revised 2026-09-23.

The Apple Container portability project exposed a broader design: Industry
Vault needs one development platform whose compute can run on exe.dev or Apple
Container without changing the agent environment, access model, or operating
workflow.

This page describes that platform-neutral architecture. The
[Apple Container Development VMs](apple-container-dev-vms.md) page describes the
Apple-specific runtime adapter. Production application VMs remain on exe.dev
and are outside this redesign.

## Goal

A developer or agent should find the same environment after connecting to a
development VM on either compute provider:

- user `exedev`, UID/GID 1000, home `/home/exedev`
- Ubuntu 24.04 userspace
- the same shell, PATH, filesystem layout, packages, and systemd services
- the same pinned IV tools, coding agents, skills, and data locations
- the same Tailscale hostname, `tag:dev` identity, MagicDNS, and Tailscale SSH
- the same model and remote MCP endpoints
- the same centrally captured AI-session record in Aperture
- the same Git-linked authoring provenance through Entire
- the same `iv-provision.lock` contract, apart from explicit platform and
  architecture fields

“Identical” means behavioral parity, not byte identity. Compute architecture,
kernel, virtual hardware, boot mechanism, and surrounding provider control
plane may differ.

## Non-goals

- Moving production application workloads from exe.dev to Apple Container
- Reproducing exe.dev public ingress, TLS termination, authenticated edge,
  billing, or complete integration control plane on macOS
- Requiring byte-identical images or binaries across AMD64 and ARM64
- Turning Aperture into a general service mesh for all VM-to-VM traffic
- Storing subscription OAuth state or broad provider credentials in images

## Platform architecture

```text
IV development platform
├── Management plane
│   └── iv-provision: desired state, lifecycle, promotion, inventory, parity
├── Gateway plane
│   └── Aperture: models, remote MCP, selected APIs, remote execution
├── Compute plane
│   ├── exe.dev VMs
│   └── Apple container machines
├── Host plane
│   ├── exe.dev infrastructure
│   ├── klundstedt-mini
│   └── klundstedt-mbp
└── Image and configuration plane
    ├── exeslim: bootable OCI images
    └── iv-provision: guest convergence
```

Aperture is called the gateway plane rather than only control plane because it
carries model inference and remote tool traffic as well as administrative tools.

## Ownership boundaries

| Component | Owns | Does not own |
| --- | --- | --- |
| `kylelundstedt/exeslim` | Bootable OCI images, Ubuntu/systemd baseline, `exedev` identity, architecture publication, and thin provider adaptations | Volatile agents, skills, MCP policy, physical host configuration |
| `kylelundstedt/iv-provision` | Desired guest state, pinned tools, agents, skills, services, lifecycle orchestration, tailnet promotion, inventory, and parity tests | macOS workstation configuration and production application images |
| `kylelundstedt/dotfiles` | Minimal physical-Mac configuration and genuinely host-native services | The Linux development environment supplied by a VM |
| Aperture | Model routing, authoritative AI-session captures, remote MCP and HTTP connectors, connector credentials, grants, audit, and selected remote execution | Local skills, VM filesystem tools, Git transport, object-storage signing, guest desired state, Git provenance |
| Entire | Authoring checkpoints and agent decision context linked to the code and Git history they produced | Fleet request routing, model governance, complete operational request capture |
| Project repositories | Project instructions, project-specific skills, code, tests, Entire checkpoints, and durable project memory | Fleet-wide machine provisioning |

## Management plane

`iv-provision` is the existing primary authority for exe.dev lifecycle and the
target authority and inventory owner for the cross-provider platform. The
portable `create-dev-vm` workflow described here is planned work; its policy and
desired-state rules will live in this repository.

The target command should support at least:

```text
create-dev-vm --platform exe ...
create-dev-vm --platform apple --host klundstedt-mini ...
create-dev-vm --platform apple --host klundstedt-mbp ...
```

The provider adapters differ only where the substrate requires it:

```text
create-dev-vm
├── exe executor
│   └── scoped exe.dev HTTPS API
└── Apple executor
    ├── local container CLI
    └── container CLI over an approved remote path
```

Both paths converge on the same identity, tailnet posture, `iv-provision`
release, agent configuration, services, and parity checks.

## Tailnet identity and enrollment

All development VMs finish as persistent, tag-owned `tag:dev` nodes with
Tailscale SSH enabled. Provider adapters may differ during bootstrap, but the
resulting identity and policy posture are part of the platform contract.

`iv-provision` owns any transition from a temporary or user-owned enrollment to
`tag:dev`, and node retirement as well as creation. Promotion must use an exact
device ID, never hostname alone. Validate owner, hostname, recent creation time,
expected node attributes, absence of unexpected tags, and a matching
in-progress lifecycle operation before applying the tag.

The existing `api-tailscale` integration has only `auth_keys` authority and is
intentionally insufficient for promotion. Do not widen that shared integration.
Use a separate provisioning credential, such as
`api-tailscale-provisioner`, attached directly and exclusively to the
`iv-provision` control VM.

The concrete Apple enrollment sequence is documented by the
[Apple runtime adapter](apple-container-dev-vms.md#apple-tailnet-enrollment).

## Gateway plane: remote MCP

Every development VM registers one remote MCP endpoint:

```text
http://ai.dojo-sun.ts.net/v1/mcp
```

Examples use HTTP because the gateway is tailnet-only and the connection is
already encrypted by WireGuard; this also matches Aperture's coding-client
configuration guidance. If the deployed gateway terminates HTTPS reliably, the
scheme may be upgraded consistently for MCP and model clients without changing
the architecture.

Aperture is the canonical catalog and credential boundary for
network-accessible MCP services. It aggregates connectors behind one endpoint,
injects upstream credentials, prefixes capabilities to avoid collisions, and
applies connector- or tool-level grants during discovery and invocation.

```text
Claude / Codex / Shelley on every dev VM
                    |
                    `-- Aperture /v1/mcp
                              |-- MotherDuck
                              |-- GitHub
                              |-- Tigris
                              |-- Readwise
                              `-- personal-mcp
```

Ordinary `tag:dev` VMs receive the common connector set. The `iv-provision`
control VM should also carry a distinct tag such as `tag:iv-control`, whose
additional grants expose sensitive administration and fleet connectors.
Ordinary VMs must not discover those tools.

The shared endpoint does not erase node identity. Aperture still distinguishes
callers for audit, revocation, grants, and per-node limits. No upstream MCP
credential is stored in a development VM.

### Direct MCP exceptions

Keep these registered directly in the VM when required:

- stdio MCP processes
- project-local tools that need the VM filesystem
- temporary MCP servers started by a repository
- tools whose useful scope is one VM rather than the fleet

Existing `.int.exe.xyz` MCP URLs are exe.dev edge integrations and generally
cannot be Aperture upstreams. Migrate each service to its direct upstream, an
Aperture built-in or verified connector, or a tailnet-accessible relay.

Skills do not move into Aperture. Native skills are local instruction,
reference, and executable bundles. `iv-provision` owns the fleet guest skill
manifest and vendored contents; project-specific skills stay in project repos.

## Gateway plane: cloud models

Use Aperture as the common cloud-model endpoint. Aperture passthrough providers
let the official client retain its subscription OAuth credential while
inference travels through Aperture for model grants, per-node audit, usage
reporting, and guardrails. Aperture centralizes path and policy, not the
subscription credential.

```text
Claude Code -- Claude Pro/Max OAuth -----> Aperture -----> Anthropic
Codex ------ ChatGPT subscription OAuth -> Aperture -----> ChatGPT Codex backend
Shelley ---- managed/API credential ----> Aperture -----> configured API provider
Local models ---------------------------> Aperture -----> LM Studio on either Mac
```

### Claude Code

Every VM uses the same base URL:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://ai.dojo-sun.ts.net"
  }
}
```

Each VM completes `claude /login` with its user's Claude Pro or Max account. Do
not set `ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN` on this path. Claude Code
performs login and refresh directly with Anthropic; inference traverses
Aperture.

### Codex

Every VM uses the same provider shape:

```toml
model_provider = "aperture"

[model_providers.aperture]
name = "Aperture"
base_url = "http://ai.dojo-sun.ts.net/codex"
wire_api = "responses"
requires_openai_auth = true
```

Each VM signs Codex into the user's ChatGPT Plus, Pro, Team, or Enterprise
account. Codex performs login and refresh directly with the provider; inference
traverses Aperture.

### Subscription credential lifecycle

Login state belongs to one VM's persistent home directory. It must not be baked
into an image, copied from a template, committed, or distributed by
`iv-provision`. New VMs have a one-time interactive Claude and Codex login step.

Subscription passthrough is limited to the provider's official client. Do not
route Claude or ChatGPT subscription credentials into Shelley or another
third-party harness. Shelley uses a centrally configured API-based provider.

### LM Studio providers

Expose each Mac's loopback-only LM Studio instance through a tailnet-only Serve
path and configure it as a self-hosted OpenAI-compatible Aperture provider:

```text
lmstudio-mini  -> klundstedt-mini /lmstudio
lmstudio-mbp   -> klundstedt-mbp  /lmstudio
```

Enable the API formats LM Studio actually serves, normally OpenAI Chat and
Responses, and list only approved chat models rather than every embedding model
returned by `/v1/models`. Use provider-qualified model names initially so a
request selects its physical host deterministically; do not assume automatic
health failover merely because two providers expose the same model ID.

This makes Aperture capture local-model prompts, responses, session identity,
tool-use content, duration, and compatible token usage like any other routed
inference request. The design is conditional on an end-to-end latency and
streaming canary: traffic crosses Frankfurt on the way to and from a Mac. Keep a
documented direct host-local endpoint as a performance or outage break-glass
path, with the explicit understanding that requests on that path are absent from
the central Aperture ledger.

## Selected APIs and administrative tools

Aperture HTTP connectors can centralize ordinary REST credentials such as
bearer tokens, API keys, HTTP Basic, OAuth client credentials, and per-user
OAuth. Good candidates include Notion, Telnyx, PingOne, and read-only API
access.

Do not expose broad administrative credentials through a raw connector merely
because Aperture can proxy them. Publish narrow, validated operations from a
custom control-plane MCP service instead, for example:

```text
ivcontrol_create_exe_vm
ivcontrol_promote_tailnet_node
ivcontrol_retire_vm
ivcontrol_inventory
```

That service can run on `iv-provision`, keep existing exe.dev edge credentials
where they already live, and expose only reviewed operations to Aperture. Grant
those tools only to `tag:iv-control`.

Aperture does not currently solve every credential path:

- GitHub MCP/API access does not replace Git clone and push authentication.
- Generic HTTP authentication does not replace S3 Signature Version 4 signing.
- Aperture identity does not replace provider-specific VM metadata and
  provenance.

Those paths need explicit portable adapters rather than one broad shared token.

## Remote execution

Aperture's built-in Tailscale SSH connector can list SSH-enabled nodes and run a
single audited shell command. It is a candidate common execution path for
`iv-provision`, exe.dev development VMs, Apple VMs, and
`klundstedt-mini`.

Grant command execution narrowly. The connector acts as the Aperture node and
is bounded by the tailnet SSH policy. Long-running lifecycle work should start a
supervised detached job rather than depend on one interactive command session.

`klundstedt-mbp` uses the standard Tailscale app and does not accept Tailscale
SSH. It remains a local executor unless a narrow authenticated worker service is
added deliberately.

## AI-session ledger and Git provenance

Aperture is the authoritative centralized AI-session ledger. For every routed
LLM request it can retain and export identity, node ID and tags, full request
and response bodies, redacted headers, model, token classes, duration, tool-use
details, and the native Claude or Codex session identifier. Configure nonzero
capture retention and S3-compatible export with `require_export` before retiring
an existing archive.

Entire remains the authoritative Git-linked provenance layer. It records agent
decision context and checkpoints with the repository and code they produced,
which Aperture's request log does not do. Retain:

- the Entire CLI and Git checkpoint backend
- `entire-agent-shelley`
- native Claude and Codex Entire integrations where supported
- `entire-push-check`
- checkpoint refs pushed with their repositories

Where possible, record the same native agent session identifier in Entire
metadata that Aperture exports as `session_id`. Verify identifier equivalence for
Claude, Codex, and Shelley before making that cross-link part of the contract.

AgentsView is retired from the target platform rather than migrated. After a
side-by-side capture canary and archive preservation, remove:

- the `iv-agentsview` central collector
- per-VM AgentsView binaries and source daemons
- `av-src-*` exe.dev integrations and fleet sync tokens
- the AgentsView MCP endpoint
- `entire-agent-agentsview`
- AgentsView provisioning, monitoring, backup, and retirement steps

This deliberately gives up AgentsView-specific semantic recall, secret scans,
Git outcome analytics, and normalized local harness archives. Aperture's full
capture/export plus Entire's Git provenance are the chosen replacement. Direct
LM Studio or other break-glass inference that bypasses Aperture is an explicit
logging gap, while Entire can still retain code-linked authoring context.

Ordinary persistent VM-to-VM service traffic continues to belong directly on
the tailnet rather than through Aperture.

## High availability and failure boundaries

Lifecycle logic should not require one interactive workstation. Provider
executors should support local operation and at least one remotely reachable
worker where the substrate permits it. The Apple host topology and its deliberate
Tailscale differences are documented by the
[Apple runtime adapter](apple-container-dev-vms.md#host-roles).

There are separate availability levels:

1. Provider-local VM creation and initial Aperture enrollment should survive loss
   of the central control VM where practical. An Apple VM may remain temporarily
   user-owned in this degraded state; it is not parity-complete and must not be
   treated as `tag:dev` until promotion succeeds.
2. Promotion to `tag:dev` initially depends on the privileged authority on
   `iv-provision` and resumes when that authority returns.
3. Remote MCP and cloud-model governance depend on Aperture in Frankfurt.
4. Local repositories, skills, agents, VM-local MCP, and host-local models must
   continue working during an Aperture outage.

Preserve documented break-glass direct paths for genuinely critical remote
services. If a secondary promotion credential is added to a Mac, use an
independent credential for audit and revocation; `devices:core` has broad blast
radius.

## Implementation plan

### 1. Define the platform contract

Create machine-readable parity checks for identity, filesystem layout, OS,
services, pinned tools, agents, skills, model/MCP configuration, tailnet state,
and persistence. Keep an explicit allowlist for intended provider differences.

### 2. Implement portable lifecycle orchestration

Create one `create-dev-vm` workflow with exe.dev and Apple executors. Record
operations, resulting inventory, image/provisioner provenance, and verification
results in one format.

### 3. Implement enrollment and promotion

Configure the Aperture Tailnet connector, add the dedicated promotion
credential on `iv-provision`, validate exact device identity, apply `tag:dev`,
and test retirement as well as creation.

### 4. Centralize remote MCP and models

Register one Aperture MCP endpoint in Claude, Codex, and Shelley. Configure
common and control-plane connector grants. Configure Claude and Codex
subscription passthrough, API-based Shelley providers, both LM Studio hosts,
full-capture retention, S3 export with `require_export`, and the one-time login
runbook.

### 5. Consolidate credentials and agent configuration

Move fleet guest instructions, skills, settings, and remote MCP registration
under `iv-provision`. Reduce dotfiles to the physical-host role. Add narrow
control-plane MCP tools rather than raw administrative API proxies.

### 6. Retire AgentsView and preserve Entire provenance

Run representative Claude, Codex, Shelley, MCP, and LM Studio sessions through
Aperture and compare its retained/S3-exported captures with the existing
AgentsView archive. Preserve the historical archive, remove the collector,
source daemons, integrations, MCP endpoint, and AgentsView adapter, and keep the
Entire checkpoint path and scheduled push verification. Update VM creation,
provisioning, monitoring, backup, and retirement runbooks in the same migration.

### 7. Add inventory, audit, and availability behavior

Define authoritative inventory, operation logs, retry/idempotency rules,
break-glass paths, and promotion failover. State which component owns deletion
and credential revocation.

### 8. Continuously test provider parity

Run the same suite against exe.dev and Apple canaries, including real model and
MCP calls, Tailscale SSH, service health, and stop/start persistence.

## Open decisions

- Exact command and state format for `create-dev-vm`
- Whether Mac promotion failover justifies another `devices:core` credential
- How personal OAuth connectors authorize tag-owned development VMs
- Which services require direct break-glass paths
- Whether Frankfurt latency is acceptable for both LM Studio hosts
- Whether Entire and Aperture expose identical Claude, Codex, and Shelley
  session identifiers for durable cross-linking
- Portable Git clone/push credential design
- Portable S3 signing and short-lived credential design
- Authentication and URL shape for Apple-hosted Shelley
- Authoritative inventory format and backup location
