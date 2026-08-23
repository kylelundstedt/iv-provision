"""F. Reproductions for the failure modes found in cloud-disk 1.8.0.

Each function is a self-contained reproduction. They are the evidence behind
the 'Failure modes' section of the report, and are the first thing to re-run
against a newer cloud-disk build.

Run: python -m tests.test_f_findings [name ...]
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

T = "F"


def f1_prefix_collision_silently_shares_volume():
    """F1 (data loss, high severity).

    `cloud-disk create <name> -bucket B` with no -prefix writes at the bucket
    root. The *name* is only a local label in /etc/cloud-disk/disks. So two
    disks created with different names in the same bucket are the same volume,
    with no warning -- and both can be mounted read-write at once, on the same
    host, each believing it owns an independent ext4 filesystem.

    Expected-if-safe: the second create refuses, or the second mount is fenced.
    Observed on 1.8.0: both succeed.
    """
    for d in ("f1-alpha", "f1-beta"):
        H.cd_umount(d)
    H.sudo("sed -i '/^\\[f1-/,+3d' /etc/cloud-disk/disks", check=False)

    a = H.cd_create("f1-alpha", size="5G", prefix=None)
    H.emit(T, "f1_create_alpha_rc", a.returncode, "rc", "no-prefix",
           output=(a.stdout + a.stderr)[-200:])
    mp_a = H.cd_mountpoint("f1-alpha")
    H.own_mount(mp_a)
    Path(f"{mp_a}/from_alpha.txt").write_text("alpha wrote this\n")
    subprocess.run(["sync"])

    b = H.cd_create("f1-beta", size="5G", prefix=None)
    H.emit(T, "f1_create_beta_rc", b.returncode, "rc", "no-prefix",
           output=(b.stdout + b.stderr)[-200:])
    second_create_refused = b.returncode != 0
    H.emit(T, "f1_second_create_refused", second_create_refused, "bool", "no-prefix")
    if second_create_refused:
        H.cd_umount("f1-alpha")
        return

    mp_b = H.cd_mountpoint("f1-beta")
    H.own_mount(mp_b)

    sa = H.cd_status("f1-alpha").get("status", {})
    sb = H.cd_status("f1-beta").get("status", {})
    same_volume = sa.get("name") == sb.get("name")
    H.emit(T, "f1_same_underlying_volume", same_volume, "bool", "no-prefix",
           alpha_volume=sa.get("name"), beta_volume=sb.get("name"),
           alpha_lease=sa.get("leaseHolder"), beta_lease=sb.get("leaseHolder"),
           alpha_epoch=sa.get("leaseEpoch"), beta_epoch=sb.get("leaseEpoch"))
    H.emit(T, "f1_both_mounted_rw_simultaneously",
           H.is_mounted(mp_a) and H.is_mounted(mp_b), "bool", "no-prefix",
           alpha_mp=mp_a, beta_mp=mp_b)

    # Two independent ext4 mounts over one backing store: writes on one are
    # invisible to the other, and the last drain wins.
    Path(f"{mp_b}/from_beta.txt").write_text("beta wrote this\n")
    subprocess.run(["sync"])
    H.emit(T, "f1_alpha_sees_beta_file", os.path.exists(f"{mp_a}/from_beta.txt"),
           "bool", "no-prefix")
    H.emit(T, "f1_beta_sees_alpha_file", os.path.exists(f"{mp_b}/from_alpha.txt"),
           "bool", "no-prefix")

    # And a delete of either name destroys the shared volume.
    H.cd_umount("f1-beta")
    H.cd_umount("f1-alpha")
    d = H.cd_delete("f1-beta")
    H.emit(T, "f1_delete_beta_rc", d.returncode, "rc", "no-prefix",
           output=(d.stdout + d.stderr)[-160:])
    n, _ = H.bucket_usage()
    H.emit(T, "f1_objects_left_after_deleting_one_name", n, "count", "no-prefix")
    m = H.cd_mount("f1-alpha", check=False)
    H.emit(T, "f1_alpha_survives_beta_delete", m.returncode == 0, "bool", "no-prefix",
           output=(m.stdout + m.stderr)[-200:])
    H.cd_umount("f1-alpha")
    H.cd_delete("f1-alpha")


def f2_config_set_is_lost_on_collision():
    """F2. Corollary of F1: `--set` at create time appears to do nothing.

    When two names share a volume, the second create adopts the first's
    persisted config, so `--set write-back=false` silently reverts to true.
    With an explicit -prefix the same command persists correctly.
    """
    H.cd_umount("f2-a")
    H.cd_umount("f2-b")
    H.sudo("sed -i '/^\\[f2-/,+3d' /etc/cloud-disk/disks", check=False)

    H.cd_create("f2-a", size="5G", prefix=None)
    H.cd_create("f2-b", size="5G", prefix=None, sets={"write-back": "false"})
    got = H.sudo("cloud-disk config f2-b show -all", check=False).stdout
    wb = [l for l in got.splitlines() if l.startswith("write-back ")]
    H.emit(T, "f2_writeback_after_set_no_prefix", (wb[0].split()[1] if wb else "?"),
           "str", "no-prefix", note="requested false")
    H.cd_umount("f2-b")
    H.cd_umount("f2-a")
    H.cd_delete("f2-a")

    H.cd_create("f2-c", size="5G", sets={"write-back": "false"})   # auto prefix
    got = H.sudo("cloud-disk config f2-c show -all", check=False).stdout
    wb = [l for l in got.splitlines() if l.startswith("write-back ")]
    H.emit(T, "f2_writeback_after_set_with_prefix", (wb[0].split()[1] if wb else "?"),
           "str", "with-prefix", note="requested false")
    H.cd_umount("f2-c")
    H.cd_delete("f2-c")


def f3_nbd_timeout_blocks_io_for_ten_minutes():
    """F3 (availability). Kill the daemon: in-flight I/O hangs in D-state
    until nbd-request-timeout (default 10m). The process cannot be killed,
    the mount cannot be lazily released cleanly, and on a build box that is a
    ten-minute hang with no diagnostics.

    Measured directly here with the default timeout.
    """
    disk = "f3-hang"
    H.cd_umount(disk)
    H.cd_delete(disk)
    p = H.cd_create(disk, size="5G")     # default nbd-request-timeout (10m)
    if p.returncode != 0:
        H.emit(T, "f3_create_failed", (p.stdout + p.stderr)[-200:], "str", "default-timeout")
        return
    mp = H.cd_mountpoint(disk)
    H.own_mount(mp)
    to = H.sudo(f"cloud-disk config {disk} get nbd-request-timeout", check=False).stdout.strip()
    H.emit(T, "f3_nbd_request_timeout", to or "10m(default)", "str", "default-timeout")

    src = ('import os,sys\n'
           'fd=os.open(sys.argv[1],os.O_CREAT|os.O_WRONLY|os.O_TRUNC,0o644)\n'
           'b=b"z"*1048576\n'
           'while True:\n    os.write(fd,b); os.fdatasync(fd)\n')
    Path("/tmp/f3w.py").write_text(src)
    proc = subprocess.Popen([sys.executable, "/tmp/f3w.py", f"{mp}/hang.bin"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(8)
    pid = H.cd_pid(disk)
    t0 = time.monotonic()
    H.sudo(f"kill -9 {pid}", check=False)
    time.sleep(5)
    stat = H.run(f"ps -o stat= -p {proc.pid}", check=False).stdout.strip()
    H.emit(T, "f3_writer_state_after_kill", stat or "gone", "str", "default-timeout",
           note="D = uninterruptible sleep; SIGKILL will not land")
    k = H.run(f"kill -9 {proc.pid}", check=False)
    time.sleep(5)
    still = H.run(f"ps -o stat= -p {proc.pid}", check=False).stdout.strip()
    H.emit(T, "f3_survives_sigkill", bool(still), "str", "default-timeout", state=still)
    try:
        proc.wait(timeout=780)
        H.emit(T, "f3_unblock_s", round(time.monotonic() - t0, 1), "s", "default-timeout")
    except subprocess.TimeoutExpired:
        H.emit(T, "f3_unblock_s", ">780", "s", "default-timeout")
        proc.kill()
    H.sudo(f"umount -l {mp}", check=False)
    time.sleep(3)
    H.cd_umount(disk)
    H.cd_delete(disk)


def f4_nbd_device_ceiling():
    """F4 (capacity). nbds_max caps concurrent disks per VM."""
    n_dev = len([p for p in Path("/dev").glob("nbd*") if p.name[3:].isdigit()])
    has_nbd = "nbd" in Path("/proc/devices").read_text()
    mod = H.run("cat /sys/module/nbd/parameters/nbds_max", check=False).stdout.strip()
    H.emit(T, "f4_nbd_in_proc_devices", has_nbd, "bool", "capacity")
    H.emit(T, "f4_nbd_devices", n_dev, "count", "capacity", nbds_max=mod or "unreadable")


def f5_root_disk_encryption():
    """F5. -enable-io-uring-writes is documented broken on dm-crypt. Is the
    exe.dev root disk encrypted?"""
    lsblk = H.run("lsblk -o NAME,TYPE,FSTYPE", check=False).stdout
    crypt = "crypt" in lsblk
    dm = H.run("ls /dev/mapper/", check=False).stdout.strip()
    H.emit(T, "f5_dmcrypt_present", crypt, "bool", "security", mapper=dm[:120],
           note="io_uring writes are safe to try only if this is False")


ALL = [f1_prefix_collision_silently_shares_volume,
       f2_config_set_is_lost_on_collision,
       f3_nbd_timeout_blocks_io_for_ten_minutes,
       f4_nbd_device_ceiling,
       f5_root_disk_encryption]


def main():
    want = sys.argv[1:]
    for fn in ALL:
        if want and fn.__name__ not in want and fn.__name__.split("_")[0] not in want:
            continue
        try:
            fn()
        except Exception as e:
            H.emit(T, f"{fn.__name__}_EXCEPTION", repr(e)[:300], "str", "")
            print(f"!! {fn.__name__}: {e}", file=sys.stderr)


if __name__ == "__main__":
    main()
