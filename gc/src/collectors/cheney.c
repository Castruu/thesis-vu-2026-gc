#include "collectors.h"
#include "gc_host.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

struct cheney_state {
  gc_ref from_space;
  gc_ref to_space;
  gc_ref top;
  uint32_t extent;
};

static void flip(gc_collector *self, gc_host *host) {
  struct cheney_state *st = (struct cheney_state *)self->state;
  gc_ref temp = st->from_space;
  st->from_space = st->to_space;
  st->to_space = temp;

  st->top = st->to_space + st->extent;
  gc_host_set_watermark(host, st->to_space);
}

static gc_ref copy(gc_host *host, gc_ref from_ref) {
  gc_ref to_address = gc_host_watermark(host);
  uint64_t bytes = gc_host_object_bytes(host, from_ref);
  gc_host_move_object(host, from_ref, to_address);
  gc_host_set_watermark(host, to_address + bytes);
  gc_host_set_forwarded(host, from_ref, to_address);
  return to_address;
}

static gc_ref forward(gc_host *host, gc_ref ref) {
  if (gc_host_is_forwarded(host, ref)) {
    return gc_host_get_forwarded(host, ref);
  }
  return copy(host, ref);
}

static void process_obj(gc_host *host, gc_ref *obj, void *ctx) {
  (void)ctx;
  gc_ref ref = *obj;
  if (ref != GC_NULL) {
    *obj = forward(host, ref);
  }
}

static gc_ref cheney_alloc(gc_collector *self, gc_host *host, uint32_t length,
                           uint8_t is_ref) {

  struct cheney_state *st = (struct cheney_state *)self->state;
  if (st->to_space == 0) {
    st->to_space = gc_host_heap_base(host);
    uint32_t heap_end = gc_host_heap_budget(host);
    st->extent = (heap_end - st->to_space) / 2;
    st->extent &= ~3u;
    st->top = st->to_space + st->extent;
    st->from_space = st->to_space + st->extent;
  }

  uint32_t needed = length * sizeof(uint32_t) + GC_HOST_HEADER_SIZE;
  if (needed + gc_host_watermark(host) > st->top) {
    return GC_HOST_FULL_SENTINEL;
  }

  return gc_host_raw_alloc(host, length, is_ref);
}

static void cheney_collect(gc_collector *self, gc_host *host,
                           gc_collect_stats *out) {
  struct cheney_state *st = (struct cheney_state *)self->state;
  gc_ref old_watermark = gc_host_watermark(host);
  flip(self, host);
  gc_ref scan = gc_host_watermark(host);

  gc_host_enumerate_roots(host, process_obj, st);

  while (scan < gc_host_watermark(host)) {
    gc_host_enumerate_object_refs(host, scan, process_obj, st);
    scan += gc_host_object_bytes(host, scan);
  }

  gc_ref new_watermark = gc_host_watermark(host);
  uint64_t live = new_watermark - st->to_space;

  out->live_bytes = live;
  out->bytes_moved = live;
  out->free_bytes = st->top - new_watermark;
  out->largest_free_chunk = st->top - new_watermark;
  out->bytes_freed = (old_watermark - st->from_space) - live;
}

static void cheney_destroy(gc_collector *self) {
  free(self->state);
  free(self);
}

static void cheney_write_barrier(gc_collector *self, gc_host *host, gc_ref obj,
                                 uint32_t index, gc_ref new_val) {
  (void)self;
  (void)host;
  (void)obj;
  (void)index;
  (void)new_val;
}

gc_collector *cheney_create(void) {
  gc_collector *c = calloc(1, sizeof(gc_collector));
  c->alloc = cheney_alloc;
  c->write_barrier = cheney_write_barrier;
  c->collect = cheney_collect;
  c->destroy = cheney_destroy;

  c->state = calloc(1, sizeof(struct cheney_state));

  return c;
}
