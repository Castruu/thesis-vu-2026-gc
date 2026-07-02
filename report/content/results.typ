#import "@preview/lilaq:0.5.0" as lq

= Results <results>

All 1280 runs produced a valid result: 946 completed (`ok`) and 334 ran out of memory (`oom`); none faulted.
Of these, 1024 exercise the four collectors under evaluation (mark-sweep, mark-compact, Cheney, generational); the remaining 256 are the no-op baseline, which never collects and therefore completes only at the 8 MiB anchor.
It appears below only as a no-GC reference.
Every figure averages over the eight seeds ($n = 8$) and reports the _population_ standard deviation as a measure of seed-to-seed spread.
We do not run a formal significance test; instead we treat a difference as real only when it exceeds the combined spread of the values compared.
This chapter reports the measurements; @discussion interprets them.

== Space efficiency

@tab-frontier reports the lowest heap budget on which each collector runs each workload
to completion on all eight seeds. Mark-sweep, mark-compact, and the generational collector
share the same, tightest frontier on every workload. The Cheney collector ties them on
`churn` but needs exactly one budget step more (a 2$times$ heap) on `density`, `longlived`, and
`mutate` alike. Because the budget axis doubles at each step
across the frontier region, the sweep can only bound a collector's frontier to within a
factor of two; the Cheney result is therefore _consistent with_ the predicted \~2$times$ semispace
penalty but is not measured more precisely than that. The frontier criterion is also strict:
all eight seeds must complete, and just below the frontier, completion is often partial, not
absent (Cheney completes seven of the eight `density` seeds at 16 KiB, so its extra step
there rests on a single seed). The frontier is not a clean multiple
of the live set (@tab-workloads): a collector also needs headroom for the transient garbage
allocated between collections, and Cheney additionally loses half its heap to the inactive
semispace. On `longlived`, whose \~41 KiB live set is the largest, Cheney's 128 KiB
frontier is about 3$times$ the live set, combining semispace halving with that headroom. The
generational collector escapes Cheney's penalty even though it too is a copying collector:
it reserves no permanent half-heap, and under tight budgets its router falls back to a
full-heap major collection (a mark-compact of the whole heap, @sec-generational) that
reclaims everything, so its frontier coincides with the non-moving collectors' rather than
with Cheney's.

#figure(
  caption: [Lowest heap budget at which all eight seeds complete, per collector and
    workload. The baseline completes only at the 8 MiB anchor.],
  table(
    columns: (auto, auto, auto, auto, auto),
    align: (left, right, right, right, right),
    table.header([*Collector*], [*churn*], [*density*], [*longlived*], [*mutate*]),
    [mark_sweep], [16 KiB], [16 KiB], [64 KiB], [32 KiB],
    [mark_compact], [16 KiB], [16 KiB], [64 KiB], [32 KiB],
    [cheney], [16 KiB], [32 KiB], [128 KiB], [64 KiB],
    [generational], [16 KiB], [16 KiB], [64 KiB], [32 KiB],
  ),
) <tab-frontier>

== GC overhead and pause-time distribution

@tab-pauses reports, at a representative middle budget of 262,144 bytes (256 KiB), the total time
each collector spends paused (its GC overhead, RQ1; reported in milliseconds and, in
@fig-overhead, as a percentage of run time) alongside the per-collection pause
distribution (RQ2). Mark-sweep's overhead here is small: at this budget it spends at most
1.1% of run time collecting on any workload, against up to 18% for
mark-compact (@fig-overhead). Even where mark-sweep is the slowest collector overall, it
barely collects, so it is not slow because of its collections. The generational collector
sits at the high end of the overhead range (8.0–9.4% on `churn`, `longlived`, and `mutate`). On the
high-churn workloads this is because it collects far more often than the others (93 collections
on `churn`, about nine of them full-heap majors, against mark-compact's 28), not because any single collection is expensive; on
`mutate` its collections are fewer but individually dearer, since its minor collections must each process the pointers the
write barrier records (@discussion). Only on `density` does the overhead stay low, diluted by that
workload's long mutator baseline. The per-collection picture
is the reverse (@fig-pauses): Cheney's pauses are near the \~1 µs timer floor on the
high-churn workloads, where its work scales with a tiny live set, while the generational
collector has the smallest mean pause on `longlived` (8.3 µs) because a minor collection
touches only the nursery, not the whole retained list; mark-compact has the largest pauses
because of its several heap passes. The generational collector's pauses are the most
heavy-tailed: its mean stays low, but its maximum is set by its _first_ collection, which
promotes the startup-built structure into the old generation, re-initialising the free
old-generation reserve once per promoted survivor (739.9 µs on `longlived` against an 8.3 µs mean; this
cost scales with the budget, @discussion). The router additionally fires a full-heap _major_
collection, which mark-compacts the entire heap, whenever objects that were promoted and
have since died fill the old generation: at this budget that happens about nine times per
run on `churn` and `density` and two to three times on `mutate` but never on `longlived`,
and majors grow more frequent as the budget tightens. The
relocation column shows that
mark-compact's copying work depends on how scattered the survivors are, not on live-set
size: it moves only 4 KiB on `longlived`, where the retained list is already contiguous,
but \~47 KiB on `churn`; Cheney instead copies the whole live set every collection (3.2 MiB
cumulative across 81 collections on `longlived`), whereas the generational collector copies
only young survivors (56 KiB on `longlived`, \~60$times$ less than Cheney). Pauses are timed with
`CLOCK_MONOTONIC`, whose effective granularity on the test machine is \~1 µs (raw
per-collection durations are multiples of 1000 ns), so the \~1 µs Cheney `churn` figures sit
at the timer floor and should be read as "of order one microsecond"; the large
maximum-pause entries for the generational collector reflect its one expensive first
collection, not scheduling noise (their seed-to-seed spread is small, e.g.
739.9 ± 26.1 µs on `longlived`).

#figure(
  caption: [At the 256 KiB budget ($n = 8$ seeds): collections, total GC overhead (ms),
    mean pause (µs, ± SD), maximum pause (µs), and cumulative bytes moved (KiB).],
  table(
    columns: (auto, auto, auto, auto, auto, auto, auto),
    align: (left, left, right, right, right, right, right),
    table.header([*Workload*], [*Collector*], [*Colls*], [*Overhead*], [*Mean*], [*Max*], [*Moved*]),
    [churn], [mark_sweep], [28], [0.45], [16.4 ± 0.4], [21.4], [0],
    [churn], [mark_compact], [28], [1.27], [46.0 ± 1.5], [55.1], [47],
    [churn], [cheney], [57], [0.06], [1.0 ± 0.1], [2.4], [284],
    [churn], [generational], [93], [1.33], [14.5 ± 3.3], [47.6], [161],
    [density], [mark_sweep], [28], [0.48], [17.3 ± 0.6], [23.1], [0],
    [density], [mark_compact], [28], [1.35], [48.7 ± 1.2], [61.2], [48],
    [density], [cheney], [58], [0.17], [2.9 ± 0.6], [7.4], [407],
    [density], [generational], [94], [1.39], [15.2 ± 3.4], [54.9], [162],
    [longlived], [mark_sweep], [32], [0.80], [24.9 ± 0.5], [32.8], [0],
    [longlived], [mark_compact], [32], [1.98], [61.5 ± 1.6], [72.6], [4],
    [longlived], [cheney], [81], [1.21], [15.0 ± 0.3], [23.4], [3319],
    [longlived], [generational], [110], [0.91], [8.3 ± 0.3], [739.9], [56],
    [mutate], [mark_sweep], [6], [0.16], [25.7 ± 1.1], [27.8], [0],
    [mutate], [mark_compact], [6], [0.39], [64.4 ± 3.6], [71.5], [46],
    [mutate], [cheney], [14], [0.15], [10.6 ± 0.3], [14.8], [237],
    [mutate], [generational], [21], [1.58], [73.8 ± 2.0], [486.1], [169],
  ),
) <tab-pauses>

#figure(
  lq.diagram(
    width: 11cm,
    height: 5.5cm,
    ylabel: [Mean pause (µs)],
    yscale: "log",
    ylim: (0.1, 120),
    xaxis: (ticks: ((0, [churn]), (1, [density]), (2, [longlived]), (3, [mutate]))),
    legend: (position: top),
    lq.bar((-0.3, 0.7, 1.7, 2.7), (16.4, 17.3, 24.9, 25.7), width: 0.2, base: 0.1, label: [mark-sweep]),
    lq.bar((-0.1, 0.9, 1.9, 2.9), (46.0, 48.7, 61.5, 64.4), width: 0.2, base: 0.1, label: [mark-compact]),
    lq.bar((0.1, 1.1, 2.1, 3.1), (1.0, 2.9, 15.0, 10.6), width: 0.2, base: 0.1, label: [cheney]),
    lq.bar((0.3, 1.3, 2.3, 3.3), (14.5, 15.2, 8.3, 73.8), width: 0.2, base: 0.1, label: [generational]),
  ),
  kind: image,
  supplement: [Figure],
  caption: [Mean collection pause by workload at the 256 KiB budget (logarithmic axis).
    Mark-compact pauses are largest and Cheney's sit near the \~1 µs timer floor on the
    high-churn workloads; the generational collector's _mean_ pause is small (smallest of all on
    `longlived`), but its maximum is far larger because of its one expensive first collection
    (@tab-pauses).],
) <fig-pauses>

#figure(
  lq.diagram(
    width: 11cm,
    height: 5.5cm,
    ylabel: [GC overhead (% of run time)],
    yscale: "log",
    ylim: (0.05, 40),
    xaxis: (ticks: ((0, [churn]), (1, [density]), (2, [longlived]), (3, [mutate]))),
    legend: (position: top),
    lq.bar((-0.3, 0.7, 1.7, 2.7), (0.8, 0.2, 1.1, 0.5), width: 0.2, base: 0.05, label: [mark-sweep]),
    lq.bar((-0.1, 0.9, 1.9, 2.9), (9.2, 0.8, 18.2, 2.2), width: 0.2, base: 0.05, label: [mark-compact]),
    lq.bar((0.1, 1.1, 2.1, 3.1), (0.5, 0.1, 11.7, 0.8), width: 0.2, base: 0.05, label: [cheney]),
    lq.bar((0.3, 1.3, 2.3, 3.3), (9.4, 0.8, 9.2, 8.0), width: 0.2, base: 0.05, label: [generational]),
  ),
  kind: image,
  supplement: [Figure],
  caption: [Total GC overhead (time spent collecting as a percentage of run time) by
    workload at the 256 KiB budget (logarithmic axis). Mark-sweep's overhead never exceeds
    $1.1%$ on any workload, which is why its throughput deficit cannot be a collection cost;
    the generational collector's overhead is comparable to mark-compact's because it
    collects far more often.],
) <fig-overhead>

== Throughput

@tab-throughput reports total run time at the same 256 KiB budget. The two moving
collectors and the generational collector cluster tightly together and are all faster than
mark-sweep on every workload. On the allocation-bound workloads the speedup over mark-sweep
is 4.0$times$ (`churn`) and up to 7.6$times$ (`longlived`); on the low-allocation `mutate` it is \~1.7$times$,
and on `density` only \~1.2$times$, because run time there is dominated by reference-heavy mutator
work rather than by allocation (recall `churn` and `density` are matched on allocation
volume, @implementation). Differences _among_ the three fast collectors are small (at most
\~1.5 ms on `churn`, `longlived`, and `mutate`; \~3.7 ms on `density`, well within its
\~4–6 ms seed spread): Cheney is marginally fastest on the
allocation-heavy `churn`, the generational collector is marginally fastest on `longlived`
(where its minor collections trace only the nursery, not the whole retained list), and
mark-compact and Cheney edge it out on `mutate`, whose remembered-set traffic the
generational write barrier must service (RQ4). Since mark-sweep barely collects at this
budget (@tab-pauses), its gap to the others is mutator-side, not collection-side. @discussion
takes up the cause.

#figure(
  caption: [Total run time in milliseconds (mean ± SD over $n = 8$ seeds) at the
    256 KiB budget. Lower is better.],
  table(
    columns: (auto, auto, auto, auto, auto),
    align: (left, right, right, right, right),
    table.header([*Workload*], [*mark_sweep*], [*mark_compact*], [*cheney*], [*generational*]),
    [churn], [54.4 ± 0.7], [13.8 ± 0.2], [12.7 ± 0.1], [14.0 ± 0.4],
    [density], [200.9 ± 6.6], [163.9 ± 5.7], [164.2 ± 3.9], [167.6 ± 5.6],
    [longlived], [75.5 ± 5.4], [10.9 ± 0.2], [10.4 ± 0.4], [9.9 ± 0.2],
    [mutate], [30.0 ± 1.3], [18.1 ± 0.3], [18.4 ± 0.7], [19.6 ± 0.3],
  ),
) <tab-throughput>

== Throughput across the budget sweep

@fig-sweep plots run time across the full budget range for `churn` and `longlived`,
answering RQ1 directly. We show these two because they are the workloads where the effect
is largest; `density` and `mutate` exhibit the same flat-versus-growing shape with smaller
magnitude (the moving collectors flat, mark-sweep rising), and their full sweeps appear in
@fig-sweep-extra in Appendix A. The moving and generational collectors are essentially flat
across all budgets, because compaction keeps the heap dense regardless of its size.
Mark-sweep behaves very differently: its run time _grows_ as the budget grows (churn: 18 ms
at 16 KiB rising to 122 ms at 1 MiB; longlived: 19 ms rising to 150 ms), even though its GC
overhead, far from keeping pace, falls below 1% across this range (it is higher only at the
tightest, near-OOM budgets, where the run is short). The generational collector is the one
that ticks _up_ slightly at the largest budgets on `longlived` (10 ms at 256 KiB to 12 ms at
1 MiB): a bigger nursery lets each major collection span more of the heap, so its rare
mark-compact passes cost more. At the 8 MiB anchor almost no collection fires for the three
non-generational collectors (only Cheney collects once), and they collapse to the same \~9–13 ms; the generational
collector is the exception and is discussed with the anchor in @sec-anchor.

#figure(
  grid(
    columns: 2,
    column-gutter: 8pt,
    lq.diagram(
      width: 6.2cm,
      height: 4.6cm,
      title: [churn],
      xlabel: [Heap budget],
      ylabel: [Run time (ms)],
      xlim: (-0.3, 6.3),
      xaxis: (ticks: ((0, [16K]), (2, [64K]), (4, [256K]), (6, [1M]))),
      legend: (position: left + top),
      lq.plot((0, 1, 2, 3, 4, 5, 6), (18.2, 17.8, 19.5, 35.2, 54.4, 64.9, 121.8), label: [m-sweep], mark: "o"),
      lq.plot((0, 1, 2, 3, 4, 5, 6), (15.6, 14.4, 14.1, 13.9, 13.8, 14.0, 14.1), label: [m-compact], mark: "s"),
      lq.plot((0, 1, 2, 3, 4, 5, 6), (15.9, 13.5, 12.9, 12.9, 12.7, 13.2, 12.6), label: [cheney], mark: "x"),
      lq.plot((0, 1, 2, 3, 4, 5, 6), (15.3, 14.2, 14.2, 13.8, 14.0, 14.4, 14.4), label: [generational], mark: "+"),
    ),
    lq.diagram(
      width: 6.2cm,
      height: 4.6cm,
      title: [longlived],
      xlabel: [Heap budget],
      ylabel: [Run time (ms)],
      xlim: (1.5, 6.5),
      xaxis: (ticks: ((2, [64K]), (4, [256K]), (6, [1M]))),
      legend: (position: right + top),
      lq.plot((2, 3, 4, 5, 6), (19.5, 42.1, 75.5, 92.0, 148.5), label: [m-sweep], mark: "o"),
      lq.plot((2, 3, 4, 5, 6), (17.3, 12.2, 10.9, 11.0, 10.4), label: [m-compact], mark: "s"),
      lq.plot((3, 4, 5, 6), (13.6, 10.4, 9.8, 9.3), label: [cheney], mark: "x"),
      lq.plot((2, 3, 4, 5, 6), (16.8, 10.1, 9.9, 11.0, 12.3), label: [generational], mark: "+"),
    ),
  ),
  kind: image,
  supplement: [Figure],
  caption: [Run time versus heap budget for `churn` (left) and `longlived` (right), mean
    over $n = 8$ seeds. The moving and generational collectors stay roughly flat as the
    budget grows while mark-sweep's run time climbs, even though its GC overhead stays under
    \~1%. The 8 MiB anchor (no collection) is omitted; `longlived` does not survive below
    64 KiB (128 KiB for Cheney).],
) <fig-sweep>

== The no-GC anchor <sec-anchor>

The 8 MiB anchor serves as a control: for the three non-generational collectors almost no
collection fires (only Cheney collects once on the higher-allocation workloads, a single
negligible pause), so run time is essentially pure mutator work plus the cost of the
allocation fast path. @tab-anchor shows each of those collectors within roughly a standard
deviation of the baseline, with one marginal exception: mark-sweep on `longlived` sits
0.5 ms (\~5%) above it, just outside the combined seed spread, a residual consistent with its
allocation path checking its (empty) free lists on every allocation. The allocation and
write-barrier hooks otherwise add negligible overhead when the collector does not run.
The small spread between them on `density` (165.3–168.4 ms against a baseline of
166.4 ± 3.9 ms) is well within seed variance and should be read as ties, not as real
differences.
The generational collector is the exception, and deliberately so: because it sizes its
nursery at one quarter of the heap rather than using all of it, even an 8 MiB heap fills the
2 MiB nursery on the high-allocation workloads (which allocate \~6.9 MiB) and triggers a
handful of collections (three on `churn`, `density`, and `longlived`; on the low-allocation
`mutate` a single seed collects once, which produces the wide ± 6.0 ms spread in @tab-anchor). The anchor is therefore _not_ a pure-mutator control for the
generational collector, which is why its anchor times sit above the others. The effect is
pronounced on `longlived` (35.5 ms against \~9 ms for the rest): there the first collection
promotes the startup-built list and initialises the multi-megabyte old-generation reserve in
a single \~26 ms pause that dominates the run. The 8 MiB `longlived` anchor is the
large-budget tail of the behaviour in @fig-sweep, and we attribute it in @discussion.

#figure(
  caption: [Total run time in milliseconds (mean ± SD over $n = 8$ seeds) at the 8 MiB
    anchor.],
  table(
    columns: (auto, auto, auto, auto, auto),
    align: (left, right, right, right, right),
    table.header([*Collector*], [*churn*], [*density*], [*longlived*], [*mutate*]),
    [baseline], [13.4 ± 0.6], [166.4 ± 3.9], [9.4 ± 0.2], [18.4 ± 0.3],
    [mark_sweep], [13.5 ± 0.2], [168.2 ± 5.2], [9.9 ± 0.2], [18.5 ± 1.2],
    [mark_compact], [13.2 ± 0.4], [168.4 ± 4.7], [9.6 ± 0.6], [18.4 ± 0.5],
    [cheney], [13.3 ± 0.3], [165.3 ± 5.5], [9.8 ± 0.2], [18.1 ± 0.5],
    [generational], [15.2 ± 0.7], [167.8 ± 5.0], [35.5 ± 0.4], [20.4 ± 6.0],
  ),
) <tab-anchor>

@discussion interprets these measurements per research question.
