= Background <background>

This chapter introduces the IJVM and its heap model, and then summarises the three
collection algorithms compared in this thesis. Throughout, the _mutator_ is the running
program and the _collector_ is the garbage collector that reclaims unreachable memory.

== The IJVM and its heap model

The IJVM is a stack-based bytecode interpreter derived from Tanenbaum's Integer Java
Virtual Machine @tanenbaum. For this thesis the interpreter is extended with a small set
of heap instructions for allocating and accessing arrays: `NEWARRAY` and `ANEWARRAY`
allocate integer and reference arrays respectively, while `IALOAD`/`AIALOAD` and
`IASTORE`/`AIASTORE` load and store their elements. Every heap object carries an
eight-byte header recording its length and a small set of tag bits.

Two properties of this model matter for garbage collection. First, the object model is
_precise_: the tag bits distinguish integer arrays from reference arrays, so the
collector knows exactly which slots contain pointers and never has to guess. This rules
out the conservative scanning that complicates collectors for languages such as C.
Second, the roots are equally precise: the operand stack is tagged, so the collector can
enumerate exactly the references the mutator can still reach.

== The trade-off triangle

A tracing collector starts from the roots and follows references to find every
reachable (_live_) object; everything else is garbage and may be reclaimed
@jones2011gchandbook. Collectors differ in _how_ they reclaim, and each choice trades
off mutator throughput, pause time, and memory footprint. A collector that reclaims
quickly may fragment memory; one that avoids fragmentation may pay for extra passes over
the heap; one that makes both allocation and reclamation cheap may need to reserve extra
space. The remainder of this chapter describes the three points in this design space
that we implement @wilson1992.

== Mark-sweep

Mark-sweep, the oldest tracing algorithm @mccarthy1960, marks every live object reachable
from the roots and then sweeps the heap, returning unmarked objects to a free list. It is
simple and _non-moving_: object addresses never change, so no references need to be
updated. The cost is that the reclaimed memory is scattered, so the allocator must search
free lists and the heap can fragment. Our implementation uses size-segregated free lists
(buckets for small, medium, and large objects plus an overflow bucket) and coalesces
adjacent free blocks during the sweep.

== Mark-compact

Mark-compact also begins by marking, but instead of sweeping into free lists it slides
the live objects together to one end of the heap, leaving a single contiguous free
region. This eliminates fragmentation and restores cheap bump-pointer allocation, at the
cost of several passes over the heap per collection: our implementation marks, computes a
new address for each live object in a forwarding map, updates every reference to point at
the new addresses, and finally relocates the objects.

== Cheney copying collection

A copying collector divides the heap into two equal _semispaces_. The mutator allocates
in one semispace; when it fills, the collector copies the live objects into the other
semispace and the roles flip. Cheney's algorithm @cheney1970 performs this copy
breadth-first using the to-space itself as the work queue, so it needs no auxiliary
stack. Allocation is a bump pointer and compaction is implicit in the copy, making both
operations cheap; the price is that only half of the reserved memory is usable at any
time, and the collector copies all live data on every collection.

== Generational collection

The _weak generational hypothesis_ observes that most objects die young
@ungar1984. A generational collector exploits this by allocating into a small _young_
generation that it collects frequently and cheaply, promoting survivors to an _old_
generation collected rarely. This requires a _write barrier_ to record pointers from old
objects to young ones. A generational collector is outside the scope of the implemented
comparison and is discussed as future work; the interface nonetheless reserves a
write-barrier hook for it.

== Related work

The idea of comparing collectors behind a single interface is not new. The Memory
Management Toolkit (MMTk) realises exactly this design at production scale: a
framework in which many collectors share allocation, tracing, and root-scanning
services so that they can be compared within one Java virtual machine
@blackburn2004. Blackburn et al. used it to show that several widely held "myths"
about collector performance do not survive controlled measurement. Hertz and Berger
took a complementary angle, quantifying the cost of garbage collection against
explicit memory management @hertz2005. Both works operate on a full JVM with
realistic benchmarks. This thesis applies the same single-framework principle in a
deliberately minimal, pedagogical setting: the IJVM is small enough that each
collector is a couple of hundred lines, the object model is precise, and the
workloads are synthetic and seed-controlled, which trades realism for transparency
and exact reproducibility.
