#!/usr/bin/env python3
"""Benchmark driver for the GC comparison study.

Runs the full cross product of a matrix file against the VM binary.
Workload binaries are generated per (workload, seed) via gen_workload.py
and assembled with gojasm. The VM writes a per-run summary CSV and a
per-collection series CSV; the driver records the summary plus pause
stats computed from the series into results/runs.csv. It computes
nothing else about GC behavior and asserts nothing about the numbers.
"""

import argparse
import csv
import itertools
import json
import math
import os
import statistics
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HARNESS_DIR = Path(__file__).resolve().parent
REPO_ROOT = HARNESS_DIR.parent.parent

CSV_COLUMNS = [
    "run_id",
    "timestamp",
    "binary_mtime",
    "collector",
    "budget",
    "workload",
    "seed",
    "exit_code",
    "status",
    "run_ns",
    "mutator_ns",
    "proc_wall_ns",
    "instructions",
    "bytes_allocated",
    "alloc_count",
    "collections",
    "total_pause_ns",
    "pause_mean_ns",
    "pause_max_ns",
    "pause_p99_ns",
    "peak_watermark",
    "peak_live_bytes",
    "bytes_freed_total",
    "bytes_moved_total",
    "exit_status",
    "reason",
]

SUMMARY_COLUMNS = [
    "run_ns",
    "mutator_ns",
    "instructions",
    "bytes_allocated",
    "alloc_count",
    "peak_watermark",
    "peak_live_bytes",
    "collections",
    "total_pause_ns",
    "max_pause_ns",
    "bytes_freed_total",
    "bytes_moved_total",
    "exit_status",
]

# exit_status column values; the column, not the process exit code, is the
# semantic authority on run outcome.
ES_UNSET, ES_COMPLETED, ES_OOM, ES_FAULT = 0, 1, 2, 3
ES_NAMES = {
    ES_UNSET: "UNSET",
    ES_COMPLETED: "COMPLETED",
    ES_OOM: "OOM",
    ES_FAULT: "FAULT",
}

# Names accepted by gc_create() in gc/src/collectors.c.
KNOWN_COLLECTORS = {"baseline", "mark_sweep", "mark_compact", "cheney", "generational"}


def parse_args():
    ap = argparse.ArgumentParser(description="GC benchmark matrix driver")
    ap.add_argument(
        "--binary",
        required=True,
        default="../../vm/ijvm",
        help="path to the ijvm binary",
    )
    ap.add_argument("--matrix", required=True, help="JSON file of matrix axes")
    ap.add_argument("--results", default="./results", help="results directory")
    ap.add_argument("--timeout", type=float, default=300, help="per-run timeout (s)")
    ap.add_argument(
        "--gojasm",
        default=str(REPO_ROOT / "vm" / "tools" / "gojasm"),
        help="path to the gojasm assembler",
    )
    ap.add_argument(
        "--jasm-config",
        default=str(HARNESS_DIR / "ijvm_heap.conf"),
        help="gojasm opcode config with the heap instructions",
    )
    ap.add_argument(
        "--dry-run", action="store_true", help="print planned commands, run nothing"
    )
    ap.add_argument(
        "--rerun-failed",
        action="store_true",
        help="re-attempt rows whose latest status is not ok/oom",
    )
    return ap.parse_args()


def name_safe(value):
    return isinstance(value, str) and value and not any(c in value for c in " /\\")


def load_matrix(path):
    with open(path) as f:
        matrix = json.load(f)
    for axis in ("collector", "budget", "workload", "seed"):
        if not isinstance(matrix.get(axis), list) or not matrix[axis]:
            sys.exit(f"matrix file is missing a non-empty '{axis}' list")
    if not all(isinstance(s, int) for s in matrix["seed"]):
        sys.exit("matrix 'seed' entries must all be integers")
    iterations = matrix.get("iterations")
    if not isinstance(iterations, int) or iterations < 1:
        sys.exit(
            "matrix file needs a positive integer 'iterations' (scalar, not a list)"
        )
    unknown = set(matrix["collector"]) - KNOWN_COLLECTORS
    if unknown:
        sys.exit(
            f"unknown collector(s) {sorted(unknown)}; "
            f"gc_create accepts {sorted(KNOWN_COLLECTORS)}"
        )
    for axis in ("collector", "workload"):
        bad = [v for v in matrix[axis] if not name_safe(v)]
        if bad:
            sys.exit(f"matrix '{axis}' entries must be filename-safe strings: {bad}")
    return matrix


def enumerate_runs(matrix):
    runs = []
    for collector, budget, workload, seed in itertools.product(
        matrix["collector"], matrix["budget"], matrix["workload"], matrix["seed"]
    ):
        runs.append(
            {
                "run_id": f"{collector}_{workload}_b{budget}_s{seed}",
                "collector": collector,
                "budget": budget,
                "workload": workload,
                "seed": seed,
            }
        )
    return runs


def load_statuses(csv_path):
    """Latest recorded status per run_id (runs.csv is append-only)."""
    statuses = {}
    if csv_path.exists():
        with open(csv_path, newline="") as f:
            reader = csv.DictReader(f)
            if reader.fieldnames != CSV_COLUMNS:
                sys.exit(
                    f"{csv_path} has a different column schema (old driver version?); "
                    "use a fresh --results directory"
                )
            for row in reader:
                statuses[row["run_id"]] = row["status"]
    return statuses


def workload_commands(args, workload, seed, iterations, workloads_dir):
    stem = f"{workload}_s{seed}_i{iterations}"
    jas_path = workloads_dir / f"{stem}.jas"
    ijvm_path = workloads_dir / f"{stem}.ijvm"
    gen_cmd = [
        sys.executable,
        str(HARNESS_DIR / "gen_workload.py"),
        "--family",
        workload,
        "--seed",
        str(seed),
        "--iterations",
        str(iterations),
        "--out",
        str(jas_path),
    ]
    asm_cmd = [args.gojasm, "-c", args.jasm_config, "-o", str(ijvm_path), str(jas_path)]
    return ijvm_path, gen_cmd, asm_cmd


def ensure_workload_binary(args, workload, seed, iterations, workloads_dir):
    """Generate + assemble the .ijvm for one (workload, seed); deterministic,
    so an existing file is reused. Returns (path, None, None) or
    (None, reason, captured_output)."""
    ijvm_path, gen_cmd, asm_cmd = workload_commands(
        args, workload, seed, iterations, workloads_dir
    )
    if ijvm_path.exists():
        return ijvm_path, None, None
    for label, cmd in (("gen_workload.py", gen_cmd), ("gojasm", asm_cmd)):
        try:
            proc = subprocess.run(
                cmd, capture_output=True, text=True, timeout=args.timeout
            )
        except subprocess.TimeoutExpired:
            return None, f"{label} timed out", ""
        if proc.returncode != 0:
            output = f"--- stdout ---\n{proc.stdout}\n--- stderr ---\n{proc.stderr}"
            return None, f"{label} failed with exit code {proc.returncode}", output
    return ijvm_path, None, None


def parse_summary(path):
    """Return the single summary row as a dict of strings, or None."""
    try:
        with open(path, newline="") as f:
            rows = list(csv.DictReader(f))
    except OSError:
        return None
    if len(rows) != 1:
        return None
    row = rows[0]
    if any(row.get(col) in (None, "") for col in SUMMARY_COLUMNS):
        return None
    try:
        int(row["exit_status"])
    except ValueError:
        return None
    return row


def parse_series(path):
    """Return the list of dur_ns values (possibly empty: a header-only series
    file is valid and means zero collections), or None if unreadable."""
    try:
        with open(path, newline="") as f:
            reader = csv.DictReader(f)
            if reader.fieldnames is None or "dur_ns" not in reader.fieldnames:
                return None
            return [int(row["dur_ns"]) for row in reader]
    except (OSError, ValueError):
        return None


def pause_summary(durations):
    """mean/max/p99 (nearest-rank) of pause durations; Nones when empty."""
    if not durations:
        return None, None, None
    durations = sorted(durations)
    p99 = durations[math.ceil(0.99 * len(durations)) - 1]
    return statistics.mean(durations), durations[-1], p99


def vm_command(args, run, binary_path, summary_path, series_path):
    return [
        args.binary,
        "--collector",
        run["collector"],
        "--budget",
        str(run["budget"]),
        "--summary",
        str(summary_path),
        "--series",
        str(series_path),
        str(binary_path),
    ]


def fault_warning(run_id, es_name):
    print(
        f"WARNING: {run_id}: exit_status={es_name} — this indicates a "
        "workload-generator or VM bug, not a collector result",
        file=sys.stderr,
    )


def run_one(args, run, binary_path, summary_path, series_path):
    """Execute one run; return (status, exit_code, proc_wall_ns, summary,
    durations, reason, output)."""
    cmd = vm_command(args, run, binary_path, summary_path, series_path)
    start = time.monotonic_ns()
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=args.timeout)
    except subprocess.TimeoutExpired as e:
        proc_wall_ns = time.monotonic_ns() - start
        output = f"--- stdout ---\n{e.stdout or ''}\n--- stderr ---\n{e.stderr or ''}"
        return (
            "failed",
            None,
            proc_wall_ns,
            None,
            None,
            f"timeout after {args.timeout}s",
            output,
        )
    proc_wall_ns = time.monotonic_ns() - start
    rc = proc.returncode
    output = f"--- stdout ---\n{proc.stdout}\n--- stderr ---\n{proc.stderr}"

    if rc == 1:
        return (
            "failed",
            rc,
            proc_wall_ns,
            None,
            None,
            "setup failure (exit 1)",
            output,
        )
    if rc == 2:
        summary = parse_summary(summary_path)
        es_name = "unreadable"
        if summary is not None:
            es_name = ES_NAMES.get(int(summary["exit_status"]), "unknown")
        fault_warning(run["run_id"], es_name)
        return (
            "failed",
            rc,
            proc_wall_ns,
            None,
            None,
            f"invalid experiment: exit 2, exit_status={es_name}",
            output,
        )
    if rc != 0:
        return (
            "failed",
            rc,
            proc_wall_ns,
            None,
            None,
            f"unexpected exit code {rc}",
            output,
        )

    summary = parse_summary(summary_path)
    if summary is None:
        return (
            "failed",
            rc,
            proc_wall_ns,
            None,
            None,
            "missing/unparseable summary file despite exit 0",
            output,
        )
    es = int(summary["exit_status"])
    if es == ES_UNSET:
        return (
            "failed",
            rc,
            proc_wall_ns,
            None,
            None,
            "exit_status UNSET despite exit 0",
            output,
        )
    if es == ES_FAULT:
        fault_warning(run["run_id"], "FAULT")
        return (
            "failed",
            rc,
            proc_wall_ns,
            None,
            None,
            "invalid experiment: exit_status=FAULT despite exit 0",
            output,
        )
    if es not in (ES_COMPLETED, ES_OOM):
        return (
            "failed",
            rc,
            proc_wall_ns,
            None,
            None,
            f"unknown exit_status value {es}",
            output,
        )

    durations = parse_series(series_path)
    if durations is None:
        return (
            "failed",
            rc,
            proc_wall_ns,
            None,
            None,
            "missing/unparseable series file despite exit 0",
            output,
        )
    status = "oom" if es == ES_OOM else "ok"
    return status, rc, proc_wall_ns, summary, durations, "", output


def append_row(csv_path, row):
    write_header = not csv_path.exists()
    with open(csv_path, "a", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_COLUMNS)
        if write_header:
            writer.writeheader()
        writer.writerow(row)


def main():
    args = parse_args()
    for label, path in (
        ("binary", args.binary),
        ("gojasm", args.gojasm),
        ("gojasm config", args.jasm_config),
    ):
        if not os.path.isfile(path):
            sys.exit(f"{label} not found: {path}")
    matrix = load_matrix(args.matrix)
    iterations = matrix["iterations"]
    runs = enumerate_runs(matrix)

    results_dir = Path(args.results)
    csv_path = results_dir / "runs.csv"
    workloads_dir = results_dir / "workloads"
    summary_dir = results_dir / "summary"
    series_dir = results_dir / "series"
    statuses = load_statuses(csv_path)

    def should_skip(run):
        status = statuses.get(run["run_id"])
        if status in ("ok", "oom"):
            return True
        return status is not None and not args.rerun_failed

    pending = [r for r in runs if not should_skip(r)]
    skipped = len(runs) - len(pending)
    if skipped:
        print(f"skipping {skipped}/{len(runs)} runs already recorded in {csv_path}")

    if args.dry_run:
        shown = set()
        for run in pending:
            pair = (run["workload"], run["seed"])
            ijvm_path, gen_cmd, asm_cmd = workload_commands(
                args, run["workload"], run["seed"], iterations, workloads_dir
            )
            if pair not in shown and not ijvm_path.exists():
                shown.add(pair)
                print("generate: " + " ".join(gen_cmd))
                print("assemble: " + " ".join(asm_cmd))
            summary_path = summary_dir / f"{run['run_id']}.summary.csv"
            series_path = series_dir / f"{run['run_id']}.series.csv"
            print(" ".join(vm_command(args, run, ijvm_path, summary_path, series_path)))
        print(f"dry run: {len(pending)} runs planned, nothing executed")
        return

    results_dir.mkdir(parents=True, exist_ok=True)
    (results_dir / "logs").mkdir(exist_ok=True)
    workloads_dir.mkdir(exist_ok=True)
    summary_dir.mkdir(exist_ok=True)
    series_dir.mkdir(exist_ok=True)
    binary_mtime = int(os.path.getmtime(args.binary))
    workload_cache = {}  # (workload, seed) -> (ijvm_path|None, reason, output)

    for i, run in enumerate(pending, 1):
        pair = (run["workload"], run["seed"])
        if pair not in workload_cache:
            workload_cache[pair] = ensure_workload_binary(
                args, run["workload"], run["seed"], iterations, workloads_dir
            )
        binary_path, gen_reason, gen_output = workload_cache[pair]

        summary_path = summary_dir / f"{run['run_id']}.summary.csv"
        series_path = series_dir / f"{run['run_id']}.series.csv"

        if binary_path is None:
            status, exit_code, proc_wall_ns = "failed", None, None
            summary, durations = None, None
            reason = f"workload generation failed: {gen_reason}"
            output = gen_output
        else:
            status, exit_code, proc_wall_ns, summary, durations, reason, output = (
                run_one(args, run, binary_path, summary_path, series_path)
            )

        row: dict[str, object] = dict.fromkeys(CSV_COLUMNS, "")
        row.update(
            {
                "run_id": run["run_id"],
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "binary_mtime": binary_mtime,
                "collector": run["collector"],
                "budget": run["budget"],
                "workload": run["workload"],
                "seed": run["seed"],
                "exit_code": "" if exit_code is None else exit_code,
                "status": status,
                "proc_wall_ns": "" if proc_wall_ns is None else proc_wall_ns,
                "reason": reason,
            }
        )

        if summary is not None:
            pause_mean, pause_max, pause_p99 = pause_summary(durations)
            row.update(
                {
                    "run_ns": summary["run_ns"],
                    "mutator_ns": summary["mutator_ns"],
                    "instructions": summary["instructions"],
                    "bytes_allocated": summary["bytes_allocated"],
                    "alloc_count": summary["alloc_count"],
                    "collections": summary["collections"],
                    "total_pause_ns": summary["total_pause_ns"],
                    "pause_mean_ns": "" if pause_mean is None else pause_mean,
                    "pause_max_ns": "" if pause_max is None else pause_max,
                    "pause_p99_ns": "" if pause_p99 is None else pause_p99,
                    "peak_watermark": summary["peak_watermark"],
                    "peak_live_bytes": summary["peak_live_bytes"],
                    "bytes_freed_total": summary["bytes_freed_total"],
                    "bytes_moved_total": summary["bytes_moved_total"],
                    "exit_status": summary["exit_status"],
                }
            )

        if status == "failed":
            log_path = results_dir / "logs" / f"{run['run_id']}.log"
            log_path.write_text(f"reason: {reason}\n{output or ''}\n")

        append_row(csv_path, row)
        statuses[run["run_id"]] = status

        config = (
            f"{run['collector']} budget={run['budget']} "
            f"{run['workload']} seed={run['seed']}"
        )
        suffix = f" ({reason})" if reason else ""
        print(f"[{i}/{len(pending)}] {config} -> {status}{suffix}", flush=True)


if __name__ == "__main__":
    main()
