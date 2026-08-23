"""B. Performance, always against a control.

Every workload runs on three arms where applicable:
  local        -- the VM's own disk (the control)
  cloud-disk   -- default write-back
  cloud-disk-wt-- write-through (write-back=false)
  httpfs       -- no cloud-disk at all; DuckDB reads Parquet from the bucket

Ratios, not absolutes, are the deliverable.

Run: python -m tests.test_b_performance
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from cdbench import harness as H
from cdbench import workload as W

T = "B"

# The documented "tuned for a database" recipe:
#   https://www.tigrisdata.com/docs/cloud-disk/tuning/#example-tuned-for-a-database
#     --set disk-cache-size=100G --set max-cache-size=16G
#     --set flush-workers=16    --set max-staging-bytes=16G
# scaled to this VM (16GB RAM, 60GB root). The important one is
# disk-cache-size: it defaults to 0, i.e. the local-disk read cache is OFF,
# so an untuned disk serves every RAM-cache miss from Tigris over the network.
DB_TUNING = {
    "disk-cache-size": os.environ.get("CDBENCH_DISK_CACHE", "20G"),
    "max-cache-size": os.environ.get("CDBENCH_MAX_CACHE", "8G"),
    "flush-workers": "16",
    "max-staging-bytes": "8G",
}

ROWS_PQ = int(os.environ.get("CDBENCH_ROWS_PQ", 40_000_000))   # ~3GB parquet
ROWS_DB_SMALL = int(os.environ.get("CDBENCH_ROWS_SMALL", 1_500_000))   # < max-cache-size
ROWS_DB_BIG = int(os.environ.get("CDBENCH_ROWS_BIG", 30_000_000))      # >> max-cache-size


def _fresh(disk, size="30G", **kw):
    H.cd_umount(disk)
    H.cd_delete(disk)
    p = H.cd_create(disk, size=size, **kw)
    if p.returncode != 0:
        raise RuntimeError(f"create {disk}: {p.stdout}{p.stderr}")
    mp = H.cd_mountpoint(disk)
    H.own_mount(mp)
    return mp


def _local_dir() -> str:
    d = str(H.LOCAL_BASE)
    shutil.rmtree(d, ignore_errors=True)
    Path(d).mkdir(parents=True, exist_ok=True)
    return d


# ------------------------------------------------------------------ B1 bulk
def b1_bulk_write(base: str, arm: str, rows=ROWS_PQ):
    """Sequential-write-heavy: COPY ... TO a partitioned Parquet dataset."""
    ds = f"{base}/pq"
    t0 = time.monotonic()
    W.duck(W.gen_parquet_sql(ds, rows))
    subprocess.run(["sync"])
    el = time.monotonic() - t0
    nbytes = H.dir_size_bytes(ds)
    H.emit(T, "b1_parquet_write_s", round(el, 3), "s", arm, rows=rows, bytes=nbytes,
           mb_per_s=round(nbytes / 1e6 / el, 1))
    return ds, nbytes


def b1b_dd_stream(base: str, arm: str, mb=2048):
    el = W.dd_write(f"{base}/dd.bin", mb)
    H.emit(T, "b1b_dd_write_s", round(el, 3), "s", arm, mb=mb,
           mb_per_s=round(mb / el, 1))
    H.run(f"rm -f {base}/dd.bin", check=False)


# ------------------------------------------------------------------ B2 duckdb reads
def b2_duckdb_reads(base: str, arm: str, rows: int, label: str, cold_drop=True):
    """Build a .duckdb of a given size, then scan + random-read it.

    label 'small' = fits in max-cache-size; 'big' = must fault from Tigris.
    """
    db = f"{base}/{label}.duckdb"
    H.run(f"rm -f {db}", check=False)
    t0 = time.monotonic()
    W.duck(W.build_duckdb_sql(rows), dbfile=db, memory_limit="4GB")
    build = time.monotonic() - t0
    subprocess.run(["sync"])
    size = int(H.run(f"stat -c %s {db}", check=False).stdout.strip() or 0)
    H.emit(T, f"b2_{label}_build_s", round(build, 3), "s", arm, rows=rows, db_bytes=size)

    if cold_drop:
        H.drop_page_cache()

    t0 = time.monotonic()
    W.duck(W.SCAN_SQL, dbfile=db, memory_limit="4GB")
    H.emit(T, f"b2_{label}_full_scan_s", round(time.monotonic() - t0, 3), "s", arm,
           db_bytes=size)

    for i, seed in enumerate((7919, 104729, 15485863)):
        H.drop_page_cache()
        t0 = time.monotonic()
        W.duck(W.random_read_sql(2000, rows, seed), dbfile=db, memory_limit="4GB")
        H.emit(T, f"b2_{label}_random_read_s", round(time.monotonic() - t0, 3), "s", arm,
               iteration=i, db_bytes=size)

    # warm repeat: same query, no cache drop -- what a repeated query costs
    t0 = time.monotonic()
    W.duck(W.random_read_sql(2000, rows, 7919), dbfile=db, memory_limit="4GB")
    H.emit(T, f"b2_{label}_random_read_warm_s", round(time.monotonic() - t0, 3), "s", arm,
           db_bytes=size)
    return db, size


# ------------------------------------------------------------------ B3 fsync
def b3_fsync(base: str, arm: str, n=400, bs=4096):
    path = f"{base}/fsync.bin"
    el, ops = W.fsync_bench(path, n=n, bs=bs)
    H.emit(T, "b3_fsync_ops_per_s", round(ops, 1), "ops/s", arm, n=n, block=bs,
           elapsed_s=round(el, 3))
    H.run(f"rm -f {path}", check=False)


def b3b_duckdb_checkpoints(base: str, arm: str, n=12):
    """DuckDB checkpoint churn -- the sqlmesh/state-table shape."""
    db = f"{base}/ckpt.duckdb"
    H.run(f"rm -f {db} {db}.wal", check=False)
    W.duck("CREATE TABLE state(k BIGINT, v VARCHAR, ts TIMESTAMP);", dbfile=db)
    t0 = time.monotonic()
    for i in range(n):
        W.duck(f"INSERT INTO state SELECT i, md5(i::VARCHAR), now() FROM range({i}*5000,({i}+1)*5000) t(i); CHECKPOINT;",
               dbfile=db)
    el = time.monotonic() - t0
    H.emit(T, "b3b_checkpoint_cycle_s", round(el, 3), "s", arm, cycles=n,
           per_cycle_s=round(el / n, 3))
    H.run(f"rm -f {db} {db}.wal", check=False)


# ------------------------------------------------------------------ B4 cold mount
def b4_cold_mount(disk: str, arm: str, dbpath_rel: str, warm_bytes: str | None = None):
    """First query after a fresh mount vs warm. Optionally re-tune warm-start-bytes.

    The local cache is wiped, so this is the 'new host, cold everything' case,
    not the 'remount on the same box' case.
    """
    if warm_bytes is not None:
        H.cd_config_set(disk, warm_start_bytes=warm_bytes)
    H.cd_umount(disk, check=True)
    H.wipe_local_cache()
    H.drop_page_cache()
    t0 = time.monotonic()
    H.cd_mount(disk)
    mount_s = time.monotonic() - t0
    mp = H.cd_mountpoint(disk)
    H.own_mount(mp)
    db = f"{mp}/{dbpath_rel}"
    t0 = time.monotonic()
    W.duck(W.SCAN_SQL, dbfile=db, memory_limit="4GB")
    cold = time.monotonic() - t0
    t0 = time.monotonic()
    W.duck(W.SCAN_SQL, dbfile=db, memory_limit="4GB")
    warm = time.monotonic() - t0
    H.emit(T, "b4_mount_s", round(mount_s, 3), "s", arm, warm_start_bytes=warm_bytes or "default")
    H.emit(T, "b4_first_query_cold_s", round(cold, 3), "s", arm, warm_start_bytes=warm_bytes or "default")
    H.emit(T, "b4_second_query_warm_s", round(warm, 3), "s", arm, warm_start_bytes=warm_bytes or "default")


# ------------------------------------------------------------------ B5 httpfs
def b5_httpfs(prefix: str, arm: str = "httpfs"):
    """The honest alternative: query Parquet straight out of the bucket."""
    secret = (
        "INSTALL httpfs; LOAD httpfs; "
        f"CREATE OR REPLACE SECRET t (TYPE S3, KEY_ID '{os.environ['AWS_ACCESS_KEY_ID']}', "
        f"SECRET '{os.environ['AWS_SECRET_ACCESS_KEY']}', ENDPOINT 't3.storage.dev', "
        "REGION 'auto', URL_STYLE 'vhost'); "
    )
    glob = f"s3://{H.BUCKET}/{prefix}/**/*.parquet"
    t0 = time.monotonic()
    p = W.duck(W.parquet_scan_sql(glob), memory_limit="4GB", extra_init=secret, check=False)
    el = time.monotonic() - t0
    H.emit(T, "b5_httpfs_scan_s", round(el, 3), "s", arm, ok=p.returncode == 0,
           err=(p.stderr[:200] if p.returncode else ""))
    for i, seed in enumerate((7919, 104729)):
        t0 = time.monotonic()
        p = W.duck(W.parquet_point_sql(glob, 2000, ROWS_PQ, seed), memory_limit="4GB",
                   extra_init=secret, check=False)
        H.emit(T, "b5_httpfs_point_s", round(time.monotonic() - t0, 3), "s", arm,
               iteration=i, ok=p.returncode == 0, err=(p.stderr[:200] if p.returncode else ""))


def b5_upload_parquet(local_ds: str, prefix: str) -> float:
    """Put the same Parquet dataset in the bucket for the httpfs arm."""
    import boto3
    cli = H.s3_client()
    t0 = time.monotonic()
    n = 0
    for p in Path(local_ds).rglob("*.parquet"):
        key = f"{prefix}/{p.relative_to(local_ds)}"
        cli.upload_file(str(p), H.BUCKET, key)
        n += 1
    el = time.monotonic() - t0
    H.emit(T, "b5_upload_s", round(el, 3), "s", "httpfs", files=n)
    return el


# ------------------------------------------------------------------ presets
def b6_presets(presets=("database", "durable", "sequential-reads")):
    for pre in presets:
        disk = f"b6-{pre}"
        try:
            mp = _fresh(disk, size="30G", preset=pre)
            cfg = H.sudo(f"cloud-disk config {disk} show", check=False).stdout
            H.emit(T, "b6_preset_config", cfg.replace("\n", " | ")[:600], "str", pre)
            b1b_dd_stream(mp, f"preset:{pre}", mb=1024)
            b3_fsync(mp, f"preset:{pre}", n=300)
            b2_duckdb_reads(mp, f"preset:{pre}", ROWS_DB_SMALL, "small")
        except Exception as e:
            H.emit(T, "b6_preset_EXCEPTION", repr(e)[:300], "str", pre)
        finally:
            H.cd_umount(disk)
            H.cd_delete(disk)


def main():
    stage = os.environ.get("CDBENCH_STAGE", "all")
    keep = os.environ.get("CDBENCH_KEEP") == "1"

    if stage in ("all", "local"):
        d = _local_dir()
        b1b_dd_stream(d, "local")
        ds, _ = b1_bulk_write(d, "local")
        b3_fsync(d, "local")
        b3b_duckdb_checkpoints(d, "local")
        b2_duckdb_reads(d, "local", ROWS_DB_SMALL, "small")
        b2_duckdb_reads(d, "local", ROWS_DB_BIG, "big")
        if stage == "all":
            b5_upload_parquet(ds, "httpfs-bench")

    if stage in ("all", "httpfs"):
        b5_httpfs("httpfs-bench")

    if stage in ("all", "cd"):
        disk = "b-wb"
        mp = _fresh(disk, size="30G")
        b1b_dd_stream(mp, "cloud-disk")
        b1_bulk_write(mp, "cloud-disk")
        b3_fsync(mp, "cloud-disk")
        b3b_duckdb_checkpoints(mp, "cloud-disk")
        b2_duckdb_reads(mp, "cloud-disk", ROWS_DB_SMALL, "small")
        b2_duckdb_reads(mp, "cloud-disk", ROWS_DB_BIG, "big")
        b4_cold_mount(disk, "cloud-disk/warm=1G(default)", "big.duckdb")
        b4_cold_mount(disk, "cloud-disk/warm=0", "big.duckdb", warm_bytes="0")
        b4_cold_mount(disk, "cloud-disk/warm=8G", "big.duckdb", warm_bytes="8G")
        if not keep:
            H.cd_umount(disk)
            H.cd_delete(disk)

    if stage in ("all", "wt"):
        disk = "b-wt"
        mp = _fresh(disk, size="30G", sets={"write-back": "false"})
        b1b_dd_stream(mp, "cloud-disk-wt")
        b1_bulk_write(mp, "cloud-disk-wt", rows=ROWS_PQ // 4)
        b3_fsync(mp, "cloud-disk-wt", n=200)
        b3b_duckdb_checkpoints(mp, "cloud-disk-wt", n=6)
        b2_duckdb_reads(mp, "cloud-disk-wt", ROWS_DB_SMALL, "small")
        if not keep:
            H.cd_umount(disk)
            H.cd_delete(disk)

    if stage in ("all", "tuned"):
        # Same disk shape as the 'cd' arm, but with the documented database
        # tuning applied. This is the arm that decides the verdict for
        # read-heavy dataset serving.
        disk = "b-tuned"
        mp = _fresh(disk, size="30G", sets=DB_TUNING)
        cfg = H.sudo(f"cloud-disk config {disk} show", check=False).stdout
        H.emit(T, "b7_tuned_config", cfg.replace("\n", " | ")[:500], "str", "cloud-disk-tuned")
        b1b_dd_stream(mp, "cloud-disk-tuned")
        b1_bulk_write(mp, "cloud-disk-tuned")
        b3_fsync(mp, "cloud-disk-tuned")
        b3b_duckdb_checkpoints(mp, "cloud-disk-tuned")
        b2_duckdb_reads(mp, "cloud-disk-tuned", ROWS_DB_SMALL, "small")
        b2_duckdb_reads(mp, "cloud-disk-tuned", ROWS_DB_BIG, "big")
        # cold mount with the L2 cache wiped: what a fresh host actually pays
        b4_cold_mount(disk, "cloud-disk-tuned/warm=1G(default)", "big.duckdb")
        b4_cold_mount(disk, "cloud-disk-tuned/warm=8G", "big.duckdb", warm_bytes="8G")
        # ...and the steady state a long-lived build box lives in: L2 warm,
        # only the page cache dropped.
        H.drop_page_cache()
        t0 = time.monotonic()
        W.duck(W.SCAN_SQL, dbfile=f"{H.cd_mountpoint(disk)}/big.duckdb", memory_limit="4GB")
        H.emit(T, "b7_scan_l2_warm_s", round(time.monotonic() - t0, 3), "s", "cloud-disk-tuned")
        H.emit(T, "b7_l2_cache_bytes", H.dir_size_bytes("/var/lib/cloud-disk"), "B",
               "cloud-disk-tuned")
        if not keep:
            H.cd_umount(disk)
            H.cd_delete(disk)

    if stage in ("all", "upload"):
        b5_upload_parquet(f"{H.LOCAL_BASE}/pq", "httpfs-bench")

    if stage in ("all", "presets"):
        b6_presets()


if __name__ == "__main__":
    main()
