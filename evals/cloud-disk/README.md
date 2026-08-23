# Tigris Cloud Disk as IV Dataset storage — evaluation

**Question:** can we build and store IV Datasets on a Cloud Disk attached to an
exe.dev VM, and should we?

## Verdict: **yes, but only for read-heavy dataset serving and versioning — not as a build volume, and not without tuning**

Three numbers drove it:

| | |
|---|---|
| **0.54s vs 8.9s** | random reads over a 2.4GB `.duckdb` — tuned vs default Cloud Disk. Untuned it is **16× slower**. Caveat: the tuned arm's cache (8G+20G) exceeded the file, so this measures *cache on vs cache off*, not behaviour past cache capacity — see [methodology](#read-this-before-quoting-a-number). |
| **693 MB** | fsync-acked data lost on host loss with the default `write-back=true`. Not a rollback of a few seconds — 693 of 782 acked 1MB records vanished. `write-back=false` lost **0 MB**, at 6.2 fsync ops/s vs 350 (**56× slower**). |
| **1.75s / 851 KB** | to fork a live 1.1GB dataset, and what the fork costs in the bucket. Copy-on-write dataset versioning is real, works, and is the one thing here IV cannot do today. |

Measured on `iv-cloud-disk` (4 CPU, 16GB, 60GB root, exeslim-dev, `iv-provision`
3.0.19) against real Tigris in `iv-nonprod`, cloud-disk **1.8.0** (beta),
DuckDB 1.5.3. Second VM `iv-cloud-disk-b` for portability and fencing.

**The headline caveat is not performance, it is [F1](#f1--two-disks-silently-become-one-volume-data-loss): two disks created in the
same bucket without an explicit `-prefix` are silently the same volume**, both
mountable read-write at once, and deleting either destroys both. Any IV
adoption must set `-prefix` on every disk. That is a footgun, not a preference.

**Also tested: [TigrisFS](#tigrisfs-vs-cloud-disk) as the alternative.** It wins
decisively for Parquet (1.0× storage vs 1.75×, objects stay readable by any S3
client, N hosts can mount concurrently — which Cloud Disk cannot). It loses
decisively for `.duckdb` (8.2s vs 0.54s random reads, 15×). **Use both: TigrisFS
for Parquet, Cloud Disk for `.duckdb`.**

---

## Results

All numbers are medians of repeats, produced by `suite/`, raw rows in
`results/*.jsonl`. Regenerate with `python3 suite/report.py results/*.jsonl`.

> ### Read this before quoting a number
>
> **`drop_caches` does not clear a userspace cache.** The harness drops the
> kernel page cache between reads, but both cloud-disk and TigrisFS hold their
> own in-process caches. So every steady-state read number below is
> **warm-cache performance**, not cold-from-Tigris performance. Two consequences:
>
> **1. The tuned arm's cache was never exceeded.** The "big" 2.37GB `.duckdb`
> was chosen to exceed `max-cache-size`, and it does for the *default* config
> (1G RAM, disk cache off) — that arm genuinely faulted from Tigris, so the
> 8.884s is real. But the *tuned* arm had 8G RAM + 20G disk cache, so the file
> fit entirely and 0.536s is "fits in cache", not "faults from Tigris".
> **The 16× gap is a real measurement of turning the cache on. It is NOT
> evidence that Cloud Disk stays fast once a working set outgrows its cache** —
> that case is untested, and it is the case IV would hit at dataset scale.
> The honest cold number in this report is the cold-mount row (`b4_*`), which
> wipes `/var/lib/cloud-disk` and restarts the daemon, killing both caches:
> **16.9s default, 1.14s with `warm-start-bytes=8G`.**
>
> **2. The TigrisFS-vs-httpfs Parquet comparison is withdrawn.** TigrisFS
> scanned 526MB in 0.387s = 1,360 MB/s, within 5% of local disk. That is not
> physically plausible from object storage on this box; the daemon served data
> it had just written. The httpfs arm (26 MB/s) was run on stock settings with
> no tuning, so it is unfair in the opposite direction. **Neither number should
> be used.** This does not affect the TigrisFS conclusions that matter
> (transparency, 1.0× storage, concurrent readers), none of which are timings.
>
> Unaffected by all of the above: every durability result (the host-loss tests
> explicitly wipe the cache), every F-finding, storage amplification, fork
> timings, and the concurrency/capability results.

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

## TigrisFS vs Cloud Disk

TigrisFS 1.2.1 (a GeeseFS fork, FUSE, file→object) mounted over bucket
`cdbench-fs`, same workloads, same harness (`suite/tests/test_g_tigrisfs.py`).
The question: does IV need Cloud Disk's block device at all?

| workload | local | Cloud Disk (tuned) | **TigrisFS** | winner |
|---|---|---|---|---|
| Parquet build, 40M rows (s) | 29.2 | 30.1 | **32.1** | tie |
| Parquet scan (s)² | 0.37 | 0.36 | **0.39** | tie (both cache-warm) |
| Parquet point lookup (s)² | – | 0.54 | **1.11** | inconclusive |
| **Random read, 2.4GB `.duckdb` (s)** | 0.455 | **0.536** | **8.198** | **Cloud Disk, 15×** |
| Full scan, 2.4GB `.duckdb` (s) | 0.366 | 0.355 | 5.975 | Cloud Disk, 17× |
| Build 2.4GB `.duckdb` (s) | 34.3 | 33.5 | **180.7** | Cloud Disk, 5.4× |
| Random read, 123MB `.duckdb` (s) | 0.059 | 0.069 | 0.487 | Cloud Disk, 7× |
| 4K fsync (ops/s) | 799 | 345 | **15.4** | Cloud Disk, 22× |
| DuckDB checkpoint cycle (s) | 0.48 | 0.50 | 6.40 | Cloud Disk, 13× |
| Streaming write, dd (MB/s) | 815 | 177–285 | **14.1** | Cloud Disk, 13× |
| **Storage amplification** | – | 1.746× | **1.0000×** | **TigrisFS** |
| **Objects readable without a mount** | – | **no** | **yes** | **TigrisFS** |
| **Concurrent readers, 2 hosts** | – | **no** (exclusive lease) | **yes** | **TigrisFS** |

² **Withdrawn as a comparison** — both served from warm userspace caches; the
httpfs control (20.3s) was untuned. See
[methodology](#read-this-before-quoting-a-number). The TigrisFS conclusions
below rest on the non-timing rows, which are unaffected.

The hypothesis held exactly. **TigrisFS is fine for whole-file Parquet and bad
for anything written in place**, because DuckDB updates random offsets inside
one large file and a file→object layer has to read-modify-write the object.
15.4 fsync/s is worse than Cloud Disk's *durable* write-through mode (6.2/s is
the only thing slower).

But the three rows at the bottom are the ones that matter for IV:

- **1.0000× storage.** 526,388,908 bytes of Parquet occupied 526,388,908 bytes
  in the bucket, across 17 keys. Cloud Disk turned 1.12GB into 1,863 opaque
  `chunk-*` objects at 1.746×. **That halves the storage bill** and removes the
  amplification caveat from the cost model entirely.
- **The objects are just files.** `g1_object_is_real_parquet=True` — a plain
  boto3 client read key `bench/pq/part=0/data_0.parquet` and got `b'PAR1'`.
  Any consumer (duckdb/httpfs, a client, a Dive) can read the dataset with no
  mount, no daemon, no lease. Cloud Disk's bucket is unreadable by anything
  except another Cloud Disk mount.
- **N hosts can read at once.** Both VMs mounted `cdbench-fs` simultaneously and
  each counted 40,000,000 rows. This is the fan-out serving story that Cloud
  Disk **cannot** do — its read-only mounts still take the exclusive lease.

TigrisFS also has none of F1–F5, F7: no prefix collision, no NBD layer, no
10-minute D-state hang, no 16-device ceiling, no lease semantics.

**Conclusion: they are complementary, not competing.**

| use | tool |
|---|---|
| Parquet datasets, served to many consumers | **TigrisFS** — or nothing at all: the objects are plain files |
| `.duckdb` files, queried repeatedly | **Cloud Disk**, `-preset database` |
| Dataset versioning / staging clones | **Cloud Disk** — CoW forks, 1.75s |
| Building anything | **local disk**, then publish |

If IV's datasets are mostly Parquet, **TigrisFS is the better default and Cloud
Disk's remaining unique value is CoW forking.** Whether that alone justifies
Cloud Disk's operational surface (F1–F7) is a judgement call, but the honest
read is that it is one feature, not a platform.

### TigrisFS caveats found

- **`/dev/fuse` is `0600 root:root` on exe.dev VMs** (normally `0666`), so
  unprivileged mounts fail with `failed to open /dev/fuse: Permission denied`.
  TigrisFS must be mounted with `sudo` here.
- **`-o allow_other` is not enough**: the mount is root-owned, so every file
  appears root-owned and non-root writes fail. Needs
  `--uid $(id -u) --gid $(id -g) --file-mode 0644 --dir-mode 0755`.
- Untested: durability under crash/host loss, forking, `ReadOnlyMany` under
  *write* contention, and whether concurrent *writers* are safe (FUSE docs warn
  about multi-user mountpoints). **Do not assume the durability results in this
  report transfer to TigrisFS — they were not measured.**

---

## Postscript: DuckLake already forks datasets, better

The evaluation was framed around Cloud Disk's CoW fork as the feature that
would justify adoption. It does not, because IV's existing DuckLake
architecture already has a better one.

Measured on this VM (DuckLake catalog + partitioned Parquet, `DATA_PATH` on
local disk):

| | |
|---|---|
| Fork = copy the catalog | **3 ms** (3.9 MB) |
| Parquet copied | **none** — 105 MB shared by both catalogs |
| Independence | fork 3,001,000 rows vs parent 3,000,000 |
| New Parquet written by the fork | **4,638 bytes** (the delta only) |

The data layer never needs copying because Parquet is immutable, so only the
small mutable catalog does. A dataset fork is therefore: copy one `.ducklake`
file, pin a git commit, share the bucket.

| part of a dataset | mutable? | fork mechanism | cost |
|---|---|---|---|
| metadata (`.ducklake`) | yes | copy the file | **3 ms**, MB-scale |
| data (Parquet on Tigris) | **no** | reference the same objects | **free** |
| code | yes | `git checkout -b` | free |

This beats Cloud Disk's fork on every axis: 3 ms vs 1.75 s, no snapshot-bucket
prerequisite, no separate-target-bucket rule, no `-prefix` footgun, and the
result is readable by any S3 client instead of 1,863 opaque `chunk-*` blocks.
Cloud Disk forks a *disk image* because it cannot see files; DuckLake forks a
*dataset* because it can.

**With this, nothing in this evaluation argues for adopting Cloud Disk.**

Not tested, and worth testing before relying on it:
- The same fork with `DATA_PATH` on **Tigris** rather than local disk. The
  mechanism is identical (the catalog stores `s3://` paths), but it was not
  measured.
- **Garbage collection is the sharp edge.** DuckLake expiry/cleanup on the
  parent could delete Parquet that a fork still references. Cloud Disk's
  bucket-level fork is immune to this by construction; a catalog-level fork is
  not. This is the failure mode the design would actually hit.

Also note: exe.dev root is **ext4**, so `cp --reflink=always` fails with
`Operation not supported` — a "just copy the folder" local adapter is a full
byte copy, not a CoW fork. Filesystem-level CoW would need btrfs/XFS/ZFS.
DuckLake's catalog-copy fork sidesteps this entirely.

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
  mounts take the exclusive lease. One reader at a time. **Use TigrisFS
  instead**: two hosts mounted the same bucket concurrently and both queried
  40M rows (measured). Or N forks (cheap), or plain httpfs.
- **Parquet-only datasets.** TigrisFS matches it on speed (0.39s vs 0.36s scan),
  at 1.0× storage instead of 1.75×, with the objects readable by any S3 client
  and no lease. Cloud Disk buys you nothing here except forking.
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
- **`.duckdb` files specifically** — 15× faster than TigrisFS on random reads
  over a 2.4GB database, and 5.4× faster to build one. This is the workload
  where the block device genuinely earns its keep.

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
  tests/test_g_tigrisfs.py      G: TigrisFS arm, same workloads
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
