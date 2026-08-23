"""IV-shaped workloads: DuckDB build, Parquet export, random reads, fsync churn.

These are deliberately the same code on every arm (cloud disk / local disk /
httpfs) so a ratio is meaningful.
"""
from __future__ import annotations

import os
import subprocess
import textwrap
import time
from pathlib import Path

DUCKDB = "/usr/local/bin/duckdb"


def duck(sql: str, dbfile: str = "", memory_limit: str = "6GB", threads: int = 4,
         timeout: int = 7200, check: bool = True, extra_init: str = "") -> subprocess.CompletedProcess:
    init = f"SET memory_limit='{memory_limit}'; SET threads={threads}; {extra_init}\n"
    argv = [DUCKDB, "-c", init + sql] if dbfile == "" else [DUCKDB, dbfile, "-c", init + sql]
    p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    if check and p.returncode != 0:
        raise RuntimeError(f"duckdb failed rc={p.returncode}\n{p.stdout}\n{p.stderr}")
    return p


# --------------------------------------------------------------- generators

def gen_parquet_sql(dest: str, rows: int, files: int = 8) -> str:
    """Multi-file Parquet dataset: sequential-write heavy, like a dlt/sqlmesh land step."""
    return textwrap.dedent(f"""
        COPY (
          SELECT
            i AS id,
            (i * 2654435761) % 1000000 AS k,
            i % {files} AS part,
            ('2024-01-01'::DATE + INTERVAL (i % 900) DAY) AS dt,
            hash(i)::VARCHAR AS h,
            repeat(md5((i % 4096)::VARCHAR), 3) AS payload,
            (i % 997) / 7.0 AS amount
          FROM range({rows}) t(i)
        ) TO '{dest}' (FORMAT PARQUET, PARTITION_BY (part), OVERWRITE_OR_IGNORE 1,
                       COMPRESSION ZSTD, ROW_GROUP_SIZE 122880);
    """)


def build_duckdb_sql(rows: int, src_parquet: str | None = None) -> str:
    """Build a .duckdb the way IV builds a dataset: a wide fact + index-ish sort."""
    if src_parquet:
        src = f"SELECT * FROM read_parquet('{src_parquet}')"
    else:
        src = f"""SELECT i AS id, (i * 2654435761) % 1000000 AS k, i % 8 AS part,
                       ('2024-01-01'::DATE + INTERVAL (i % 900) DAY) AS dt,
                       hash(i)::VARCHAR AS h,
                       repeat(md5((i % 4096)::VARCHAR), 3) AS payload,
                       (i % 997) / 7.0 AS amount
                FROM range({rows}) t(i)"""
    return textwrap.dedent(f"""
        CREATE OR REPLACE TABLE fact AS {src};
        CREATE OR REPLACE TABLE dim AS SELECT DISTINCT k, k % 100 AS bucket FROM fact;
        CHECKPOINT;
    """)


def duckdb_integrity(dbfile: str, timeout: int = 3600) -> tuple[bool, str]:
    """Verify every block checksum in a .duckdb file.

    DuckDB 1.5.3 has no `PRAGMA integrity_check` (verified: 'Pragma Function
    with name integrity_check does not exist'). The equivalent is to enable
    debug_verify_blocks and force a full scan of every table, which validates
    the per-block checksums; a corrupted block raises IO Error and the CLI
    exits 1. Confirmed by deliberately flipping bytes in a test db.
    """
    listing = duck("SELECT table_name FROM duckdb_tables();", dbfile=dbfile, check=False)
    if listing.returncode != 0:
        return False, (listing.stdout + listing.stderr)[:300]
    tables = [ln.strip("│ ").strip() for ln in listing.stdout.splitlines()
              if ln.startswith("│") and "table_name" not in ln and "varchar" not in ln]
    tables = [t for t in tables if t and not set(t) <= set("-─")]
    if not tables:
        return False, "no tables found"
    sql = "SET debug_verify_blocks=true;\n" + "\n".join(
        f"SELECT count(*) FROM \"{t}\";" for t in tables)
    p = duck(sql, dbfile=dbfile, check=False, timeout=timeout)
    return p.returncode == 0, (p.stdout + p.stderr)[-300:]


RANDOM_READ_SQL = textwrap.dedent("""
    SELECT count(*), sum(amount), max(h)
    FROM fact
    WHERE id IN (SELECT (hash(g * {seed}) % {maxid})::BIGINT FROM range({n}) t(g));
""")


def random_read_sql(n_points: int, maxid: int, seed: int = 1) -> str:
    return RANDOM_READ_SQL.format(n=n_points, maxid=maxid, seed=seed or 1)


SCAN_SQL = "SELECT part, count(*), sum(amount), avg(k) FROM fact GROUP BY 1 ORDER BY 1;"


def parquet_scan_sql(glob: str) -> str:
    return (f"SELECT part, count(*), sum(amount), avg(k) "
            f"FROM read_parquet('{glob}', hive_partitioning=1) GROUP BY 1 ORDER BY 1;")


def parquet_point_sql(glob: str, n_points: int, maxid: int, seed: int = 1) -> str:
    return textwrap.dedent(f"""
        SELECT count(*), sum(amount), max(h)
        FROM read_parquet('{glob}', hive_partitioning=1)
        WHERE id IN (SELECT (hash(g * {seed}) % {maxid})::BIGINT FROM range({n_points}) t(g));
    """)


# --------------------------------------------------------------- fsync churn

FSYNC_C = r"""
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
int main(int argc, char **argv) {
    const char *path = argv[1];
    long n = atol(argv[2]);
    long bs = argc > 3 ? atol(argv[3]) : 4096;
    char *buf = aligned_alloc(4096, bs);
    memset(buf, 'x', bs);
    int fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd < 0) { perror("open"); return 1; }
    struct timespec a, b;
    clock_gettime(CLOCK_MONOTONIC, &a);
    for (long i = 0; i < n; i++) {
        if (write(fd, buf, bs) != bs) { perror("write"); return 1; }
        if (fdatasync(fd) != 0) { perror("fdatasync"); return 1; }
    }
    clock_gettime(CLOCK_MONOTONIC, &b);
    double el = (b.tv_sec - a.tv_sec) + (b.tv_nsec - a.tv_nsec) / 1e9;
    printf("%.6f %.1f\n", el, n / el);
    close(fd);
    return 0;
}
"""


def fsync_bench(path: str, n: int = 500, bs: int = 4096) -> tuple[float, float]:
    """Returns (elapsed_s, ops_per_s). Pure python fallback if no cc."""
    buf = b"x" * bs
    fd = os.open(path, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o644)
    t0 = time.monotonic()
    try:
        for _ in range(n):
            os.write(fd, buf)
            os.fdatasync(fd)
    finally:
        el = time.monotonic() - t0
        os.close(fd)
    return el, n / el


def dd_write(path: str, mb: int, bs_mb: int = 1, fsync: bool = True) -> float:
    conv = "conv=fsync" if fsync else ""
    t0 = time.monotonic()
    p = subprocess.run(
        f"dd if=/dev/zero of={path} bs={bs_mb}M count={mb // bs_mb} {conv} status=none",
        shell=True, capture_output=True, text=True, timeout=7200)
    el = time.monotonic() - t0
    if p.returncode != 0:
        raise RuntimeError(p.stderr)
    return el
