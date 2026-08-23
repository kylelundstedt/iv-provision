# Tigris Cloud Disk as IV Dataset storage — evaluation

**Question:** can we build and store IV Datasets on a Cloud Disk attached to an
exe.dev VM, and should we?

## Verdict: **yes, but only for read-heavy dataset serving and versioning — not as a build volume, and not without tuning**

Three numbers drove it:

| | |
|---|---|
| **0.54s vs 8.9s** | random reads over a 2.4GB `.duckdb` — tuned vs default Cloud Disk. Untuned it is **16× slower**; tuned it is **within 1.2× of local disk** (0.45s). The default config is the difference between unusable and fine. |
| **693 MB** | fsync-acked data lost on host loss with the default `write-back=true`. Not a rollback of a few seconds — 693 of 782 acked 1MB records vanished. `write-back=false` lost **0 MB**, at 6.2 fsync ops/s vs 350 (**56× slower**). |
| **1.75s / 851 KB** | to fork a live 1.1GB dataset, and what the fork costs in the bucket. Copy-on-write dataset versioning is real, works, and is the one thing here IV cannot do today. |

Measured on `iv-cloud-disk` (4 CPU, 16GB, 60GB root, exeslim-dev, `iv-provision`
3.0.19) against real Tigris in `iv-nonprod`, cloud-disk **1.8.0** (beta),
DuckDB 1.5.3. Second VM `iv-cloud-disk-b` for portability and fencing.

**The headline caveat is not performance, it is [F1](#f1--two-disks-silently-become-one-volume-data-loss): two disks created in the
same bucket without an explicit `-prefix` are silently the same volume**, both
mountable read-write at once, and deleting either destroys both. Any IV
adoption must set `-prefix` on every disk. That is a footgun, not a preference.

---

## Results

All numbers are medians of repeats, produced by `suite/`, raw rows in
`results/*.jsonl`. Regenerate with `python3 suite/report.py results/*.jsonl`.

### Performance vs local disk and vs httpfs-on-Parquet

| workload | local | cloud-disk (default) | cloud-disk (tuned) | `-preset database` | cloud-disk write-through | httpfs on Parquet | tuned vs local |
|---|---|---|---|---|---|---|---|
| Streaming write, 2GB dd (MB/s) | 814.5 | 92.3 | 176.7 | 285.2 | 198.8 | – | **0.22×** |
| Parquet build, 40M rows (s) | 29.16 | 30.06 | 30.15 | – | 16.45¹ | – | 0.97× |
| 4K fsync (ops/s) | 799.4 | 350.1 | 344.5 | 257.6 | **6.2** | – | 0.43× |
| DuckDB checkpoint cycle (s) | 0.48 | 0.53 | 0.50 | – | 5.60 | – | 0.95× |
| Full scan, 2.4GB `.duckdb` (s) | 0.366 | 15.97 | **0.355** | 0.567 | – | 20.26 | 1.03× |
| **Random read, 2.4GB `.duckdb` (s)** | 0.455 | **8.884** | **0.536** | 0.607 | – | 18.21 | 0.85× |
| Random read, 123MB `.duckdb` (s) | 0.059 | 0.077 | 0.069 | – | 0.081 | – | 0.86× |
| Cold-mount first query (s) | – | 12.42 | **1.14**² | – | – | – | – |

¹ smaller row count on this arm (10M), not comparable to the others.
² with `warm-start-bytes=8G`; 16.9s at the 1G default. See [cold mount](#cold-mount).

Tuning applied is the documented ["tuned for a
database"](https://www.tigrisdata.com/docs/cloud-disk/tuning/#example-tuned-for-a-database)
recipe scaled to the box: `disk-cache-size=20G max-cache-size=8G
flush-workers=16 max-staging-bytes=8G`.

**The single most important number in this report** is the 2.4GB random-read
row. `disk-cache-size` defaults to **0** — the local-disk read cache is *off*,
so every RAM-cache miss goes to Tigris over the network. Setting it turns a
16× regression into a 1.2× one. The gap between the small (123MB, fits cache)
and big (2.4GB, does not) cases on the *default* config is 0.077s → 8.884s,
**115×**. On the tuned config it is 0.069s → 0.536s, **7.8×**.

**httpfs loses for these workloads.** Querying the same Parquet straight from
the bucket took 20.3s (scan) and 18.2s (point lookups) vs 0.36s / 0.54s on a
tuned Cloud Disk — **40×** worse. If the working set fits the local cache,
Cloud Disk is decisively better than reading Parquet over HTTP. For a
*one-shot* scan of data you will never touch again, httpfs avoids the cache-fill
cost and the disk entirely, and is the simpler answer.

### Durability

| scenario | acked data lost | `.duckdb` intact + queryable | recovery mount |
|---|---|---|---|
| daemon `SIGKILL`, local WAL survives, `write-back=true` | **0 MB** | yes | 27.6s |
| daemon `SIGKILL`, local WAL survives, `write-back=false` | **0 MB** | yes | 34.0s |
| **host loss** (WAL+cache destroyed), `write-back=true` | **693 MB** | yes | 22.6s |
| **host loss** (WAL+cache destroyed), `write-back=false` | **0 MB** | yes | 18.6s |

The distinction the docs blur: killing the *daemon* loses nothing, because the
WAL under `/var/lib/cloud-disk` replays on the next mount. Losing the *host*
loses everything not yet drained to Tigris. At the moment of kill the disk was
carrying **1006 MB dirty across 15 staging segments, committed epoch 11 vs
latest epoch 1475** — a ~1400-epoch backlog. That is the real exposure, and it
is much larger than "a few seconds of writes".

In **every** case the `.duckdb` file passed block-checksum verification and
answered queries. I did not manage to corrupt a DuckDB file on Cloud Disk in
any crash scenario. Round-trip integrity also held: after wiping
`/var/lib/cloud-disk` **entirely** and remounting, a 634MB Parquet tree and its
`.duckdb` were byte-identical (`a1_parquet_tree_match=True`,
`a1_duckdb_file_match=True`). The bucket really is the source of truth.

> DuckDB 1.5.3 has no `PRAGMA integrity_check` (it errors: *Pragma Function with
> name integrity_check does not exist*). The suite instead sets
> `debug_verify_blocks=true` and scans every table, which validates per-block
> checksums — verified to actually catch corruption by flipping bytes in a test
> database, which then failed with `IO Error: Corrupt database file: computed
> checksum ... does not match stored checksum`.

### Lifecycle

| capability | result |
|---|---|
| Snapshot a live, actively-written disk | **10.5–90.9s** (`-force`; drains first) |
| Fork that snapshot into a new disk | **1.75–2.15s** |
| Mount the fork | 4.0–7.9s |
| Fork independent of parent | **yes** — parent unchanged, marker file did not leak |
| Fork's `.duckdb` queryable | **yes** — 10,000,000 rows both sides, checksums verify |
| Fork storage cost | **851 KB** billed vs parent's 3.7GB — genuinely copy-on-write |
| Portability A→B | **yes** — byte-identical sha256, 3.2s mount, 2.7s verify |
| Reboot with disk mounted | **yes** — `cloud-disk@d4-reboot` came back, sha matched |

This is the section that would justify adoption. Forking a multi-TB dataset in
seconds, for ~nothing, is a capability IV does not have. Staging clones and
dataset versioning both fall out of it.

Snapshot time is **not** constant: it drains dirty state first, so it ranges
from 10.5s on a quiet disk to 90.9s on one mid-build with ~1GB dirty. The
*fork* is consistently ~2s regardless — it is the snapshot that costs, and it
costs in proportion to un-drained writes. Quiesce before snapshotting if the
latency matters.

**Prerequisites nobody documents**, both found by hitting them:
- The bucket must be a **snapshot bucket** first: `tigris buckets
  enable-snapshots <bucket>`. Without it, `cloud-disk snapshot create` fails
  with `InvalidRequest` and `snapshot list` fails with `Wrong bucket type`.
- Forking happens at **bucket** granularity (it calls S3 `CreateBucket` with a
  fork source), so a fork **must target a different bucket** —
  same-bucket forks fail `BucketAlreadyExists`. The fork also inherits the
  *parent's* key prefix inside the new bucket, so mounting it needs
  `-prefix <parent-name>`, not the fork's own name.
- `-snapshot` wants the **version** (epoch-nanosecond id), not the friendly
  name; passing the name gives *"Snapshot version invalid or in future"*.
- `snapshot list` returns **newest first**. Taking the last element silently
  forks an *older* snapshot — it succeeds, so this fails quietly.

### Concurrency and operational safety

| test | result |
|---|---|
| Cross-host RW steal (VM B mounts VM A's live disk) | **correctly refused** — `lease held by another host: held by iv-cloud-disk:7982 (expires in 26s)`. Holder wrote 1472MB uninterrupted, lease stayed epoch 2. |
| Same-host steal (second process, same hostname) | **lease IS stolen from a live mount**, epoch 1→2. Evicted writer got `errno=5 Input/output error`. Bucket stayed consistent; post-steal remount verified 500,000 rows. |
| `ReadOnlyMany` (two VMs, read-only) | **not supported.** A read-only mount still takes the **exclusive** lease; VM B was refused with the same lease error across repeated attempts spanning >30s. |
| Reboot with disk mounted | survives, unit auto-remounts, data verified |

The fencing story is **safe but not shareable**. A lease steal never silently
succeeded: the evicted writer always got EIO rather than both sides writing.
But the same-host case does treat a live mount as crash recovery — reproduced
here, epoch 1→2, matching the behaviour reported on `iv-provision`.

---

## Failure modes found

Each is reproduced by `suite/tests/test_f_findings.py`. cloud-disk is in beta;
these are reported as findings, not worked around.

### F1 — two disks silently become one volume (data loss)

`cloud-disk create <name> -bucket B` with **no `-prefix`** writes at the bucket
root. The name is only a local label in `/etc/cloud-disk/disks`. So:

```
cloud-disk create f1-alpha -bucket cloud-disk-test -size 5G   # rc=0
cloud-disk create f1-beta  -bucket cloud-disk-test -size 5G   # rc=0, "Mounting existing disk"
```

Measured consequences:
- `f1_second_create_refused=False` — no warning, no error.
- `f1_same_underlying_volume=True` — both report volume `cloud-disk-test`.
- `f1_both_mounted_rw_simultaneously=True` — two ext4 filesystems, **both
  read-write**, over one backing store, on one host. The lease does not help:
  both daemons show the *same* holder and epoch.
- Views diverge: `f1_beta_sees_alpha_file=True` but `f1_alpha_sees_beta_file=False`.
- `cloud-disk delete f1-beta` → **0 objects left**, and `f1-alpha` no longer
  mounts: *disk "cloud-disk-test" does not exist*.

I hit this accidentally before finding it deliberately: three test disks
(`a1-roundtrip`, `a2-wb`, `a3-wt`) were one volume, and one `delete` wiped all
three. **Mitigation: always pass `-prefix <name>`.** The suite now does.

### F2 — `--set` at create time silently ignored

Corollary of F1. When two names share a volume, the second create adopts the
first's persisted config, so `--set write-back=false` reverts to `true`:

- `f2_writeback_after_set_no_prefix=true` (requested `false`)
- `f2_writeback_after_set_with_prefix=false` (correct)

This one is nastier than F1 because it fails *silently in the safe-looking
direction*: you ask for durable write-through and get write-back.

### F3 — killing the daemon hangs I/O for 10 minutes, unkillably

`f3_unblock_s=**602.2**`. With the daemon gone, in-flight I/O blocks in
uninterruptible sleep until `nbd-request-timeout` (default 10m) fires:

- `f3_writer_state_after_kill=D`
- `f3_survives_sigkill=True` — `SIGKILL` will not land on a `D`-state task.

On a build box that is a ten-minute hang with no diagnostics. The suite sets
`nbd-request-timeout=45s` to stay usable; IV should tune it explicitly.

### F4 — orphaned daemon after a failed mount holds the lease

When a read-only mount failed at the ext4 step, the daemon **stayed alive**,
spinning at ~170% CPU and holding the lease. `cloud-disk umount` then reported
`d-shared is not mounted` while refusing new mounts with *"already being
mounted or served by another process on this host"*. Recovery needed a manual
`kill -9` plus `rm /run/cloud-disk/<name>.lock`. Stale `.lock` files also
accumulate for every failed invocation (including typos like `-h.lock`).

### F5 — read-only mounts need an undocumented recipe

`--set readonly=true` alone **fails to mount**: ext4 tries to replay its
journal, the write is refused by the read-only export, and the mount dies with
`can't read superblock`. Working recipe found:

```bash
cloud-disk mount <d> -bucket B -prefix P --set readonly=true --set no-fs=true
mount -o ro,noload /dev/nbdN /mnt/ro          # noload skips journal replay
duckdb -c "ATTACH '/mnt/ro/ds.duckdb' AS d (READ_ONLY); SELECT ..."
```

(`-readonly` is not a mount flag at all.) DuckDB also cannot open a `.duckdb`
positionally on a read-only filesystem — *"Cannot open file ...: Read-only file
system"* — it must be `ATTACH`ed `READ_ONLY`.

### F6 — credentials stored in plaintext

Confirmed on this VM: `/etc/cloud-disk/disks` is `600 root:root` but contains
the Tigris `tid_`/`tsec_` pair **in cleartext**, for every disk
(`a6_access_key_plaintext=True`, `a6_secret_key_plaintext=True`).

This matters more than the file mode suggests: exe.dev VMs have
**passwordless sudo** (`a6_passwordless_sudo=True`, `/etc/sudoers.d/exedev`),
so *any* process that can run `sudo` — including every agent session — can read
the key. On a shared or long-lived VM, mounting one Cloud Disk effectively
grants every future occupant of that box the credential's full scope. Scope
keys to a single bucket (as done here) and treat any VM that has mounted a
Cloud Disk as holding that secret for its lifetime.

### F7 — `nbds_max=16` is a hard ceiling

`f4_nbd_devices=16`, `nbds_max=16`. **16 concurrent disks per VM**, kernel
module parameter. One-disk-per-dataset does not scale past 16 without a reboot
with a different `nbds_max`. Relevant if IV ever wants a disk per dataset.

### Not a finding

- `WARN falling back to IMDSv1 ... EC2 IMDS failed` — harmless, as expected.
- The exe.dev root disk is **not** dm-crypt (`f5_dmcrypt_present=False`,
  `/dev/mapper/` holds only `control`), so `-enable-io-uring-writes` is not
  disqualified on that ground. I did not benchmark it — experimental flag,
  beta product, and the fsync path was not the bottleneck once tuned.

---

## Cost model at IV dataset scale

Measured on a real dataset: **1.12GB of filesystem data occupied 1.96GB across
1,863 objects** — **1.75× amplification**, ~1,658 objects per logical GB at the
1MB default chunk size. (`c2_overhead_ratio=1.7462`.) The amplification is
version churn: the parent bucket showed 5,127 versions for ~3.7GB.

At Tigris standard pricing ($0.02/GB/mo, Class A $0.005/1k, Class B $0.0005/1k):

| logical dataset | stored | storage/mo | full rebuild (PUTs) | cold full scan (GETs) |
|---|---|---|---|---|
| 100 GB | 175 GB | **$3.49** | $0.83 | $0.08 |
| 1 TB | 1.75 TB | **$34.92** | $8.29 | $0.83 |
| 10 TB | 17.5 TB | **$349.23** | $82.91 | $8.29 |

**Per-request cost is not the thing to worry about** at 1MB chunks — a full
rebuild of a 10TB dataset is ~$83 in PUTs against ~$349/mo of storage. The
1.75× storage amplification is the real cost line, and it is what makes the
headline $0.02/GB effectively **$0.035/GB**. Budget accordingly. Forks are
nearly free (851 KB for a 1.1GB dataset view), so dataset versioning does not
multiply this.

Caveat: amplification was measured on a ~1GB dataset over a few hours of
churn. A long-lived disk with more rewrite history could sit higher; a
write-once dataset lower. Worth re-measuring at IV scale before committing.

---

## Don't use it for

- **Build volumes for fsync-heavy work.** sqlmesh state, DuckDB checkpoint
  churn, anything transactional. 350 fsync/s vs 800 local at best; **6.2/s**
  with the durable setting — 129× slower than local. Build on local disk, then
  publish to Cloud Disk.
- **Anything relying on `write-back=true` surviving host loss.** 693 MB of
  fsync-acked data disappeared. If the data matters and the host is
  ephemeral, use `write-back=false` and accept 6 fsync/s, or don't use Cloud
  Disk for that step.
- **Fan-out read serving.** `ReadOnlyMany` does not work in 1.8.0 — read-only
  mounts take the exclusive lease. One reader at a time. If you need N readers,
  use N forks (cheap) or serve Parquet from the bucket.
- **More than 16 disks per VM.** Hard `nbds_max` ceiling.
- **Streaming-write-bound bulk loads.** 176 MB/s tuned vs 814 MB/s local, 0.22×.
  Fine for a 30s Parquet build (CPU-bound anyway, 0.97×), bad for a
  write-throughput-bound job.
- **Shared or long-lived multi-tenant VMs**, until credential storage improves
  (F6). Passwordless sudo makes the key readable by anything on the box.
- **Any bucket where you don't set `-prefix`** (F1). Non-negotiable.
- **One-shot scans of cold data.** Filling the cache to read once is wasted
  work; httpfs on Parquet is simpler, even though it is 40× slower per query.

## Where it is genuinely good

- **Dataset versioning and staging clones** — 1.75s CoW forks, ~free, verified
  independent and queryable. Nothing in IV does this today.
- **Build-on-one-box, serve-from-another** — verified byte-identical across
  VMs in ~3s, no copy step.
- **Read-heavy serving of a working set that fits the local cache** — within
  1.2× of local disk, 40× faster than httpfs-on-Parquet.
- **Datasets larger than the VM's disk** — a 40GB disk on a 60GB box, paying
  only for what is written.

## Recommended configuration, if IV adopts this

**Use `-preset database`.** It was measured, not assumed:

```bash
cloud-disk create <ds> -bucket <b> -prefix <ds> -size <n>G \
  -preset database \
  --set warm-start-bytes=8G \
  --set nbd-request-timeout=45s
```

`-prefix` is mandatory (F1). `warm-start-bytes=8G` cut cold-mount first query
from 16.9s to **1.14s**; the 1G default is too small for a multi-GB dataset.
`nbd-request-timeout` avoids the 10-minute hang (F3).

**Preset comparison, on the workload that discriminates** (random reads over a
2.4GB `.duckdb`, larger than any cache here):

| config | `disk-cache-size` | big random read | 2GB dd write | 4K fsync |
|---|---|---|---|---|
| default | **0** (off) | 8.884s | 92 MB/s | 350/s |
| `-preset database` | 4G | **0.607s** | 285 MB/s | 258/s |
| hand-tuned (doc recipe, 20G/8G) | 20G | **0.536s** | 177 MB/s | 345/s |
| `-preset durable` | 0 | not run | 360 MB/s | **6.8/s** |
| `-preset sequential-reads` | 0 | not run | 360 MB/s | 270/s |
| local disk (control) | – | 0.455s | 815 MB/s | 799/s |

`database` gets within 13% of hand-tuning for one flag, and beats it on
streaming writes. Only `database` sets `disk-cache-size` at all — `durable`
and `sequential-reads` both leave the local read cache **off**, which is what
causes the 16× regression. `sequential-reads` also made *small* random reads
worse (0.362s vs 0.069s) by over-fetching, exactly as its help text warns.
`durable` is `write-back=false` in a hat: 6.8 fsync/s.

Scale `disk-cache-size` up from the preset's 4G if the working set is larger;
that is the knob that matters.

<a name="cold-mount"></a>
### Cold mount

| `warm-start-bytes` | mount | first query | second query |
|---|---|---|---|
| 1G (default), untuned | 3.1s | 12.4s | 0.148s |
| 0, untuned | 3.8s | 8.1s | 0.164s |
| 8G, untuned | 4.0s | 10.4s | 0.158s |
| 1G (default), tuned | 5.2s | 16.9s | 0.152s |
| **8G, tuned** | 8.7s | **1.14s** | 0.152s |

Warm-start only helps when there is somewhere to put the data —
`disk-cache-size` must be set too. With both, cold-mount cost essentially
disappears. Steady state on a warm L2 cache: 0.384s scan.

---

## The suite

`suite/` is re-runnable and emits one JSON row per measurement, so two
cloud-disk versions can be diffed.

```
suite/
  cdbench/harness.py     result emission, disk lifecycle, S3 accounting
  cdbench/workload.py    DuckDB/Parquet/fsync workloads, integrity check
  tests/test_a_durability.py    A: round-trip, crash, host loss, credentials
  tests/test_b_performance.py   B: all arms incl. local control + httpfs
  tests/test_c_lifecycle.py     C: snapshot, fork, portability, cost
  tests/test_d_concurrency.py   D: leases, ReadOnlyMany, reboot
  tests/test_f_findings.py      F: reproductions of every failure mode
  report.py              aggregate jsonl -> tables / DuckDB
  sync.sh                ship suite to a VM and run a module
  run_multihost.sh       drive the two-VM tests from a controller
```

```bash
./sync.sh iv-cloud-disk tests.test_a_durability        # one module
./run_multihost.sh iv-cloud-disk iv-cloud-disk-b       # two-VM tests
python3 report.py results/*.jsonl                      # tables
python3 report.py --db out.duckdb results/*.jsonl      # queryable
```

Environment: `CDBENCH_BUCKET`, `CDBENCH_ENDPOINT`, `CDBENCH_RUN_ID`,
`CDBENCH_STAGE` (`local|cd|tuned|wt|httpfs|presets`), `CDBENCH_ONLY`,
`CDBENCH_KEEP=1` to skip teardown.

### Untested / out of scope

- `-enable-io-uring-*`, group commit, `-tier-sizes`, `-scatter-gather` — not
  benchmarked (experimental flags on a beta product).
- dlt ingestion — the Parquet/DuckDB build path covers the same write shape;
  dlt was installed but a dedicated dlt arm was not run.
- Multi-TB behaviour. Everything here is ≤2.4GB working sets on a 60GB box.
  The cache-fits/doesn't-fit cliff is characterised, but absolute numbers at
  TB scale are extrapolation, not measurement.
- Cross-region latency. Single VM, single Tigris global bucket, ~60ms TTFB.
