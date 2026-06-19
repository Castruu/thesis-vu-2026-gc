#include "collectors.h"
#include "gc_host.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define NUM_CLASSES (sizeof(free_list_sizes) / sizeof(free_list_sizes[0]))
#define NUM_BUCKETS (NUM_CLASSES + 1)

static uint32_t free_list_sizes[] = {64, 256, 1024};

struct free_list_block {
  gc_ref block_ref;
  struct free_list_block *next;
};

typedef struct free_list_block free_list_t;

struct mark_sweep_state {
  free_list_t *free_list[NUM_BUCKETS];
};

static size_t find_free_list_index(uint32_t length) {
  for (size_t i = 0; i < NUM_CLASSES; i++) {
    if (length < free_list_sizes[i])
      return i;
  }

  return NUM_CLASSES;
}

static gc_ref find_free_block(gc_collector *self, gc_host *host,
                              uint32_t length) {
  free_list_t *curr = NULL;
  free_list_t *prev = NULL;
  struct mark_sweep_state *st = self->state;
  for (size_t i = find_free_list_index(length); i < NUM_BUCKETS; i++) {
    prev = NULL;
    curr = st->free_list[i];
    while (curr != NULL) {
      uint32_t curr_length = gc_host_object_length(host, curr->block_ref);
      if (curr_length >= length) {
        break;
      }
      prev = curr;
      curr = curr->next;
    }

    if (curr != NULL) {
      if (prev == NULL) {
        st->free_list[i] = curr->next;
      } else {
        prev->next = curr->next;
      }
      gc_ref block_ref = curr->block_ref;
      free(curr);
      return block_ref;
    }
  }

  return GC_HOST_FULL_SENTINEL;
}

static void free_block(gc_collector *self, gc_host *host, gc_ref ref) {
  size_t index = find_free_list_index(gc_host_object_length(host, ref));

  struct mark_sweep_state *st = self->state;

  free_list_t *new_free = malloc(sizeof(free_list_t));
  new_free->block_ref = ref;
  new_free->next = st->free_list[index];
  st->free_list[index] = new_free;
}

static void clear_free_lists(struct mark_sweep_state *st) {
  for (size_t i = 0; i < NUM_BUCKETS; i++) {
    free_list_t *curr = st->free_list[i];
    while (curr != NULL) {
      free_list_t *next = curr->next;
      free(curr);
      curr = next;
    }
    st->free_list[i] = NULL;
  }
}

static uint64_t count_free_list_bytes(gc_host *host,
                                      struct mark_sweep_state *st) {
  uint64_t total = 0;
  for (size_t i = 0; i < NUM_BUCKETS; i++) {
    free_list_t *curr = st->free_list[i];
    while (curr != NULL) {
      total += gc_host_object_bytes(host, curr->block_ref);
      curr = curr->next;
    }
  }
  return total;
}

static void visit_refs(gc_host *host, gc_ref *slot) {
  if (gc_host_is_marked(host, *slot)) {
    return;
  }

  gc_host_set_marked(host, *slot);
  gc_host_enumerate_object_refs(host, *slot, visit_refs, NULL);
}

static void visit_root(gc_host *host, gc_ref *root) {
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
static void sweep(gc_collector *self, gc_host *host, gc_collect_stats *out) {
  struct mark_sweep_state *st = (struct mark_sweep_state *)self->state;
  uint64_t free_before = count_free_list_bytes(host, st);
  clear_free_lists(st);

  uint64_t live = 0, free_after = 0, largest = 0;
  gc_ref current = gc_host_heap_first(host);
  gc_ref run_start = GC_HOST_FULL_SENTINEL;
  while (current != GC_HOST_FULL_SENTINEL) {
    gc_ref next = gc_host_heap_next(host, current);
    if (gc_host_is_marked(host, current) != 0) {
      gc_host_clear_marked(host, current);
      live += gc_host_object_bytes(host, current);
      if (run_start != GC_HOST_FULL_SENTINEL) {
        gc_ref block = gc_host_make_free_block(host, run_start, current);
        uint64_t size = gc_host_object_bytes(host, block);
        free_after += size;
        if (size > largest)
          largest = size;
        free_block(self, host, block);
        run_start = GC_HOST_FULL_SENTINEL;
      }
    } else if (run_start == GC_HOST_FULL_SENTINEL) {
      run_start = current;
    }
    current = next;
  }

  if (run_start != GC_HOST_FULL_SENTINEL) {
    gc_ref block = gc_host_make_free_block(host, run_start, gc_host_watermark(host));
    uint64_t size = gc_host_object_bytes(host, block);
    free_after += size;
    if (size > largest)
      largest = size;
    free_block(self, host, block);
  }

  out->bytes_moved = 0;
  out->live_bytes = live;
  out->free_bytes = free_after;
  out->largest_free_chunk = largest;
  out->bytes_freed = free_after > free_before ? free_after - free_before : 0;
}

static gc_ref mark_sweep_alloc(gc_collector *self, gc_host *host,
                               uint32_t length, uint8_t is_ref) {
  gc_ref block_ref = find_free_block(self, host, length);
  if (block_ref == GC_HOST_FULL_SENTINEL) {
    return gc_host_raw_alloc(host, length, is_ref);
  }

  gc_ref rem = gc_host_split_block(host, block_ref, length, is_ref);
  if (rem != GC_HOST_FULL_SENTINEL) {
    free_block(self, host, rem);
  }
  return block_ref;
}

static void mark_sweep_collect(gc_collector *self, gc_host *host,
                               gc_collect_stats *out) {
  mark(self, host);
  sweep(self, host, out);
}

static void mark_sweep_destroy(gc_collector *self) {
  clear_free_lists(self->state);
  free(self->state);
  free(self);
}

static void mark_sweep_write_barrier(gc_collector *self, gc_host *host,
                                     gc_ref obj, uint32_t index,
                                     gc_ref new_val) {
  (void)self;
  (void)host;
  (void)obj;
  (void)index;
  (void)new_val;
}

gc_collector *mark_sweep_create(void) {
  gc_collector *c = calloc(1, sizeof(gc_collector));
  c->alloc = mark_sweep_alloc;
  c->write_barrier = mark_sweep_write_barrier;
  c->collect = mark_sweep_collect;
  c->destroy = mark_sweep_destroy;

  c->state = calloc(1, sizeof(struct mark_sweep_state));
  return c;
}
