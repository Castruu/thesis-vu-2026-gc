# Task: IJVM workload generator for a GC benchmark suite

Write a single Python 3 script, `gen_workload.py`, that emits IJVM assembly
(`.jas`) benchmark programs. Generate ONLY this script so far.

## Target machine (all context you need about it)

The programs run on a small IJVM interpreter: a stack machine with 32-bit
integer stack slots, local variables, methods with INVOKEVIRTUAL/IRETURN,
and a garbage-collected heap holding two kinds of arrays:
- value arrays (NEWARRAY length → arrayref; IALOAD / IASTORE for elements)
- reference arrays (ANEWARRAY length → arrayref; AIALOAD / AIASTORE),
  whose elements are references to other arrays; 0 is null.

Array references live on the stack / in locals as ordinary slot values.
There is no free/delete instruction — objects die by becoming unreachable
(overwriting the local or array slot that held the last reference).

### Exact assembler dialect — MATCH THIS PRECISELY
[PASTE: one complete working .jas example from your course toolchain —
 main method header, constant declarations, a loop with labels, a method
 definition + invocation]

### Exact mnemonics available
A full instruction set can be found at:
https://vu-oofp.gitlab.io/website/manual/introduction_to_the_ijvm.html

Use ONLY instructions from that list. If a family seems to need something
not listed, simplify the family rather than inventing instructions.

## CLI

gen_workload.py --family {churn,longlived,mutate,density}
                --seed INT
                --iterations INT          # main-loop trip count
                --table-size INT          # default 256, see below
                [--size-min INT --size-max INT]      # array lengths
                [--survival FLOAT]        # churn: fraction kept alive
                [--ref-ratio FLOAT]       # density: ANEWARRAY share
                [--nodes INT]             # longlived/mutate: structure size
                --out PATH

Print the resolved config as a `// key=value` comment block at the top of
the emitted file, and echo it to stdout as one JSON line.

## Determinism model — the core design constraint

ALL randomness happens in Python at generation time using
random.Random(seed). The emitted .jas is fully deterministic and contains
no RNG. Same (family, params, seed) → byte-identical output.

Do NOT unroll: emit a main loop whose per-iteration variation comes from
small precomputed integer tables baked into the program (e.g. a value
array filled at startup with a seeded sequence of sizes / indices /
decisions, read cyclically via an index local). Emitted file should stay
small (≈ table-size + constant overhead), independent of --iterations.
Keep per-iteration non-allocation work minimal — these programs measure
allocation behavior, so arithmetic overhead must be small relative to it.

## The four families (semantics, not implementations — design the bytecode)

1. churn: each iteration allocates one array (length drawn from the seeded
   size table) and drops the reference by the next iteration. A seeded
   --survival fraction of iterations instead stores the new reference into
   a long-lived "keeper" reference array (evicting a seeded victim slot),
   so a small live set persists.

2. longlived: startup phase builds a persistent linked structure of
   --nodes reference arrays (each node: [payload-ref or next-ref slots],
   reachable from one root local). Main loop then does light churn
   (allocate-and-drop) against that fixed live backdrop.

3. mutate: startup builds a ring/graph of --nodes nodes as reference
   arrays. Main loop performs AIASTORE pointer rewrites between EXISTING
   nodes (seeded source/target pairs from tables), with only occasional
   allocation. Allocation-light, mutation-heavy.

4. density: identical allocation count and size sequence regardless of
   --ref-ratio; the ratio only controls which fraction are reference
   arrays (whose slots get seeded references to other live arrays) vs
   value arrays (slots get seeded integers). Liveness pattern mirrors
   churn with fixed survival.

Each family must run to clean termination (no infinite loops, no
deliberate out-of-bounds), and its total allocation volume must scale
linearly with --iterations so heap pressure is tunable from the CLI.

## Code quality

Plain Python 3 stdlib only. One emitter function per family sharing
small helpers (label allocator, table emitter, push-constant helper that
picks BIPUSH vs LDC_W by range). Comment each emitted section with what
it does (// build size table, // main loop, ...). No tests, no extra
files.
