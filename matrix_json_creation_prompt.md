I need you to author the experiment matrix JSON that drives our GC comparison
study (the file the driver takes via `--matrix`). This is the experimental design
for a bachelor's thesis, so it needs real methodological rigor, not a toy set.
Don't just emit a file — reason about the axes first, then produce it.

## Context you should refresh from the repo

- Read `gc/harness/driver.py` (especially `load_matrix`, `enumerate_runs`) for
  the exact schema and how the cross product is built.
- Read `gc/harness/gen_workload.py` for the workload families and their
  live-set drivers (the params listed under "rigor" below).
- The collectors are NOT implemented yet (baseline is done; mark_sweep /
  mark_compact / cheney are in progress; generational is a stretch stub that
  currently behaves like baseline). So any pilot you run can only use baseline,
  and baseline's `peak_watermark` is CUMULATIVE allocation, not the live set —
  estimate live sets analytically and treat a pilot as a sanity check only.

## Hard schema constraints (the driver's load_matrix rejects anything else)

The JSON has exactly five keys:
- `"collector"`: non-empty list of strings, each ∈ {baseline, mark_sweep,
  mark_compact, cheney, generational}, matching `gc_create` verbatim.
- `"budget"`:    non-empty list of integers (heap capacity in BYTES; the VM's
  `--budget` is the heap byte budget; `DEFAULT_HEAP_CAPACITY` is 1<<20 = 1048576).
- `"workload"`:  non-empty list of strings, each a gen_workload.py family:
  {churn, longlived, mutate, density}.
- `"seed"`:      non-empty list of integers.
- `"iterations"`: a SCALAR positive integer (NOT a list) — the main-loop trip
  count, identical across every run.

The driver runs the full cross product collector × budget × workload × seed,
with iterations applied to all. Validate your file by running the driver with
`--dry-run` and confirming it parses and reports the run count you expect.

## What the study needs to support (drives the axis choices)

Two analyses, per the Handbook conventions:
1. Fix budget, vary collector → throughput-vs-pause comparison.
2. Fix collector, sweep budget → space-vs-time curve.
Plus pause-time distributions (mean/max/p99, MMU/BMU framing), so each run must
produce MANY collections, not two or three.

## Rigor requirements — get these right

1. COLLECTORS: include only the implemented ones. Build the matrix for
   {baseline, mark_sweep, mark_compact, cheney} and make generational a trivial
   one-line addition for later. Note in your rationale that running it now is
   meaningless.

2. BUDGET SWEEP is the subtle axis. The budget is ONE global list crossed with
   ALL workloads, but the workloads have different live sets, so a single sweep
   must span wide enough that EVERY workload gets several budgets in its
   "interesting region" (collections happen frequently, but non-baseline
   collectors don't OOM). Use a geometric sweep (factor ~2). Constraints:
   - The tight end must force frequent collection (near each workload's live set).
   - The loose end must approach saturation (collector rarely fires ≈ baseline).
   - Cheney halves usable heap (semispaces), so it needs ~2× the budget to hold
     the same live set — your sweep must extend high enough that Cheney has a
     non-OOM region for every workload. Cheney OOM at tight budgets is expected
     and is itself a finding (its space cost); keep those runs (OOM is data).

3. CALIBRATE, don't guess. Estimate each workload's live set analytically from
   the gen_workload.py structure (object = 8-byte header + length*4 payload;
   default lengths 4–64; table_size=256, keeper_slots=64, nodes=256,
   churn/density survival≈0.05, density ref_ratio=0.5, mutate alloc_fraction=1/16
   — persistent roots: keeper arrays, node lists/rings, and the baked-in decision
   tables). Then sanity-check with a small pilot: run a couple of workloads at a
   generous budget and read peak_watermark / peak_live_bytes from the summaries
   to confirm your sweep brackets the real live sets. Show the numbers in your
   rationale.

4. SEEDS: enough for statistical validity across workload instances. Use ≥5
   (prefer 5–10). Each seed is a distinct random workload of the same family.

5. ITERATIONS: large enough that steady-state dominates startup AND each mid-
   budget run produces enough collections for a meaningful pause distribution
   (aim for ≥~20 collections per run at mid budgets). Tune it; justify the value.

6. RUNTIME SANITY: report the total run count (|collector|×|budget|×|workload|
   ×|seed|) and a rough wall-time estimate. Keep it tractable (set a sensible
   `--timeout`). If the full cross product is too large, propose a tiered design:
   a dense core matrix for the headline comparisons plus a wider seed sweep on a
   smaller subset — but keep it as ONE valid matrix file unless you justify
   splitting.

## Deliverables
- `gc/harness/matrix.json` (valid against the schema; passes `--dry-run`).
- A short rationale (markdown): the live-set estimates + pilot numbers, why each
  budget/seed/iterations value was chosen, the total run count and time estimate,
  and any coverage caveats (e.g. workloads whose interesting region is thin under
  the global budget list, or Cheney OOM regions).

Reason it through and show the calibration before writing the file.
