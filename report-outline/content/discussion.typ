= Discussion <discussion>

== Answering the research questions

The measurements line up with the textbook trade-offs and put numbers on them. We take
the questions in reverse order, building from the space result to the throughput result
that depends on it.

For *RQ3 (space)*, the Cheney collector pays the semispace penalty predicted by theory:
because only half of the reserved heap is usable at a time, it needs one budget step more
than the non-moving collectors on `density` and a full doubling on the retention-heavy
`longlived` and `mutate`. Since the budget axis doubles at each step, this result bounds
the penalty to within a factor of two and is consistent with the expected ~2× rather than
pinning it precisely. Mark-sweep and mark-compact share an identical frontier on every
workload: they tie on footprint, because both use the whole heap.

For *RQ2 (latency)*, the ordering is the reverse of the space ordering. Cheney's pauses are
the smallest because its work scales with the live set, which is small, rather than with
the heap; this holds even though it collects about twice as often. Mark-compact has the
largest pauses because it makes several passes over the heap (mark, forward, update
references, relocate) and does so even when little actually needs to move. Mark-sweep
sits between the two. Mark-compact can pay a high
_relative_ overhead — up to 19% of run time on `longlived` — and still be a throughput
winner there, because its total run time is so short (10 ms) that even a large pause
fraction is a small absolute cost. High overhead share and high throughput are not in
tension when the run is fast.

For *RQ1 (throughput)*, the two moving collectors are statistically indistinguishable from
each other and both beat mark-sweep at moderate budgets, by 4.0× on `churn` and up to 7.9×
on `longlived`. The overhead data locates the cause precisely, and it is _not_ the
collection. At the 262 KiB budget mark-sweep's total GC overhead is tiny — under 1.1% of
run time on every workload (@tab-pauses) — even on the workloads where it is by far the
slowest collector, so its slowness cannot come from the sweep. (Overhead does climb at the
tightest, near-OOM budgets, where collections fire constantly — up to ~7% on `churn` at
16 KiB and ~21% on `longlived` at 64 KiB — but there the run is short, and the regime that
matters for the throughput gap is the moderate-to-large one below.) The
remaining cost is therefore mutator-side, and the most likely locus is the free-list
allocation path that the sweep repopulates, whose traversal is charged to mutator time
rather than pause time. The budget sweep (@fig-sweep) supports this reading. Mark-sweep's run time _grows_ with the
heap while its overhead, far from rising, falls below 1%, the signature of an allocation
path that gets more expensive as the free lists hold more and larger scattered blocks; the moving
collectors, which allocate with a bump pointer into a compacted heap, stay flat. The 8 MiB
anchor is the control: there no collection fires, so nothing is ever freed, mark-sweep never
touches a free list, and it falls within a standard deviation of the bump-pointer
collectors. We reach this attribution _by elimination_ — overhead measured directly, the
remainder tied to the free-list allocation path by the sweep and anchor controls — rather
than by direct profiling, and we therefore stop short of separating allocation-search cost
from fragmentation, which the harness does not measure individually.

== No universal winner

The practical conclusion is that the right collector depends on the binding constraint.
Under tight memory, mark-sweep and mark-compact share the smallest footprint, but
mark-compact delivers far better throughput at that footprint and is the better choice when
both matter. Where latency matters most and the extra heap is affordable, Cheney gives the
shortest pauses. Where a non-moving collector is required, or for its sheer simplicity,
mark-sweep is reasonable but concedes throughput on retention-heavy workloads, increasingly
so as the heap grows.

On `density` the collector is not the bottleneck:
there, reference-heavy mutator work dominates and the choice of collector moves total run
time by only ~1.3×. This is consistent with the free-list-cost story rather than a
counterexample to it. As noted in @implementation, `density` is matched to `churn` on
allocation volume, so mark-sweep incurs a comparable free-list cost in _absolute_
milliseconds on both; the ratio collapses on `density` only because its
reference-heavy mutator baseline (~164 ms) dwarfs that fixed addend, whereas on `churn`
(~12 ms baseline) the same addend is most of the run time. Allocation strategy matters most,
in relative terms, precisely when the program allocates heavily and does little else, as in
`churn` and `longlived`.

== Limitations and threats to validity

The most important limitation is that the write barrier is currently inert (@implementation):
with no generational collector, the `mutate` workload measures a mutator-heavy,
low-allocation workload rather than the remembered-set cost it was built to expose, and its
numbers should be read on that basis.

Several other factors bound the generalisability of these results. All measurements come
from a single machine (Apple M2 Pro, macOS 15.7.7) with the VM compiled by clang at
`-std=c11` _without optimisation_. This is the most consequential build choice for our
headline RQ1 result, which is a mutator-side cost differential: `-O2` would optimise the
free-list traversal we implicate more than it can optimise an already near-minimal bump
pointer, so it could _narrow_ the 4–7.9× gap. It cannot, however, invert the ordering —
bump allocation has essentially no work for the optimiser to remove — so we claim the
direction of the result as robust while conceding that its magnitude is build-dependent. Timing uses `CLOCK_MONOTONIC` at ~1 µs
effective granularity, so the smallest Cheney pauses are near the timer floor and are
reported as order-of-magnitude. All collectors are stop-the-world and single-threaded, so
the findings say nothing about concurrent or parallel collection. The heaps are small and
the workloads synthetic, chosen to isolate specific allocation behaviours rather than to
mimic real programs, and the budget sweep's doubling granularity limits how precisely the
space frontier can be located. Each configuration is repeated over only eight seeds; the
reported standard deviations are small for most configurations but the maximum-pause figures
in particular are noisy (for example mark-sweep `density` at the tightest 16 KiB budget,
~21 ± 23 µs, where the standard deviation exceeds the mean). Finally, the
precise object model and tagged roots are specific to this VM; a collector for a runtime that
requires conservative scanning would face costs not captured here.
