# Task: benchmark driver for a GC comparison study

Write a single Python 3 script, `/gc/harness/driver.py`, that runs a matrix of benchmark
configurations against a VM binary and collects results. Generate ONLY this
script — no analysis/plotting code, no Makefile, no README. Stdlib only.

The driver is deliberately dumb: it runs configurations and records numbers.
It computes nothing about GC behavior except summary stats of the pause list,
and asserts nothing about what the numbers should be.

## The binary contract (the VM under test behaves exactly like this)

Invocation:
    ./ijvm --collector NAME --budget BYTES workload.ijvm
    (--collector {baseline,marksweep,markcompact,copying}, --budget INT bytes,
     final positional arg = workload file path)

Exit codes: 0 = clean completion; 42 = workload hit heap OOM — an EXPECTED
outcome for any collector at tight budgets, record it as status=oom, not as
an error; anything else = failure.

On exit (including OOM) the binary prints exactly one line to stdout
starting with `GCSTATS ` followed by a single JSON object:
GCSTATS {"instructions":123,"bytes_allocated":456,"collections":7,
"pauses":[[5000,1200],[9000,1900]],"peak_watermark":890,"bytes_moved":0,
"frag_ratio":0.0,"wall_ns":99999}
`pauses` is the raw per-collection list of [start_ns, duration_ns] pairs
(possibly empty; start is relative to run start). All other stdout/stderr
is ignored, but captured to a log on failure.

## CLI of driver.py

driver.py --binary PATH
          --matrix FILE.json        # schema below
          --results DIR             # default ./results
          --reps INT                # default 5
          --timeout SECONDS         # default 300, per run
          [--dry-run]               # print planned commands, run nothing
          [--rerun-failed]          # re-attempt rows with status != ok/oom

Matrix file schema — a JSON object of axes; the driver runs the full
cross product:
{
  "collector": ["baseline","marksweep"],
  "budget":    [65536, 262144, 1048576],
  "workload":  ["workloads/churn_s42.jas", "workloads/longlived_s42.jas"]
}

## Behavior

Runs are STRICTLY SEQUENTIAL — never parallel, no process pools, no
threads: concurrent runs contend for the machine and corrupt timing.
Print one progress line per run (i/total, config, status).

For each (collector, budget, workload) × rep (1..reps):
1. run_id = short deterministic hash of (collector, budget, workload, rep).
   Idempotent resume: skip run_ids already in runs.csv with status ok or
   oom (unless --rerun-failed and the row failed).
2. Execute with subprocess + timeout; wall-clock the whole process as a
   sanity column (the binary's own wall_ns is authoritative for analysis).
3. Parse the GCSTATS line. Timeout, missing/unparseable GCSTATS, or
   unexpected exit code → record status=failed with a reason string, save
   captured stdout+stderr to results/logs/<run_id>.log, CONTINUE the matrix.
4. Compute pause summary in the driver from the durations: mean, max, p99
   (empty-safe: null when no pauses).
5. Append one row to results/runs.csv (create with header if absent):
   run_id, timestamp, binary_mtime, collector, budget, workload, rep,
   exit_code, status, wall_ns, proc_wall_ns, instructions,
   bytes_allocated, collections, pause_mean_ns, pause_max_ns,
   pause_p99_ns, peak_watermark, bytes_moved, frag_ratio
6. Write the raw pause pairs to results/pauses/<run_id>.json (skip if
   empty).
