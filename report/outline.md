# Thesis Outline — Garbage Collection Strategies for the IJVM

**Author:** Vitor Andrade Fernandez (2798043) · **Supervisor:** Atze van der Ploeg
**VU Amsterdam — BSc Computer Science**

> Status note for supervisor: this is a section-by-section outline (main ideas +
> draft results), not finished prose. All numbers below are from the full
> benchmark matrix (1280 runs: 5 collectors × 8 budgets × 4 workloads × 8 seeds,
> 50 000 iterations each), re-run against the current VM binary. *AI was used to
> help draft and analyse, as previously disclosed.*

---

## Title page
- **Working title:** *Comparing Stop-the-World Garbage Collection Strategies on a
  Stack-Based Bytecode Interpreter: Mark-Sweep, Mark-Compact, and Copying Collection
  for the IJVM.*
- Standard VU front matter (degree, program, supervisor, second reader, date).

## Abstract (~0.25 pg)
Three sentences:
1. **Motivation** — the choice of GC algorithm trades mutator throughput, pause
   latency, and memory footprint against each other, but these trade-offs are rarely
   measured side-by-side under identical conditions on a small, precise VM.
2. **What we did** — added a pluggable garbage-collection layer to the IJVM and
   implemented three canonical collectors (mark-sweep, mark-compact, Cheney copying)
   behind one host interface, plus a deterministic benchmark harness over four
   allocation patterns and a heap-budget sweep.
3. **Finding** — there is no universal winner: Cheney gives the smallest, most
   predictable pauses but needs ~2× the heap; mark-compact and mark-sweep survive the
   tightest budgets; and at moderate-to-loose budgets the moving collectors beat
   mark-sweep on throughput by up to ~5–7× because bump allocation and compaction
   avoid free-list and fragmentation costs.

## Introduction (1 pg)
- **Topic:** automatic memory management; the GC "trade-off triangle" of throughput
  vs. pause time vs. memory.
- **Problem:** the canonical collectors are textbook material, but on a given VM it is
  hard to find an apples-to-apples comparison where *only the collector changes*.
- **Motivation:** a single host interface holds the VM, workloads, and heap fixed and
  swaps the collector underneath — clean comparison, and pedagogically valuable on the
  IJVM already used in the VU OOFP course.
- **Objectives:** (1) implement three collectors behind one interface; (2) build a
  reproducible, seeded harness; (3) measure throughput, pause distribution, and space
  efficiency across four allocation patterns and a budget sweep; (4) relate results to
  textbook expectations.
- **Research questions:**
  - **RQ1 (throughput/overhead):** How do the three collectors compare on mutator
    throughput and total GC overhead as heap pressure varies?
  - **RQ2 (latency):** How do pause-time distributions (mean / max) differ across
    collectors and workloads?
  - **RQ3 (space):** How tight a heap can each collector survive, and what is Cheney's
    semispace penalty in practice?
- Contributions list + one-paragraph thesis outline.

## Background (1.5 pg)
- **IJVM in brief:** Tanenbaum-style stack machine; the heap/array opcodes used here
  (`NEWARRAY`/`ANEWARRAY`, `IALOAD`/`AIALOAD`, `IASTORE`/`AIASTORE`); 8-byte object
  header; **precise** tagging that distinguishes integer arrays from reference arrays,
  so roots and inter-object pointers are known exactly (no conservative scanning).
- **GC fundamentals:** reachability, roots, tracing; the trade-off triangle.
- **The three algorithms (textbook level):**
  - *Mark-Sweep* — mark from roots, sweep dead objects into size-segregated free
    lists; simple, non-moving, but exposed to fragmentation and free-list search cost.
  - *Mark-Compact* — mark, then slide live objects together via a forwarding map and
    fix up all references; removes fragmentation, restores bump allocation, but pays
    several heap passes per collection.
  - *Cheney copying* — two semispaces; copy live objects breadth-first into to-space.
    Allocation is a bump pointer and compaction is implicit, but usable heap is halved.
- Short note on **generational** GC and the weak generational hypothesis (sets up the
  future-work framing).
- **Scope statement:** all collectors are stop-the-world and single-threaded.

## Evaluation Criteria / Implementation (XX pg)
- **The pluggable GC interface — the central design idea.** A `gc_collector` vtable
  (`alloc` / `collect` / `write_barrier` / `destroy`) plus a host-side contract the VM
  implements: root enumeration over the tagged stack, per-object reference enumeration,
  linear heap walk, mark/free bits stored in the object header, forwarding pointers,
  and object relocation. Because every collector consumes the same primitives, the
  comparison isolates the *algorithm*.
- **Per-collector implementation notes:**
  - `baseline` — no-op collect; serves as the pure-mutator reference and the OOM
    frontier marker.
  - `mark_sweep` — size-segregated free lists (64 / 256 / 1024 B + overflow),
    coalescing sweep.
  - `mark_compact` — mark → compute new locations (forwarding map) → update references
    → relocate; bump pointer afterwards.
  - `cheney` — semispace flip, breadth-first forwarding scan.
  - `generational` — **stub only** (no young/old split, no remembered set);
    explicitly out of scope, carried as future work. Honestly flagged.
- **Evaluation criteria (what we measure and why):** mutator throughput
  (`mutator_ns`), total GC overhead (`total_pause_ns`, `collections`), pause
  distribution (mean / max — responsiveness), space efficiency (lowest surviving
  budget, `peak_live_bytes`), and relocation work (`bytes_moved`).
- **Methodology / harness:** the matrix (5 × 8 × 4 × 8 = 1280 runs); deterministic
  seeded workloads at 50 000 iterations for steady state; the budget sweep rationale
  (tight → OOM probe, mid → interesting collection counts, 8 MiB anchor → no GC at
  all). Reproducible via fixed seeds + checked-in config:
  `./driver.py --binary ../../vm/ijvm --matrix ./matrix.json`.
- **Workload families:**

  | Workload | Allocation behavior | Live set | Stresses |
  |---|---|---|---|
  | `churn` | high alloc, ~5% survival | ~12.7 KiB | throughput under churn |
  | `density` | denser reference graphs | ~14.8 KiB | tracing / mutator cost |
  | `longlived` | 256-node retained linked list | ~42 KiB | compaction / fragmentation |
  | `mutate` | ¼ alloc, ¾ pointer mutation | ~46 KiB | write-barrier path |

## Results (2 pg)
> All collectors completed the full matrix. `baseline` and the `generational` stub
> only survive at the 8 MiB anchor (no real collector), so they appear as the
> no-GC reference, not as competitors.

**Finding 1 — Space efficiency (RQ3): Cheney pays a ~2× heap penalty.** Lowest
surviving heap budget (bytes), per collector × workload:

| collector | churn | density | longlived | mutate |
|---|---|---|---|---|
| mark_sweep | 16 384 | 16 384 | 65 536 | 32 768 |
| mark_compact | 16 384 | 16 384 | 65 536 | 32 768 |
| cheney | 16 384 | 32 768 | **131 072** | **65 536** |
| baseline / generational | 8 MiB only | 8 MiB only | 8 MiB only | 8 MiB only |

→ Mark-sweep and mark-compact tolerate the tightest heaps; Cheney consistently needs
the next budget step up (one full doubling on `longlived`/`mutate`), exactly the
semispace cost predicted by theory.

**Finding 2 — Latency (RQ2): Cheney has the smallest pauses, mark-compact the
largest.** Mean and max pause at budget = 262 144 B (averaged over 8 seeds):

| workload | collector | collections | pause mean (ns) | pause max (ns) | moved (KB) |
|---|---|---|---|---|---|
| churn | mark_sweep | 28 | 16 650 | 22 625 | 0 |
| churn | mark_compact | 28 | 46 692 | 57 000 | 47 |
| churn | cheney | 57 | **1 051** | **2 250** | 284 |
| longlived | mark_sweep | 32 | 25 924 | 35 625 | 0 |
| longlived | mark_compact | 32 | 61 425 | 73 375 | 4 |
| longlived | cheney | 81 | 15 046 | 22 625 | 3 320 |

→ Cheney's pause scales with *live* data, not heap size, so its pauses are smallest
even though it collects roughly 2× as often. Mark-compact's multi-pass relocation
gives it the **largest** pauses despite the fewest collections.

**Finding 3 — Throughput (RQ1): at moderate budgets the moving collectors crush
mark-sweep.** Total run time (ms, mean over seeds) at budget = 262 144 B:

| workload | mark_sweep | mark_compact | cheney |
|---|---|---|---|
| churn | 53.0 | 13.4 | **12.3** |
| longlived | 74.2 | 10.3 | **9.9** |
| mutate | 28.8 | 18.3 | **18.1** |
| density | 202.3 | 165.0 | **163.9** |

→ Mark-sweep is up to ~5–7× slower (`longlived`: 74 ms vs ~10 ms) because free-list
allocation plus fragmentation outweigh its zero relocation cost; the moving collectors
keep bump allocation and a compact heap. `density` is **mutator-bound** (~165 ms
across the board) — reference-heavy tracing dominates and collector choice barely moves
the total.

**Finding 4 — The fast path is cheap (no-GC anchor).** At the 8 MiB anchor (zero
collections) every collector is within a few percent of `baseline` (e.g. `churn` ≈
12.5–13.3 ms), confirming the allocation/barrier hooks add negligible overhead when GC
does not fire.

- Planned figures: throughput-vs-budget curves per workload; pause mean/max bars;
  OOM-frontier chart; `bytes_moved` table (0 for mark-sweep; MB-scale for Cheney,
  which copies all live data every cycle; small for mark-compact when the live set is
  already dense).

## Discussion (1.5 pg)
- **Answering the RQs against theory:** results match textbook predictions — Cheney
  trades space for short pauses and fast allocation; mark-compact spends pause time to
  reclaim space without a semispace; mark-sweep is simplest but fragmentation- and
  allocation-cost-bound. The IJVM-scale numbers make the magnitudes concrete (the ~2×
  Cheney heap penalty; mark-sweep's 5–7× throughput loss on retention-heavy workloads).
- **No universal winner:** pick by constraint — tight memory → mark-compact; latency
  sensitivity → Cheney (if you can afford 2× heap); simplicity / non-moving requirement
  → mark-sweep, accepting throughput loss.
- **Workload sensitivity:** `density` shows the collector can be irrelevant when the
  mutator dominates; `longlived` is where allocation strategy matters most.
- **Limitation — the write barrier is currently inert.** `mutate` was designed to
  stress a write barrier, but all implemented collectors use a no-op barrier (it only
  matters once a generational collector exists), so `mutate` currently measures
  ordinary tracing, not remembered-set cost. Flagged honestly.
- **Threats to validity:** stop-the-world single-thread only; small heaps; synthetic
  workloads; single machine; pauses near the microsecond timer floor; precise-root
  assumption specific to this VM.

## Conclusion (0.5 pg)
- Recap contributions: a pluggable GC layer for the IJVM, three working collectors, a
  reproducible seeded harness, and a measured characterization of the throughput /
  latency / space trade-offs.
- One-line answers to RQ1–RQ3.
- **Future work:** complete the generational collector (write barrier + remembered set
  — the `mutate` workload is already built to exercise it); explore incremental or
  concurrent collection; scale to larger and more realistic workloads.

## References
- To add to `thesis.bib` (currently near-empty): Tanenbaum (IJVM / *Structured
  Computer Organization*), McCarthy 1960 (mark-sweep origin), Cheney 1970 (copying
  collection), Jones, Hosking & Moss — *The Garbage Collection Handbook*, Wilson's GC
  survey, Ungar 1984 (generational scavenging).
