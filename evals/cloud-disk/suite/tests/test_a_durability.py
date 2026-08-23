"""A. Correctness and durability -- the gate.

If these fail nothing else matters. Each test creates its own disk, so a
failure cannot poison the next one.

Run: python -m tests.test_a_durability
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from cdbench import harness as H
from cdbench import workload as W

T = "A"
# The kernel blocks in-flight NBD I/O until this fires when the daemon dies.
# Default is 10m, which makes a crash test take 10 minutes of D-state per arm
# (measured -- see a2_writer_unblock_after_kill_s). 45s keeps the suite usable
# and is itself a finding: the default is an operational hazard.
NBD_TIMEOUT = os.environ.get("CDBENCH_NBD_TIMEOUT", "45s")


def _fresh(disk: str, size="20G", **kw):
    H.cd_umount(disk)
    H.cd_delete(disk)
    p = H.cd_create(disk, size=size, **kw)
    if p.returncode != 0:
        raise RuntimeError(f"create {disk} failed: {p.stdout}\n{p.stderr}")
    mp = H.cd_mountpoint(disk)
    H.own_mount(mp)
    return mp


# ---------------------------------------------------------------- A1
def a1_roundtrip_wipe_cache(disk="a1-roundtrip", rows=12_000_000):
    """Write dataset, checksum, unmount, WIPE local cache, remount, re-checksum.

    Proves the bucket is the source of truth, not /var/lib/cloud-disk.
    """
    mp = _fresh(disk)
    ds = f"{mp}/pq"
    db = f"{mp}/build.duckdb"

    with H.timer(T, "a1_build_s", arm="cloud-disk"):
        W.duck(W.gen_parquet_sql(ds, rows))
        W.duck(W.build_duckdb_sql(rows // 2), dbfile=db)

    size = H.dir_size_bytes(mp)
    tree = H.sha256_tree(f"{mp}/pq")
    dbsum = H.sha256_file(db)
    q_before = W.duck("SELECT count(*), sum(amount)::VARCHAR FROM fact;", dbfile=db).stdout.strip()
    H.emit(T, "a1_local_cache_bytes_mounted", H.dir_size_bytes("/var/lib/cloud-disk"), "B", "cloud-disk")

    with H.timer(T, "a1_umount_s", arm="cloud-disk"):
        H.cd_umount(disk, check=True)

    cache_before = H.dir_size_bytes("/var/lib/cloud-disk")
    H.wipe_local_cache()
    cache_after = H.dir_size_bytes("/var/lib/cloud-disk")
    H.emit(T, "a1_local_cache_bytes_after_umount", cache_before, "B", "cloud-disk",
           after_wipe=cache_after)
    H.drop_page_cache()

    with H.timer(T, "a1_remount_s", arm="cloud-disk"):
        H.cd_mount(disk)
    H.own_mount(mp)

    tree2 = H.sha256_tree(f"{mp}/pq")
    dbsum2 = H.sha256_file(db)
    q_after = W.duck("SELECT count(*), sum(amount)::VARCHAR FROM fact;", dbfile=db).stdout.strip()
    ok, out = W.duckdb_integrity(db)

    H.emit(T, "a1_parquet_tree_match", tree == tree2, "bool", "cloud-disk",
           before=tree[:16], after=tree2[:16], bytes_written=size)
    H.emit(T, "a1_duckdb_file_match", dbsum == dbsum2, "bool", "cloud-disk")
    H.emit(T, "a1_query_match", q_before == q_after, "bool", "cloud-disk", result=q_after[:80])
    H.emit(T, "a1_integrity_check_ok", ok, "bool", "cloud-disk", output=out[:200])
    return disk


# ---------------------------------------------------------------- A2/A3
WRITER_SRC = """
import os, sys
path, prog = sys.argv[1], sys.argv[2]
buf = bytearray(1024 * 1024)
fd = os.open(path, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o644)
pf = open(prog, 'w')
i = 0
try:
    while True:
        buf[0:8] = i.to_bytes(8, 'little')
        os.write(fd, bytes(buf))
        os.fdatasync(fd)          # the app is now told this record is durable
        pf.seek(0); pf.write(str(i) + '\\n'); pf.flush(); os.fsync(pf.fileno())
        i += 1
except Exception as e:
    sys.stderr.write(repr(e))
"""


def _writer_script() -> Path:
    p = Path("/tmp/cd_writer.py")
    p.write_text(WRITER_SRC)
    return p


def _crash_run(disk: str, write_back: bool, arm: str, mb=1500):
    """SIGKILL cloud-disk mid-write; measure data actually lost + DuckDB health.

    Protocol:
      1. build a duckdb file and CHECKPOINT it (durable intent)
      2. write N numbered 1MB records, fsync()ing each -- record the last
         index the *application* was told was durable
      3. SIGKILL the daemon mid-stream
      4. umount -l, remount, compare
    """
    sets = {"nbd-request-timeout": NBD_TIMEOUT} if write_back else {
        "write-back": "false", "nbd-request-timeout": NBD_TIMEOUT}
    mp = _fresh(disk, size="20G", sets=sets)
    db = f"{mp}/crash.duckdb"
    W.duck(W.build_duckdb_sql(2_000_000), dbfile=db)
    W.duck("CHECKPOINT;", dbfile=db)
    subprocess.run(["sync"])
    db_sum_before = H.sha256_file(db)

    writer = _writer_script()
    prog = "/tmp/cd_progress.txt"
    Path(prog).write_text("-1\n")
    proc = subprocess.Popen([sys.executable, str(writer), f"{mp}/stream.bin", prog],
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    time.sleep(20)  # let it get going
    pid = H.cd_pid(disk)
    acked = int(Path(prog).read_text().strip() or -1)
    t0 = time.monotonic()
    H.sudo(f"kill -9 {pid}", check=False)

    # FINDING: with the daemon gone, in-flight I/O blocks in uninterruptible
    # sleep until the NBD per-request timeout (default 10m) fires. The writer
    # cannot be killed in that window. We measure the unblock latency rather
    # than paper over it.
    unblocked = -1.0
    try:
        proc.wait(timeout=900)
        unblocked = time.monotonic() - t0
    except subprocess.TimeoutExpired:
        proc.kill()
        unblocked = -1.0
    H.emit(T, "a2_writer_unblock_after_kill_s", round(unblocked, 1), "s", arm)
    try:
        err = (proc.stderr.read() or "")[:200] if proc.stderr else ""
    except Exception as e:
        err = f"<stderr unreadable: {e.__class__.__name__}>"
    H.emit(T, "a2_writer_error_on_evict", err.strip()[:160] or "none", "str", arm)
    H.emit(T, "a2_records_acked_before_kill", acked, "count", arm)

    H.sudo(f"umount -l {mp}", check=False)
    time.sleep(2)
    with H.timer(T, "a2_recovery_mount_s", arm=arm):
        mres = H.cd_mount(disk, check=False)
    H.emit(T, "a2_remount_ok", mres.returncode == 0, "bool", arm,
           output=(mres.stdout + mres.stderr)[-200:])
    mp2 = H.cd_mountpoint(disk)
    H.own_mount(mp2)

    # how many fsync-acked 1MB records actually survived?
    survived = -1
    try:
        with open(f"{mp2}/stream.bin", "rb") as fh:
            fh.seek(0, 2)
            n = fh.tell() // (1024 * 1024)
            survived = -1
            for i in range(n):
                fh.seek(i * 1024 * 1024)
                got = int.from_bytes(fh.read(8), "little")
                if got != i:
                    break
                survived = i
    except FileNotFoundError:
        survived = -2
    lost = acked - survived
    H.emit(T, "a2_records_survived", survived, "count", arm)
    H.emit(T, "a2_acked_data_lost_mb", lost, "MB", arm)

    # ext4 journal health
    dmesg = H.sudo("dmesg", check=False).stdout[-4000:]
    H.emit(T, "a2_ext4_recovery_line",
           "; ".join([l.split("] ", 1)[-1] for l in dmesg.splitlines()
                      if "EXT4" in l and ("recovery" in l or "error" in l.lower())][-3:]) or "none",
           "str", arm)

    # DuckDB survival: the failure mode IV would actually feel
    db = f"{mp2}/crash.duckdb"
    exists = os.path.exists(db)
    ok, out = W.duckdb_integrity(db) if exists else (False, "missing")
    q = W.duck("SELECT count(*) FROM fact;", dbfile=db, check=False) if exists else None
    db_sum_after = H.sha256_file(db) if exists else ""
    H.emit(T, "a2_duckdb_present", exists, "bool", arm)
    H.emit(T, "a2_duckdb_integrity_ok", ok, "bool", arm, output=out[:200])
    H.emit(T, "a2_duckdb_query_ok", bool(q and q.returncode == 0), "bool", arm,
           rows=(q.stdout.strip()[:40] if q else ""))
    H.emit(T, "a2_duckdb_bytes_identical", db_sum_after == db_sum_before, "bool", arm)
    return disk


def a2_crash_writeback():
    return _crash_run("a2-wb", True, "write-back=true")


def a3_crash_writethrough():
    return _crash_run("a3-wt", False, "write-back=false")


# ---------------------------------------------------------------- A4
def _hostloss_run(disk: str, write_back: bool, arm: str, run_s=25):
    """SIGKILL the daemon *and destroy the local WAL* -- i.e. lose the host.

    This is the case the docs describe as 'crash-consistent, may roll back'.
    A2/A3 keep the local WAL and so recover fully; only this test measures
    what a real host loss costs, which is the number IV actually needs.
    """
    sets = {"nbd-request-timeout": NBD_TIMEOUT} if write_back else {
        "write-back": "false", "nbd-request-timeout": NBD_TIMEOUT}
    mp = _fresh(disk, size="20G", sets=sets)
    db = f"{mp}/crash.duckdb"
    W.duck(W.build_duckdb_sql(2_000_000), dbfile=db)
    W.duck("CHECKPOINT;", dbfile=db)
    subprocess.run(["sync"])

    writer = _writer_script()
    prog = "/tmp/cd_progress2.txt"
    Path(prog).write_text("-1\n")
    proc = subprocess.Popen([sys.executable, str(writer), f"{mp}/stream.bin", prog],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(run_s)
    pid = H.cd_pid(disk)
    acked = int(Path(prog).read_text().strip() or -1)
    st = H.cd_status(disk).get("status", {})
    H.emit(T, "a4_dirty_bytes_at_kill", st.get("dirtyBytes", -1), "B", arm,
           staging_segments=st.get("stagingSegments"),
           committed_epoch=st.get("lastCommittedEpoch"), latest_epoch=st.get("latestEpoch"))
    t0 = time.monotonic()
    H.sudo(f"kill -9 {pid}", check=False)
    try:
        proc.wait(timeout=900)
        H.emit(T, "a4_writer_unblock_after_kill_s", round(time.monotonic() - t0, 1), "s", arm)
    except subprocess.TimeoutExpired:
        proc.kill()
        H.emit(T, "a4_writer_unblock_after_kill_s", -1, "s", arm)
    H.sudo(f"umount -l {mp}", check=False)
    time.sleep(2)

    # ---- the host is gone: local WAL + cache with it
    H.wipe_local_cache()
    H.drop_page_cache()

    with H.timer(T, "a4_recovery_mount_s", arm=arm):
        mres = H.cd_mount(disk, check=False)
    H.emit(T, "a4_remount_ok", mres.returncode == 0, "bool", arm,
           output=(mres.stdout + mres.stderr)[-200:])
    mp2 = H.cd_mountpoint(disk)
    H.own_mount(mp2)
    H.emit(T, "a4_records_acked_before_kill", acked, "count", arm)

    survived = -1
    try:
        with open(f"{mp2}/stream.bin", "rb") as fh:
            fh.seek(0, 2)
            n = fh.tell() // (1024 * 1024)
            for i in range(n):
                fh.seek(i * 1024 * 1024)
                got = int.from_bytes(fh.read(8), "little")
                if got != i:
                    break
                survived = i
    except FileNotFoundError:
        survived = -2
    H.emit(T, "a4_records_survived", survived, "count", arm)
    H.emit(T, "a4_acked_data_lost_mb", acked - survived, "MB", arm)

    db = f"{mp2}/crash.duckdb"
    exists = os.path.exists(db)
    ok, out = W.duckdb_integrity(db) if exists else (False, "missing")
    q = W.duck("SELECT count(*) FROM fact;", dbfile=db, check=False) if exists else None
    H.emit(T, "a4_duckdb_present", exists, "bool", arm)
    H.emit(T, "a4_duckdb_integrity_ok", ok, "bool", arm, output=out[:200])
    H.emit(T, "a4_duckdb_query_ok", bool(q and q.returncode == 0), "bool", arm)
    fsck = H.sudo(f"dmesg", check=False).stdout[-3000:]
    H.emit(T, "a4_ext4_lines",
           "; ".join([l.split("] ", 1)[-1] for l in fsck.splitlines() if "EXT4" in l][-3:]) or "none",
           "str", arm)
    return disk


def a4_hostloss_writeback():
    return _hostloss_run("a4-wb", True, "hostloss/write-back=true")


def a5_hostloss_writethrough():
    return _hostloss_run("a5-wt", False, "hostloss/write-back=false")


# ---------------------------------------------------------------- A6
def a6_credentials_at_rest():
    """Security: cloud-disk persists the Tigris key in plaintext."""
    p = H.run("sudo stat -c '%a %U:%G' /etc/cloud-disk/disks", check=False)
    mode = p.stdout.strip()
    body = H.run("sudo cat /etc/cloud-disk/disks", check=False).stdout
    has_id = "tid_" in body
    has_secret = "tsec_" in body
    H.emit(T, "a6_registry_mode", mode, "str", "security")
    H.emit(T, "a6_access_key_plaintext", has_id, "bool", "security")
    H.emit(T, "a6_secret_key_plaintext", has_secret, "bool", "security")
    # who can read it? anyone who can sudo -- which on an exe.dev VM is
    # every interactive user and every agent session (NOPASSWD).
    sudoers = H.run("sudo grep -rl NOPASSWD /etc/sudoers /etc/sudoers.d 2>/dev/null", check=False)
    H.emit(T, "a6_passwordless_sudo", bool(sudoers.stdout.strip()), "bool", "security",
           files=sudoers.stdout.strip()[:120])


def main():
    keep = os.environ.get("CDBENCH_KEEP") == "1"
    disks = []
    only = os.environ.get("CDBENCH_ONLY", "").split(",") if os.environ.get("CDBENCH_ONLY") else None
    fns = (a6_credentials_at_rest, a1_roundtrip_wipe_cache, a2_crash_writeback,
           a3_crash_writethrough, a4_hostloss_writeback, a5_hostloss_writethrough)
    for fn in fns:
        if only and fn.__name__ not in only:
            continue
        try:
            r = fn()
            if r:
                disks.append(r)
        except Exception as e:
            H.emit(T, f"{fn.__name__}_EXCEPTION", repr(e)[:400], "str", "")
            print(f"!! {fn.__name__}: {e}", file=sys.stderr)
            disks.append(fn.__name__.split("_")[0].replace("a", "a") if False else None)
            disks = [d for d in disks if d]
    if not keep:
        for d in disks:
            H.cd_umount(d)
            H.cd_delete(d)


if __name__ == "__main__":
    main()
