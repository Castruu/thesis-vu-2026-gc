#include "collectors.h"
#include "gc_host.h"
#include <stdio.h>
#include <stdlib.h>

struct remember_set {
  gc_ref *slots;
  uint32_t *indexes;
  uint32_t count;
  uint32_t capacity;
};

struct generational_state {
  uint32_t nursery_start;
  uint32_t old_frontier;
  struct remember_set rs;
  gc_collector *tenured;
};

static uint8_t is_old_gen(gc_collector *self, gc_ref slot) {
  struct generational_state *st = (struct generational_state *)self->state;
  return slot < st->nursery_start;
}

static uint8_t is_in_nursery(gc_collector *self, gc_ref slot) {
  struct generational_state *st = (struct generational_state *)self->state;
  return slot >= st->nursery_start;
}

static gc_ref copy(gc_host *host, struct generational_state *st, gc_ref from_ref) {
  uint32_t len = gc_host_object_length(host, from_ref);
  uint8_t is_ref = gc_host_is_ref_array(host, from_ref);
  gc_ref dest = st->old_frontier;

  gc_ref rem = gc_host_split_block(host, dest, len, is_ref);
  if (rem == GC_HOST_FULL_SENTINEL) {
    for (uint32_t i = 0; i < len; i++) {
      gc_host_set_value(host, dest, i, gc_host_get_value(host, from_ref, i));
    }
    st->old_frontier = st->nursery_start;
  } else {
    gc_host_move_object(host, from_ref, dest);
    st->old_frontier = rem;
  }

  gc_host_set_forwarded(host, from_ref, dest);
  return dest;
}

static gc_ref forward(gc_host *host, struct generational_state *st, gc_ref ref) {
  if (gc_host_is_forwarded(host, ref)) {
    return gc_host_get_forwarded(host, ref);
  }
  return copy(host, st, ref);
}

static void process_obj(gc_host *host, gc_ref *obj, void *ctx) {
  struct generational_state *st = (struct generational_state *)ctx;
  gc_ref ref = *obj;
  if (ref != GC_NULL && ref >= st->nursery_start) {
    *obj = forward(host, st, ref);
  }
}

static void remset_add(gc_collector *self, gc_ref slot, uint32_t index) {
  struct generational_state *st = (struct generational_state *)self->state;
  if (st->rs.count == st->rs.capacity) {
    st->rs.capacity = st->rs.capacity ? st->rs.capacity * 2 : 64;
    st->rs.slots = realloc(st->rs.slots, st->rs.capacity * sizeof(gc_ref));
    st->rs.indexes = realloc(st->rs.indexes, st->rs.capacity * sizeof(gc_ref));
  }

  st->rs.slots[st->rs.count] = slot;
  st->rs.indexes[st->rs.count++] = index;
}

static void remset_clear(gc_collector *self) {
  struct generational_state *st = (struct generational_state *)self->state;
  st->rs.count = 0;
}

static void remset_forward(gc_collector *self, gc_host *host) {
  struct generational_state *st = (struct generational_state *)self->state;

  for (uint32_t i = 0; i < st->rs.count; i++) {
    gc_ref obj = st->rs.slots[i];
    uint32_t index = st->rs.indexes[i];
    gc_ref young = gc_host_get_value(host, obj, index);
    if (young == GC_NULL || young < st->nursery_start)
      continue;

    gc_host_set_value(host, obj, index, forward(host, st, young));
  }
}

static void minor_gc(gc_collector *self, gc_host *host, gc_collect_stats *out) {
  struct generational_state *st = (struct generational_state *)self->state;
  gc_ref heap_base = gc_host_heap_base(host);
  uint32_t heap_end = gc_host_heap_budget(host);
  gc_ref old_before = st->old_frontier;
  uint64_t nursery_used = gc_host_watermark(host) - st->nursery_start;
  gc_ref scan = old_before;

  if (st->old_frontier < st->nursery_start) {
    gc_host_make_free_block(host, st->old_frontier, st->nursery_start);
  }

  gc_host_enumerate_roots(host, process_obj, st);
  remset_forward(self, host);

  while (scan < st->old_frontier) {
    gc_host_enumerate_object_refs(host, scan, process_obj, st);
    scan += gc_host_object_bytes(host, scan);
  }

  uint64_t promoted = st->old_frontier - old_before;

  gc_host_set_watermark(host, st->nursery_start);
  remset_clear(self);

  out->bytes_moved = promoted;
  out->bytes_freed = nursery_used > promoted ? nursery_used - promoted : 0;
  out->live_bytes = st->old_frontier - heap_base;
  out->free_bytes = heap_end - st->old_frontier;
  out->largest_free_chunk = heap_end - st->old_frontier;
}

static void major_gc(gc_collector *self, gc_host *host, gc_collect_stats *out) {
  struct generational_state *st = (struct generational_state *)self->state;

  if (st->old_frontier < st->nursery_start) {
    gc_host_make_free_block(host, st->old_frontier, st->nursery_start);
  }

  st->tenured->collect(st->tenured, host, out);
  st->old_frontier = gc_host_watermark(host);

  uint32_t heap_end = gc_host_heap_budget(host);
  out->free_bytes = heap_end - st->old_frontier;
  out->largest_free_chunk = heap_end - st->old_frontier;

  if (st->old_frontier + 2 * GC_HOST_HEADER_SIZE > heap_end) {
    return;
  }

  uint32_t free_left = heap_end - st->old_frontier;
  st->nursery_start = (st->old_frontier + free_left / 2) & ~3u;
  gc_host_set_watermark(host, st->nursery_start);
  remset_clear(self);
}

static gc_ref generational_alloc(gc_collector *self, gc_host *host,
                                 uint32_t length, uint8_t is_ref) {
  struct generational_state *st = (struct generational_state *)self->state;
  if (st->nursery_start == 0) {
    uint32_t heap_end = gc_host_heap_budget(host);
    gc_ref heap_base = gc_host_heap_base(host);
    st->nursery_start =
        heap_base + (uint32_t)((heap_end - heap_base) * 75 / 100);
    st->nursery_start &= ~3u;
    st->old_frontier = heap_base;
    gc_host_set_watermark(host, st->nursery_start);
  }

  return gc_host_raw_alloc(host, length, is_ref);
}

static void generational_collect(gc_collector *self, gc_host *host,
                                 gc_collect_stats *out) {
  struct generational_state *st = (struct generational_state *)self->state;
  gc_ref watermark = gc_host_watermark(host);
  uint32_t used_nursery = watermark - st->nursery_start;
  uint32_t free_old = st->nursery_start - st->old_frontier;

  if (free_old < used_nursery + 2 * GC_HOST_HEADER_SIZE) {
    major_gc(self, host, out);
  } else {
    minor_gc(self, host, out);
  }
}

static void generational_destroy(gc_collector *self) {
  struct generational_state *st = (struct generational_state *)self->state;

  if (st->tenured) st->tenured->destroy(st->tenured);
  free(st->rs.slots);
  free(st->rs.indexes);
  free(self->state);
  free(self);
}

static void generational_write_barrier(gc_collector *self, gc_host *host,
                                       gc_ref obj, uint32_t index,
                                       gc_ref new_val) {
  (void)host;
  if (is_old_gen(self, obj) && is_in_nursery(self, new_val)) {
    remset_add(self, obj, index);
  }
}

gc_collector *generational_create(void) {
  gc_collector *c = calloc(1, sizeof(gc_collector));
  c->alloc = generational_alloc;
  c->write_barrier = generational_write_barrier;
  c->collect = generational_collect;
  c->destroy = generational_destroy;

  c->state =
      (struct generational_state *)calloc(1, sizeof(struct generational_state));
  ((struct generational_state *)c->state)->tenured = mark_compact_create();
  return c;
}
