= Introduction

Automatic memory management frees programmers from manual allocation and deallocation, trading a class of memory-safety bugs for the runtime cost of a garbage collector.
Since McCarthy's original mark-sweep collector for Lisp @mccarthy1960, a family of tracing algorithms has emerged, each making a different bet about how to balance three quantities that cannot all be optimised at once: the throughput of the running program (the _mutator_), the length of the pauses GC introduces, and the amount of memory the heap must reserve to operate.
This three-way tension is the central theme of the garbage-collection literature @jones2023gchandbook.

This thesis implements and empirically compares four canonical collectors on the IJVM, the small stack-based bytecode interpreter used in teaching @tanenbaum.
All four are stop-the-world and single-threaded, and all are placed behind one pluggable interface so that the virtual machine, the benchmark workloads, and the heap budget stay fixed while the collector underneath is swapped.

== Problem

The behaviour of mark-sweep, mark-compact, and copying collectors is well described in textbooks, but those descriptions are mostly qualitative ("copying collectors waste half the heap", "mark-sweep fragments").
On any concrete virtual machine it is surprisingly hard to find a comparison where _only the collector changes_.
When collectors are compared across different runtimes, allocators, or benchmark suites, the measured differences entangle the algorithm with everything else, and the textbook trade-offs remain abstract, not quantified.

== Motivation

A single host interface that all collectors share removes those confounds: identical allocation requests, identical root sets, and an identical heap are presented to each collector, so any measured difference is attributable to the algorithm.
Production frameworks already apply this principle at scale: the Memory Management Toolkit (MMTk) is the canonical example, and we contrast our approach with it in @background.
The contribution here is therefore a small, fully reproducible instance of the shared-interface idea rather than the idea itself.
The result is additionally valuable as a teaching artefact, because the IJVM is already used to teach virtual-machine concepts and its small, precise object model keeps the collectors readable.

== Objectives

The thesis pursues four objectives: (1) implement mark-sweep, mark-compact, Cheney copying, and generational collectors behind one host interface; (2) build a reproducible, seed-driven benchmark harness; (3) measure throughput, pause-time distribution, and space efficiency across four allocation patterns and a heap-budget sweep; and (4) relate the measurements back to the textbook expectations.
Concretely, we ask four research questions. The first three we ask of every collector; the fourth concerns the generational collector specifically:

- *RQ1 (throughput / overhead).* How do the collectors compare on mutator
  throughput and total GC overhead as heap pressure varies?
- *RQ2 (latency).* How do pause-time distributions (mean and maximum) differ across
  collectors and workloads?
- *RQ3 (space).* How tight a heap can each collector survive, and what is the Cheney
  collector's semispace penalty in practice?
- *RQ4 (generational).* Does the generational collector match the other collectors'
  throughput and footprint, and what do its write barrier and worst-case pause cost?

The `mutate` workload most directly exercises the generational collector's write barrier, a mechanism introduced in @background, exposing the cost it adds (RQ4; see @implementation).

== Contributions

This thesis makes three contributions:

- A single host interface for the IJVM behind which a mark-sweep, a mark-compact, a
  Cheney copying, and a generational collector are fully interchangeable, so that the
  virtual machine, workloads, and heap budget stay fixed while only the collector changes.
- A deterministic, seed-driven benchmark harness that sweeps four allocation patterns
  across eight heap budgets and records throughput, pause-time distributions, collection
  counts, and space efficiency, with the entire study reproducible from a single command.
- A measured characterisation of the throughput, latency, and space trade-offs across
  1280 runs, including an attribution, by elimination, of mark-sweep's throughput deficit
  to its free-list allocation path rather than to its collections.

== Outline

@background reviews the IJVM, the four implemented collection algorithms, and related
work. @implementation describes the pluggable GC interface, the collectors, the
evaluation metrics, and the benchmark methodology. @results reports the measurements, and
@discussion interprets them against the research questions and states the threats to
validity. @conclusion summarises the contributions and outlines future work.
