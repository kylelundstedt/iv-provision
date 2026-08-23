"""G. TigrisFS as an alternative to Cloud Disk.

TigrisFS (a GeeseFS fork) maps file -> object, so the bucket stays readable by
any S3 client. Cloud Disk stores a block device: 1,863 opaque `chunk-*` objects
for a 1.12GB dataset (measured, test C). That difference is the whole reason to
compare them.

The hypothesis under test: TigrisFS should be fine for whole-file Parquet and
bad for a `.duckdb`, because DuckDB writes in place at random offsets and a
file->object layer generally cannot partially update an object.

Same workloads as test B, so numbers drop straight into the same table.

Run: python -m tests.test_g_tigrisfs [stage]
"""
from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from cdbench import harness as H
from cdbench import workload as W
from tests.test_b_performance import (
    b1_bulk_write, b1b_dd_stream, b2_duckdb_reads, b3_fsync,
    b3b_duckdb_checkpoints, ROWS_PQ, ROWS_DB_SMALL, ROWS_DB_BIG,
)

T = "G"
ARM = "tigrisfs"
MNT = os.environ.get("CDBENCH_TFS_MNT", "/mnt/tfs")
FS_BUCKET = os.environ.get("CDBENCH_TFS_BUCKET", "cdbench-fs")


def mount(extra: str = ""):
    """Mount the bucket with TigrisFS.

    Note: needs root on an exe.dev VM because /dev/fuse is mode 0600 root:root
    here (normally 0666), so unprivileged FUSE mounts fail with
    'failed to open /dev/fuse: Permission denied'. Recorded as a finding.
    """
    H.sudo(f"mkdir -p {MNT}", check=False)
    if H.is_mounted(MNT):
        return True
    # --uid/--gid are needed as well as allow_other: the FUSE mount is owned by
    # root, so without them every file in the bucket appears root-owned and the
    # benchmark user cannot write (Permission denied).
    t0 = time.monotonic()
    p = H.sudo(f"tigrisfs --endpoint {H.ENDPOINT} -o allow_other "
               f"--uid {os.getuid()} --gid {os.getgid()} "
               f"--file-mode 0644 --dir-mode 0755 {extra} "
               f"{FS_BUCKET} {MNT}", check=False, timeout=600)
    time.sleep(3)
    ok = H.is_mounted(MNT)
    H.emit(T, "g0_mount_s", round(time.monotonic() - t0, 3), "s", ARM,
           ok=ok, output=(p.stdout + p.stderr)[-200:])
    return ok


def umount():
    H.sudo(f"umount {MNT}", check=False, timeout=600)


def g1_parquet(rows=ROWS_PQ):
    """The case TigrisFS should be good at: whole-file Parquet writes."""
    base = f"{MNT}/bench"
    H.run(f"mkdir -p {base}", check=False)
    ds, nbytes = b1_bulk_write(base, ARM, rows=rows)

    # read it back through the filesystem
    H.drop_page_cache()
    t0 = time.monotonic()
    p = W.duck(W.parquet_scan_sql(f"{ds}/**/*.parquet"), memory_limit="4GB", check=False)
    H.emit(T, "g1_parquet_scan_s", round(time.monotonic() - t0, 3), "s", ARM,
           ok=p.returncode == 0, err=(p.stderr[:200] if p.returncode else ""))

    t0 = time.monotonic()
    p = W.duck(W.parquet_point_sql(f"{ds}/**/*.parquet", 2000, rows), memory_limit="4GB",
               check=False)
    H.emit(T, "g1_parquet_point_s", round(time.monotonic() - t0, 3), "s", ARM,
           ok=p.returncode == 0, err=(p.stderr[:200] if p.returncode else ""))

    # transparency: is it still a normal object in the bucket?
    try:
        cli = H.s3_client()
        keys, total = [], 0
        for page in cli.get_paginator("list_objects_v2").paginate(
                Bucket=FS_BUCKET, Prefix="bench/pq/"):
            for o in page.get("Contents", []):
                keys.append((o["Key"], o["Size"]))
                total += o["Size"]
        pq = [k for k, _ in keys if k.endswith(".parquet")]
        H.emit(T, "g1_bucket_keys_readable", bool(pq), "bool", ARM,
               parquet_files=len(pq), total_keys=len(keys), sample=pq[:2])
        if pq:
            # Can a plain S3 client read it with no mount at all? This is the
            # property Cloud Disk does NOT have: its bucket holds opaque
            # chunk-* blocks (1,863 of them for 1.12GB, test C).
            body = cli.get_object(Bucket=FS_BUCKET, Key=pq[0])["Body"].read(4)
            H.emit(T, "g1_object_is_real_parquet", body == b"PAR1", "bool", ARM,
                   magic=repr(body))
        # storage amplification, directly comparable to c2_overhead_ratio
        H.emit(T, "g1_bucket_bytes", total, "B", ARM, objects=len(keys),
               logical_bytes=nbytes,
               overhead_ratio=round(total / nbytes, 4) if nbytes else -1)
    except Exception as e:
        H.emit(T, "g1_bucket_keys_readable", False, "bool", ARM, err=repr(e)[:200])


def g2_duckdb(label="small", rows=ROWS_DB_SMALL):
    """The case TigrisFS should be bad at: in-place random writes to a .duckdb.

    Bounded so a pathological result cannot hang the suite.
    """
    base = f"{MNT}/bench"
    H.run(f"mkdir -p {base}", check=False)
    try:
        b2_duckdb_reads(base, ARM, rows, label)
    except subprocess.TimeoutExpired:
        H.emit(T, f"g2_{label}_TIMEOUT", True, "bool", ARM,
               note="DuckDB build did not finish within the workload timeout")
    except Exception as e:
        H.emit(T, f"g2_{label}_EXCEPTION", repr(e)[:300], "str", ARM)


def g3_fsync_and_stream():
    base = f"{MNT}/bench"
    H.run(f"mkdir -p {base}", check=False)
    try:
        b1b_dd_stream(base, ARM, mb=1024)
    except Exception as e:
        H.emit(T, "g3_dd_EXCEPTION", repr(e)[:200], "str", ARM)
    try:
        b3_fsync(base, ARM, n=200)
    except Exception as e:
        H.emit(T, "g3_fsync_EXCEPTION", repr(e)[:200], "str", ARM)
    try:
        b3b_duckdb_checkpoints(base, ARM, n=6)
    except Exception as e:
        H.emit(T, "g3_ckpt_EXCEPTION", repr(e)[:200], "str", ARM)


def g4_concurrent_readers(vm_b=os.environ.get("CDBENCH_VM_B", "iv-cloud-disk-b")):
    """The thing Cloud Disk could NOT do: two hosts reading at once.

    Cloud Disk refused a second read-only mount (exclusive lease, measured in
    test D). An object store should have no such limit. Driven from VM A;
    the remote half runs the same module over ssh.
    """
    ok_local = H.is_mounted(MNT)
    H.emit(T, "g4_local_mounted", ok_local, "bool", ARM)
    r = subprocess.run(
        ["ssh", vm_b, "set -a; . ~/.cd/creds; set +a; "
         f"sudo mkdir -p {MNT}; "
         "sudo --preserve-env=AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY,"
         "AWS_ENDPOINT_URL_S3,AWS_REGION "
         f"tigrisfs --endpoint {H.ENDPOINT} -o allow_other {FS_BUCKET} {MNT} 2>&1 | tail -2; "
         f"sleep 3; mountpoint -q {MNT} && echo MOUNTED; "
         f"duckdb -c \"SELECT count(*) FROM read_parquet('{MNT}/bench/pq/**/*.parquet');\" 2>&1 | tail -4"],
        capture_output=True, text=True, timeout=900)
    out = r.stdout + r.stderr
    H.emit(T, "g4_second_host_mounted", "MOUNTED" in out, "bool", ARM,
           output=out[-300:].replace("\n", " | "))
    H.emit(T, "g4_second_host_query_ok", any(c.isdigit() for c in out.split("MOUNTED")[-1]),
           "bool", ARM)


def main():
    stage = sys.argv[1] if len(sys.argv) > 1 else "all"
    if not mount():
        print("mount failed", file=sys.stderr)
        return
    if stage in ("all", "parquet"):
        g1_parquet()
    if stage in ("all", "fsync"):
        g3_fsync_and_stream()
    if stage in ("all", "duckdb"):
        g2_duckdb("small", ROWS_DB_SMALL)
    if stage == "duckdb-big":
        g2_duckdb("big", ROWS_DB_BIG)
    if stage in ("all", "concurrent"):
        g4_concurrent_readers()


if __name__ == "__main__":
    main()
