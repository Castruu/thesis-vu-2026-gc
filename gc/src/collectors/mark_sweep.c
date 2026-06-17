#include "collectors.h"
#include "gc_host.h"
#include <stdio.h>
#include <stdlib.h>

static uint32_t free_list_sizes[] = {
    64, 256, 1024
};

struct free_list_block {
  gc_ref block_ref;
  struct free_list_block* next;
};

typedef struct free_list_block free_list_t;

static free_list_t* free_list[sizeof(free_list_sizes) + 1] = { 0 };

static size_t find_free_list_index(uint32_t length) {
    for(size_t i = 0; i < sizeof(free_list_sizes); i++) {
        if(length < free_list_sizes[i]) return i;
    }

    return sizeof(free_list_sizes);
}

static free_list_t* find_free_block(gc_host* host, uint32_t length) {
    free_list_t* curr = NULL;
    for(size_t i = find_free_list_index(length); i < sizeof(free_list); i++) {
        curr = free_list[i];
        free_list_t* best = NULL;
        int64_t best_diff = -1;
        while(curr->next != NULL) {
            uint32_t curr_length = gc_host_object_length(host, curr->block_ref);
            if(curr_length >= length) {
                if(best == NULL) {
                    best = curr;
                    best_diff = curr_length - length;
                    continue;
                }
                int64_t diff = curr_length - length;
                best = diff < best_diff ? curr : best;
                best_diff = diff < best_diff ? diff : best_diff;

                if(best_diff == 0) return curr;
            }
            curr = curr->next;
        }

        if(best != NULL) return best;
    }

    return NULL;
}

static gc_ref mark_sweep_alloc(gc_collector *self, gc_host *host,
                               uint32_t length, uint8_t is_ref) {
  (void)self;
  return gc_host_raw_alloc(host, length, is_ref);
}

static void mark_sweep_collect(gc_collector *self, gc_host *host,
                               gc_collect_stats *out) {
  (void)self;
  (void)host;
  (void)out;
}

static void mark_sweep_destroy(gc_collector *self) { free(self); }

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
  printf("mark_sweep GENERATOR!");
  gc_collector *c = calloc(1, sizeof(gc_collector));
  c->alloc = mark_sweep_alloc;
  c->write_barrier = mark_sweep_write_barrier;
  c->collect = mark_sweep_collect;
  c->destroy = mark_sweep_destroy;
  return c;
}
