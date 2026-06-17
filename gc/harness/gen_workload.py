#!/usr/bin/env python3
"""gen_workload.py - emit deterministic IJVM (.jas) GC benchmark programs.

Four workload families: churn, longlived, mutate, density.

All randomness happens here at generation time via random.Random(seed); the
emitted program contains no RNG. Per-iteration variation comes from small
integer tables baked into the program and read cyclically through one index
local, so the emitted file size is O(--table-size) and independent of
--iterations. Same (family, params, seed) -> byte-identical output.
"""

import argparse
import json
import os
import random

# Hardcoded family constants (echoed in the resolved config).
KEEPER_SLOTS = 64            # capacity of the long-lived keeper array (churn/density)
DENSITY_SURVIVAL = 0.05      # fixed survival fraction for the density family
MUTATE_ALLOC_FRACTION = 1.0 / 4.0   # fraction of mutate iterations that allocate
                                    # (3/4 remain pure pointer rewrites; raised
                                    # from 1/16 so the heap fills fast enough to
                                    # trigger collections across the budget sweep)


class Prog:
    """Collects body lines, locals and LDC_W constants, then renders the .jas
    file. Labels and constant names come from deterministic counters."""

    def __init__(self):
        self.lines = []
        self.vars = []
        self.consts = {}  # value -> name, insertion-ordered
        self._label_n = 0

    def var(self, name):
        self.vars.append(name)
        return name

    def label(self, base):
        self._label_n += 1
        return "%s_%d" % (base, self._label_n)

    def emit(self, *instructions):
        for ins in instructions:
            self.lines.append("    " + ins)

    def mark(self, lab):
        self.lines.append(lab + ":")

    def comment(self, text):
        self.lines.append("    // " + text)

    def push(self, value):
        """Push an integer constant: BIPUSH if it fits a signed byte,
        otherwise LDC_W via a named pool constant."""
        if -128 <= value <= 127:
            self.emit("BIPUSH %d" % value)
        else:
            if value not in self.consts:
                name = "c_%d" % value if value >= 0 else "c_n%d" % -value
                self.consts[value] = name
            self.emit("LDC_W " + self.consts[value])

    def render(self, header):
        out = list(header)
        out.append("")
        if self.consts:
            out.append(".constant")
            for value, name in self.consts.items():
                out.append("    %s %d" % (name, value))
            out.append(".end-constant")
            out.append("")
        out.append(".main")
        out.append(".var")
        for v in self.vars:
            out.append("    " + v)
        out.append(".end-var")
        out.extend(self.lines)
        out.append(".end-main")
        return "\n".join(out) + "\n"


# ---------------------------------------------------------------------------
# shared emitter helpers
# ---------------------------------------------------------------------------

def emit_table(p, tbl_var, run_var, values, what):
    """Allocate a value array and store each precomputed entry. run_var is a
    running index local (IINC), so entry indices never need pool constants."""
    p.comment("build %s table (%d entries)" % (what, len(values)))
    p.push(len(values))
    p.emit("NEWARRAY", "ISTORE " + tbl_var)
    p.emit("BIPUSH 0", "ISTORE " + run_var)
    for v in values:
        p.push(v)                                   # value
        p.emit("ILOAD " + run_var)                  # index
        p.emit("ILOAD " + tbl_var)                  # arrayref
        p.emit("IASTORE")
        p.emit("IINC %s 1" % run_var)


def read_table(p, idx_var, tbl_var):
    """Leave table[idx] on the stack."""
    p.emit("ILOAD " + idx_var, "ILOAD " + tbl_var, "IALOAD")


def advance_index(p, idx_var, table_size):
    """idx = idx + 1, wrapped to 0 at table_size (no modulo instruction)."""
    wrap = p.label("wrap")
    done = p.label("nowrap")
    p.emit("IINC %s 1" % idx_var)
    p.emit("ILOAD " + idx_var)
    p.push(table_size)
    p.emit("IF_ICMPEQ " + wrap, "GOTO " + done)
    p.mark(wrap)
    p.emit("BIPUSH 0", "ISTORE " + idx_var)
    p.mark(done)


def begin_countdown(p, ctr_var, count, what):
    """Open a counted loop running `count` times; close with end_countdown."""
    p.comment(what)
    top = p.label("loop")
    end = p.label("done")
    p.push(count)
    p.emit("ISTORE " + ctr_var)
    p.mark(top)
    p.emit("ILOAD " + ctr_var, "IFEQ " + end)
    return top, end


def end_countdown(p, ctr_var, top, end):
    p.emit("IINC %s -1" % ctr_var, "GOTO " + top)
    p.mark(end)


# ---------------------------------------------------------------------------
# family emitters
# ---------------------------------------------------------------------------

def emit_churn(p, rng, cfg):
    n = cfg["table_size"]
    sizes = [rng.randint(cfg["size_min"], cfg["size_max"]) for _ in range(n)]
    survive = [1 if rng.random() < cfg["survival"] else 0 for _ in range(n)]
    victims = [rng.randrange(cfg["keeper_slots"]) for _ in range(n)]

    size_tbl = p.var("size_tbl")
    surv_tbl = p.var("surv_tbl")
    vict_tbl = p.var("vict_tbl")
    keeper = p.var("keeper")
    tmp = p.var("tmp")
    idx = p.var("idx")
    ctr = p.var("ctr")
    run = p.var("run")

    emit_table(p, size_tbl, run, sizes, "allocation size")
    emit_table(p, surv_tbl, run, survive, "survival flag")
    emit_table(p, vict_tbl, run, victims, "keeper victim slot")

    p.comment("long-lived keeper array: holds the surviving fraction")
    p.push(cfg["keeper_slots"])
    p.emit("ANEWARRAY", "ISTORE " + keeper)
    p.emit("BIPUSH 0", "ISTORE " + idx)

    top, end = begin_countdown(p, ctr, cfg["iterations"],
                               "main loop: allocate, occasionally keep, drop otherwise")
    p.comment("allocate one value array of the next seeded size")
    read_table(p, idx, size_tbl)
    p.emit("NEWARRAY", "ISTORE " + tmp)  # overwriting tmp kills the previous drop
    p.comment("survival decision: 0 = drop (dies when tmp is next overwritten)")
    skip = p.label("skip")
    read_table(p, idx, surv_tbl)
    p.emit("IFEQ " + skip)
    p.emit("ILOAD " + tmp)               # value: new array ref
    read_table(p, idx, vict_tbl)         # index: victim slot (evicted ref dies)
    p.emit("ILOAD " + keeper)            # arrayref
    p.emit("AIASTORE")
    p.mark(skip)
    advance_index(p, idx, n)
    end_countdown(p, ctr, top, end)


def emit_longlived(p, rng, cfg):
    n = cfg["table_size"]
    sizes = [rng.randint(cfg["size_min"], cfg["size_max"]) for _ in range(n)]

    size_tbl = p.var("size_tbl")
    root = p.var("root")
    node = p.var("node")
    tmp = p.var("tmp")
    idx = p.var("idx")
    ctr = p.var("ctr")
    run = p.var("run")

    emit_table(p, size_tbl, run, sizes, "payload/allocation size")

    p.comment("startup: build a linked list of --nodes nodes rooted in 'root'")
    p.comment("node layout: [0]=next, [1]=value-array payload")
    p.emit("BIPUSH 0", "ISTORE " + root)  # null
    p.emit("BIPUSH 0", "ISTORE " + idx)
    top, end = begin_countdown(p, ctr, cfg["nodes"], "build loop (head insert)")
    p.emit("BIPUSH 2", "ANEWARRAY", "ISTORE " + node)
    p.emit("ILOAD " + root, "BIPUSH 0", "ILOAD " + node, "AIASTORE")  # node.next = head
    read_table(p, idx, size_tbl)
    p.emit("NEWARRAY")                                               # value: payload ref
    p.emit("BIPUSH 1", "ILOAD " + node, "AIASTORE")                  # node.payload = it
    p.emit("ILOAD " + node, "ISTORE " + root)                        # head = node
    advance_index(p, idx, n)
    end_countdown(p, ctr, top, end)

    top, end = begin_countdown(p, ctr, cfg["iterations"],
                               "main loop: allocate-and-drop churn against the live backdrop")
    read_table(p, idx, size_tbl)
    p.emit("NEWARRAY", "ISTORE " + tmp)  # dropped when tmp is next overwritten
    advance_index(p, idx, n)
    end_countdown(p, ctr, top, end)


def emit_mutate(p, rng, cfg):
    n = cfg["table_size"]
    nodes = cfg["nodes"]
    srcs = [rng.randrange(nodes) for _ in range(n)]
    dsts = [rng.randrange(nodes) for _ in range(n)]
    allocs = [1 if rng.random() < cfg["alloc_fraction"] else 0 for _ in range(n)]
    sizes = [rng.randint(cfg["size_min"], cfg["size_max"]) for _ in range(n)]

    src_tbl = p.var("src_tbl")
    dst_tbl = p.var("dst_tbl")
    alloc_tbl = p.var("alloc_tbl")
    size_tbl = p.var("size_tbl")
    nodedir = p.var("nodedir")
    node = p.var("node")
    prev = p.var("prev")
    pos = p.var("pos")
    idx = p.var("idx")
    ctr = p.var("ctr")
    run = p.var("run")

    emit_table(p, src_tbl, run, srcs, "rewrite source node")
    emit_table(p, dst_tbl, run, dsts, "rewrite target node")
    emit_table(p, alloc_tbl, run, allocs, "occasional-allocation flag")
    emit_table(p, size_tbl, run, sizes, "payload size")

    p.comment("startup: node directory (the root) of --nodes ring-linked nodes")
    p.comment("node layout: [0]=next, [1]=payload")
    p.push(nodes)
    p.emit("ANEWARRAY", "ISTORE " + nodedir)
    p.emit("BIPUSH 0", "ISTORE " + prev)
    p.emit("BIPUSH 0", "ISTORE " + pos)
    top, end = begin_countdown(p, ctr, nodes, "build loop")
    p.emit("BIPUSH 2", "ANEWARRAY", "ISTORE " + node)
    p.emit("ILOAD " + prev, "BIPUSH 0", "ILOAD " + node, "AIASTORE")  # node.next = prev
    p.emit("ILOAD " + node, "ILOAD " + pos, "ILOAD " + nodedir, "AIASTORE")  # dir[pos] = node
    p.emit("ILOAD " + node, "ISTORE " + prev)
    p.emit("IINC %s 1" % pos)
    end_countdown(p, ctr, top, end)
    p.comment("close the ring: dir[0].next = last node")
    p.emit("ILOAD " + prev, "BIPUSH 0")                  # value, index
    p.emit("BIPUSH 0", "ILOAD " + nodedir, "AIALOAD")    # arrayref: dir[0]
    p.emit("AIASTORE")
    p.emit("BIPUSH 0", "ISTORE " + idx)

    top, end = begin_countdown(p, ctr, cfg["iterations"],
                               "main loop: pointer rewrites, occasional allocation")
    p.comment("rewrite: dir[src].next = dir[dst]")
    read_table(p, idx, dst_tbl)
    p.emit("ILOAD " + nodedir, "AIALOAD")                # value: dst node
    p.emit("BIPUSH 0")                                   # index: next slot
    read_table(p, idx, src_tbl)
    p.emit("ILOAD " + nodedir, "AIALOAD")                # arrayref: src node
    p.emit("AIASTORE")
    p.comment("occasional allocation: replace dir[src].payload (old one dies)")
    noalloc = p.label("noalloc")
    read_table(p, idx, alloc_tbl)
    p.emit("IFEQ " + noalloc)
    read_table(p, idx, size_tbl)
    p.emit("NEWARRAY")                                   # value: new payload
    p.emit("BIPUSH 1")                                   # index: payload slot
    read_table(p, idx, src_tbl)
    p.emit("ILOAD " + nodedir, "AIALOAD")                # arrayref: src node
    p.emit("AIASTORE")
    p.mark(noalloc)
    advance_index(p, idx, n)
    end_countdown(p, ctr, top, end)


def emit_density(p, rng, cfg):
    n = cfg["table_size"]
    # Draw order matters: sizes first, so the size sequence is identical for
    # any --ref-ratio under the same seed. The kind draw consumes exactly one
    # rng.random() per entry regardless of ratio, keeping later tables
    # identical too.
    sizes = [rng.randint(cfg["size_min"], cfg["size_max"]) for _ in range(n)]
    kinds = [1 if rng.random() < cfg["ref_ratio"] else 0 for _ in range(n)]
    survive = [1 if rng.random() < cfg["survival"] else 0 for _ in range(n)]
    victims = [rng.randrange(cfg["keeper_slots"]) for _ in range(n)]
    fills = [rng.randint(0, 32767) for _ in range(n)]

    size_tbl = p.var("size_tbl")
    kind_tbl = p.var("kind_tbl")
    surv_tbl = p.var("surv_tbl")
    vict_tbl = p.var("vict_tbl")
    fill_tbl = p.var("fill_tbl")
    keeper = p.var("keeper")
    tmp = p.var("tmp")
    length = p.var("length")
    fillv = p.var("fillv")
    j = p.var("j")
    idx = p.var("idx")
    ctr = p.var("ctr")
    run = p.var("run")

    emit_table(p, size_tbl, run, sizes, "allocation size")
    emit_table(p, kind_tbl, run, kinds, "array kind (1 = reference array)")
    emit_table(p, surv_tbl, run, survive, "survival flag (fixed fraction)")
    emit_table(p, vict_tbl, run, victims, "keeper victim slot")
    emit_table(p, fill_tbl, run, fills, "value-array fill value")

    p.comment("long-lived keeper array: holds the surviving fraction")
    p.push(cfg["keeper_slots"])
    p.emit("ANEWARRAY", "ISTORE " + keeper)
    p.emit("BIPUSH 0", "ISTORE " + idx)

    def fill_loop(value_var, store_op):
        # for (j = length; j != 0; ) { j--; tmp[j] = value_var; }
        ftop = p.label("fill")
        fdone = p.label("filled")
        p.emit("ILOAD " + length, "ISTORE " + j)
        p.mark(ftop)
        p.emit("ILOAD " + j, "IFEQ " + fdone)
        p.emit("IINC %s -1" % j)
        p.emit("ILOAD " + value_var, "ILOAD " + j, "ILOAD " + tmp, store_op)
        p.emit("GOTO " + ftop)
        p.mark(fdone)

    top, end = begin_countdown(p, ctr, cfg["iterations"],
                               "main loop: same allocations either kind, churn-style liveness")
    read_table(p, idx, size_tbl)
    p.emit("ISTORE " + length)
    read_table(p, idx, fill_tbl)
    p.emit("ISTORE " + fillv)            # read on both branches: identical work
    valarr = p.label("valarr")
    filled = p.label("kinddone")
    read_table(p, idx, kind_tbl)
    p.emit("IFEQ " + valarr)
    p.comment("reference array: every slot points at the live keeper array")
    p.emit("ILOAD " + length, "ANEWARRAY", "ISTORE " + tmp)
    fill_loop(keeper, "AIASTORE")
    p.emit("GOTO " + filled)
    p.mark(valarr)
    p.comment("value array: every slot gets the seeded fill value")
    p.emit("ILOAD " + length, "NEWARRAY", "ISTORE " + tmp)
    fill_loop(fillv, "IASTORE")
    p.mark(filled)
    p.comment("survival decision, as in churn")
    skip = p.label("skip")
    read_table(p, idx, surv_tbl)
    p.emit("IFEQ " + skip)
    p.emit("ILOAD " + tmp)               # value
    read_table(p, idx, vict_tbl)         # index
    p.emit("ILOAD " + keeper)            # arrayref
    p.emit("AIASTORE")
    p.mark(skip)
    advance_index(p, idx, n)
    end_countdown(p, ctr, top, end)


EMITTERS = {
    "churn": emit_churn,
    "longlived": emit_longlived,
    "mutate": emit_mutate,
    "density": emit_density,
}


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description="Generate deterministic IJVM (.jas) GC benchmark programs.")
    ap.add_argument("--family", required=True, choices=sorted(EMITTERS))
    ap.add_argument("--seed", required=True, type=int)
    ap.add_argument("--iterations", required=True, type=int,
                    help="main-loop trip count")
    ap.add_argument("--table-size", type=int, default=256,
                    help="length of the baked-in decision tables")
    ap.add_argument("--size-min", type=int, default=4, help="min array length")
    ap.add_argument("--size-max", type=int, default=64, help="max array length")
    ap.add_argument("--survival", type=float, default=0.05,
                    help="churn: fraction of iterations kept alive")
    ap.add_argument("--ref-ratio", type=float, default=0.5,
                    help="density: fraction of allocations that are reference arrays")
    ap.add_argument("--nodes", type=int, default=256,
                    help="longlived/mutate: persistent structure size")
    ap.add_argument("--out", default=None,
                    help="output .jas path (default: workload/<family>_s<seed>_i<iterations>.jas"
                         " next to this script)")
    args = ap.parse_args()

    if args.out is None:
        out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "workload")
        os.makedirs(out_dir, exist_ok=True)
        args.out = os.path.join(
            out_dir, "%s_s%d_i%d.jas" % (args.family, args.seed, args.iterations))

    if args.iterations < 1:
        ap.error("--iterations must be >= 1")
    if args.table_size < 1:
        ap.error("--table-size must be >= 1")
    if not 1 <= args.size_min <= args.size_max:
        ap.error("require 1 <= --size-min <= --size-max")
    if not 0.0 <= args.survival <= 1.0:
        ap.error("--survival must be in [0, 1]")
    if not 0.0 <= args.ref_ratio <= 1.0:
        ap.error("--ref-ratio must be in [0, 1]")
    if args.nodes < 1:
        ap.error("--nodes must be >= 1")

    cfg = {
        "family": args.family,
        "seed": args.seed,
        "iterations": args.iterations,
        "table_size": args.table_size,
        "size_min": args.size_min,
        "size_max": args.size_max,
    }
    if args.family == "churn":
        cfg["survival"] = args.survival
        cfg["keeper_slots"] = KEEPER_SLOTS
    elif args.family == "longlived":
        cfg["nodes"] = args.nodes
    elif args.family == "mutate":
        cfg["nodes"] = args.nodes
        cfg["alloc_fraction"] = MUTATE_ALLOC_FRACTION
    elif args.family == "density":
        cfg["ref_ratio"] = args.ref_ratio
        cfg["survival"] = DENSITY_SURVIVAL  # fixed by design, not --survival
        cfg["keeper_slots"] = KEEPER_SLOTS

    rng = random.Random(args.seed)
    p = Prog()
    EMITTERS[args.family](p, rng, cfg)
    p.comment("clean termination")
    p.emit("HALT")

    header = ["// %s=%s" % (k, cfg[k]) for k in sorted(cfg)]
    with open(args.out, "w") as f:
        f.write(p.render(header))
    print(json.dumps(cfg, sort_keys=True))


if __name__ == "__main__":
    main()
