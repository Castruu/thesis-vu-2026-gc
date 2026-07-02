= Implementation and Methodology <implementation>

Where MMTk (@background) realises the shared-interface idea at production scale, the interface here is far smaller.
This chapter describes that pluggable GC interface, the collectors built on it, the metrics we use to evaluate them, and the benchmark harness that produces the measurements.

== A pluggable collector interface

The central design idea is that every collector implements the same small interface and is handed the same primitives by the virtual machine (@fig-interface).
A collector exposes four operations: allocate an object, collect, apply a write barrier on a pointer store, and destroy.
In return the VM provides a host-side contract: enumerate the roots (the reference-tagged slots of the operand stack, as described in @heap-model), enumerate the references within a given object, walk the heap linearly, read and write the mark and free bits stored in the object header, install and read forwarding pointers, and relocate an object.
Because all collectors consume exactly these primitives, swapping one for another changes nothing else in the system, and any measured difference is attributable to the algorithm rather than to a different allocator, object layout, or root-scanning strategy.

#figure(
  image("/resources/interface.svg", width: 92%),
  caption: [The pluggable collector interface. The VM exposes a fixed set of host
    primitives to one interface that every collector implements, so swapping the collector
    changes nothing else in the system.],
) <fig-interface>

== The collectors

We evaluate four collectors against a no-op baseline, summarised in @tab-collectors.
The _baseline_ never collects; it allocates until the heap is exhausted and serves both as a pure-mutator throughput reference and as a marker of the point at which a heap budget is simply too small.
The four collectors realise the algorithms of @background.
The generational collector is the only one that uses the interface's write-barrier hook; the other three leave it inert.

#figure(
  caption: [The evaluated collectors and their key implementation choices.],
  table(
    columns: (auto, auto, auto),
    align: (left, left, left),
    table.header([*Collector*], [*Allocation*], [*Reclamation*]),
    [baseline], [bump pointer], [none (reference only)],
    [mark_sweep], [size-segregated free lists], [mark, then sweep into free lists],
    [mark_compact], [bump pointer], [mark, forward, update refs, relocate],
    [cheney], [bump pointer in one semispace], [copy live to the other semispace],
    [generational], [bump pointer in nursery], [copy nursery survivors to old generation; mark-compact the whole heap when it fills],
  ),
) <tab-collectors>

=== The generational collector <sec-generational>

The generational collector is the one collector that combines two of the others instead of implementing a single textbook algorithm, so its mechanism warrants a closer description than @tab-collectors gives.
It divides the single heap into two generations by address: a low _old_ (tenured) generation and a high _young_ _nursery_, separated by a movable boundary `nursery_start`.
On the first allocation it places that boundary three quarters of the way up the heap, so the nursery is the top quarter and the old generation the bottom three quarters, and points the watermark at `nursery_start`.
The mutator then allocates straight into the nursery with the same bump pointer the other collectors use (`raw_alloc`); only when a collection promotes survivors does the old generation grow.

The collector follows the _weak generational hypothesis_ (@background): it collects the nursery often and cheaply, and the old generation only when forced to.
A _minor_ collection is a Cheney-style copy (@background) restricted to the nursery: it forwards every reference reachable from the roots that points into the nursery, copying the target down into the old generation and leaving a forwarding pointer, then scans the freshly promoted objects breadth-first for further nursery pointers.
Promotion is immediate (a survivor is tenured the first time it is found live, with no intermediate ageing), and a promoted object is carved out of the old generation's free space with `split_block`, which also yields the remaining free block.
Because the IJVM has no nursery-local roots beyond the stack, a minor collection would miss any pointer that lives in an _old_ object and points _into_ the nursery, which the write barrier exists to prevent.
On every reference store the barrier checks whether an old object is being made to point at a young one and, if so, appends the (object, slot-index) pair to a _remembered set_ (a growable array).
A minor collection treats those recorded slots as extra roots, so old$arrow.r$young pointers are followed and updated, and clears the set afterward.
After a minor collection the watermark is reset to `nursery_start`, reclaiming the whole nursery at once.

A _major_ collection reclaims the old generation as well. Rather than implement a second algorithm, the generational collector _reuses the mark-compact collector as a sub-collector_: it instantiates a `mark_compact` instance at construction and, on a major collection, delegates to its `collect`, which mark-compacts the entire heap to the base.
It then re-establishes the boundary, splitting the remaining free space evenly (a 50/50 old/young split of what is left) so allocation can resume.
A small router decides between the two on each collection: if the free space left in the old generation cannot accommodate the bytes currently used in the nursery (plus headroom), a worst-case minor collection might not fit its survivors, so a major collection runs; otherwise a minor collection runs.
Under a tight heap the old generation fills and majors fire regularly, which lets the generational collector match the non-moving collectors' space frontier (@results) instead of paying Cheney's permanent half-heap penalty.

One implementation interaction is worth flagging because it shapes the measurements.
Because array payloads are zero-initialised on allocation (see below), carving a survivor out of the old generation's free block with `split_block` re-initialises the _remainder_ of that block, which is nearly the entire free old generation, and each split leaves one large remainder block for the next, so this happens on _every_ promotion.
A minor collection's cost therefore scales with the number of survivors it promotes times the old generation's free space: the first minor collection, which promotes the whole startup-built structure, costs time proportional to the heap budget and is the dominant term in the generational collector's largest pauses (@results, @discussion); subsequent collections are cheap because they promote few or no survivors, not because the remainder shrinks.

== Evaluation criteria

We judge the collectors on the three axes of the trade-off triangle, using the metrics below.
_Mutator throughput_ is the time the program spends outside the collector, reported as total run time minus total pause time.
_GC overhead_ is the total time spent paused and the number of collections triggered.
_Pause distribution_ is the mean and maximum collection pause, which capture responsiveness.
_Space efficiency_ is the lowest heap budget on which a collector can run a workload to completion without running out of memory.
Finally, _relocation work_ is the number of bytes a moving collector copies, which is zero for the non-moving mark-sweep collector.

== Benchmark methodology

The study runs the full cross product of a configuration matrix: five collector configurations (the four collectors under evaluation plus the no-op baseline reference), eight heap budgets (16, 32, 64, 128, 256, and 512 KiB and 1 MiB, doubling at each step, plus an 8 MiB no-collection anchor reached by a deliberate $times 8$ jump), four workloads, and eight random seeds, for a total of 1280 runs, of which 1024 exercise the four collectors and the remaining 256 the baseline.
Each run executes 50,000 iterations of its workload so that steady-state behaviour, not start-up, dominates the measurement.

Each benchmark is itself an IJVM program. The pipeline is: a generator emits a workload as
IJVM assembly (`.jas`); the `gojasm` assembler translates it to a bytecode binary
(`.ijvm`); the IJVM then executes that binary under one of the collectors, which manages
the program's heap as it runs the array instructions of @background; and the VM writes the
measurements to disk, where a driver collects them. The two halves of this pipeline (the
generator and the driver) are described in the next two subsections. Everything is checked
into the repository#footnote[https://github.com/Castruu/thesis-vu-2026-gc], and a single
command reproduces the entire study.

The budget sweep is chosen to bracket the interesting region: the tightest budgets probe where each collector runs out of memory, the middle budgets produce enough collections to measure pause behaviour, and the 8 MiB anchor is large enough that almost no collection fires (only Cheney collects once on the higher-allocation workloads, at negligible cost), isolating pure mutator throughput.
The range is set relative to the workloads' live sets (@tab-workloads): the tightest budgets sit at or below the larger live sets so that the out-of-memory frontier falls inside the sweep.
The live-set figure quoted for each workload is its _peak live bytes_: the largest number of reachable bytes the collectors report at the start of a collection, measured at the 256 KiB budget, including object headers, and averaged over the eight seeds. The generational collector is excluded from this figure because it records the old-generation high-water mark rather than the true reachable set, so its peak-live value is not comparable with the others'.
The averaged figure is stable across seeds because the workloads' retained structure is seed-independent, even though the exact peak at any single collection point shifts with collection timing.

All runs were performed on an Apple M2 Pro (10 cores, 32 GiB RAM) running macOS 15.7.7, with the VM and collectors compiled by clang at `-std=c11` _without optimisation_.
Time is wall-clock, measured with `CLOCK_MONOTONIC` at roughly 1 µs effective granularity.
Array payloads are zero-initialised on allocation, so a tracing collector never follows an uninitialised slot as if it were a reference; this applies uniformly to every collector and so does not bias the comparison.

== Workload generation

A workload is not a hand-written program but the output of a generator parameterised by a _family_, a _seed_, and an _iteration count_.
The generator's defining property is that all randomness is resolved at generation time: a single seeded pseudo-random stream draws a set of small fixed-length _decision tables_ (for example the size of each allocation, whether it survives, and which slot it overwrites) and bakes them into the emitted program as integer arrays.
The program itself contains no random-number generator.
Its main loop walks the tables through a single index that wraps around at the table length (256 entries by default), so successive iterations vary their behaviour without the program growing: the emitted file is proportional to the table size and independent of the iteration count.
Two properties follow.
First, the same (family, seed) always produces a byte-identical program, so every collector and budget runs exactly the same bytecode.
Second, per-iteration variety comes entirely from the baked tables, never from a runtime decision.

Allocations are arrays built with the heap instructions of @background: `NEWARRAY` for integer arrays and `ANEWARRAY` for reference arrays, with `IASTORE`/`AIASTORE` and `IALOAD`/`AIALOAD` to write and read their elements.
Array lengths are drawn uniformly from 4 to 64 elements.
The four families differ in what they allocate and in what they keep reachable (i.e. in the shape of garbage they present to the collector):

/ churn: Builds a long-lived _keeper_ reference array of 64 slots. Each iteration allocates
  one integer array; that array is immediately dead unless, with probability 0.05, it is
  stored into a (seeded) keeper slot, evicting and thereby killing the previous occupant.
  The result is a heavy stream of short-lived garbage over a small, roughly constant live
  set.

/ longlived: Builds a singly linked list of 256 nodes at start-up, each node a two-slot
  reference array holding a _next_ pointer and a value-array payload. The main loop then
  allocates and immediately drops an array each iteration, churning short-lived garbage
  against a large, permanently reachable structure that every collection must trace and, for
  the moving collectors, relocate.

/ mutate: Builds a directory of 256 ring-linked nodes. Each iteration rewrites a pointer
  (setting one node's _next_ field to another node via `AIASTORE`), and only on one iteration
  in four replaces a node's payload with a freshly allocated array (the old payload dies).
  This is mostly pointer mutation with little allocation; the rewrite is precisely the operation recorded by the generational write barrier (@sec-generational).

/ density: Like churn (a 64-slot keeper, 5% survival), but each iteration allocates either a
  reference array (with probability 0.5) whose every slot points at the live keeper, or an
  integer array filled with a constant. It therefore matches churn's allocation behaviour
  while producing reference-dense objects that cost more to trace. Because the generator
  draws the per-iteration sizes before the array kinds, `churn` and `density` issue the same
  sequence of per-iteration allocation sizes under a given seed (each allocating \~6.9 MiB
  across about 50,000 arrays, matched to within 0.04%), differing in reference density. This lets us separate allocation cost
  from tracing cost when we compare them in @results.

All four families share the same main-loop skeleton and differ only in what they allocate and what they keep reachable.
Each iteration reads its parameters from the decision tables at the current index, performs its allocation, conditionally retains the new object or rewrites a pointer, and then advances the index (wrapping back to the start at the table length).
The churn loop is the simplest instance of this skeleton:

```text
keeper ← new ref array[64]        // long-lived survivors
idx ← 0
repeat ITERATIONS times:
    obj ← new int array[size[idx]]  // NEWARRAY; old obj dies
    if survive[idx] = 1:            // ~5% of iterations
        keeper[victim[idx]] ← obj   // AIASTORE; old ref dies
    idx ← (idx + 1) mod 256
```

#figure(
  caption: [The four workload families and the behaviour each exercises. Live set is peak
    reachable bytes (measured at the 256 KiB budget).],
  table(
    columns: (auto, auto, auto, auto),
    align: (left, left, right, left),
    table.header([*Workload*], [*Allocation behaviour*], [*Live set*], [*Stresses*]),
    [churn], [high alloc, \~5% survival], [\~5.1 KiB], [throughput under churn],
    [density], [denser reference graphs], [\~7.1 KiB], [tracing / mutator cost],
    [longlived], [256-node retained list], [\~41 KiB], [compaction / fragmentation],
    [mutate], [¼ alloc, ¾ pointer mutation], [\~17 KiB], [mutator-heavy, low alloc],
  ),
) <tab-workloads>

== Benchmark harness (driver)

A driver script turns the matrix into individual runs and records their results.
It enumerates the cross product into one run per (collector, budget, workload, seed) combination, each identified by a readable run id such as `mark_sweep_churn_b262144_s42`.
Because a generated program depends only on its family and seed, the driver builds each of the 32 distinct programs (four families $times$ eight seeds) once, caches the assembled binary, and reuses it across the forty collector $times$ budget combinations that need it.
This guarantees that the collectors are compared on byte-identical bytecode.

For each run the driver invokes the VM, passing the collector name, the heap budget, and two output paths, and the VM writes its measurements to those files instead of to its standard output.
The first is a per-run _summary_ recording run time, mutator time, allocation and collection counts, peak watermark and peak live bytes, total and maximum pause time, bytes freed and moved, and a final exit status.
The second is a _series_ with one row per collection, giving that collection's duration and the heap occupancy around it.
The driver records the summary verbatim and computes only the pause-time distribution (the mean and maximum of the per-collection durations, with a 99th percentile retained in `runs.csv` but not analysed here) from the series; it performs no other interpretation of the numbers.

The authority on a run's outcome is the summary's exit-status field, not the process exit code.
A status of _completed_ is recorded as `ok`; _out of memory_ is recorded as `oom` and is itself a valid experimental result.
It defines the space-efficiency frontier of @results, marking budgets too small for a given collector.
A fault or unset status, an unparseable output, or a timeout is recorded as `failed` and logged for inspection.
Each completed run appends one fully populated row with the raw summary plus the computed pause statistics to an append-only master table, `runs.csv`, which is the single file from which the tables and figures of @results are derived; the per-run summary and series files and the assembled programs are retained alongside it.
Because the master table is append-only and keyed by run id, an interrupted sweep resumes simply by skipping the runs already recorded, and the entire 1280-run matrix is driven by one invocation.
As an equivalence check, `runs.csv` confirms that the choice of collector does not change what the program does: across all 233 (workload, budget, seed) configurations completed by more than one collector, every collector executed the identical instruction count and the identical number of allocations, with no discrepancy.
The collectors thus differ only in how they reclaim memory, not in the computation they run.
