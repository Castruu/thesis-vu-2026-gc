= Implementation and Methodology <implementation>

Where MMTk (@background) realises the shared-interface idea at production scale, the
interface here is deliberately minimal. This chapter describes that pluggable GC interface,
the four collectors built on it, the metrics we use to evaluate them, and the benchmark
harness that produces the measurements.

== A pluggable collector interface

The central design idea is that every collector implements the same small interface and
is handed the same primitives by the virtual machine. A collector exposes four
operations: allocate an object, collect, apply a write barrier on a pointer store, and
destroy. In return the VM provides a host-side contract: enumerate the roots over the
tagged operand stack, enumerate the references within a given object, walk the heap
linearly, read and write the mark and free bits stored in the object header, install and
read forwarding pointers, and relocate an object. Because all collectors consume exactly
these primitives, swapping one for another changes nothing else in the system, and any
measured difference is attributable to the algorithm rather than to a different
allocator, object layout, or root-scanning strategy.

== The collectors

We evaluate three collectors against a no-op baseline, summarised in @tab-collectors. The
_baseline_ never collects; it allocates until the heap is exhausted and serves both as a
pure-mutator throughput reference and as a marker of the point at which a heap budget is
simply too small. The three collectors realise the algorithms of @background. The
interface also reserves a write-barrier hook for a generational collector, which is left
to future work (@conclusion) and is not part of this evaluation.

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
  ),
) <tab-collectors>

== Evaluation criteria

The collectors are judged on the three axes of the trade-off triangle, made concrete by
the following metrics. _Mutator throughput_ is the time the program spends outside the
collector, reported as total run time minus total pause time. _GC overhead_ is the total
time spent paused and the number of collections triggered. _Pause distribution_ is the
mean and maximum collection pause, which capture responsiveness. _Space efficiency_ is
the lowest heap budget on which a collector can run a workload to completion without
running out of memory. Finally, _relocation work_ is the number of bytes a moving
collector copies, which is zero for the non-moving mark-sweep collector.

== Benchmark methodology

The harness runs the full cross product of a configuration matrix: four collector
configurations (the three collectors under evaluation plus the no-op baseline reference),
eight heap budgets ranging from 16 KiB to 8 MiB, four workloads, and eight random seeds,
for a total of 1024 runs — of which 768 exercise the three collectors. Each run executes
50,000 iterations of its workload so that steady-state behaviour, rather than start-up,
dominates the measurement.

Reproducibility is built in. Each workload is generated deterministically from its seed,
assembled once, and reused across every collector and budget, so all collectors run
byte-identical programs. The matrix and the assembler configuration are checked into the
repository#footnote[#text(fill: red)[TODO: insert repository URL before submission.]],
and a single command reproduces the entire study. The budget sweep is chosen
to bracket the interesting region: the tightest budgets probe where each collector runs
out of memory, the middle budgets produce enough collections to measure pause behaviour,
and the 8 MiB anchor is large enough that no collection ever fires, isolating pure
mutator throughput.

The budget range and iteration count are chosen relative to the workloads' live sets
(@tab-workloads): the tightest budgets sit at or below the larger live sets so that the
out-of-memory frontier falls inside the sweep, while 50,000 iterations is enough for every
workload to reach and hold its steady-state live set rather than measuring transient
start-up. The live-set figure quoted for each workload is its _peak live bytes_: the
largest number of reachable bytes any collector reports at the start of a collection,
measured at the 262 KiB budget, including object headers, and averaged over the eight seeds.
It is essentially deterministic — the seed-to-seed spread is under 7% — because the
workloads' retained structure is seed-independent.

One workload dimension is currently dormant. `mutate` is built so that most iterations
overwrite an existing array element rather than allocate, which is the access pattern a
write barrier exists to track. Because all collectors in this study use a no-op write
barrier (a barrier only does work once a generational collector exists, see
@background), `mutate` presently measures a mutator-heavy, low-allocation workload rather
than barrier cost; we report it on that basis and return to it as future work.

All runs were performed on a single machine: an Apple M2 Pro (10 cores, 32 GiB RAM) running
macOS 15.7.7, with the VM and collectors compiled by clang at `-std=c11` _without
optimisation_. Time is wall-clock, measured with `CLOCK_MONOTONIC` at roughly 1 µs effective
granularity.

The four workloads, summarised in @tab-workloads, exercise different allocation
behaviours. _churn_ allocates rapidly but keeps almost nothing alive; _density_ builds
denser reference graphs to stress tracing; _longlived_ retains a linked structure of 256
nodes to stress retention and fragmentation; and _mutate_ mostly overwrites existing
array elements rather than allocating (see the dormant-dimension note above). `churn` and
`density` are deliberately matched on allocation volume — each issues ~7.2 MB across about
50,000 allocations — and differ only in how reference-heavy the surviving graph is, which
lets us separate allocation cost from tracing cost when we compare them in @results.

#figure(
  caption: [The four workload families and the behaviour each exercises. Live set is peak
  reachable bytes (measured at the 262 KiB budget).],
  table(
    columns: (auto, auto, auto, auto),
    align: (left, left, right, left),
    table.header([*Workload*], [*Allocation behaviour*], [*Live set*], [*Stresses*]),
    [churn], [high alloc, \~5% survival], [\~5.3 KiB], [throughput under churn],
    [density], [denser reference graphs], [\~7.3 KiB], [tracing / mutator cost],
    [longlived], [256-node retained list], [\~42 KiB], [compaction / fragmentation],
    [mutate], [¼ alloc, ¾ pointer mutation], [\~17 KiB], [mutator-heavy, low alloc],
  ),
) <tab-workloads>
