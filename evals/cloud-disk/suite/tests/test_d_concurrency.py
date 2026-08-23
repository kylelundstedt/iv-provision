"""D. Concurrency and operational safety.

D1/D2 need a second VM; they are driven from the *controller* (iv-provision)
via tests/run_multihost.sh, which calls into this module on each host.
D3 (same-host lease steal) and D4 (reboot survival) run locally.

Run: python -m tests.test_d_concurrency <subtest>
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

T = "D"
HOST = os.uname().nodename


def _fresh(disk, size="20G", **kw):
    H.cd_umount(disk)
    H.cd_delete(disk)
    p = H.cd_create(disk, size=size, **kw)
    if p.returncode != 0:
        raise RuntimeError(f"create {disk}: {p.stdout}{p.stderr}")
    mp = H.cd_mountpoint(disk)
    H.own_mount(mp)
    return mp


# ------------------------------------------------------------- D-prep
def prep(disk="d-shared", rows=3_000_000):
    """Create a disk with a real dataset for the multi-host tests."""
    mp = _fresh(disk)
    W.duck(W.gen_parquet_sql(f"{mp}/pq", rows))
    W.duck(W.build_duckdb_sql(rows), dbfile=f"{mp}/ds.duckdb", memory_limit="4GB")
    subprocess.run(["sync"])
    H.cd_umount(disk, check=True)
    print(json.dumps({"disk": disk, "mountpoint": mp}))


# ------------------------------------------------------------- D1 rw steal
def _mount_explicit(disk: str, extra: str = "", check=False):
    """Mount by bucket+prefix. The registry is per-host, so VM B has no entry
    for a disk VM A created -- every cross-host mount needs this form."""
    return H.sudo(f"cloud-disk mount {disk} -bucket {H.BUCKET} -prefix {disk} "
                  f"-endpoint {H.ENDPOINT} {extra}", check=check, timeout=1800)


def rw_hold(disk="d-shared", seconds=90):
    """Mount rw and keep writing; report the first error we see.

    Run on host A while host B tries to steal the lease.
    """
    seconds = float(seconds)
    _mount_explicit(disk, check=True)
    mp = H.cd_mountpoint(disk)
    H.own_mount(mp)
    st = H.cd_status(disk).get("status", {})
    H.emit(T, "d1_lease_acquired", st.get("leaseEpoch"), "epoch", f"holder/{HOST}",
           holder=st.get("leaseHolder"), status=st.get("leaseStatus"))
    path = f"{mp}/holder.bin"
    fd = os.open(path, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o644)
    buf = b"h" * (1024 * 1024)
    t0 = time.monotonic()
    n = 0
    err = ""
    while time.monotonic() - t0 < seconds:
        try:
            os.write(fd, buf)
            os.fdatasync(fd)
            n += 1
        except OSError as e:
            err = f"{e.__class__.__name__}: errno={e.errno} {e.strerror}"
            break
        time.sleep(0.05)
    el = time.monotonic() - t0
    H.emit(T, "d1_holder_write_error", err or "none", "str", f"holder/{HOST}",
           mb_written=n, seconds=round(el, 1))
    try:
        os.close(fd)
    except OSError as e:
        H.emit(T, "d1_holder_close_error", repr(e)[:120], "str", f"holder/{HOST}")
    st = H.cd_status(disk).get("status", {})
    H.emit(T, "d1_holder_final_lease", st.get("leaseStatus", "gone"), "str", f"holder/{HOST}",
           epoch=st.get("leaseEpoch"), holder=st.get("leaseHolder"))


def rw_steal(disk="d-shared"):
    """Try to mount the same disk rw from a second host. Must not silently win."""
    t0 = time.monotonic()
    p = _mount_explicit(disk)
    el = time.monotonic() - t0
    H.emit(T, "d1_steal_mount_rc", p.returncode, "rc", f"stealer/{HOST}",
           seconds=round(el, 1), output=(p.stdout + p.stderr)[-400:])
    if p.returncode == 0:
        mp = H.cd_mountpoint(disk)
        H.own_mount(mp)
        st = H.cd_status(disk).get("status", {})
        H.emit(T, "d1_steal_succeeded", True, "bool", f"stealer/{HOST}",
               epoch=st.get("leaseEpoch"), holder=st.get("leaseHolder"))
        ok, out = W.duckdb_integrity(f"{mp}/ds.duckdb")
        H.emit(T, "d1_steal_duckdb_ok", ok, "bool", f"stealer/{HOST}", output=out[:200])
    else:
        H.emit(T, "d1_steal_succeeded", False, "bool", f"stealer/{HOST}")


# ------------------------------------------------------------- D2 readonly fanout
RO_MP = "/mnt/cd-ro"


def ro_mount(disk="d-shared", label="ro"):
    """ReadOnlyMany: can several VMs mount one dataset read-only at once?

    Two gotchas, both found the hard way:

    1. `--set readonly=true` alone FAILS to mount: cloud-disk still asks the
       kernel to mount ext4 read-write-ish, ext4 tries to replay its journal,
       the write is refused by the read-only export and the mount dies with
       "can't read superblock". The working recipe is to export the block
       device only (`--set no-fs=true`) and mount it ourselves with
       `-o ro,noload`, which skips journal replay.
    2. `-readonly` is not a mount flag at all (it is a config key).

    Also note DuckDB cannot open a .duckdb on a read-only *filesystem* via the
    positional-file form; it must be ATTACHed READ_ONLY.
    """
    t0 = time.monotonic()
    p = _mount_explicit(disk, extra="--set readonly=true --set no-fs=true")
    el = time.monotonic() - t0
    H.emit(T, "d2_ro_export_rc", p.returncode, "rc", f"{label}/{HOST}",
           seconds=round(el, 2), output=(p.stdout + p.stderr)[-300:])
    if p.returncode != 0:
        # The interesting failure: a *read-only* mount is still refused because
        # the lease is exclusive. Record it as such.
        H.emit(T, "d2_ro_blocked_by_lease",
               "lease held by another host" in (p.stdout + p.stderr), "bool",
               f"{label}/{HOST}")
        return

    dev = H.cd_status(disk).get("state", {}).get("device", "")
    st = H.cd_status(disk).get("status", {})
    H.emit(T, "d2_ro_lease", st.get("leaseStatus", "?"), "str", f"{label}/{HOST}",
           epoch=st.get("leaseEpoch"), holder=st.get("leaseHolder"),
           note="a read-only mount still takes the EXCLUSIVE lease")
    H.sudo(f"mkdir -p {RO_MP}", check=False)
    m = H.sudo(f"mount -o ro,noload {dev} {RO_MP}", check=False)
    H.emit(T, "d2_ro_fs_mount_rc", m.returncode, "rc", f"{label}/{HOST}",
           output=(m.stdout + m.stderr)[-200:])
    if m.returncode != 0:
        return
    t0 = time.monotonic()
    q = W.duck(f"ATTACH '{RO_MP}/ds.duckdb' AS d (READ_ONLY); "
               "SELECT part, count(*) FROM d.fact GROUP BY 1 ORDER BY 1;", check=False)
    H.emit(T, "d2_ro_query_s", round(time.monotonic() - t0, 3), "s", f"{label}/{HOST}",
           ok=q.returncode == 0, err=(q.stderr[:200] if q.returncode else ""))
    w = H.run(f"sh -c 'echo x > {RO_MP}/should_fail'", check=False)
    H.emit(T, "d2_ro_write_rejected", w.returncode != 0, "bool", f"{label}/{HOST}",
           err=(w.stderr or w.stdout)[:160])


def ro_release(disk="d-shared"):
    H.sudo(f"umount {RO_MP}", check=False)
    H.cd_umount(disk)


# ------------------------------------------------------------- D3 same-host steal
def d3_same_host_steal(disk="d3-lease"):
    """Two cloud-disk processes, same hostname, same disk.

    Reported behaviour to verify: the second is treated as crash recovery and
    takes the lease from a *live* mount, bumping the epoch; the evicted mount
    then fails writes with EIO rather than corrupting the bucket.
    """
    mp = _fresh(disk)
    W.duck(W.build_duckdb_sql(500_000), dbfile=f"{mp}/ds.duckdb")
    subprocess.run(["sync"])
    st1 = H.cd_status(disk).get("status", {})
    H.emit(T, "d3_first_lease", st1.get("leaseEpoch"), "epoch", "same-host",
           holder=st1.get("leaseHolder"))

    # hold an open fd on the first mount
    fd = os.open(f"{mp}/holder.bin", os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o644)
    os.write(fd, b"a" * 4096)
    os.fdatasync(fd)

    mp2 = f"/mnt/cloud-disk/{disk}-second"
    H.sudo(f"mkdir -p {mp2}", check=False)
    t0 = time.monotonic()
    # A second mount of the *same registry name* is refused outright, so to
    # get two daemons onto one volume we address it by bucket+prefix under a
    # different local name -- which is what F1 shows any careless user can do.
    p = H.sudo(f"cloud-disk mount {disk}-second -bucket {H.BUCKET} -prefix {disk} "
               f"-endpoint {H.ENDPOINT} --set mount-point={mp2}", check=False, timeout=900)
    el = time.monotonic() - t0
    H.emit(T, "d3_second_mount_rc", p.returncode, "rc", "same-host",
           seconds=round(el, 1), output=(p.stdout + p.stderr)[-400:])

    st2 = H.cd_status(f"{disk}-second").get("status", {}) or H.cd_status(disk).get("status", {})
    H.emit(T, "d3_lease_after", st2.get("leaseEpoch"), "epoch", "same-host",
           holder=st2.get("leaseHolder"), status=st2.get("leaseStatus"))
    stolen = p.returncode == 0 and st2.get("leaseEpoch") != st1.get("leaseEpoch")
    H.emit(T, "d3_lease_stolen_from_live_mount", stolen, "bool", "same-host")

    err = "none"
    try:
        for _ in range(40):
            os.write(fd, b"b" * 4096)
            os.fdatasync(fd)
            time.sleep(0.1)
    except OSError as e:
        err = f"errno={e.errno} {e.strerror}"
    H.emit(T, "d3_evicted_write_error", err, "str", "same-host")
    try:
        os.close(fd)
    except OSError:
        pass

    # after the dust settles, is the bucket still consistent?
    H.cd_umount(f"{disk}-second")
    H.sudo(f"umount -l {mp}", check=False)
    H.cd_umount(disk)
    H.sudo(f"umount -l {mp2}", check=False)
    time.sleep(2)
    H.wipe_local_cache()
    r = H.cd_mount(disk, check=False)
    H.emit(T, "d3_post_steal_remount_rc", r.returncode, "rc", "same-host",
           output=(r.stdout + r.stderr)[-200:])
    if r.returncode == 0:
        m = H.cd_mountpoint(disk)
        H.own_mount(m)
        ok, out = W.duckdb_integrity(f"{m}/ds.duckdb")
        H.emit(T, "d3_post_steal_duckdb_ok", ok, "bool", "same-host", output=out[:200])
    H.cd_umount(disk)
    H.cd_delete(disk)


# ------------------------------------------------------------- D4 reboot
def d4_arm_reboot(disk="d4-reboot"):
    """Enable the systemd unit, write data, then the caller reboots the VM."""
    mp = _fresh(disk)
    W.duck(W.build_duckdb_sql(1_000_000), dbfile=f"{mp}/ds.duckdb")
    subprocess.run(["sync"])
    sha = H.sha256_file(f"{mp}/ds.duckdb")
    Path("/tmp/d4_sha").write_text(sha)
    H.emit(T, "d4_pre_reboot_sha", sha[:32], "str", "reboot")
    H.cd_umount(disk, check=True)
    e = H.sudo(f"systemctl enable --now cloud-disk@{disk}", check=False, timeout=900)
    time.sleep(10)
    active = H.run(f"systemctl is-active cloud-disk@{disk}", check=False).stdout.strip()
    H.emit(T, "d4_unit_active_before_reboot", active, "str", "reboot",
           enable_rc=e.returncode, output=(e.stdout + e.stderr)[-200:])
    mounted = H.is_mounted(H.cd_mountpoint(disk))
    H.emit(T, "d4_mounted_before_reboot", mounted, "bool", "reboot")


def d4_check_reboot(disk="d4-reboot"):
    active = H.run(f"systemctl is-active cloud-disk@{disk}", check=False).stdout.strip()
    mp = H.cd_mountpoint(disk)
    mounted = H.is_mounted(mp)
    H.emit(T, "d4_unit_active_after_reboot", active, "str", "reboot")
    H.emit(T, "d4_mounted_after_reboot", mounted, "bool", "reboot")
    up = H.run("uptime -p", check=False).stdout.strip()
    H.emit(T, "d4_uptime", up, "str", "reboot")
    if mounted:
        sha = H.sha256_file(f"{mp}/ds.duckdb")
        want = Path("/tmp/d4_sha").read_text().strip() if Path("/tmp/d4_sha").exists() else ""
        H.emit(T, "d4_sha_match", sha == want, "bool", "reboot", after=sha[:32])
        ok, out = W.duckdb_integrity(f"{mp}/ds.duckdb")
        H.emit(T, "d4_duckdb_ok", ok, "bool", "reboot", output=out[:200])
    H.sudo(f"systemctl disable --now cloud-disk@{disk}", check=False, timeout=900)
    H.cd_delete(disk)


if __name__ == "__main__":
    fn = sys.argv[1] if len(sys.argv) > 1 else "d3_same_host_steal"
    args = sys.argv[2:]
    globals()[fn](*args)
