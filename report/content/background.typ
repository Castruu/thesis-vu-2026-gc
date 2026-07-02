= Background <background>

This chapter introduces the IJVM and its heap model, and then summarises the four collection algorithms compared in this thesis.
Throughout, the _mutator_ is the running program and the _collector_ is the garbage collector that reclaims unreachable memory.

== The IJVM and its heap model <heap-model>

The IJVM is a stack-based bytecode interpreter derived from Tanenbaum's Integer Java Virtual Machine @tanenbaum.
For this thesis the interpreter is extended with a small set of heap instructions for allocating and accessing arrays: `NEWARRAY` and `ANEWARRAY` allocate integer and reference arrays respectively, while `IALOAD`/`AIALOAD` and `IASTORE`/`AIASTORE` load and store their elements.
Every heap object carries an eight-byte header recording its length and a small set of tag bits.
Objects live in one contiguous region and are allocated by advancing an allocation frontier called the _watermark_; a collector that empties or compacts the heap moves the watermark back to make the reclaimed space reusable.

Two properties of this model matter for garbage collection.
First, the object model is _precise_: the tag bits distinguish integer arrays from reference arrays, so the collector knows exactly which slots contain pointers and never has to guess.
This rules out the conservative scanning that complicates collectors for languages such as C.
Second, the roots are equally precise.
The mutator keeps its working values (operands and local variables alike) on a single stack, and a parallel tag array marks each slot as either an integer or a heap reference, using the same one-bit reference tag the VM attaches to every value it pushes.
To find the roots, the collector walks the live portion of this stack and yields exactly the slots tagged as references; the IJVM has no global or static state, so those stack slots are the only roots.
Each root is yielded by address rather than by value, so a moving collector can rewrite the slot in place when it relocates the object the root points to.

== The trade-off triangle

A tracing collector starts from the roots and follows references to find every reachable (_live_) object; everything else is garbage and may be reclaimed @jones2023gchandbook.
Collectors differ in _how_ they reclaim, and each choice trades off mutator throughput, pause time, and memory footprint.
A collector that reclaims quickly may fragment memory; one that avoids fragmentation may pay for extra passes over the heap; one that makes both allocation and reclamation cheap may need to reserve extra space.
The remainder of this chapter describes the four points in this design space that we implement @wilson1992.

== Mark-sweep <mark-sweep>

Mark-sweep, the oldest tracing algorithm @mccarthy1960, marks every live object reachable from the roots and then sweeps the heap, returning unmarked objects to a free list.
It is simple and _non-moving_: object addresses never change, so no references need to be updated.
The cost is that the reclaimed memory is scattered, so the allocator must search free lists and the heap can fragment.
Our implementation uses size-segregated free lists (buckets for small, medium, and large objects plus an overflow bucket) and coalesces adjacent free blocks during the sweep.
In the pseudocode, the heap is walked with `get_heap_first`/`get_heap_next`, which return `FULL_HEAP_SENTINEL` once past the last object; the same sentinel doubles as a "no value" marker (for example, an inactive free-block run).

```pseudo
collect() {
  mark();
  sweep();
}

// Mark: trace every object reachable from the roots.
mark() {
  for root in get_roots() {
    trace(root);
  }
}

trace(obj) {
  if(obj is marked) return;
  set_marked(obj);
  for ref in references_of(obj) {   // none for integer arrays
    trace(ref);
  }
}

// Sweep: reclaim unmarked objects, coalescing a run of
// adjacent dead objects into a single free block.
sweep() {
  current <- get_heap_first();
  run_start <- FULL_HEAP_SENTINEL;

  while(current is not FULL_HEAP_SENTINEL) {
    next <- get_heap_next(current);
    if(current is marked) {            // live object
      clear_mark(current);             // reset for next cycle
      if(run_start is not FULL_HEAP_SENTINEL) {
        free_block(run_start, current);  // close dead run
        run_start <- FULL_HEAP_SENTINEL;
      }
    } else if(run_start is FULL_HEAP_SENTINEL) {
      run_start <- current;            // dead: begin a run
    }
    current <- next;
  }

  if(run_start is not FULL_HEAP_SENTINEL) {
    free_block(run_start, get_watermark());  // trailing run
  }
}
```

== Mark-compact

Mark-compact @knuth1968 also begins by marking, but instead of sweeping into free lists it slides the live objects together to one end of the heap, leaving a single contiguous free region.
This eliminates fragmentation and restores cheap bump-pointer allocation, at the cost of several passes over the heap per collection: our implementation marks, computes a new address for each live object in a forwarding map, updates every reference to point at the new addresses, and finally relocates the objects.
The mark phase is identical to mark-sweep (@mark-sweep), so the pseudocode below shows only the three compaction passes.

```pseudo
collect() {
  mark();                          // trace from roots (as in mark-sweep)
  end <- compute_locations(heap_base);
  update_references(heap_base);
  relocate(heap_base);
  set_watermark(end);
}

// forward_map is keyed by an object's word offset from the heap base:
// index(obj) = (obj - heap_base) >> 2.

// Pass 1: assign each live object its compacted address.
compute_locations(heap_base) {
  scan <- get_heap_first();
  dest <- heap_base;
  while(scan is not FULL_HEAP_SENTINEL) {
    if(scan is marked) {
      forward_map[index(scan)] <- dest;
      dest <- dest + get_bytes(scan);
    }
    scan <- get_heap_next(scan);
  }
  return dest;                      // end of the compacted region
}

// Pass 2: rewrite every reference through the forward map.
update_references(heap_base) {
  for root in get_roots() {
    root <- forward_map[index(root)];
  }
  obj <- get_heap_first();
  while(obj is not FULL_HEAP_SENTINEL) {
    if(obj is marked) {
      for ref in references_of(obj) {   // none for integer arrays
        ref <- forward_map[index(ref)];
      }
    }
    obj <- get_heap_next(obj);
  }
}

// Pass 3: move each live object to its new address.
relocate(heap_base) {
  scan <- get_heap_first();
  while(scan is not FULL_HEAP_SENTINEL) {
    next <- get_heap_next(scan);   // read before the move clobbers it
    if(scan is marked) {
      dest <- forward_map[index(scan)];
      clear_mark(scan);
      move_object(scan, dest);
    }
    scan <- next;
  }
}
```

== Cheney copying collection

A copying collector divides the heap into two equal _semispaces_.
The mutator allocates in one semispace; when it fills, the collector copies the live objects into the other semispace and the roles flip.
Cheney's algorithm @cheney1970 performs this copy breadth-first using the to-space itself as the work queue, so it needs no auxiliary stack.
Allocation is a bump pointer and compaction is implicit in the copy, making both operations cheap; the price is that only half of the reserved memory is usable at any time, and the collector copies all live data on every collection.
The bump allocation lives within the active semispace and triggers a collection once it would pass `top` (the end of that half), so the pseudocode below shows only the collection.

```pseudo
// Semispace state: to_space and from_space are the two halves of the
// heap (each `extent` bytes); `top` is the end of the active to_space.

collect() {
  flip();
  scan <- get_watermark();         // start of to-space

  for root in get_roots() {
    process(root);
  }

  // breadth-first: to-space itself is the work queue
  while(scan < get_watermark()) {
    for ref in references_of(scan) {   // none for integer arrays
      process(ref);
    }
    scan <- scan + get_bytes(scan);
  }
}

flip() {
  temp       <- from_space;
  from_space <- to_space;
  to_space   <- temp;
  top        <- to_space + extent;
  set_watermark(to_space);
}

// Forward one reference: copy its target on first encounter,
// then repoint the slot at the to-space copy.
process(slot) {
  if(slot != NULL) {
    slot <- forward(slot);
  }
}

forward(obj) {
  if(obj is forwarded) {
    return get_forward_addr(obj);
  }
  return copy(obj);
}

copy(obj) {
  to_addr <- get_watermark();
  bytes   <- get_bytes(obj);
  move_object(obj, to_addr);
  set_watermark(to_addr + bytes);
  set_forwarded(obj, to_addr);
  return to_addr;
}
```

== Generational collection

The _weak generational hypothesis_ observes that most objects die young @lieberman1983.
A generational collector exploits this with _generation scavenging_ @ungar1984: allocating into a small _young_ generation (the _nursery_) that it collects frequently and cheaply, _promoting_ the few survivors to an _old_ (tenured) generation that it collects only rarely.
Because most objects are dead by the first collection, the common case touches only the small nursery and ignores the bulk of the live data sitting in the old generation, so the collector does far less work per byte allocated than one that traces the whole heap each time.

This division creates one problem.
A collection of the nursery alone starts only from the roots, so it would miss a live nursery object that is reachable only through a pointer held in an _old_ object: an old$arrow.r$young pointer.
The standard remedy is a _write barrier_: a small action the mutator runs on every pointer store, noticing when an old object is made to point at a young one and recording the location in a _remembered set_.
A nursery collection then treats the remembered set as an extra set of roots, so such objects are found and (if they survive) promoted.
The barrier and remembered set make a nursery-only collection sound; their cost is paid on the mutation-heavy workloads.
A _major_ collection, run only when the old generation fills, reclaims the whole heap with one of the algorithms above.

```pseudo
// write barrier: run on every pointer store obj.slot <- new_val.
write_barrier(obj, slot, new_val) {
  if(is_old(obj) and is_young(new_val)) {
    remember(obj, slot);             // record old -> young pointer
  }
}

// minor collection: a nursery-only trace whose roots are the
// stack roots plus the remembered old -> young pointers.
minor_collect() {
  for root in get_roots() {
    process(root);                   // copy/promote as in Cheney
  }
  for (obj, slot) in remembered_set {
    process(obj.slot);
  }
  scan_promoted_objects();           // breadth-first, as in Cheney
  reclaim_nursery();
  clear(remembered_set);
}
```

@sec-generational gives the concrete choices our implementation makes: a Cheney-style minor collection with immediate promotion, and a major collection that reuses the mark-compact collector over the whole heap.

== Related work

The idea of comparing collectors behind a single interface is not new.
The Memory Management Toolkit (MMTk) realises exactly this design at production scale: a framework in which many collectors share allocation, tracing, and root-scanning services so that they can be compared within one Java virtual machine @blackburn2004icse.
Blackburn et al. used it to show that several widely held "myths" about collector performance do not survive controlled measurement @blackburn2004.
Hertz and Berger took a complementary angle, quantifying the cost of garbage collection against explicit memory management @hertz2005.
Both works operate on a full JVM with realistic benchmarks.
This thesis applies the same single-framework principle in a much smaller, fully controlled setting: the IJVM is small enough that each collector is a couple of hundred lines, the object model is precise, and the workloads are synthetic and seed-controlled, which trades realism for transparency and exact reproducibility.
The next chapter turns this principle into a concrete interface, the collectors built on it, and the harness that measures them.
