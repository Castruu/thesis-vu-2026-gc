# GC Project — Handoff / State Document
 
> Purpose: pick up GC work in a clean context without re-deriving anything.
> Scope: this doc is the **GC layer**. The IJVM substrate is consumed only through the
> `gc_host.h` contract below — its internals live in `VM_NOTES.md` and are NOT needed here.
> Project: comparative study + implementation of GC algorithms on an IJVM substrate.
> Language: **C all the way** (see §6). Atze has approved this.
 
---
 
## 0. TL;DR of where things stand
 
- **Substrate contracts the GC relies on are in place** (null model, precise roots,
  32-bit references, walkable heap). Two host services still need to be written:
  **root enumeration** and the **heap-walk primitive** (§2).
- **Next build targets:** `gc_host.h` (the host↔GC interface) + the `Collector` vtable +
  the **baseline** (null) collector, built together with a **minimal harness**.
- **Then:** mark-sweep (Handbook Ch. 2) → mark-compact (Ch. 3) → Cheney copying (Ch. 4)
  → [stretch] generational.
---
 
## 1. Substrate contracts the GC can rely on
 
These are guarantees the IJVM upholds; the GC consumes them and does not need to know how
they're maintained internally (that's `VM_NOTES.md`).
 
- **Null:** a reference is a heap offset (`uint32_t`); `0` == `HEAP_NULL` == null. **No live
  object ever lives at offset 0**, so a zeroed reference-array slot is unambiguously null.
- **Reference width:** reference VALUE is 32-bit (forced by the IJVM stack); element STORAGE
  is `int32_t` (4 bytes) — a reference occupies one element slot directly. Heap capacity
  bound: `< UINT32_MAX` (~4 GB), far beyond any benchmark budget. (>4 GB would need handle
  tables — OUT OF SCOPE.)
- **Object header (`heap_array`):** `{ uint32_t length; uint32_t tags; }` = 8 bytes, followed
  inline by `length` $\times$ `int32_t` elements. `tags` bits: `TAG_REFERENCE (1u<<0)`,
  `TAG_MARKED (1u<<1)`, `TAG_FREE (1u<<2)` — independent bits (a chunk can be reference-array
  AND free at once).
- **Layout is walkable:** objects are contiguous and 4-aligned (the 8-byte header keeps
  offsets 4-aligned; an odd `length` leaves the next offset 4- but not 8-aligned). Stride =
  `HEAP_HEADER_SIZE + length*4`. So given an object you can compute the next one from `length`.
- **`raw_alloc` (current `alloc` in heap.c):** policy-free bump allocator. Returns an offset,
  or `HEAP_FULL_SENTINEL` (`UINT32_MAX`) on OOM. **Do NOT add free-list logic to it** (§4).
- **Roots are precise:** the operand-stack/local slots are tagged so a reference is always
  distinguishable from an integer. The GC gets them via root enumeration (§2.1), which yields
  slot **locations**. Root range is `0..sp` inclusive.
---
 
## 2. Host services still to write (these block the GC layer)
 
### 2.1 Root enumeration — TOP PRIORITY (everything blocks on it)
VM-side function exposed through `gc_host.h`. Decided shape:
`void gc_host_enumerate_roots(gc_host*, void (*visit)(void*ctx, gc_ref*slot), void*ctx);`
- For each root slot, call `visit` with the slot's **LOCATION** (`gc_ref*`), not its value.
- **Slot location, not value** — a moving collector must rewrite roots in place after
  relocation; a returned value is a dead-end copy you can't write back through. One `gc_ref*`
  serves both read (trace) and write (relocate + update).
- **Visitor, not a returned array** — VM owns no roots buffer (awkward mid-collection), GC
  decides the per-root action via the callback, `ctx` carries collector state opaquely, and it
  generalizes to future root sources (globals, tail-call call stack) without changing GC code.
- **Slot pointers are valid only within a single collection pass.** The stack can `realloc`,
  so a captured slot pointer dangles across a stack resize. The mutator is stopped during
  collection, so this is safe in practice — just don't stash slot pointers across anything that
  could grow the stack.
### 2.2 Heap-walk primitive
Host service, shared by mark-sweep's sweep AND compaction. Given an offset, return the next
object's offset: `next = current + HEAP_HEADER_SIZE + length*4`. Walk range
`HEAP_BASE → watermark`. Relies on the contract that a freed chunk keeps a valid `length` (§3).
 
### 2.3 `is_heap_freed`
Still stubbed in the VM. It's DEFINED BY the collector (needs the free representation), so it
gets implemented when mark-sweep does (§5.4), not before.
 
---
 
## 3. CRITICAL invariants the GC must not break
 
- **Null:** `0` = null; never allocate a live object at offset 0.
- **`length` is sacred during the heap walk.** When mark-sweep frees a chunk it must NOT
  destroy `length` — the linear walk needs the stride to step over dead chunks, and the
  free-list needs the chunk size. A freed chunk keeps a parseable header; free-list `next`
  goes in the element region, never over the header.
- **Reference value and element storage are both 32-bit (`int32_t`).** Don't widen stack
  slots or element storage.
- **Roots are slots `0..sp`.** Root enumeration must not exceed `sp`.
---
 
## 4. Layering: the free list belongs to the COLLECTOR, not the heap
 
The **free list is a mark-sweep artifact, not a substrate feature.** Three of four collectors
(copying, mark-compact, generational-nursery) allocate by **bump** and never use a free list.
 
- **Host substrate exposes only mechanism, no policy:** `raw_alloc` (bump), heap walk,
  mark-bit get/set/clear, object-ref-slots query, root enumeration.
- **Each collector implements its OWN allocation strategy** in its private `state`:
  - **Mark-sweep:** `state` holds the **free-list head** (a `gc_ref` offset; `HEAP_NULL` =
    empty). Its `alloc` tries the free list, falls back to `raw_alloc`. Free-list `next` links
    live INSIDE the dead chunks' element regions (zero extra memory).
  - **Cheney / mark-compact:** `alloc` is just `raw_alloc` into the active region; no free list.
- Free-list policy knobs (first-fit vs best-fit; exact-fit vs split; coalesce vs not) ARE the
  fragmentation/throughput story the thesis measures. **Start simplest** (first-fit, no split,
  no coalesce) for correctness; treat coalescing/splitting as measurable variations, not
  day-one features.
---
 
## 5. Build plan (forward)
 
### 5.1 `gc_host.h` — the host↔GC contract (replaces the dropped FFI boundary)
Single header = the COMPLETE interface between `vm/` and `gc/`. Correctness test:
**`gc/` compiles including only `gc_host.h` (+ stdlib), never the VM's internal headers.**
- **Opaque forward-declared types** (`typedef struct IJVM gc_host;`,
  `typedef struct HEAP_STRUCT gc_heap;`) so the GC holds handles but can't dereference VM
  internals — the compiler enforces the boundary.
- **Host → GC services:** `raw_alloc`, root enumeration (visitor, slot locations),
  object-ref-slots query (visitor), heap walk (`first`/`next`), per-object accessors
  (`length`, total bytes, is-reference-array), mark bit get/set/clear.
- **GC → host: the `gc_collector` vtable** (struct of function pointers):
  - `alloc(self, host, length, is_ref_array)` — what NEWARRAY calls; does collect-and-retry.
  - `collect(self, host)` — explicit collection hook (also used by tests).
  - `write_barrier(self, host, obj, index, new_val)` — **include from day one** even though
    mark-sweep leaves it empty; moving/generational collectors need it, and this keeps the VM
    code unchanged across collectors. Add `read_barrier` only if a collector needs it.
  - `void *state` — collector-private (free list, to/from space, etc.).
- Reference type: `typedef uint32_t gc_ref; #define GC_NULL 0u` (== `HEAP_NULL`).
### 5.2 Repo / tree discipline (enforces public/private split, brief §5)
- Tree split `vm/` (private: loader, dispatch, stack/heap internals) vs `gc/` (public:
  collector interface, algorithms, harness, analysis).
- `gc/` may include **only `gc_host.h`** from the VM side. If `gc/` transitively pulls in
  instruction dispatch / the binary loader / VM-specific signatures, the split is violated.
  Keep the "lift `gc/` into a separate repo against a stub host" test passable.
### 5.3 Baseline collector (null collector)
- A REAL vtable implementation, NOT "the VM with GC removed" — goes through the same interface
  as the real collectors, to prove the plumbing.
- `alloc` → `raw_alloc`; on failure, OOM is **terminal** (baseline never collects).
  `collect` → no-op. `write_barrier` → no-op.
- Purpose: (a) performance floor / control group; (b) validates the interface AND the harness
  before any real collection logic exists.
- Signature behavior (a result, not a bug): zero pauses, monotonic heap growth, max
  throughput, dies at OOM.
### 5.4 Algorithm ladder (in order)
1. Baseline (above).
2. **Mark-sweep** (Ch. 2): enumerate roots → trace+mark (`TAG_MARKED`) → sweep (walk
   `HEAP_BASE→watermark`; marked → clear mark + step; unmarked → set `TAG_FREE`, thread onto
   free list, step). First collector to exercise the whole substrate; will surface any gap.
   `is_heap_freed` implemented here.
3. **Mark-compact** (Ch. 3): Lisp2 sliding; uses moving infrastructure (forwarding,
   slot-location roots).
4. **Cheney copying** (Ch. 4): semispaces, bump alloc, evacuate live; cashes in barriers +
   slot-location roots.
5. **[stretch] Generational:** nursery + old space, write barrier, minor/major.
---
 
## 6. Architecture decisions
 
- **C all the way** (Rust dropped). Upside: no FFI confound in measurements, simpler debugging.
  Cost: the public/private boundary is now enforced by `#include` discipline + the `vm/`|`gc/`
  tree split (§5.2), not a language barrier. Atze approved.
- The `Collector` interface is a **C vtable**: swap the collector, hold host + harness constant.
---
 
## 7. Measurement / harness
 
### Metrics (per brief §7) — captured via instrumentation at specific events
- **Throughput** — instructions (or bytes allocated) / wall-clock.
- **Pause time** — time *inside* `collect()`, per collection → distribution → mean/max/p99.
- **Peak heap / space** — high-water mark of watermark / live bytes.
- **Collection frequency** — count of `collect()` calls.
- **Fragmentation** — (mark-sweep) free bytes vs largest allocatable chunk, post-collection.
- **Bytes moved** — (moving collectors) bytes copied per collection.
### Harness = the driver, held CONSTANT while the collector varies
Per run: (1) fix config = {collector, workload, heap budget, seed}; (2) build the VM with that
collector + budget, seed the workload RNG; (3) run to completion with instrumentation; (4) emit
**one config-tagged row** of metrics (CSV/JSON: config columns + metric columns). Analysis =
filter/plot that table (fix budget vary collector → throughput-vs-pause; fix collector sweep
budget → space-vs-time).
 
### Methodology (avoid the classic comparative-study failure)
- **Hold everything constant except the collector:** same workloads, seeds, budgets, machine,
  build flags, capture method. Mismatched conditions = non-comparable numbers.
- **Build the harness EARLY, alongside baseline** — validates the instrument on a subject whose
  numbers you can predict (baseline: zero pauses, monotonic growth), and forces the
  instrumentation hooks into the interface before four collectors depend on them.
- **Don't measure a naive first implementation as DATA** — smoke-test it, then measure the
  report-stable version. Measure each collector for real once stable, before the next.
- **Final reported numbers** come from one pass with every collector through a single **frozen
  harness version**.
- Workload families: churn / long-lived / cyclic-mutation-heavy / pointer-dense vs scalar-dense.
  All seeded.
### Design BEFORE writing baseline
The **set of instrumentation hooks** — where each metric's counter/timer lives (host vs
collector vs harness). The `collect()` timing and bytes-moved counter touch the `Collector`
interface, so settle them before collectors implement against it.
 
---
 
## 8. Immediate next actions (ordered)
 
1. **Write root enumeration** (VM side, visitor, slot *locations* — `gc_ref*` — over root range
   `0..sp`). **Everything else blocks on this.**
2. **Write the heap-walk** primitive (`next = current + HEAP_HEADER_SIZE + length*4`).
3. **Draft `gc_host.h`** (opaque handles; host services + collector vtable; `gc_ref`/`GC_NULL`).
4. **Set up `vm/` vs `gc/` tree split** with `gc/` including only `gc_host.h`.
5. **Design instrumentation hooks**, then build **baseline + minimal one-workload harness**
   together; validate the pipeline on baseline's predictable numbers.
6. Then **mark-sweep** (Ch. 2).
---
 
## 9. References
- Primary: Jones, Hosking, Moss, *The Garbage Collection Handbook*, 2nd ed., 2023.
  Ch. 2 (mark-sweep), Ch. 3 (mark-compact), Ch. 4 (copying), Ch. 11 (runtime interface:
  roots, pointer finding, barriers).
- Substrate origin: VU OOFP/SyPP course manual (private; informs the private IJVM only).
- IJVM-internal implementation notes: see `VM_NOTES.md` (not needed for GC work).
