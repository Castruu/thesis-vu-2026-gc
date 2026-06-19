#import "@preview/lilaq:0.5.0" as lq

= Results <results>

All 1024 runs completed. Of these, 768 exercise the three collectors under evaluation
(mark-sweep, mark-compact, Cheney); the remaining 256 are the no-op baseline, which never
collects and therefore completes only at the 8 MiB anchor. It appears below as the no-GC
reference, not as a competitor. Every figure averages over the eight seeds ($n = 8$) and
reports the _population_ standard deviation as a measure of seed-to-seed spread. We do not
run a formal significance test; instead we adopt the deliberately conservative heuristic of
calling a difference real only when it exceeds the combined spread of the values compared.
This chapter reports the measurements; @discussion interprets them.

== Space efficiency

@tab-frontier reports the lowest heap budget on which each collector runs each workload
to completion. Mark-sweep and mark-compact share the same, tightest frontier on every
workload. The Cheney collector ties them on `churn` but needs one budget step more on
`density` and a full doubling on the retention-heavy `longlived` and `mutate`. Because
the budget axis doubles at each step, the sweep can only bound a collector's frontier to
within a factor of two; the Cheney result is therefore _consistent with_ the predicted
~2× semispace penalty but is not measured more precisely than that. The frontier is not a
clean multiple of the live set (@tab-workloads): a collector also needs headroom for the
transient garbage allocated between collections, and Cheney additionally loses half its
heap to the inactive semispace. On `longlived`, whose ~42 KiB live set is the largest,
Cheney's 131,072-byte frontier is about 3× the live set, combining semispace halving with
that headroom.

#figure(
  caption: [Lowest surviving heap budget in bytes, per collector and workload. The
  baseline completes only at the 8 MiB anchor.],
  table(
    columns: (auto, auto, auto, auto, auto),
    align: (left, right, right, right, right),
    table.header([*Collector*], [*churn*], [*density*], [*longlived*], [*mutate*]),
    [mark_sweep], [16,384], [16,384], [65,536], [32,768],
    [mark_compact], [16,384], [16,384], [65,536], [32,768],
    [cheney], [16,384], [32,768], [131,072], [65,536],
  ),
) <tab-frontier>

#figure(
  lq.diagram(
    width: 11cm, height: 5cm,
    ylabel: [Lowest surviving budget (KiB)],
    xaxis: (ticks: ((0, [churn]), (1, [density]), (2, [longlived]), (3, [mutate]))),
    legend: (position: left + top),
    lq.bar((-0.25, 0.75, 1.75, 2.75), (16, 16, 64, 32), width: 0.25, label: [mark-sweep]),
    lq.bar((0, 1, 2, 3), (16, 16, 64, 32), width: 0.25, label: [mark-compact]),
    lq.bar((0.25, 1.25, 2.25, 3.25), (16, 32, 128, 64), width: 0.25, label: [cheney]),
  ),
  kind: image, supplement: [Figure],
  caption: [Lowest heap budget (KiB) on which each collector completes each workload.
  Mark-sweep and mark-compact tie everywhere; Cheney needs a strictly larger budget on
  every workload except `churn`, up to a doubling on `longlived` and `mutate`.],
) <fig-frontier>

== GC overhead and pause-time distribution

@tab-pauses reports, at a representative middle budget of 262,144 bytes, the total time
each collector spends paused (its GC overhead, RQ1) alongside the per-collection pause
distribution (RQ2). _Mark-sweep's overhead here is tiny_: at this budget it spends at most
1.1% of run time collecting on any workload, against up to 19% for
mark-compact (@fig-overhead). Even where mark-sweep is the slowest collector overall it
barely collects, so it is not slow because of its collections. The per-collection picture is the reverse (@fig-pauses): Cheney has by
far the smallest mean pause on every workload despite collecting roughly twice as often,
because its work scales with the small live set, while mark-compact has the largest pauses
because of its several heap passes. The relocation column shows that mark-compact's copying work depends on how
scattered the survivors are, not on live-set size — it moves only 4 KiB on `longlived`,
where the retained list is already contiguous, but ~47 KiB on `churn`; Cheney instead
copies the whole live set every collection (3.3 MiB cumulative across 81 collections on
`longlived`). Pauses are timed with `CLOCK_MONOTONIC`, whose effective granularity on the
test machine is ~1 µs (raw per-collection durations are multiples of 1000 ns), so the
~1 µs Cheney `churn` figures sit at the timer floor and should be read as "of order one
microsecond"; the noisy maximum-pause entries (for example mark-compact `churn`) likewise
reflect occasional scheduling spikes on a single seed.

#figure(
  caption: [At a 262,144-byte budget ($n = 8$ seeds): collections, total GC overhead (ms),
  mean pause (µs, ± SD), maximum pause (µs), and cumulative bytes moved (KiB).],
  table(
    columns: (auto, auto, auto, auto, auto, auto, auto),
    align: (left, left, right, right, right, right, right),
    table.header([*Workload*], [*Collector*], [*Colls*], [*Overhead*], [*Mean*], [*Max*], [*Moved*]),
    [churn], [mark_sweep], [28], [0.46], [16.9 ± 0.6], [22.2], [0],
    [churn], [mark_compact], [28], [1.39], [50.5 ± 11.9], [180.8], [47],
    [churn], [cheney], [57], [0.06], [1.1 ± 0.1], [2.8], [284],
    [density], [mark_sweep], [28], [0.50], [18.0 ± 0.7], [26.5], [0],
    [density], [mark_compact], [28], [1.35], [48.9 ± 1.4], [60.4], [48],
    [density], [cheney], [58], [0.18], [3.1 ± 0.6], [7.5], [407],
    [longlived], [mark_sweep], [32], [0.85], [26.5 ± 2.9], [68.5], [0],
    [longlived], [mark_compact], [32], [1.97], [61.4 ± 1.1], [76.4], [4],
    [longlived], [cheney], [81], [1.21], [14.9 ± 0.6], [42.8], [3,319],
    [mutate], [mark_sweep], [6], [0.16], [26.5 ± 2.0], [29.1], [0],
    [mutate], [mark_compact], [6], [0.40], [65.0 ± 3.6], [70.0], [46],
    [mutate], [cheney], [14], [0.15], [10.2 ± 0.2], [12.8], [237],
  ),
) <tab-pauses>

#figure(
  lq.diagram(
    width: 11cm, height: 5.5cm,
    ylabel: [Mean pause (µs)], yscale: "log", ylim: (0.1, 120),
    xaxis: (ticks: ((0, [churn]), (1, [density]), (2, [longlived]), (3, [mutate]))),
    legend: (position: top),
    lq.bar((-0.25, 0.75, 1.75, 2.75), (16.9, 18.0, 26.5, 26.5), width: 0.25, base: 0.1, label: [mark-sweep]),
    lq.bar((0, 1, 2, 3), (50.5, 48.9, 61.4, 65.0), width: 0.25, base: 0.1, label: [mark-compact]),
    lq.bar((0.25, 1.25, 2.25, 3.25), (1.1, 3.1, 14.9, 10.2), width: 0.25, base: 0.1, label: [cheney]),
  ),
  kind: image, supplement: [Figure],
  caption: [Mean collection pause by workload at the 262 KiB budget (logarithmic axis).
  Mark-compact pauses are largest and Cheney's are near the ~1 µs timer floor — the inverse
  of the GC-overhead ordering, since Cheney collects far more often.],
) <fig-pauses>

#figure(
  lq.diagram(
    width: 11cm, height: 5.5cm,
    ylabel: [GC overhead (% of run time)], yscale: "log", ylim: (0.05, 40),
    xaxis: (ticks: ((0, [churn]), (1, [density]), (2, [longlived]), (3, [mutate]))),
    legend: (position: top),
    lq.bar((-0.25, 0.75, 1.75, 2.75), (0.9, 0.2, 1.1, 0.5), width: 0.25, base: 0.05, label: [mark-sweep]),
    lq.bar((0, 1, 2, 3), (10.4, 0.8, 19.3, 2.2), width: 0.25, base: 0.05, label: [mark-compact]),
    lq.bar((0.25, 1.25, 2.25, 3.25), (0.5, 0.1, 12.4, 0.8), width: 0.25, base: 0.05, label: [cheney]),
  ),
  kind: image, supplement: [Figure],
  caption: [Total GC overhead — time spent collecting as a percentage of run time — by
  workload at the 262 KiB budget (logarithmic axis). Mark-sweep's overhead never exceeds
  $1.1%$ on any workload, which is why its throughput deficit cannot be a collection cost.],
) <fig-overhead>

== Throughput

@tab-throughput reports total run time at the same 262,144-byte budget. The two moving
collectors are statistically indistinguishable from each other (their means differ by less
than a combined standard deviation) and both are substantially faster than mark-sweep on
every workload. The speedup of the moving collectors over mark-sweep ranges from 4.0×
(`churn`) to 7.9× (`longlived`); on `density` the ratio is only 1.3× because run time there
is dominated by reference-heavy mutator work rather than by allocation. Since GC overhead
is under 1.1% for mark-sweep (@tab-pauses), this gap is mutator-side, not collection time —
@discussion takes up the cause.

#figure(
  caption: [Total run time in milliseconds (mean ± SD over $n = 8$ seeds) at a
  262,144-byte budget. Lower is better.],
  table(
    columns: (auto, auto, auto, auto),
    align: (left, right, right, right),
    table.header([*Workload*], [*mark_sweep*], [*mark_compact*], [*cheney*]),
    [churn], [53.9 ± 1.8], [13.4 ± 0.5], [12.5 ± 0.3],
    [longlived], [76.0 ± 2.8], [10.2 ± 0.1], [9.7 ± 0.2],
    [mutate], [30.0 ± 0.7], [18.3 ± 0.3], [17.8 ± 0.3],
    [density], [205.3 ± 5.6], [163.5 ± 4.5], [163.2 ± 4.7],
  ),
) <tab-throughput>

== Throughput across the budget sweep

@fig-sweep plots run time across the full budget range for `churn` and `longlived`,
answering RQ1 directly. We show these two because they are the workloads where the effect
is largest; `density` and `mutate` exhibit the same flat-versus-growing shape with smaller
magnitude (the moving collectors flat, mark-sweep rising), and their full sweeps are in the
repository. The moving collectors are essentially flat across all budgets, because
compaction keeps the heap dense regardless of its size. Mark-sweep behaves very
differently: its run time _grows_ as the budget grows (churn: 18 ms at 16 KiB rising to
120 ms at 1 MiB; longlived: 19 ms rising to 150 ms), even though its GC overhead, far from
keeping pace, falls below 1% across this range (it is higher only at the tightest, near-OOM
budgets, where the run is short). At the 8 MiB anchor no collection fires and all three
collapse to the same ~9–13 ms.

#figure(
  grid(columns: 2, column-gutter: 8pt,
    lq.diagram(
      width: 6.2cm, height: 4.6cm,
      title: [churn], xlabel: [Heap budget], ylabel: [Run time (ms)],
      xlim: (-0.3, 6.3),
      xaxis: (ticks: ((0, [16K]), (2, [64K]), (4, [256K]), (6, [1M]))),
      legend: (position: left + top),
      lq.plot((0, 1, 2, 3, 4, 5, 6), (17.8, 17.5, 19.0, 34.2, 53.9, 67.8, 120.1), label: [m-sweep], mark: "o"),
      lq.plot((0, 1, 2, 3, 4, 5, 6), (14.7, 13.7, 13.3, 13.1, 13.4, 13.1, 13.2), label: [m-compact], mark: "s"),
      lq.plot((0, 1, 2, 3, 4, 5, 6), (14.8, 12.8, 12.3, 12.1, 12.5, 12.1, 12.3), label: [cheney], mark: "x"),
    ),
    lq.diagram(
      width: 6.2cm, height: 4.6cm,
      title: [longlived], xlabel: [Heap budget], ylabel: [Run time (ms)],
      xlim: (1.5, 6.5),
      xaxis: (ticks: ((2, [64K]), (4, [256K]), (6, [1M]))),
      legend: (position: right + top),
      lq.plot((2, 3, 4, 5, 6), (19.3, 42.0, 76.0, 94.9, 150.5), label: [m-sweep], mark: "o"),
      lq.plot((2, 3, 4, 5, 6), (16.7, 11.6, 10.2, 9.8, 9.8), label: [m-compact], mark: "s"),
      lq.plot((3, 4, 5, 6), (13.1, 9.7, 8.9, 8.6), label: [cheney], mark: "x"),
    ),
  ),
  kind: image, supplement: [Figure],
  caption: [Run time versus heap budget for `churn` (left) and `longlived` (right), mean
  over $n = 8$ seeds. The moving collectors stay flat as the budget grows while
  mark-sweep's run time climbs, even though its GC overhead stays under ~1%. The 8 MiB
  anchor (no collection) is omitted; `longlived` does not survive below 64 KiB (128 KiB
  for Cheney).],
) <fig-sweep>

== The no-GC anchor

The 8 MiB anchor serves as a control: no collection fires, so run time is pure mutator work
plus the cost of the allocation fast path. @tab-anchor shows every collector within roughly a
standard deviation of the baseline, confirming that the allocation and write-barrier hooks add
negligible overhead when the collector does not run. The small spread between collectors on
`density` (163.2–165.5 ms against a baseline of 163.3 ± 5.0 ms) is well within seed variance
and should be read as ties, not as real differences.

#figure(
  caption: [Total run time in milliseconds (mean ± SD over $n = 8$ seeds) at the 8 MiB
  anchor.],
  table(
    columns: (auto, auto, auto, auto, auto),
    align: (left, right, right, right, right),
    table.header([*Collector*], [*churn*], [*density*], [*longlived*], [*mutate*]),
    [baseline], [12.4 ± 0.2], [163.3 ± 5.0], [8.7 ± 0.2], [17.7 ± 0.2],
    [mark_sweep], [13.2 ± 0.3], [164.7 ± 5.4], [9.4 ± 0.4], [18.0 ± 0.4],
    [mark_compact], [12.4 ± 0.1], [165.5 ± 5.5], [8.7 ± 0.1], [17.9 ± 0.3],
    [cheney], [12.6 ± 0.2], [163.3 ± 4.9], [8.9 ± 0.2], [17.7 ± 0.2],
  ),
) <tab-anchor>
