# Experiment matrix rationale

The matrix (`matrix.json`) drives the GC comparison study. It encodes the full
cross product **collector × budget × workload × seed**, with a single scalar
`iterations` applied to every run. This document shows the calibration behind
each axis: the analytic live-set model, the pilot numbers that validate it, and
the reasoning for every chosen value, plus the coverage caveats.

## Object model (from the VM source)

Confirmed against `vm/include/heap.h` and `vm/src/gc_host.c`:

- Object = **8-byte header** (`sizeof(heap_array)` = two `uint32_t`: length + tags)
  plus **`length * 4`** payload bytes. True for both value arrays (`NEWARRAY`)
  and reference arrays (`ANEWARRAY`) — refs are 4-byte words.
- `alloc` OOMs when `watermark + (8 + length*4) > capacity`; `capacity` is the
  `--budget` byte value. The default is `DEFAULT_HEAP_CAPACITY = 1<<20`.
- Collection is **allocation-failure triggered**: `gc_alloc` does not retry; each
  collector's own `alloc` is expected to collect-then-retry on the
  `HEAP_FULL_SENTINEL`. **baseline never collects**, so it simply OOMs once
  cumulative allocation exceeds the budget. That makes baseline's
  `peak_watermark` a clean readout of **cumulative allocation** (the prompt's
  warning), which is exactly the pilot signal used below. `peak_live_bytes` is 0
  under baseline (it never runs a trace), so **live sets are derived
  analytically** and cross-checked against `bytes_allocated`/`alloc_count`.

Default generator params (`gen_workload.py`): `table_size=256`, `size_min=4`,
`size_max=64` (mean length 34 → **mean array = 8 + 34·4 = 144 B**),
`keeper_slots=64`, `nodes=256`, churn/density `survival=0.05`, density
`ref_ratio=0.5`, mutate `alloc_fraction=1/4` (raised from the generator's original
1/16 — see the mutate coverage note at the end).

## Live-set estimates (analytic) + pilot validation

Persistent roots are held in locals, which `gc_host_enumerate_roots` scans
(the IJVM local-variable area lives in the tagged operand stack), so the decision
tables, keeper arrays, node lists/rings and directory all stay live.

| Workload   | Persistent live objects | **Live set** | Alloc / iter |
|------------|--------------------------|--------------|--------------|
| churn      | 3 value tables (3·1032) + keeper ref-array (264) + 64 survivors (64·144=9216) | **≈ 12.7 KiB** | ≈ 142 B |
| density    | 5 value tables (5·1032) + keeper (264) + 64 survivors (9216) | **≈ 14.8 KiB** | ≈ 142 B |
| longlived  | 1 table (1032) + 256 nodes ×(16 node + 144 payload = 160) = 40 960 | **≈ 42.1 KiB** | ≈ 142 B |
| mutate     | 4 tables (4128) + nodedir (1032) + 256 nodes ×16 (4096) + 256 payloads ×144 (36 864) | **≈ 46.1 KiB** | ≈ 32 B |

A table is a value array of length 256 → 8 + 256·4 = **1032 B**. The keeper is a
64-slot ref array → 8 + 64·4 = 264 B. mutate's nodes are always reachable via the
directory (`nodedir[0..255]`) regardless of `.next` rewrites, so all 256 nodes and
their accumulated payloads stay live.

**Pilot (baseline, `--budget` large enough to avoid OOM):**

| Run | bytes_allocated | alloc_count | mutator_ns |
|-----|-----------------|-------------|------------|
| churn  i2000  | 286 864   | 2004  | 2.30 ms |
| longlived i2000 | 324 984 | 2513  | 0.71 ms |
| density i2000 | 288 928   | 2006  | 9.16 ms |
| churn  i50000 | 7 102 608 | 50004 | 17.8 ms |
| longlived i50000 | 7 140 728 | 50513 | 12.4 ms |
| mutate i50000 | 1 621 680 | 12368 | 24.8 ms |
| density i50000 | 7 104 672 | 50006 | 227 ms |

These confirm the model: alloc rate is **142 B/iter** for churn/longlived/density
and **≈ 32 B/iter** for mutate (`1 621 680 / 50000 ≈ 32`, at the tuned
`alloc_fraction = 1/4` — see the mutate note below). `alloc_count` matches the
structural breakdown exactly (e.g. churn = 3 tables + keeper + 2000 main = 2004).
mutate's i50000 run has ~12 100 payload allocations — far above the ~1567 needed
(coupon-collector over 256 slots, ≈ filled by ~6 300 iterations at 1/4) —
confirming its live set is **saturated** well before iteration 50 000.

## Budget sweep — `2^14 … 2^20` (16 KiB → 1 MiB), factor 2, plus an 8 MiB no-GC anchor — 8 points

One global geometric list crossed with all four workloads. Live sets span
12.7–46.1 KiB (factor 3.6); the seven-point ×2 sweep brackets every workload's
interesting region between "collects constantly" and "collects ≈ never", and the
8 MiB top point is a deliberate off-grid jump (above every workload's *total*
allocation) serving as a no-GC reference (see below).

Estimated collections per run ≈ `total_garbage / (budget − live_set)` (one cycle
allocates `budget − live` of garbage before refilling). With total garbage ≈ 7.1 MB
(churn/longlived/density) and ≈ 1.62 MB (mutate, at `alloc_fraction = 1/4`):

| budget \ workload | churn (L≈12.7K) | density (L≈14.8K) | longlived (L≈42.1K) | mutate (L≈46.1K) |
|-------------------|------:|------:|------:|------:|
| 16 384  | ~1900 | ~4500 | **OOM** (B<L) | **OOM** |
| 32 768  | ~350  | ~395  | **OOM** | **OOM** |
| 65 536  | ~135  | ~140  | ~305  | **~83** |
| 131 072 | ~60   | ~62   | ~80   | **~19** |
| 262 144 | ~28   | ~28   | ~32   | ~8   |
| 524 288 | ~14   | ~14   | ~15   | ~3   |
| 1 048 576 | ~7  | ~7    | ~7    | ~2 (1.62M>1M) |
| 8 388 608 | ~0  | ~0    | ~0    | ~0  (no-GC anchor: budget > total alloc) |

- **Tight end (16 KiB)** sits just above churn/density live sets → hammers them
  with collections; it is below longlived/mutate live sets, so those OOM there
  (a real space-cost finding, kept as data).
- **No-GC anchor (8 MiB)** sits above every workload's *total* cumulative allocation
  (≤ 7.14 MB at 50 000 iters), so **baseline completes** there (its OOM cause
  disappears) and the tracing collectors fire ≈ 0 times. This is the clean
  overhead-free throughput reference for the space–time curves: every collector's
  run time at 8 MiB ≈ pure mutator time, and the cost of collection at the tighter
  budgets is read relative to it.
- **At 16 KiB – 1 MiB, baseline OOMs on every workload** — it never collects, so it
  exhausts the heap as soon as cumulative allocation exceeds the budget (≥ 1.62 MB,
  above 1 MiB). Expected and illustrative (it shows why a collector is needed);
  those rows give only pre-OOM mutator timing, with the completed reference coming
  from the 8 MiB column.
- **Cheney** halves usable heap (two semispaces), so it needs ~2× the budget to
  hold the same live set. Expected Cheney OOM regions (kept — its space cost *is*
  the finding):
  - churn: OOM at 16 384 (usable 8 K < 12.7 K).
  - density: OOM at 16 384 (usable 8 K < 14.8 K).
  - longlived: OOM at 16 384 … 131 072 (usable < 84.2 K); fine at 262 144 +.
  - mutate: OOM at 16 384 … 131 072 (usable < 92.2 K); fine at 262 144 +.
- Non-moving collectors (mark_sweep/mark_compact) OOM only where `budget < live`:
  longlived and mutate at 16 384 and 32 768.

This supports both headline analyses: **fix budget, vary collector** (e.g. at
65 536 or 131 072 the three tracing collectors — mark_sweep, mark_compact, cheney
— all have a non-OOM region for churn/density/longlived, with baseline as the
no-GC control that OOMs and generational currently tracking baseline) and
**fix collector, sweep budget** (4–7 budget points per workload in its non-OOM
range trace the space–time curve).

## Iterations — 50 000 (scalar)

- **Steady state dominates startup.** Startup is ≤ ~42 KB of structure; the main
  loop allocates millions of bytes. mutate's live set is fully saturated by
  ~25 000 iterations (validated above), so 50 000 guarantees steady state for all
  families.
- **Enough collections for pause distributions.** At mid budgets the
  142 B/iter families produce 28–305 collections (≥ 20 target comfortably met
  across 32 768–262 144). See the table above.
- Larger iterations mainly inflate runtime (density is 227 ms/run already) and
  push tight-budget churn/density into the thousands of collections without adding
  analytical value.

## Seeds — 8

`[1, 7, 13, 42, 101, 271, 1009, 9973]`. Each seed is a distinct random instance of
the same family (sizes, survival flags, victim slots, rewrite targets). Eight
exceeds the prompt's ≥5 floor and gives reasonable spread for mean/p99/MMU
statistics across workload instances while keeping the run count tractable. (42
matches the workload already checked into `harness/workload/`.)

## Run count and wall-time

**Run count = |collector| · |budget| · |workload| · |seed| = 5 · 8 · 4 · 8 = 1280.**

Workload binaries are generated once per (workload, seed) = 4 · 8 = **32 `.ijvm`
files**, reused across all collector × budget combinations.

Wall-time: baseline mutator time per i50000 run ranges 12–227 ms (density is the
outlier). Real collectors add GC time (not yet measurable — collectors are
unimplemented), and OOM runs terminate early. Taking a conservative
~0.3–0.7 s/run including GC work and process spawn, **1280 runs ≈ 6–15 minutes**
total. No single run plausibly approaches even 30 s, so run with **`--timeout 120`**
(below the 300 s default, well above any real run). Density at the tightest
budgets with thousands of collections is the only thing to watch; 120 s leaves
ample margin.

## Coverage caveats

1. **mutate's interesting region is still the narrowest, but now usable.** Its
   `alloc_fraction` was raised from 1/16 to **1/4** (in `gen_workload.py`,
   `MUTATE_ALLOC_FRACTION`) precisely to address this: at 1/16 only budget 65 536
   produced ≥ 20 collections; at 1/4 both **65 536 (~83)** and **131 072 (~19)**
   do, with a meaningful trend at 262 144 (~8). 3 of every 4 iterations remain
   pure pointer rewrites, so mutate keeps its identity as a write-barrier /
   remembered-set stressor (the 256 long-lived nodes are still heavily mutated)
   while filling the heap fast enough to exercise the budget sweep. The live set
   and OOM thresholds are unchanged (more frequent payload *replacement* adds no
   live objects). The knob is one line and tunable; 1/2 would widen the region
   further but pushes mutate toward churn-like allocation. The very loose budgets
   (≥ 524 288) still give mutate few collections — lean the densest pause
   histograms on churn / density / longlived there.
2. **OOM rows are expected and retained as data** — both the Cheney semispace OOMs
   and the `budget < live` non-moving OOMs (longlived/mutate at 16–32 KiB) quantify
   each collector's minimum-heap requirement.
3. **baseline only completes at the 8 MiB anchor.** At all budgets 16 KiB – 1 MiB
   it OOMs (cumulative allocation ≥ 1.62 MB > 1 MiB), which is correct for a no-GC
   control and is itself the "why you need a collector" result. The **8 MiB budget**
   was added precisely so there is one completed-run, no-GC *throughput* reference:
   it sits above every workload's total allocation (≤ 7.14 MB), so baseline runs to
   completion and the tracing collectors fire ≈ 0 times. Read the GC throughput
   cost at tighter budgets relative to this column.

## generational

**Included** in the matrix (`"collector"` list) at the author's request, for the
thesis write-up. Caveat for interpretation: the `generational` collector is
currently a stub that behaves identically to baseline, so its recorded numbers
will duplicate baseline's until the real collector is implemented — do not draw
GC conclusions from its current results. Its presence costs one collector ×
8 · 4 · 8 = 256 extra runs.
