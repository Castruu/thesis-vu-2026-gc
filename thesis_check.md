You are auditing a bachelor's thesis codebase (comparative GC study on an
IJVM substrate, all C) for completeness of the CODING phase. Do NOT
implement anything. Your output is a single prioritized gap list:
everything missing, stubbed, or inconsistent with the design contract
below, ordered by what blocks what.

First read /thesis-files/GC_PROJECT_HANDOFF.md, /thesis-files/thesis_brief.md,
and /thesis-files/VM_NOTES.md for background. Then audit the repo against
the following design contract, which is authoritative and more current
than those documents where they differ.

## Known-missing (verify, don't re-derive)

The collector implementations are expected to be absent or partial. For
each, report its exact state (absent / stubbed / partial / complete):
1. baseline (null collector): alloc→raw_alloc, OOM terminal, collect
   no-op, write_barrier no-op. Must be a real vtable implementation.
2. mark-sweep: trace+mark via TAG_MARKED, sweep HEAP_BASE→watermark,
   free-list in private state (first-fit, no split, no coalesce),
   implements is_heap_freed.
3. Cheney copying: semispaces, bump alloc, root rewrite via slot
   locations.
4. mark-compact: Lisp2 sliding.

Also expected missing: stats propagation — each collector filling the
gc_collect_stats out-param (bytes_freed, bytes_moved, live_bytes,
free_bytes, largest_free_chunk).

## Architecture invariants to CHECK (violations are gaps)

A. Boundary discipline:
   - gc/ translation units compile with -Igc only; they include gc_host.h
     (+ stdlib) and never any vm/ header. Check the Makefile/build flags
     AND the actual #include lines.
   - No vm/ file includes collectors.h or gc_stats.h. Run:
     grep -rn 'collectors.h\|gc_stats.h' vm/ — must be empty.
   - gc_host.h is self-sufficient (compiles standalone) and contains:
     gc_ref typedef + GC_NULL, opaque handles (typedef struct IJVM
     gc_host), the gc_collector vtable (alloc, collect taking
     gc_collect_stats *out, write_barrier, void *state), gc_collect_stats
     (5 uint64_t fields), gc_exit_cause enum (UNSET=0, COMPLETED, OOM,
     FAULT), host service prototypes (raw_alloc, root enumeration
     visitor with gc_ref* slot locations, heap walk first/next, object
     accessors, mark bit ops), and entry points: gc_create, gc_alloc,
     gc_collect, gc_write_barrier, gc_dump_stats.

B. VM-side wiring (exactly three files should have GC fingerprints):
   - vm/gc_host.c: adapter shims between internal alloc()/heap/stack and
     the gc_host_* contract functions. Verify root enumeration is
     implemented (visitor over stack slots 0..sp inclusive, passing slot
     LOCATIONS as gc_ref*, using the tags[] array) and the heap-walk
     primitive (next = current + HEAP_HEADER_SIZE + length*4) exists.
   - vm/ijvm.c: NEWARRAY/ANEWARRAY call gc_alloc (not heap.c alloc
     directly); gc_write_barrier called at AIASTORE; instruction_count
     incremented only for completed instructions (faulting instruction
     uncounted, HALT counted); fault codes set on all terminal error
     paths (OOM=1, bounds/negative-count/invalid-opcode=2).
   - vm/main.c: getopt with --collector/--budget/--summary/--series,
     both-or-neither check on the two paths, fopen "w", gc_create after
     heap init, run, m->faulted → gc_exit_cause translation switch with
     default→UNSET, gc_dump_stats before destroy_ijvm, fclose, exit code
     0 for COMPLETED|OOM, 2 for FAULT|UNSET, 1 for setup failures.
   - heap.c must NOT include gc_host.h and must NOT contain free-list
     logic. stack.c untouched by GC concerns.

C. Single timed chokepoint:
   - gc_collect() in gc/collectors.c is the ONLY place collection is
     invoked and timed: zeroes a gc_collect_stats, stamps gc_now_ns()
     before/after the vtable collect, calls gc_stats_record_collection
     once. Collectors' alloc paths trigger collection through this
     wrapper, never the vtable directly. Verify no other call site times
     or invokes vtable collect.

D. gc_stats module (gc/gc_stats.{c,h}):
   - Header declares only: gc_stats_init, gc_stats_count_alloc,
     gc_stats_record_collection, gc_stats_dump, gc_now_ns. No struct
     definitions, no static state in the header.
   - .c holds the static state struct and collection_record privately;
     lazy realloc growth (cap ? cap*2 : 64), realloc into a temp pointer,
     abort() with stderr message on allocation failure (never silently
     drop a record).
   - gc_now_ns uses CLOCK_MONOTONIC; it is the single clock for both
     run_start and collection stamps.
   - Dump writes summary schema: run_ns,mutator_ns,instructions,
     bytes_allocated,alloc_count,peak_watermark,peak_live_bytes,
     collections,total_pause_ns,max_pause_ns,bytes_freed_total,
     bytes_moved_total,exit_status — header line + one row, and series
     schema: t_ns,dur_ns,bytes_freed,bytes_moved,live_bytes,free_bytes,
     largest_free_chunk with t_ns run-relative. Check the fold sums
     bytes_freed (NOT free_bytes), max_pause is computed AND emitted,
     format specifiers match types under -Wall -Wextra (casts or PRIu64,
     %zu for size_t), exit_status printed as plain %d.
   - gc_stats_init is called during gc_create (verify the wiring exists —
     an unstamped run_start_ns silently breaks t_ns).
   - gc_dump_stats in collectors.c is a one-line forward to the internal
     dump; main.c calls only the gc_ prefixed entry point.

E. Harness integration:
   - The Python driver invokes: ijvm --collector X --budget N
     --summary path --series path <binary>; matrix has collector/budget/
     workload/seed axes; run_id = {collector}_{workload}_b{budget}_s{seed};
     per-run summary+series file pairs under results/; exit_status column
     (not exit code) is the semantic authority; header-only series files
     are valid (zero collections); FAULT/UNSET runs are quarantined
     loudly, OOM runs are kept as data.
   - KNOWN_COLLECTORS in the driver matches gc_create's accepted strings
     verbatim.
   - gen_workload.py exists and produces the four seeded workload
     families (churn, long-lived, cyclic/mutation-heavy, pointer-dense
     vs scalar-dense) as .jas, with an assembly step to IJVM binaries.
     Report which families exist.

F. Build:
   - Builds clean under -Wall -Wextra. Run the build and report warnings.
   - There is a way to build/select collectors at runtime via gc_create
     (no per-collector compile-time builds needed).

## Output format

1. BLOCKERS — gaps that prevent the next collector from being written
   or measured, in dependency order.
2. CONTRACT VIOLATIONS — places where code contradicts the invariants
   above (file:line, what it says, what it should say).
3. STUBS/TODOS — grep for TODO/FIXME/stub and anything returning
   placeholder values; list with location.
4. KNOWN-MISSING STATUS — the four collectors and stats propagation,
   each with its exact current state.
5. NICE-TO-HAVE — anything you noticed that isn't required by the
   contract (label clearly; do not mix into the above).

Be specific: file paths, line numbers, exact symbol names. If something
is ambiguous, say what you'd need to check rather than guessing. Do not
propose redesigns — the contract above is locked.
