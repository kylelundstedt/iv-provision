"""Shared harness: result recording, disk lifecycle, timing.

Every test emits one or more Result rows into results.jsonl. Rows are
append-only and machine-readable so two runs (e.g. cloud-disk versions)
can be diffed with DuckDB.
"""
from __future__ import annotations

import json
import os
import shlex
import subprocess
import time
import uuid
from contextlib import contextmanager
from dataclasses import dataclass, field, asdict
from pathlib import Path

RESULTS = Path(os.environ.get("CDBENCH_RESULTS", "/home/exedev/cdbench-results/results.jsonl"))
RUN_ID = os.environ.get("CDBENCH_RUN_ID") or uuid.uuid4().hex[:12]
BUCKET = os.environ.get("CDBENCH_BUCKET", "cloud-disk-test")
ENDPOINT = os.environ.get("CDBENCH_ENDPOINT", "https://t3.storage.dev")
LOCAL_BASE = Path(os.environ.get("CDBENCH_LOCAL", "/home/exedev/cdbench-local"))
CD_STATE = Path("/var/lib/cloud-disk")


def _now() -> float:
    return time.monotonic()


def emit(test: str, metric: str, value, unit: str = "", arm: str = "", **extra) -> None:
    RESULTS.parent.mkdir(parents=True, exist_ok=True)
    row = {
        "run_id": RUN_ID,
        "ts": time.time(),
        "test": test,
        "arm": arm,
        "metric": metric,
        "value": value,
        "unit": unit,
    }
    row.update(extra)
    with RESULTS.open("a") as fh:
        fh.write(json.dumps(row) + "\n")
    print(f"[result] {test} arm={arm} {metric}={value}{unit} {extra if extra else ''}", flush=True)


def run(cmd, check=True, capture=True, timeout=3600, env=None, cwd=None):
    """Run a shell command. Returns CompletedProcess."""
    if isinstance(cmd, str):
        args, shell = cmd, True
    else:
        args, shell = cmd, False
    e = dict(os.environ)
    if env:
        e.update(env)
    return subprocess.run(
        args,
        shell=shell,
        check=check,
        capture_output=capture,
        text=True,
        timeout=timeout,
        env=e,
        cwd=cwd,
    )


_PRESERVE = "AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY,AWS_ENDPOINT_URL_S3,AWS_REGION"


def sudo(cmd, **kw):
    """sudo, preserving the Tigris credentials.

    Note: cloud-disk needs them for `create`; after that the registry at
    /etc/cloud-disk/disks has them (in plaintext -- see report).
    """
    return run(f"sudo --preserve-env={_PRESERVE} {cmd}", **kw)


@contextmanager
def timer(test: str, metric: str, arm: str = "", unit: str = "s", **extra):
    t0 = _now()
    box = {}
    try:
        yield box
    finally:
        dt = _now() - t0
        emit(test, metric, round(dt, 4), unit, arm, **{**extra, **box})


def timeit(fn, *a, **kw) -> float:
    t0 = _now()
    fn(*a, **kw)
    return _now() - t0


# ---------------------------------------------------------------- disk ops

def cd_status(disk: str) -> dict:
    p = sudo(f"cloud-disk status {disk}", check=False)
    try:
        return json.loads(p.stdout)
    except Exception:
        return {}


def cd_pid(disk: str):
    return cd_status(disk).get("state", {}).get("pid")


def cd_mountpoint(disk: str) -> str:
    st = cd_status(disk).get("state", {})
    return st.get("mountPoint") or f"/mnt/cloud-disk/{disk}"


def is_mounted(path: str) -> bool:
    return subprocess.run(["mountpoint", "-q", path]).returncode == 0


def cd_create(disk: str, size="20G", sets: dict | None = None, preset: str | None = None,
              parent: str | None = None, snapshot: str | None = None, no_mount=False,
              mount_point: str | None = None, extra: str = "",
              prefix: str | None = "auto") -> subprocess.CompletedProcess:
    """Create a disk.

    NOTE (v1.8.0 finding F1): `-prefix` defaults to empty, so every disk
    created in the same bucket without an explicit prefix is THE SAME VOLUME,
    silently. The local name in /etc/cloud-disk/disks is just a label. We
    therefore default prefix to the disk name; pass prefix=None to reproduce
    the collision deliberately (see tests/test_f_findings.py).
    """
    args = [f"cloud-disk create {shlex.quote(disk)}", f"-bucket {BUCKET}", f"-endpoint {ENDPOINT}"]
    if prefix == "auto":
        prefix = disk
    if prefix:
        args.append(f"-prefix {shlex.quote(prefix)}")
    if parent:
        args.append(f"-parent {shlex.quote(parent)}")
    else:
        args.append(f"-size {size}")
    if snapshot:
        args.append(f"-snapshot {shlex.quote(snapshot)}")
    if preset:
        args.append(f"-preset {preset}")
    if no_mount:
        args.append("-no-mount")
    if mount_point:
        args.append(f"--set mount-point={mount_point}")
    for k, v in (sets or {}).items():
        args.append(f"--set {k}={v}")
    if extra:
        args.append(extra)
    return sudo(" ".join(args), check=False, timeout=1800)


def cd_mount(disk: str, check=True) -> subprocess.CompletedProcess:
    return sudo(f"cloud-disk mount {disk}", check=check, timeout=1800)


def cd_umount(disk: str, check=False) -> subprocess.CompletedProcess:
    return sudo(f"cloud-disk umount {disk}", check=check, timeout=1800)


def cd_delete(disk: str) -> subprocess.CompletedProcess:
    return sudo(f"cloud-disk delete {disk} -force", check=False, timeout=1800)


def cd_config_set(disk: str, **kw) -> subprocess.CompletedProcess:
    kvs = " ".join(f"{k.replace('_','-')}={v}" for k, v in kw.items())
    return sudo(f"cloud-disk config {disk} set {kvs}", check=False)


def wipe_local_cache(disk: str | None = None) -> None:
    """Nuke the local WAL/cache so the bucket must be the source of truth."""
    target = CD_STATE if disk is None else CD_STATE / disk
    sudo(f"rm -rf {target}", check=False)
    sudo(f"mkdir -p {CD_STATE}", check=False)


def drop_page_cache() -> None:
    sudo("sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'", check=False)


def dir_size_bytes(path: str) -> int:
    p = sudo(f"du -sb {path}", check=False)
    try:
        return int(p.stdout.split()[0])
    except Exception:
        return -1


# ---------------------------------------------------------------- S3 side

def s3_client():
    import boto3
    return boto3.client(
        "s3",
        endpoint_url=ENDPOINT,
        aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
        region_name="auto",
    )


def bucket_usage(prefix: str = "") -> tuple[int, int]:
    """(objects, bytes) under prefix."""
    cli = s3_client()
    n = 0
    total = 0
    tok = None
    while True:
        kw = {"Bucket": BUCKET, "Prefix": prefix, "MaxKeys": 1000}
        if tok:
            kw["ContinuationToken"] = tok
        r = cli.list_objects_v2(**kw)
        for o in r.get("Contents", []):
            n += 1
            total += o["Size"]
        if not r.get("IsTruncated"):
            break
        tok = r.get("NextContinuationToken")
    return n, total


def own_mount(path: str) -> None:
    """Make a freshly-mounted disk writable by the benchmark user."""
    sudo(f"chown -R exedev:exedev {shlex.quote(path)}", check=False, timeout=600)


def sha256_file(path: str) -> str:
    p = sudo(f"sha256sum {shlex.quote(path)}", check=True, timeout=3600)
    return p.stdout.split()[0]


def sha256_tree(path: str) -> str:
    """Stable checksum over a directory tree (names + contents)."""
    cmd = (
        f"sh -c \"find {shlex.quote(path)} -type f -not -path '*/lost+found/*' "
        f"| LC_ALL=C sort | xargs -r sha256sum | sha256sum\""
    )
    p = sudo(cmd, check=True, timeout=3600)
    return p.stdout.split()[0]
