= Introduction

Automatic memory management frees programmers from manual allocation and
deallocation, trading a class of memory-safety bugs for the runtime cost of a garbage
collector. Since McCarthy's original mark-sweep collector for Lisp @mccarthy1960, a
family of tracing algorithms has emerged, each making a different bet about how to
balance three quantities that cannot all be optimised at once: the throughput of the
running program (the _mutator_), the length of the pauses GC introduces, and the
amount of memory the heap must reserve to operate. This three-way tension is the
central theme of the garbage-collection literature @jones2011gchandbook.

This thesis implements and empirically compares three canonical collectors on the
IJVM, the small stack-based bytecode interpreter used in teaching @tanenbaum. All three
are stop-the-world and single-threaded, and all three are placed behind one pluggable
interface so that the virtual machine, the benchmark workloads, and the heap budget
stay fixed while the collector underneath is swapped.

== Problem

The behaviour of mark-sweep, mark-compact, and copying collectors is well described in
textbooks, but those descriptions are mostly qualitative ("copying collectors waste
half the heap", "mark-sweep fragments"). On any concrete virtual machine it is
surprisingly hard to find a comparison where _only the collector changes_. When
collectors are compared across different runtimes, allocators, or benchmark suites, the
measured differences entangle the algorithm with everything else, and the textbook
trade-offs remain abstract rather than quantified.

== Motivation

A single host interface that all collectors share removes those confounds: identical
allocation requests, identical root sets, and an identical heap are presented to each
collector, so any measured difference is attributable to the algorithm. Production
frameworks already apply this principle at scale — the Memory Management Toolkit (MMTk)
is the canonical example, and we contrast with it in @background — so the contribution
here is not the idea of a shared interface but a deliberately minimal, fully reproducible,
pedagogical instance of it. Doing this on the IJVM is additionally valuable as a teaching
artefact, because the IJVM is already used to teach virtual-machine concepts and its
small, precise object model keeps the collectors readable.

== Objectives

The thesis pursues four objectives: (1) implement mark-sweep, mark-compact, and Cheney
copying collectors behind one host interface; (2) build a reproducible, seed-driven
benchmark harness; (3) measure throughput, pause-time distribution, and space
efficiency across four allocation patterns and a heap-budget sweep; and (4) relate the
measurements back to the textbook expectations. Concretely, we ask three research
questions:

- *RQ1 (throughput / overhead).* How do the three collectors compare on mutator
  throughput and total GC overhead as heap pressure varies?
- *RQ2 (latency).* How do pause-time distributions (mean and maximum) differ across
  collectors and workloads?
- *RQ3 (space).* How tight a heap can each collector survive, and what is the Cheney
  collector's semispace penalty in practice?

The benchmark suite includes a fourth, mutation-heavy workload (`mutate`) that does not
map to any of these questions; it is carried to provision for the write-barrier path of a
future generational collector rather than to answer an RQ in this study (see
@implementation).

== Contributions

This thesis makes three contributions:

- A single host interface for the IJVM behind which a mark-sweep, a mark-compact, and a
  Cheney copying collector are fully interchangeable, so that the virtual machine,
  workloads, and heap budget stay fixed while only the collector changes.
- A deterministic, seed-driven benchmark harness that sweeps four allocation patterns
  across eight heap budgets and records throughput, pause-time distributions, collection
  counts, and space efficiency, with the entire study reproducible from a single command.
- A measured characterisation of the throughput, latency, and space trade-offs across
  1024 runs, including an attribution — by elimination — of mark-sweep's throughput deficit
  to its free-list allocation path rather than to its collections.

== Outline

@background reviews the IJVM and the three collection algorithms. @implementation
describes the pluggable GC interface, the collectors, the evaluation metrics, and the
benchmark methodology. @results reports the measurements, and @discussion interprets
them against the research questions and states the threats to validity. @conclusion
summarises the contributions and outlines future work, chiefly a generational
collector.
