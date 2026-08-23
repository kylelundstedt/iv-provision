"""C. Dataset lifecycle -- snapshot, fork, portability, cost shape.

This is the section that would justify adoption: copy-on-write forks of a
large dataset in seconds is a capability IV does not have today.

Run: python -m tests.test_c_lifecycle
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from cdbench import harness as H
from cdbench import workload as W

T = "C"
PARENT = os.environ.get("CDBENCH_PARENT", "c-parent")
ROWS = int(os.environ.get("CDBENCH_C_ROWS", 20_000_000))


def _rowcount(dbfile: str) -> int:
    """Parse a scalar count out of the DuckDB box-drawing table output."""
    p = W.duck("SELECT count(*) FROM fact;", dbfile=dbfile, check=False)
    for ln in p.stdout.splitlines():
        tok = ln.strip("\u2502 ").strip()
        if tok.isdigit():
            return int(tok)
    return -1


def _fresh(disk, size="30G", **kw):
    H.cd_umount(disk)
    H.cd_delete(disk)
    p = H.cd_create(disk, size=size, **kw)
    if p.returncode != 0:
        raise RuntimeError(f"create {disk}: {p.stdout}{p.stderr}")
    mp = H.cd_mountpoint(disk)
    H.own_mount(mp)
    return mp


def c0_build_parent():
    mp = _fresh(PARENT, size="30G")
    with H.timer(T, "c0_parent_build_s", arm="cloud-disk"):
        W.duck(W.gen_parquet_sql(f"{mp}/pq", ROWS))
        W.duck(W.build_duckdb_sql(ROWS // 2), dbfile=f"{mp}/ds.duckdb", memory_limit="4GB")
    subprocess.run(["sync"])
    logical = H.dir_size_bytes(mp)
    H.emit(T, "c0_parent_logical_bytes", logical, "B", "cloud-disk")
    return mp


def c1_snapshot_and_fork(mp: str):
    """Snapshot a *live* disk mid-build, then fork it. Independence + time."""
    # start a background write so the snapshot is genuinely mid-build
    bg = subprocess.Popen(
        ["/bin/sh", "-c",
         f"while :; do dd if=/dev/urandom of={mp}/churn.bin bs=1M count=64 conv=fsync status=none; sleep 1; done"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(5)
    snap_id = f"snap-{int(time.time())}"
    try:
        # -force: snapshot a *live, actively-written* disk. Without it the CLI
        # refuses while the disk is mounted. The doc warns this 'may capture a
        # torn state' -- whether that torn state is still a queryable DuckDB
        # file is exactly what c1 is testing.
        t0 = time.monotonic()
        snap = H.sudo(f"cloud-disk snapshot {PARENT} create -name {snap_id} -force",
                      check=False, timeout=1800)
        snap_s = time.monotonic() - t0
        H.emit(T, "c1_snapshot_create_s", round(snap_s, 3), "s", "cloud-disk",
               ok=snap.returncode == 0, name=snap_id,
               output=(snap.stdout + snap.stderr)[-300:])
        if snap.returncode != 0:
            snap_id = ""
    finally:
        bg.terminate()
        bg.wait()

    lst = H.sudo(f"cloud-disk snapshot {PARENT} list", check=False)
    H.emit(T, "c1_snapshot_list", (lst.stdout + lst.stderr).replace("\n", " | ")[-500:],
           "str", "cloud-disk")

    # sha of the parent's duckdb before the fork diverges
    parent_sum = H.sha256_file(f"{mp}/ds.duckdb")
    parent_rows = _rowcount(f"{mp}/ds.duckdb")

    # The snapshot *version* (epoch ns), not the friendly name, is what -snapshot
    # wants: passing the name gives 'Snapshot version invalid or in future'.
    # `snapshot list` returns NEWEST FIRST, so element 0 is the one we just
    # took. Taking [-1] silently forks an older snapshot -- which still
    # succeeds, and is a quiet way to fork the wrong data.
    version = ""
    try:
        entries = json.loads(lst.stdout)
        for e in entries:
            if snap_id and snap_id in e.get("name", ""):
                version = e["name"].split(";")[0].strip()
                break
        if not version and entries:
            version = entries[0]["name"].split(";")[0].strip()
    except Exception:
        m = re.findall(r"\b(\d{19})\b", lst.stdout)
        version = m[0] if m else ""
    H.emit(T, "c1_snapshot_version", version or "unresolved", "str", "cloud-disk")

    # FINDING F6: cloud-disk forks at *bucket* granularity (it calls S3
    # CreateBucket with a fork source), so the fork MUST target a different
    # bucket -- forking into the same bucket fails with BucketAlreadyExists.
    # The fork also inherits the parent's key prefix inside the new bucket,
    # so the mount must pass -prefix <parent> rather than the fork's own name.
    # Tigris will not re-create a recently deleted bucket name
    # (BucketInaccessible), so each run forks into a fresh, timestamped bucket.
    fork = "c-fork"
    fork_bucket = os.environ.get("CDBENCH_FORK_BUCKET", f"{H.BUCKET}-fork-{int(time.time())}")
    H.cd_umount(fork)
    H.sudo(f"sed -i '/^\\[{fork}\\]/,+3d' /etc/cloud-disk/disks", check=False)

    t0 = time.monotonic()
    p = H.sudo(
        f"cloud-disk create {fork} -bucket {fork_bucket} -endpoint {H.ENDPOINT} "
        f"-parent {PARENT} -snapshot {version} "
        f"--set mount-point=/mnt/cloud-disk/{fork}", check=False, timeout=1800)
    fork_s = time.monotonic() - t0
    H.emit(T, "c1_fork_create_s", round(fork_s, 3), "s", "cloud-disk",
           ok=p.returncode == 0, snapshot=version, bucket=fork_bucket,
           parent_logical_bytes=H.dir_size_bytes(mp),
           output=(p.stdout + p.stderr)[-300:])

    t0 = time.monotonic()
    m = H.sudo(f"cloud-disk mount {fork} -bucket {fork_bucket} -prefix {PARENT} "
               f"-endpoint {H.ENDPOINT} --set mount-point=/mnt/cloud-disk/{fork}",
               check=False, timeout=1800)
    H.emit(T, "c1_fork_mount_s", round(time.monotonic() - t0, 3), "s", "cloud-disk",
           ok=m.returncode == 0, output=(m.stdout + m.stderr)[-300:])
    if m.returncode != 0:
        return None

    fmp = f"/mnt/cloud-disk/{fork}"
    H.own_mount(fmp)
    fdb = f"{fmp}/ds.duckdb"
    ok, out = W.duckdb_integrity(fdb) if os.path.exists(fdb) else (False, "missing")
    q = W.duck("SELECT count(*), sum(amount)::VARCHAR FROM fact;", dbfile=fdb, check=False)
    fork_rows = _rowcount(fdb)
    H.emit(T, "c1_fork_duckdb_integrity_ok", ok, "bool", "cloud-disk", output=out[:200])
    H.emit(T, "c1_fork_query_ok", q.returncode == 0, "bool", "cloud-disk",
           rows=q.stdout.replace("\n", " ")[:120])
    H.emit(T, "c1_fork_matches_parent_rows", fork_rows == parent_rows and fork_rows > 0,
           "bool", "cloud-disk", parent_rows=parent_rows, fork_rows=fork_rows)

    # independence: write to the fork, parent must not change
    H.run(f"sh -c 'echo forkonly > {fmp}/FORK_MARKER'", check=False)
    W.duck("CREATE TABLE fork_only AS SELECT 1 x; CHECKPOINT;", dbfile=fdb, check=False)
    subprocess.run(["sync"])
    parent_marker = os.path.exists(f"{mp}/FORK_MARKER")
    parent_sum2 = H.sha256_file(f"{mp}/ds.duckdb")
    H.emit(T, "c1_fork_independent", (not parent_marker) and parent_sum == parent_sum2,
           "bool", "cloud-disk", parent_marker_leaked=parent_marker,
           parent_db_unchanged=parent_sum == parent_sum2)

    # cost shape of a fork: copy-on-write, or a full duplicate?
    n_obj, n_bytes = H.bucket_usage()
    H.emit(T, "c1_parent_bucket_after_fork", n_bytes, "B", "cloud-disk", objects=n_obj)
    try:
        cli = H.s3_client()
        tot = cnt = 0
        tok = None
        while True:
            kw = {"Bucket": fork_bucket, "MaxKeys": 1000}
            if tok:
                kw["ContinuationToken"] = tok
            r = cli.list_objects_v2(**kw)
            for o in r.get("Contents", []):
                cnt += 1
                tot += o["Size"]
            if not r.get("IsTruncated"):
                break
            tok = r["NextContinuationToken"]
        H.emit(T, "c1_fork_bucket_bytes", tot, "B", "cloud-disk", objects=cnt,
               note="listed size of a CoW fork; billed size may differ")
    except Exception as e:
        H.emit(T, "c1_fork_bucket_bytes", -1, "B", "cloud-disk", err=repr(e)[:160])
    return fork


def c2_sparseness(mp: str, disk: str = PARENT):
    """Logical size vs bytes actually stored in the bucket, and object count."""
    used = H.dir_size_bytes(mp)
    df = H.run(f"df -B1 --output=size,used {mp} | tail -1", check=False).stdout.split()
    logical, fs_used = (int(df[0]), int(df[1])) if len(df) == 2 else (-1, -1)
    H.cd_umount(disk, check=True)   # force a full drain so the bucket is authoritative
    n_obj, n_bytes = H.bucket_usage()
    H.emit(T, "c2_disk_logical_bytes", logical, "B", "cloud-disk")
    H.emit(T, "c2_fs_used_bytes", fs_used, "B", "cloud-disk", du_bytes=used)
    H.emit(T, "c2_bucket_bytes", n_bytes, "B", "cloud-disk", objects=n_obj)
    H.emit(T, "c2_overhead_ratio", round(n_bytes / fs_used, 4) if fs_used > 0 else -1,
           "x", "cloud-disk")
    H.cd_mount(disk, check=False)
    H.own_mount(H.cd_mountpoint(disk))


def c3_export(disk: str = PARENT):
    """Half 1 of portability, run on VM A: checksum then hand off."""
    mp = H.cd_mountpoint(disk)
    sums = H.sha256_file(f"{mp}/ds.duckdb")
    rows = _rowcount(f"{mp}/ds.duckdb")
    H.emit(T, "c3_duckdb_sha", sums[:32], "str", "vm-a", rows=rows)
    with H.timer(T, "c3_umount_s", arm="vm-a"):
        H.cd_umount(disk, check=True)
    print(json.dumps({"disk": disk, "sha": sums, "rows": rows}))


def c3_import(disk: str = PARENT, expect_sha: str = "", expect_rows: str = ""):
    """Half 2, run on VM B: mount the same disk and verify byte-identity.

    Note the mount needs -bucket/-prefix/-endpoint explicitly: the registry in
    /etc/cloud-disk/disks is per-host, so a disk is only 'known' on the box
    that created it. That is the whole manual step in the handoff story.
    """
    t0 = time.monotonic()
    p = H.sudo(f"cloud-disk mount {disk} -bucket {H.BUCKET} -prefix {disk} "
               f"-endpoint {H.ENDPOINT}", check=False, timeout=1800)
    H.emit(T, "c3_remote_mount_s", round(time.monotonic() - t0, 3), "s", "vm-b",
           ok=p.returncode == 0, output=(p.stdout + p.stderr)[-200:])
    if p.returncode != 0:
        return
    mp = H.cd_mountpoint(disk)
    t0 = time.monotonic()
    sums = H.sha256_file(f"{mp}/ds.duckdb")
    H.emit(T, "c3_remote_checksum_s", round(time.monotonic() - t0, 3), "s", "vm-b")
    rows = _rowcount(f"{mp}/ds.duckdb")
    ok, out = W.duckdb_integrity(f"{mp}/ds.duckdb")
    H.emit(T, "c3_sha_matches", sums == expect_sha, "bool", "vm-b",
           got=sums[:32], want=expect_sha[:32])
    H.emit(T, "c3_rows_match", str(rows) == str(expect_rows), "bool", "vm-b",
           got=rows, want=expect_rows)
    H.emit(T, "c3_remote_duckdb_integrity_ok", ok, "bool", "vm-b", output=out[:160])


def main():
    stage = os.environ.get("CDBENCH_STAGE", "all")
    if stage in ("all", "build"):
        mp = c0_build_parent()
    else:
        mp = H.cd_mountpoint(PARENT)
    if stage in ("all", "fork"):
        c1_snapshot_and_fork(mp)
    if stage in ("all", "cost"):
        c2_sparseness(mp)
    if stage in ("all", "portability"):
        c3_export()


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] in ("c3_export", "c3_import", "c2_sparseness"):
        globals()[sys.argv[1]](*sys.argv[2:])
    else:
        main()
