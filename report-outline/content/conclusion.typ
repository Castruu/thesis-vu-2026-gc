= Conclusion <conclusion>

This thesis added a pluggable garbage-collection layer to the IJVM and used it to
compare three canonical stop-the-world collectors under identical conditions. The
contributions are a single host interface behind which mark-sweep, mark-compact, and
Cheney copying collectors are interchangeable; a deterministic, seed-driven benchmark
harness; and a measured characterisation of the throughput, latency, and space
trade-offs across four allocation patterns and a heap-budget sweep of 1024 runs.

The headline result is that no collector wins on every axis. Cheney delivers the
smallest pauses but requires up to roughly twice the heap of the non-moving collectors.
Mark-sweep and mark-compact share the smallest footprint, and at moderate budgets the two
moving collectors outperform mark-sweep on throughput by between roughly 4× and 7.9× — an
allocation-path cost, not a collection cost. Together these answer the three research questions: on throughput (RQ1) the moving
collectors win and mark-sweep's deficit is an allocation-path cost; on latency (RQ2)
Cheney's pauses are smallest and mark-compact's largest; and on space (RQ3) the non-moving
collectors share the tightest frontier while Cheney pays up to a doubling. The practical
upshot is mark-compact for tight memory where throughput also matters, Cheney for low
latency when heap is plentiful, and mark-sweep for simplicity or a non-moving requirement,
at a throughput cost.

== Future work

The clearest next step is to complete the generational collector. Its interface hook
already exists, and the `mutate` workload is already built to exercise the write barrier
that a generational collector needs; finishing it would turn the currently inert
write-barrier measurements into a real comparison and test the weak generational
hypothesis on the IJVM. Beyond that, the stop-the-world restriction invites work on
incremental or concurrent collection to bound pause times, and the synthetic workloads
invite validation against larger and more realistic programs.
