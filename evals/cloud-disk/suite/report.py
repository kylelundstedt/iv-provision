"""Aggregate results.jsonl into the report tables (and a DuckDB table).

    python report.py results/*.jsonl            # markdown tables to stdout
    python report.py --db out.duckdb results/*.jsonl

Designed for diffing two cloud-disk versions:
    python report.py --compare old.jsonl new.jsonl
"""
from __future__ import annotations

import json
import sys
from collections import defaultdict
from pathlib import Path


def load(paths):
    rows = []
    for p in paths:
        for line in Path(p).read_text().splitlines():
            line = line.strip()
            if line:
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return rows


def pick(rows, metric, arm=None):
    out = [r for r in rows if r["metric"] == metric and (arm is None or r["arm"] == arm)]
    return out[-1]["value"] if out else None


def median(vals):
    v = sorted(x for x in vals if isinstance(x, (int, float)))
    if not v:
        return None
    return v[len(v) // 2]


def med_metric(rows, metric, arm, field=None):
    """Median of `value`, or of an extra field (e.g. mb_per_s) when given."""
    vals = []
    for r in rows:
        if r["metric"] != metric or r["arm"] != arm:
            continue
        v = r.get(field) if field else r["value"]
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            vals.append(v)
    return median(vals)


# (label, metric, extra-field, higher-is-better, {arm: metric-override})
PERF_ROWS = [
    ("Streaming write, 2GB dd (MB/s)", "b1b_dd_write_s", "mb_per_s", True, {}),
    ("Parquet build, 40M rows (s)", "b1_parquet_write_s", None, False, {}),
    ("4K fsync (ops/s)", "b3_fsync_ops_per_s", None, True, {}),
    ("DuckDB checkpoint cycle (s)", "b3b_checkpoint_cycle_s", None, False, {}),
    ("Scan, 2.4GB db (s)", "b2_big_full_scan_s", None, False,
     {"httpfs": "b5_httpfs_scan_s"}),
    ("Random read, 2.4GB db (s)", "b2_big_random_read_s", None, False,
     {"httpfs": "b5_httpfs_point_s"}),
    ("Random read, 123MB db (s)", "b2_small_random_read_s", None, False, {}),
    ("Cold-mount first query (s)", "b4_first_query_cold_s", None, False,
     {"cloud-disk": "b4_first_query_cold_s", "cloud-disk-tuned": "b4_first_query_cold_s"}),
]

ARMS = ["local", "cloud-disk", "cloud-disk-tuned", "cloud-disk-wt", "httpfs"]
# cold-mount results are emitted under composite arm names
ARM_ALIASES = {
    "cloud-disk": ["cloud-disk", "cloud-disk/warm=1G(default)"],
    "cloud-disk-tuned": ["cloud-disk-tuned", "cloud-disk-tuned/warm=8G"],
}


def perf_table(rows):
    lines = ["| workload | " + " | ".join(ARMS) + " | tuned vs local |",
             "|---|" + "---|" * (len(ARMS) + 1)]
    for label, metric, field, higher, overrides in PERF_ROWS:
        cells = []
        vals = {}
        for a in ARMS:
            m = overrides.get(a, metric)
            v = None
            for cand in ARM_ALIASES.get(a, [a]):
                v = med_metric(rows, m, cand, field)
                if v is not None:
                    break
            vals[a] = v
            cells.append("-" if v is None else f"{v:g}")
        loc, tun = vals.get("local"), vals.get("cloud-disk-tuned")
        if loc and tun:
            ratio = (loc / tun) if not higher else (tun / loc)
            rr = f"{ratio:.2f}x"
        else:
            rr = "-"
        lines.append(f"| {label} | " + " | ".join(cells) + f" | {rr} |")
    return "\n".join(lines)


def durability_table(rows):
    lines = ["| scenario | acked MB lost | duckdb intact | recovery mount (s) |", "|---|---|---|---|"]
    for arm, label in [
        ("write-back=true", "daemon SIGKILL, WAL survives (write-back)"),
        ("write-back=false", "daemon SIGKILL, WAL survives (write-through)"),
        ("hostloss/write-back=true", "HOST LOSS, WAL destroyed (write-back)"),
        ("hostloss/write-back=false", "HOST LOSS, WAL destroyed (write-through)"),
    ]:
        pre = "a2" if not arm.startswith("hostloss") else "a4"
        lost = pick(rows, f"{pre}_acked_data_lost_mb", arm)
        ok = pick(rows, f"{pre}_duckdb_integrity_ok", arm)
        rec = pick(rows, f"{pre}_recovery_mount_s", arm)
        lines.append(f"| {label} | {lost} | {ok} | {rec} |")
    return "\n".join(lines)


def to_duckdb(rows, path):
    import duckdb
    con = duckdb.connect(path)
    con.execute("""CREATE OR REPLACE TABLE results(
        run_id VARCHAR, ts DOUBLE, test VARCHAR, arm VARCHAR,
        metric VARCHAR, value VARCHAR, unit VARCHAR, extra JSON)""")
    con.executemany(
        "INSERT INTO results VALUES (?,?,?,?,?,?,?,?)",
        [(r.get("run_id"), r.get("ts"), r.get("test"), r.get("arm"), r.get("metric"),
          str(r.get("value")), r.get("unit"),
          json.dumps({k: v for k, v in r.items()
                      if k not in ("run_id", "ts", "test", "arm", "metric", "value", "unit")}))
         for r in rows])
    print(f"wrote {len(rows)} rows to {path}")


def main():
    args = sys.argv[1:]
    db = None
    if args and args[0] == "--db":
        db = args[1]
        args = args[2:]
    rows = load(args)
    if db:
        to_duckdb(rows, db)
        return
    print("## Performance (median of repeats)\n")
    print(perf_table(rows))
    print("\n## Durability\n")
    print(durability_table(rows))


if __name__ == "__main__":
    main()
