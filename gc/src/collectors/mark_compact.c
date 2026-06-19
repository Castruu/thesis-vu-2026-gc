#include "collectors.h"
#include "gc_host.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

struct mark_compact_state {
  gc_ref *forward_map;
  gc_ref heap_base;
};

static void visit_refs(gc_host *host, gc_ref *slot, void *ctx) {
  (void)ctx;
  if (gc_host_is_marked(host, *slot)) {
    return;
  }

  gc_host_set_marked(host, *slot);
  gc_host_enumerate_object_refs(host, *slot, visit_refs, NULL);
}

static void visit_root(gc_host *host, gc_ref *root, void *ctx) {
  (void)ctx;
  if (gc_host_is_marked(host, *root)) {
    return;
  }

  gc_host_set_marked(host, *root);
  gc_host_enumerate_object_refs(host, *root, visit_refs, NULL);
}

static void mark(gc_collector *self, gc_host *host) {
  (void)self;
  gc_host_enumerate_roots(host, visit_root, NULL);
}

static gc_ref calculate_forward_index(struct mark_compact_state *st,
                                      gc_ref ref) {
  return (ref - st->heap_base) >> 2;
}

static void update_obj_ref(gc_host *host, gc_ref *obj, void *ctx) {
  (void)host;
  struct mark_compact_state *st = (struct mark_compact_state *)ctx;
  if (*obj == GC_NULL)
    return;
  *obj = st->forward_map[calculate_forward_index(st, *obj)];
}

static gc_ref compute_locations(gc_collector *self, gc_host *host,
                                gc_ref toRegion) {
  struct mark_compact_state *st = (struct mark_compact_state *)self->state;
  gc_ref scan = gc_host_heap_first(host);
  gc_ref dest = toRegion;
  while (scan != GC_HOST_FULL_SENTINEL) {
    if (gc_host_is_marked(host, scan)) {
      st->forward_map[calculate_forward_index(st, scan)] = dest;
      dest += gc_host_object_bytes(host, scan);
    }
    scan = gc_host_heap_next(host, scan);
  }

  return dest;
}

static void update_references(gc_collector *self, gc_host *host) {
  gc_host_enumerate_roots(host, update_obj_ref, self->state);

  gc_ref curr = gc_host_heap_first(host);
  while (curr != GC_HOST_FULL_SENTINEL) {
    if (gc_host_is_marked(host, curr)) {
      gc_host_enumerate_object_refs(host, curr, update_obj_ref, self->state);
    }
    curr = gc_host_heap_next(host, curr);
  }
}

static uint64_t relocate(gc_collector *self, gc_host *host) {
  struct mark_compact_state *st = (struct mark_compact_state *)self->state;
  uint64_t total_moved = 0;
  gc_ref curr = gc_host_heap_first(host);
  while (curr != GC_HOST_FULL_SENTINEL) {
    gc_ref next = gc_host_heap_next(host, curr);
    if (gc_host_is_marked(host, curr)) {
      gc_ref destination = st->forward_map[calculate_forward_index(st, curr)];
      gc_host_clear_marked(host, curr);
      gc_host_move_object(host, curr, destination);
      if (curr != destination) {
        total_moved += gc_host_object_bytes(host, destination);
      }
    }
    curr = next;
  }

  return total_moved;
}

static void compact(gc_collector *self, gc_host *host, gc_collect_stats *out) {
  gc_ref heap_base = gc_host_heap_base(host);
  gc_ref old_watermark = gc_host_watermark(host);
  gc_ref new_watermark = compute_locations(self, host, heap_base);
  update_references(self, host);
  uint64_t moved = relocate(self, host);

  gc_host_set_watermark(host, new_watermark);

  out->live_bytes = new_watermark - heap_base;
  out->free_bytes = old_watermark - new_watermark;
  out->largest_free_chunk = old_watermark - new_watermark;
  out->bytes_freed = old_watermark - new_watermark;
  out->bytes_moved = moved;
}

static gc_ref mark_compact_alloc(gc_collector *self, gc_host *host,
                                 uint32_t length, uint8_t is_ref) {
  (void)self;
  return gc_host_raw_alloc(host, length, is_ref);
}

static void mark_compact_collect(gc_collector *self, gc_host *host,
                                 gc_collect_stats *out) {

  struct mark_compact_state *st = (struct mark_compact_state *)self->state;
  if (st->forward_map == NULL) {
    st->forward_map = malloc((gc_host_heap_budget(host) >> 2) * sizeof(gc_ref));
    st->heap_base = gc_host_heap_base(host);
  }
  mark(self, host);
  compact(self, host, out);
}

static void mark_compact_destroy(gc_collector *self) {
  free(((struct mark_compact_state *)self->state)->forward_map);
  free(self->state);
  free(self);
}

static void mark_compact_write_barrier(gc_collector *self, gc_host *host,
                                       gc_ref obj, uint32_t index,
                                       gc_ref new_val) {
  (void)self;
  (void)host;
  (void)obj;
  (void)index;
  (void)new_val;
}

gc_collector *mark_compact_create(void) {
  gc_collector *c = calloc(1, sizeof(gc_collector));
  c->alloc = mark_compact_alloc;
  c->write_barrier = mark_compact_write_barrier;
  c->collect = mark_compact_collect;
  c->destroy = mark_compact_destroy;

  c->state = calloc(1, sizeof(struct mark_compact_state));
  return c;
}
