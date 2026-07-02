= Conclusion <conclusion>

This thesis added a pluggable garbage-collection layer to the IJVM and used it to compare four canonical stop-the-world collectors under identical conditions.
The contributions are a single host interface behind which mark-sweep, mark-compact, Cheney copying, and generational collectors are interchangeable; a deterministic, seed-driven benchmark harness; and a measured characterisation of the throughput, latency, and space trade-offs across four allocation patterns and a heap-budget sweep of 1280 runs.

No single collector dominated: each won on one axis and gave up another.
Cheney's mean pauses were the shortest we measured on the high-churn workloads, but on three of the four workloads it could not run in less than about double the heap the non-moving collectors needed.
Mark-sweep and mark-compact tied for the smallest footprint; against them the moving and generational collectors won throughput by up to 7.6$times$ at moderate budgets, a gap we traced to mark-sweep's free-list allocation path, not to its collections.
The generational collector was the most balanced collector: it matched the moving collectors' throughput and the non-moving collectors' footprint and gave the lowest typical pause on retention-heavy workloads, where promoting only young survivors let it copy roughly 60$times$ less data than Cheney; its cost was a heavy-tailed worst case, part of which we identified as a fixable initialisation artefact rather than an algorithmic limit.
In terms of the research questions: on throughput (RQ1) the moving and generational collectors win and mark-sweep's deficit is an allocation-path cost; on latency (RQ2) Cheney's mean pauses are smallest, the generational collector's are smallest on the retention-heavy workload but heavy-tailed, and mark-compact's are largest; on space (RQ3) the non-moving and generational collectors share the tightest frontier while Cheney pays up to a doubling; and on the generational collector specifically (RQ4), it matches the moving collectors' throughput and the non-moving collectors' footprint at the lowest typical pause, paying with the write barrier on mutation-heavy work and a heavy-tailed worst-case pause.
For a practitioner: choose the generational collector or mark-compact for tight memory where throughput also matters, Cheney for a bounded maximum pause when heap is plentiful, and mark-sweep for simplicity or a non-moving requirement, at a throughput cost.

== Future work

The generational collector implemented here is deliberately minimal, and the clearest next steps are to refine it.
It sizes the nursery by a fixed heuristic (a quarter of the heap initially, then half of the remaining free space after each major collection), promotes every survivor immediately, and collects the old generation by full-heap mark-compact; an ageing nursery, a split tuned to the live set, and an old generation that need not be compacted in full would likely lower both its promotion rate and its major-collection cost.
More immediately, its largest pauses are inflated by the repeated zero-initialisation of the old-generation reserve during promotion (@discussion); initialising only the bytes handed out, or zeroing the reserve once in bulk, would remove that spike.
Beyond the generational collector, the stop-the-world restriction invites work on incremental or concurrent collection to bound pause times, and the synthetic workloads invite validation against larger and more realistic programs.
