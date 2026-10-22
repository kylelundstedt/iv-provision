---
name: archil
description: "Persistent elastic filesystems, serverless command execution, and disk management for AI agents."
compatibility: "Node.js 18+. API key from https://console.archil.com."
license: MIT
allowed-tools: Bash
---

# Archil

Elastic, S3-backed POSIX filesystems with serverless command execution — persistent storage that agents can read, write, and run code against.

This file is a lightweight overview. For depth on any topic, follow the links into supporting files and docs; don't duplicate that material here.

- **[`disk` CLI](#disk-cli)** — create, inspect, manage disks; run `exec`
- **[Serverless Execution](#serverless-execution)** — run bash/python/node with the disk mounted
- **[TypeScript SDK](#typescript-sdk)** — programmatic access from Node.js
- **[Mount Semantics](#mount-semantics)** — shared mode, delegations, consistency, cache
- **[Mounting](#mounting)** — Linux, macOS, and the exec container runtime
- **[Data Sources](#data-sources)** — S3, GCS, R2, S3-compatible, Azure Blob

## Quick Setup

Before running any commands, verify prerequisites:

```
Here's what I'll do to get you set up:

- [ ] Run the `disk` CLI via npx (no install needed)
- [ ] Configure Archil credentials
- [ ] Verify disk access
- [ ] Run a test command

Shall I proceed?
```

Wait for the user to confirm before continuing.

**Step 1 — Run the CLI with npx (no install required):**

```bash
npx disk --help
```

**Step 2 — Set credentials:**

Sign up at [console.archil.com](https://console.archil.com) if you don't have an account. Get your API key from the console.

```bash
export ARCHIL_API_KEY="key-your_api_key"
export ARCHIL_REGION="aws-us-east-1"
```

**Step 3 — Verify setup:**

```bash
npx disk list
```

If this returns your disks, you're ready. If it fails, check your API key and region.

**Step 4 — Test execution (AWS regions only):**

```bash
npx disk exec <disk-id> "echo hello from archil && ls -la"
```

Do not proceed until `disk list` returns successfully.

## Choosing the Right Tool

| Task | Tool |
|------|------|
| Run commands against files on a disk | `disk exec` |
| Create/delete/inspect disks | `disk` CLI |
| Programmatic disk ops from Node.js | TypeScript SDK |
| Mount on a Linux server | `archil` CLI |
| Browse files on macOS | Archil.app (no CLI) |
| Kubernetes-native mount | [CSI driver](https://docs.archil.com/reference/csi-driver) |
| Declarative disk management | [Terraform provider](https://docs.archil.com/reference/terraform) |

## Credential Types

| Credential | Env Var | Used By | Scope |
|-----------|---------|---------|-------|
| API Key | `ARCHIL_API_KEY` | `disk` CLI, SDK | Account-wide |
| Mount Token (CLI) | `ARCHIL_MOUNT_TOKEN` | `archil` CLI, Archil.app | Single disk |
| Mount Token (SDK) | `ARCHIL_DISK_TOKEN` | TypeScript SDK | Single disk |

API keys and mount tokens are **different credentials**. API keys manage disks and run exec. Mount tokens grant filesystem-level access to one specific disk.

---

## `disk` CLI

The `disk` npm package is the primary agent-facing tool. Pure JavaScript, runs anywhere Node.js runs. Invoke with `npx disk` (no install) or `bunx disk`.

```bash
npx disk list                           # list disks in current region
npx disk get <disk-id>                  # disk details
npx disk create <name>                  # create disk, returns one-time mount token
npx disk delete <disk-id>               # delete disk (S3 data persists)
npx disk exec <disk-id> "<command>"     # run a command with the disk mounted
npx disk api-keys list|create|delete    # manage API keys
```

Full reference: [disk-cli-reference.md](https://archil.com/skill/disk-cli-reference.md).

---

## Serverless Execution

`disk exec` launches a container with the disk mounted at `/mnt/data`, runs a command, and returns stdout/stderr/exit code and timing. Files persist on the disk across exec calls; container state does not.

**AWS-only today**: `aws-us-east-1`, `aws-us-west-2`, `aws-eu-west-1`. GCP does not support exec.

### Limits

| Limit | Value |
|-------|-------|
| Command timeout | 5 minutes |
| stdout / stderr cap | 128 KiB each |
| Billing | `executeMs` only, 1ms granularity, 100ms minimum |
| Queue time | Not billed |

### Exec Runs in Shared Mode

The exec container is just another mounted client and mounts in **shared mode**, so [mount semantics](#mount-semantics) apply — in particular, [delegations](https://archil.com/skill/delegations.md). Dynamic ownership auto-claims new subdirectories, so most short-lived execs never notice. When writes do fail with `Read-only file system`, you have two clean fixes: scope writes to a fresh per-job subdirectory, or run `archil checkout <path>` inside the exec command itself (the `archil` CLI is available in the container).

### Pre-installed Tools

The exec container includes `coreutils`, `grep`, `sed`, `awk`, `find`, `curl`, `jq`, `python3`, `node`, and the `archil` CLI.

### Common Patterns

```bash
# Clone + install + build
npx disk exec <id> "git clone https://github.com/user/repo.git && cd repo && npm i && npm run build"

# Persistent agent workspace
npx disk exec <id> "mkdir -p /mnt/data/workspace && echo 'session note' >> /mnt/data/workspace/log.txt"

# Fan-out in bash
for f in file1 file2 file3; do
  npx disk exec <id> "grep -c ERROR /mnt/data/logs/$f" &
done; wait
```

Full docs: https://docs.archil.com/compute/serverless-execution.

---

## TypeScript SDK

For programmatic access from Node.js, use the `disk` npm package as a library — same artifact as the CLI.

```typescript
import * as archil from "disk";
archil.configure({ apiKey: process.env.ARCHIL_API_KEY, region: "aws-us-east-1" });

const d = await archil.getDisk("dsk-abc123");
const { stdout, exitCode } = await d.exec("grep -r ERROR logs/");
```

Full reference: [typescript-sdk.md](https://archil.com/skill/typescript-sdk.md).

---

## Mount Semantics

Every Archil mount — on a Linux host, in macOS Finder, or inside a `disk exec` container — shares the same model. Understand this once and it applies everywhere.

- **Single-client (exclusive) mode**: default on Linux. One client owns the whole disk; all writes work immediately.
- **Shared mode**: default on Archil.app (macOS), exec containers, and Linux with `--shared`. Multiple clients mount concurrently. Reads always work; writes require holding a **delegation** (exclusive ownership of a path).
- **Delegations** are recursive — owning a directory covers every file beneath it. Only one client can hold a delegation on a given path at a time.
- **Dynamic ownership**: creating a new file/directory in an unowned location auto-claims it. Covers most short-lived exec writes automatically. Does **not** extend to deleting or rewriting existing files.
- **Release**: `archil checkin <path>` on Linux / in exec, right-click → Check In on macOS, or unmount (auto-releases everything).
- **Consistency**: strong read-after-write between Archil clients after `fsync`; eventual (seconds to minutes) between Archil and S3 in either direction.
- **Cache**: default `min(25% of RAM, 2 GiB)` per client, 30s directory-listing TTL. Tune with `archil set-cache-expiry`.

Full model and patterns: [delegations.md](https://archil.com/skill/delegations.md) and https://docs.archil.com/concepts/shared-disks.

---

## Mounting

### Linux — `archil` CLI

FUSE-based mount. Install and use:

```bash
curl -s https://archil.com/install | sh

export ARCHIL_MOUNT_TOKEN="<disk-token>"
sudo --preserve-env=ARCHIL_MOUNT_TOKEN archil mount <disk-name> /mnt/data --region aws-us-east-1
```

Add `--shared` for multi-client mode. Use `archil unmount` (never `umount`). All flags, fstab integration, subdirectory mounts, and cache tuning are covered in the reference.

Full reference: [cli-reference.md](https://archil.com/skill/cli-reference.md) and https://docs.archil.com/mounting/linux.

### macOS — Archil.app (menu bar)

macOS uses an FSKit-based menu bar app, **not a CLI**. Requires macOS 26 (Tahoe)+. Install with the same `curl | sh`, then launch `Archil.app` from the menu bar and mount via the UI — disks appear as native Finder volumes under `/Volumes/`.

**Delegations are Finder-only on macOS**: right-click → Check Out and right-click → Check In. There is no `archil` CLI on macOS. `npx disk` still works for control-plane operations.

Docs: https://docs.archil.com/mounting/macos.

### Inside `disk exec` Containers

Each exec container mounts the disk automatically at `/mnt/data` in shared mode — no install step needed. The `archil` CLI is available inside the container if you need to explicitly `checkout`/`checkin` a path. See [Exec Runs in Shared Mode](#exec-runs-in-shared-mode).

---

## Data Sources

Archil syncs with object storage backends. Data stays in your bucket — Archil caches and syncs.

| Type | Provider |
|------|----------|
| `s3` | Amazon S3 (bucket policy recommended, or IAM credentials) |
| `gcs` | Google Cloud Storage (HMAC credentials) |
| `r2` | Cloudflare R2 (API token + endpoint) |
| `s3-compatible` | MinIO, DigitalOcean Spaces, Wasabi, Backblaze B2 |
| `azure-blob` | Azure Blob Storage (Terraform provider today) |

Docs: https://docs.archil.com/data-sources/s3-object-storage.

---

## Pricing

| Component | Cost |
|-----------|------|
| Active cached data | $0.20/GiB-month (time-weighted average) |
| Serverless exec | Billed on `executeMs` (1ms granularity, 100ms floor) |
| API calls, transfers, reads, metadata | Free |

Cache expires ~1 hour after last access; you only pay for data actively in the cache. Full model: https://docs.archil.com/administration/billing.

---

## Troubleshooting

Quick index. Full guide: [troubleshooting.md](https://archil.com/skill/troubleshooting.md).

| Issue | Fix |
|-------|-----|
| `archil: command not found` (macOS) | No CLI on macOS. Use `npx disk` or Archil.app |
| Mount permission denied | Use `sudo --preserve-env=ARCHIL_MOUNT_TOKEN` |
| Auth failure | Verify `ARCHIL_API_KEY` with `npx disk list` |
| `Read-only file system` on write | You haven't checked out a delegation on the path you're writing to. Run `archil checkout <path>` (Linux or inside an exec container), or write into a fresh subdirectory so dynamic ownership claims it for you. Full model: [delegations.md](https://archil.com/skill/delegations.md) |
| S3 sync delay | Expected — eventual consistency (seconds to minutes) |
| Exec timeout | Commands must complete within 5 minutes |
| stdout truncated | Exec caps at 128 KiB — pipe to file on disk |
| Exec not available in region | Exec is AWS-only today |
| npm EACCES | Use `npx disk` (no install) rather than a global install |

## Workload-Specific Guidance

For recommended mount options, cache sizes, and patterns per workload (AI training, model serving, databases, CI, Jupyter, genomics, etc.), see [workload-guide.md](https://archil.com/skill/workload-guide.md).

## Supporting Files

- **[disk-cli-reference.md](https://archil.com/skill/disk-cli-reference.md)** — `disk` npm package CLI reference
- **[typescript-sdk.md](https://archil.com/skill/typescript-sdk.md)** — TypeScript SDK reference
- **[cli-reference.md](https://archil.com/skill/cli-reference.md)** — `archil` (Linux mount) CLI reference
- **[delegations.md](https://archil.com/skill/delegations.md)** — Complete guide to shared-mode write access
- **[troubleshooting.md](https://archil.com/skill/troubleshooting.md)** — Error messages, fixes, diagnostics
- **[workload-guide.md](https://archil.com/skill/workload-guide.md)** — Recommended configurations per workload

## Documentation Index

Full docs: https://docs.archil.com/llms.txt

| Topic | URL |
|-------|-----|
| Introduction | https://docs.archil.com/getting-started/introduction |
| Quickstart | https://docs.archil.com/getting-started/quickstart |
| Architecture | https://docs.archil.com/details/architecture |
| Performance | https://docs.archil.com/details/performance |
| Security | https://docs.archil.com/details/security |
| Consistency | https://docs.archil.com/details/consistency |
| POSIX Support | https://docs.archil.com/details/support |
| Serverless Exec | https://docs.archil.com/compute/serverless-execution |
| TypeScript SDK | https://docs.archil.com/sdks/typescript |
| `disk` CLI | https://docs.archil.com/reference/disk-cli |
| `archil` CLI (Linux) | https://docs.archil.com/reference/archil-cli |
| Agent Bash Tool | https://docs.archil.com/guides/ai/bash-tool |
| Multi-Agent Systems | https://docs.archil.com/guides/ai/multi-agent-systems |
| FAISS Vector Search | https://docs.archil.com/guides/ai/faiss |
| S3 Data Source | https://docs.archil.com/data-sources/s3-object-storage |
| Shared Disks | https://docs.archil.com/concepts/shared-disks |
| Pricing | https://docs.archil.com/administration/billing |
| Terraform | https://docs.archil.com/reference/terraform |
| K8s CSI Driver | https://docs.archil.com/reference/csi-driver |
| API Reference | https://docs.archil.com/api-reference/introduction |
| Troubleshooting | https://docs.archil.com/reference/troubleshooting |
| macOS Mount | https://docs.archil.com/mounting/macos |
| Linux Mount | https://docs.archil.com/mounting/linux |
| Container Mount | https://docs.archil.com/mounting/containers |
| PostgreSQL | https://docs.archil.com/guides/databases/postgres |
| SQLite | https://docs.archil.com/guides/databases/sqlite |
| Jupyter | https://docs.archil.com/guides/data-science/jupyter-serverless |
