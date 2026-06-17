Update driver_prompt.py (the GC benchmark driver) to match the current VM
output contract. The VM no longer prints a GCSTATS line; it writes two
per-run CSV files. Make the following changes:

## 1. New VM invocation contract

The VM is invoked as:
  ./ijvm --collector <name> --budget <n> --summary <path> --series <path> <binary>

- --summary and --series are paths the driver constructs; the VM fopen()s
  them in "w" mode and writes them at exit. Both must always be passed.
- The positional argument is an IJVM binary produced by gen_workload.py,
  not a workload name. Add a step that calls gen_workload.py with
  (workload, seed) to produce the binary before each run (cache per
  (workload, seed) pair — same pair always yields the same binary, so
  generate once per pair, not once per run).

## 2. Seed axis

- Add "seed" as a required axis in the matrix JSON (a list of integers),
  validated like the other axes. Seeds are fixed constants from the matrix
  file, never generated.
- Remove the --reps flag and the rep field; seeds replace repetition
  (one run per (collector, budget, workload, seed) tuple).
- run_id becomes the human-readable string
  f"{collector}_{workload}_b{budget}_s{seed}" instead of a sha256 hash.
  Field values are filename-safe by construction (validate: no spaces or
  slashes in collector/workload names).

## 3. Per-run output files

- summary path: results/<run_id>.summary.csv
- series path:  results/<run_id>.series.csv
- Delete the results/pauses/ directory logic and the GCSTATS/STATS_KEYS
  parsing entirely (parse_gcstats, OOM_EXIT_CODE, stats dict handling).

## 4. Summary file schema (one header line + one data line)

Columns: run_ns, mutator_ns, instructions, bytes_allocated, alloc_count,
peak_watermark, peak_live_bytes, collections, total_pause_ns, max_pause_ns,
bytes_freed_total, bytes_moved_total, exit_status

- exit_status is an integer enum: 0=UNSET, 1=COMPLETED, 2=OOM, 3=FAULT.
- The exit_status COLUMN is the semantic authority on run outcome, not the
  process exit code.

## 5. Series file schema (one header line + one row per collection)

Columns: t_ns, dur_ns, bytes_freed, bytes_moved, live_bytes, free_bytes,
largest_free_chunk

- Compute pause_mean_ns / pause_max_ns / pause_p99_ns (nearest-rank, keep
  the existing pause_summary math) from the dur_ns column of the series
  file instead of from a JSON pause list.
- A series file containing ONLY the header line is VALID and means zero
  collections (this is baseline's correct behavior, and also occurs for
  other collectors at large budgets). It must produce empty pause stats,
  not a failure.

## 6. Exit-code contract (replaces OOM_EXIT_CODE=42)

- exit 0: run produced valid data (COMPLETED or OOM — read the column to
  distinguish; both are kept as data, status "ok" or "oom").
- exit 1: setup failure (bad args, binary not loadable) — no files were
  written; status "failed".
- exit 2: FAULT or UNSET — invalid experiment. Status "failed", and print
  a loud warning: a fault means a workload-generator or VM bug, not a
  collector result. Keep writing the log file for these.
- Timeout handling stays as is (status "failed").
- Cross-check: if exit code is 0 but the summary file is missing or
  unparseable, or exit_status reads UNSET, treat as "failed" with an
  explanatory reason.

## 7. runs.csv (the append-only index) — update columns

Replace the stats columns with the new summary schema. New CSV_COLUMNS:
run_id, timestamp, binary_mtime, collector, budget, workload, seed,
exit_code, status, run_ns, mutator_ns, proc_wall_ns, instructions,
bytes_allocated, alloc_count, collections, total_pause_ns, pause_mean_ns,
pause_max_ns, pause_p99_ns, peak_watermark, peak_live_bytes,
bytes_freed_total, bytes_moved_total, exit_status, reason

(frag_ratio is gone from the row: fragmentation is now a per-collection
series in the .series.csv files, analyzed separately; don't aggregate it
here.)

## 8. Keep unchanged

- The skip/rerun-failed resume logic keyed on run_id (it still works with
  readable run_ids).
- --dry-run (update the printed command to the new argv shape).
- Per-failure log files under results/logs/.
- Append-only runs.csv with header-on-create.

Also update KNOWN_COLLECTORS to exactly the names gc_create() accepts —
check gc/src/collectors.c and use its strings verbatim rather than
guessing.
