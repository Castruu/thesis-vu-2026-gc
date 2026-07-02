= Discussion <discussion>

== Answering the research questions

The measurements line up with the textbook trade-offs and put numbers on them.
We take the first three questions in reverse order, building from the space result to the throughput result that depends on it, and then draw the three together for the generational collector (RQ4).

For *RQ3 (space)*, the Cheney collector pays the semispace penalty predicted by theory: because only half of the reserved heap is usable at a time, it needs exactly one budget step more (a 2$times$ heap) than the non-moving collectors on `density`, `longlived`, and `mutate` alike.
As @results notes, the doubling budget axis bounds this penalty to within a factor of two, consistent with the expected \~2$times$ without pinning it precisely.
Mark-sweep and mark-compact share an identical frontier on every workload: they tie on footprint, because both use the whole heap.
The generational collector, although it too copies, escapes Cheney's penalty and shares the non-moving frontier: it reserves no permanent semispace, and when the old generation cannot absorb the nursery its router falls back to a full-heap mark-compact that reclaims all of memory, so under tight budgets it degrades gracefully into its mark-compact sub-collector and pays for space exactly what mark-compact does.

For *RQ2 (latency)*, the ordering is the reverse of the space ordering.
Cheney's pauses are the smallest on the high-churn workloads because its work scales with the live set, which is small, not with the heap; this holds even though it collects two to two-and-a-half times as often.
Mark-compact has the largest pauses because it makes several passes over the heap (mark, forward, update references, relocate) and does so even when little actually needs to move.
Mark-sweep sits between the two.
Mark-compact can pay a high _relative_ overhead (up to 18% of run time on `longlived`) and still be a throughput winner there, because its total run time is so short (\~11 ms) that even a large pause fraction is a small absolute cost.
The generational collector splits the latency picture in two.
Its _mean_ pause is the smallest of all on `longlived` (8.3 µs), because a minor collection traces only the nursery and ignores the large retained list sitting in the old generation, which is the payoff the generational hypothesis predicts.
Its _maximum_ pause, however, is the largest and most heavy-tailed: its first collection promotes the startup-built structure, re-initialising the old-generation reserve as it goes, at a cost that grows with the heap (739.9 µs on `longlived` at 256 KiB, \~26 ms at the 8 MiB anchor), and under tight heaps its full-heap major collections add further spikes.
The generational collector thus trades a low typical pause for a worse worst case, as the standard generational latency profile predicts; here that worst case is aggravated by an implementation cost we discuss below.

For *RQ1 (throughput)*, the two moving collectors and the generational collector cluster together and all beat mark-sweep at moderate budgets, by \~4$times$ on `churn` and up to 7.6$times$ on `longlived` (where the generational collector is in fact marginally the fastest of all, because its minor collections never touch the retained list).
The overhead data rules the collection out as the cause.
At the 256 KiB budget mark-sweep's total GC overhead is tiny: under 1.1% of run time on every workload (@tab-pauses), even on the workloads where it is by far the slowest collector, so its slowness cannot come from the sweep.
(Overhead does climb at the tightest, near-OOM budgets, where collections fire constantly: up to \~7% on `churn` at 16 KiB and \~21% on `longlived` at 64 KiB, but there the run is short, and the regime that matters for the throughput gap is the moderate-to-large one below.) The remaining cost is therefore mutator-side, and the most likely locus is the free-list allocation path that the sweep repopulates, whose traversal is charged to mutator time instead of pause time.
The budget sweep (@fig-sweep) supports this reading.
Mark-sweep's run time _grows_ with the heap while its overhead, far from rising, falls below 1%, which is what one would expect if the cost is in an allocation path that gets more expensive as the free space it walks is scattered across an ever-larger heap span; the moving collectors, which allocate with a bump pointer into a compacted heap, stay flat.
The 8 MiB anchor is the control: there no collection fires, so nothing is ever freed, mark-sweep's free lists stay empty, and it falls within a standard deviation of the bump-pointer collectors (its allocation path still checks those empty lists, leaving a residual \~0.5 ms against the baseline on `longlived`, @results).
We reach this attribution _by elimination_ (overhead measured directly, the remainder tied to the free-list allocation path by the sweep and anchor controls) rather than by direct profiling, and we therefore stop short of separating allocation-search cost from fragmentation, which the harness does not measure individually.

*RQ4 (generational)* draws the previous three results together for the one collector that spans the design space.
The answer to its first half is yes: the generational collector reaches the moving collectors' throughput, clustering with them to within seed variance (within \~1.5 ms on `churn`, `longlived`, and `mutate`) and running marginally the fastest of all on `longlived` (@tab-throughput), while sharing the non-moving collectors' tightest space frontier (@tab-frontier). It obtains copying-collector speed without Cheney's half-heap footprint.
The cost of that combination has two parts.
The first shows up on the mutation-heavy workload: on `mutate` the generational collector is the slowest of the fast collectors (19.6 ms against mark-compact's 18.1 ms) and carries the highest GC overhead of any collector on that workload (8.0% against at most 2.2% for the others, @fig-overhead).
Two effects combine here, and the harness does not separate them: the nursery is only a quarter of the heap, so it fills quickly and triggers more collections (21 against mark-compact's 6, all but two or three of them minor), and each minor collection must process the old$arrow.r$young pointers the write barrier records.
The barrier's own mutator-side cost is not measured in isolation, so we attribute the \~1.5 ms gap to this combination, not to the barrier alone.
The second part is the worst-case pause already seen under RQ2: the generational collector's maximum pause is the largest of all (486.1 µs on `mutate`, and larger still on `longlived`), set by its first collection and its full-heap major collections.
Part of that tail is a fixable initialisation artefact, not an algorithmic cost, as the limitations below explain.

== Choosing a collector

Which collector is best depends on which resource is scarcest.
Under tight memory, mark-sweep and mark-compact share the smallest footprint, but mark-compact delivers several times the throughput at that footprint and is the better choice when both matter.
The generational collector is the most balanced collector: it matches mark-compact's footprint and throughput while delivering the lowest _typical_ pause on retention-heavy workloads, so it is the best choice when average latency and space both matter at once.
Its weakness is the worst case: its first collection and its major collections are expensive. Where a bounded _maximum_ pause is what matters, Cheney, whose pauses stay near the timer floor on the high-churn workloads and never spike, remains preferable when the extra heap is affordable.
Where a non-moving collector is required, or for its simplicity, mark-sweep is reasonable but concedes throughput on retention-heavy workloads, increasingly so as the heap grows.

On `density` the collector is not the bottleneck: there, reference-heavy mutator work dominates and the choice of collector moves total run time by only \~1.2$times$.
This too is consistent with the free-list-cost story.
As noted in @implementation, `density` is matched to `churn` on allocation volume, so mark-sweep incurs a comparable free-list cost in _absolute_ milliseconds on both; the ratio collapses on `density` only because its reference-heavy mutator baseline (\~164 ms) dwarfs that fixed addend, whereas on `churn` (\~12 ms baseline) the same addend is most of the run time.
Allocation strategy matters most, in relative terms, precisely when the program allocates heavily and does little else, as in `churn` and `longlived`.

== Limitations and threats to validity

The most important limitation concerns the generational collector, which is a deliberately simple instance of the design and is not tuned: it sizes the nursery by a fixed heuristic (a quarter of the heap initially, then half of the free space left after each major collection), promotes every survivor on its first collection with no intermediate ageing, and has a single old generation collected by full-heap mark-compact.
A more careful design (an ageing nursery, a split tuned to the live set instead of a fixed fraction, an old generation that need not be compacted in full) would likely cut both its major-collection cost and its promotion rate.
A second, more pointed limitation is that the generational collector's largest pauses are inflated by an implementation artefact rather than by the algorithm: because array payloads are zero-initialised on allocation (@implementation), carving each promoted survivor out of the old generation re-initialises the remaining multi-megabyte reserve, so the first collection, which promotes the whole startup-built structure, costs time proportional to the heap budget (it is what produces the \~26 ms pause and the 35.5 ms run time at the 8 MiB `longlived` anchor, @results).
This is not fundamental to generational collection; a one-time bulk zero of the reserve, or initialising only the bytes actually handed out, would remove it, and the generational throughput and mean-pause results should be read as the algorithm's, with this first-collection spike noted as a fixable cost.

Several other factors bound the generalisability of these results.
All measurements come from a single machine (Apple M2 Pro, macOS 15.7.7) with the VM compiled by clang at `-std=c11` _without optimisation_.
The optimisation level is held fixed for the same reason as the workloads, seeds, budgets, and machine: so that the collector is the only variable that changes.
This is not a neutral choice between collectors, since `-O0` plausibly penalises the code-heavy free-list path more than the near-minimal bump pointer, and a different fixed level would shift the _absolute_ numbers.
It does not, however, threaten the _ordering_ of the collectors or its _attribution_, which are what this study asks about: a bump-pointer allocation is already close to the least work a machine can do (a load, an add, a bounds check, and a store), leaving the optimiser almost nothing to remove, whereas the free-list walk has loops and branches that `-O2` can speed up, so optimisation can narrow the throughput gap but not reverse it.
We therefore trade some realism, as we already do in choosing synthetic workloads, for the ability to attribute differences to the collector alone, and make no claim that `-O0` is more realistic than the optimised builds production collectors run.
Timing uses `CLOCK_MONOTONIC` at \~1 µs effective granularity, so the smallest Cheney pauses are near the timer floor and are reported as order-of-magnitude.
All collectors are stop-the-world and single-threaded, so the findings say nothing about concurrent or parallel collection.
The heaps are small and the workloads synthetic, chosen to isolate specific allocation behaviours, not to mimic real programs, and the budget sweep's doubling granularity limits how precisely the space frontier can be located.
Each configuration is repeated over only eight seeds; the reported standard deviations are small for most configurations, but the maximum-pause figures are the noisiest metric, since a single scheduling spike on one seed moves the maximum but not the mean.
Finally, the precise object model and tagged roots are specific to this VM; a collector for a runtime that requires conservative scanning would face costs not captured here.
