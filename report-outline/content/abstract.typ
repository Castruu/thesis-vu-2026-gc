The choice of a garbage collection (GC) algorithm forces a trade-off between three
competing goals: mutator throughput, pause latency, and memory footprint. Although
the canonical collectors are well documented, it is hard to find an apples-to-apples
comparison in which only the collector changes while the virtual machine, the
workloads, and the heap budget are held fixed. This makes it difficult to reason
concretely about how the textbook trade-offs play out on a small, precise machine.

This thesis adds a pluggable garbage-collection layer to the IJVM, a stack-based
bytecode interpreter, and implements three canonical stop-the-world collectors behind
a single host interface: a mark-sweep collector with size-segregated free lists, a
mark-compact collector, and a Cheney semispace copying collector. Because every
collector consumes the same allocation, root-scanning, and relocation primitives, the
comparison isolates the algorithm itself. We also contribute a deterministic,
seed-driven benchmark harness that sweeps four allocation patterns across a range of
heap budgets and records throughput, pause-time distributions, collection counts, and
space efficiency.

We evaluate the collectors over a matrix of 1024 runs (three collectors plus a no-op
baseline reference, eight heap budgets, four workloads, eight seeds). The results show that
there is no universal winner. The Cheney collector produces the smallest pauses because
its work scales with the live set rather than the heap, but it requires up to roughly
twice the heap of the non-moving collectors to survive. Mark-sweep and mark-compact share
the smallest footprint, yet at moderate budgets the two moving collectors outperform
mark-sweep on throughput by between roughly 4× and 7.9×. The cause is not collection
time — mark-sweep's collections take under 1.1% of its run time — but the mutator-side
free-list allocation cost that grows with the heap and that bump allocation into a
compacted heap avoids.
