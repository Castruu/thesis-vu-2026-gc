The choice of a garbage collection (GC) algorithm forces a trade-off between three competing goals: mutator throughput, pause latency, and memory footprint.
Although the canonical collectors are well documented, it is hard to find a like-for-like comparison in which only the collector changes while the virtual machine, the workloads, and the heap budget are held fixed.
This makes it difficult to reason concretely about how the textbook trade-offs play out on a small, precise machine.

This thesis adds a pluggable garbage-collection layer to the IJVM, a stack-based bytecode interpreter, and implements four canonical stop-the-world collectors behind a single host interface: a mark-sweep collector with size-segregated free lists, a mark-compact collector, a Cheney semispace copying collector, and a generational collector (a Cheney-style nursery over a mark-compacted old generation).
Because every collector consumes the same allocation, root-scanning, and relocation primitives, the comparison isolates the algorithm itself.
We also contribute a deterministic, seed-driven benchmark harness that sweeps four allocation patterns across a range of heap budgets and records throughput, pause-time distributions, collection counts, and space efficiency.

We evaluate the collectors over a matrix of 1280 runs (four collectors plus a no-op baseline reference, eight heap budgets, four workloads, eight seeds).
No collector is best on every axis.
The Cheney collector produces the smallest mean pauses on the high-churn workloads because its work scales with the live set rather than the heap, but it requires up to roughly twice the heap of the non-moving collectors to survive.
Mark-sweep and mark-compact share the smallest footprint, but mark-sweep pays for it in throughput, so footprint and throughput pull in opposite directions: at moderate budgets the moving and generational collectors outperform mark-sweep by up to 7.6$times$ on the allocation-bound workloads.
The cause is the mutator-side free-list allocation cost, which grows with the heap and which bump allocation into a compacted heap avoids; mark-sweep's collections themselves account for under 1.1% of its run time at those budgets.
The generational collector reaches the moving collectors' throughput while keeping the non-moving collectors' footprint, collecting in many cheap nursery passes and copying less data than Cheney on every workload (up to roughly 60$times$ less where retention is heavy); the price is a heavy-tailed worst-case pause, because its first collection and its full-heap major collections are expensive.
