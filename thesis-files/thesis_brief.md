# Thesis Project Brief — Comparative Study of Garbage Collection Algorithms
 
> Use this document as the system context for a Claude Project. It captures the research question, scope, constraints, and architecture so future conversations can pick up without re-explaining the setup.
 
---
 
## 1. Who I am
 
- Vitor Castro, third-year CS student at VU Amsterdam.
- Supervisor: **Atze van der Ploeg** (VU Amsterdam; course staff for Systems Programming Project / SyPP, supervising this as my research project). Referred to informally as "atze" in chat logs.
- Working language for the implementation: **C**.
- The project is graded as a research/programming project, not a pure thesis. Deliverables include code + writeup + evaluation.
---
 
## 2. Research question
 
**What garbage collection algorithms exist, and what are their respective benefits and downsides?**
 
The answer is produced empirically: implement multiple GC algorithms of increasing complexity, measure them under controlled workloads, and characterize their tradeoffs along the axes the field uses (pause time, throughput, space overhead, fragmentation).
 
---
 
## 3. Scope
 
- A small IJVM-style runtime as the experimental substrate (precise GC, supports both value arrays and reference arrays — i.e. `ANEWARRAY`, `AIALOAD`, `AIASTORE` in addition to the value-array equivalents).
- A pluggable GC subsystem behind a single interface, with multiple algorithm implementations.
- A benchmark/workload harness producing reproducible measurements.
- A heap-budget control knob (fix budget, vary collector; fix collector, sweep budget).
- Instrumentation: pause times (mean/max/p99), mutator throughput, peak live heap, fragmentation, collection frequency, bytes moved.
- Comparative analysis grounded in *The Garbage Collection Handbook* (Jones, Hosking, Moss, 2nd ed., 2023).
---
 
## 4. Algorithm progression (increasing complexity)
 
The complexity ladder matches the Handbook's structure and Atze's "can stretch" framing:
 
1. **Baseline** — no collection / explicit free, to establish a performance floor.
2. **Mark-sweep (precise)** — tracing, free-list allocation. Headline downside: fragmentation.
3. **Mark-compact** — adds object movement and pointer fixup (Lisp2 sliding compaction). Eliminates fragmentation at the cost of extra heap passes.
4. **Copying / Cheney semispace** — fast bump allocation, no fragmentation, halves usable heap. The cleanest space-vs-time tradeoff to chart.
5. **Stretch: generational** — nursery + old space, write barrier, minor vs. major collections.
Each algorithm implements the same `Collector` interface so the mutator and benchmarks are held constant across runs.
 
---
 
## 5. Critical constraint — academic integrity / publication
 
The IJVM substrate originates from the VU SyPP course skeleton, where implementing a precise GC is a graded bonus assignment. Atze's explicit requirement: **the published artifact must not be obviously a solution to SyPP.**
 
### Agreed split (confirmed by Atze, 25/05/2026)
- **Private repo:** the IJVM interpreter, including its heap (binary loader, instruction dispatch, stack/frame machinery, heap layout, anything course-recognizable).
- **Public repo:** the GC framework (Collector interface, all algorithm implementations, benchmark harness, analysis, writeup) — designed as an extension to the IJVM, depending on it through a narrow interface, but not exposing IJVM internals.
### What this means practically
- Public repo never contains: IJVM instruction set, binary format parsing, course-specific test files (`TestGC*.jas`, the codegrade Makefile targets), the `is_heap_freed` / `is_tos_reference` interface signatures.
- Public repo *does* contain: the Collector trait, mark-sweep / mark-compact / copying / (stretch) generational implementations, the benchmark workloads, the measurement harness, the analysis.
- The README of the public repo frames it as a GC research framework; the IJVM is mentioned only as the host runtime it plugs into, which lives elsewhere.
---
 
## 6. Architecture
 
### 6.1 The heap (lives inside the IJVM)
The heap is part of the private IJVM, not a standalone component. The GC operates on it through a narrow interface the IJVM exposes — allocate, read/write reference fields, enumerate roots, query/walk live objects — without the GC needing to know how the IJVM internally lays out memory or dispatches instructions.
 
Whatever scheme tracks free vs. used space depends on the active collector (free list for non-moving algorithms; bump pointer for moving ones), and is implemented as part of the GC extension rather than baked into the IJVM heap itself.
 
### 6.2 Roots and triggering
The IJVM gives the GC two things the GC could not easily derive on its own:
- **The root set** — derived from the operand stack, local-variable frames, and any global references the VM is currently holding. Roots are precise (the VM knows which slots hold references vs. values).
- **The trigger** — collection runs when an allocation cannot be satisfied within the heap budget. The IJVM calls into the GC, the GC collects, allocation is retried. An explicit collection hook also exists for tests.
### 6.3 The Collector interface
A single trait every algorithm implements. The IJVM and the harness are written once against the trait; only the collector swaps between runs. This isolation is what makes comparative measurements valid.
 
The interface includes read/write hooks for reference fields (not just direct memory access), because moving collectors need to mediate access for forwarding, and generational collectors need write barriers. Building this indirection in from day one — even though mark-sweep barely uses it — avoids rewriting the host later.
 
---
 
## 7. Evaluation methodology
 
### Independent variables
- Collector (mark-sweep, mark-compact, copying, [generational]).
- Heap budget (the knob — fix budget vary collector; fix collector sweep budget).
- Workload.
### Workload families (each designed to expose different tradeoffs)
- **Churn** — many short-lived allocations, almost nothing survives. Favors copying/generational; mark-sweep wastes work.
- **Long-lived** — build a persistent structure, mutate little. Mark-sweep competitive; copying pays to copy survivors repeatedly.
- **Cyclic / mutation-heavy** — graphs with cycles and frequent pointer rewrites. Stresses write barriers; demonstrates the gap between tracing and reference counting.
- **Pointer-dense vs scalar-dense** — varies how much trace/fixup actually costs vs. raw allocation.
### Metrics
Pause time (mean / max / p99), mutator throughput, peak live heap, fragmentation ratio, collection frequency, bytes moved per collection. Presented as throughput-vs-pause and space-vs-time curves per Handbook conventions (including MMU/BMU framing where appropriate).
 
### Reproducibility
All workloads seeded; benchmark harness records configuration alongside results; raw data published in the public repo.
 
---
 
## 8. References
 
- **Primary:** Jones, Hosking, Moss. *The Garbage Collection Handbook: The Art of Automatic Memory Management*, 2nd edition, CRC Press, 2023. Used for: algorithm definitions, performance metrics, correctness framing (Ch. 1 dangling-pointer/leak figure).
- **Substrate origin:** VU OOFP course manual, the precise-GC and reference-array extensions described at `vu-oofp.gitlab.io/website/manual/even_more_stuff.html`. Referenced for the private IJVM only; not part of the public artifact.
---
 
## 9. How Claude should help in this project
 
- Treat the research question and the public/private constraint as **non-negotiable framing**. Any suggestion that would put IJVM-recognizable code in the public artifact is wrong by definition.
- Prefer **first-principles explanations** over recipes. I want to understand *why* each design decision exists, not just what to type.
- When I ask "how do I do X," reply with the conceptual answer first, then the concrete shape, then code only if I ask for it.
- Cite the Handbook by chapter when grounding claims about algorithms or metrics.
- Push back when I'm wrong or when I conflate two different problems.
- Help me draft supervisor messages when I'm scoping a decision with Atze.
