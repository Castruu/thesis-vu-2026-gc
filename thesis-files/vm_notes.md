# IJVM Substrate — Internal Implementation Notes
 
> Scope: IJVM-internal mechanics. NOT needed for GC-layer work — the GC consumes the substrate
> through the `gc_host.h` contracts summarized in `GC_PROJECT_HANDOFF.md` §1. This file exists
> so the hard-won reasoning isn't lost if these opcodes/structures are touched again.
 
---
 
## 1. Reference model / null (how the contract is implemented)
 
- A reference *is* a heap offset (`uint32_t`); `0` == `HEAP_NULL` == null.
- `init_heap` starts `watermark = HEAP_BASE` (= `sizeof(heap_array)` = 8), so no real object
  lives at offset 0. This was the critical null-disambiguation fix: before it, a zeroed
  reference-array slot collided with "pointer to the first object at offset 0", which would
  make a tracing collector keep object-0 spuriously alive and a moving collector corrupt null
  slots.
- `heap.h`: `enum { HEAP_BASE = sizeof(heap_array), HEAP_NULL = 0 };` — true constant
  expressions, `HEAP_BASE` derived from the struct so it can't drift.
## 2. Reference width
 
- Reference VALUE = 32-bit (forced by the IJVM stack: slots are `int32_t`).
- Element STORAGE is `int32_t` (4 bytes); a reference occupies one element slot directly.
  Integer array elements are 32-bit values.
- Heap capacity bound `< UINT32_MAX` (~4 GB). >4 GB would require handle tables — OUT OF SCOPE.
## 3. `alloc` (heap.c) — current correct form
 
- Bump: `offset = watermark`, reserve `length * sizeof(int32_t) + HEAP_HEADER_SIZE`, bump
  watermark, return offset. Internal arithmetic is **64-bit** so `offset + requested_size`
  can't overflow the bounds check; returned offset fits in 32 bits.
- OOM → returns `HEAP_FULL_SENTINEL` (`#define HEAP_FULL_SENTINEL UINT32_MAX`). Safe sentinel
  because no real object can live at `UINT32_MAX`. Call sites in `ijvm.c`
  (`NEWARRAY`/`ANEWARRAY`) compare against it.
- Stride/alignment: header = 8 bytes, each object = `8 + length*4`, watermark stays 4-aligned
  from `HEAP_BASE` → `int32_t` element and header access is aligned/safe.
- This `alloc` IS the policy-free `raw_alloc` the GC layer wants. Do not add free-list logic.
## 4. Precise tag propagation (the stack `tags[]` array)
 
`tags[]` parallels `elements[]` and records "is this slot a reference (1) or an integer (0)".
This is what makes roots precise. The invariant: **every operation that moves a word moves its
tag with it.** Refactored `push(stack, value, tag)` so value+tag are always set together.
 
Per-opcode handling (all currently comply):
- **DUP** — copies `tags[sp-1]` to the new top. Reads the tag *after* `push` returns, so it's
  safe even if `push` triggered a `realloc` resize (never caches a pre-push pointer/index).
- **SWAP** — in-place exchange of BOTH `elements[]` and `tags[]` at `sp`/`sp-1`. No pop/push,
  which avoids tag-clearing and resize churn and is tag-correct by construction.
- **ILOAD** — carries `tags[lv+index]` onto the pushed slot (a reference local stays tagged).
- **ISTORE** — captures the tag before `pop`, writes value+tag to the local. Correct in BOTH
  directions: sets the tag when storing a ref, clears a stale tag when storing a non-ref (the
  silent-corruption direction — a stale tag would make a moving GC rewrite an integer as a
  pointer).
- **INVOKEVIRTUAL** — after writing the link pointer into the OBJREF slot (`elements[lv]`),
  clears `tags[lv] = 0`. Without this, a method invoked on a real reference receiver leaves a
  phantom tag-1 on an integer link pointer → phantom root. (The pushed locals and link words
  use plain `push(...,0)`, which also scrubs reused stack space.)
- **IRETURN** — captures the return value's tag before `pop`, restores it on the destination
  slot so a returned reference stays a root. Also `memset`s the dead frame's tags to 0.
- **NEWARRAY/ANEWARRAY** push the offset with tag 1; **AIALOAD** tags by array type; a null
  element (value 0) in a reference array rides correctly as tag-1/value-0.
- `is_tos_reference` = `tags[sp] == 1`.
### IRETURN memset — is it load-bearing?
The `memset` of the dead frame's tags is **defensive, not load-bearing**, *given* the root scan
is bounded by `sp` and every write path sets its own tag (both now true). Reasoning: slots above
`sp` aren't scanned; reused slots get re-tagged by the next `push`. So once root enumeration pins
its scan bound at `≤ sp`, the memset is redundant and could be removed to save per-return cost on
call-heavy workloads — but keep it during GC bring-up as cheap insurance, and only remove it
*together with* documenting the `≤ sp` scan bound at the enumeration site. Decision tie-break:
the `return_tag` capture/restore is what makes IRETURN correct; the memset is just hygiene.
 
## 5. Minor cleanups (pre-GC hygiene, low priority)
 
- `length`/`index` sign-compare in the array bounds checks (`int32` index vs `uint32` length) —
  same class as the `sp` sign-compare in `stack.c` (`sp` typed `int32_t` vs unsigned fields).
- `IINC` writes `elements[lv+index]` without touching the tag. Fine in well-formed code (result
  is always int), but clearing `tags[lv+index]=0` would make "tag always matches contents"
  unconditional rather than assumed.
- `is_heap_freed` stubbed — defined by the collector (needs the free representation), implement
  with mark-sweep.
## 6. Source files
 
`src/{ijvm,heap,stack,util,main}.c`, `include/{ijvm,ijvm_struct,heap,stack,util}.h`.
Build: GCC `-Wall -Wextra`
