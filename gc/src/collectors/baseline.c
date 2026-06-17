#include "gc_host.h"
#include "collectors.h"
#include <stdio.h>
#include <stdlib.h>

static gc_ref baseline_alloc(gc_collector *self, gc_host *host, uint32_t length,
                uint8_t is_ref) {
    (void) self;
    return gc_host_raw_alloc(host, length, is_ref);
}

static void baseline_collect(gc_collector *self, gc_host *host,
                gc_collect_stats *out) {
    (void) self; (void) host; (void) out;
}


static void baseline_destroy(gc_collector* self) {
    free(self);
}

static void baseline_write_barrier(gc_collector* self, gc_host* host, gc_ref obj, uint32_t index, gc_ref new_val) {
    (void)self; (void)host; (void)obj; (void)index; (void)new_val;
}

gc_collector* baseline_create(void) {
    printf("baseline GENERATOR!");
    gc_collector* c = calloc(1, sizeof(gc_collector));
    c->alloc = baseline_alloc;
    c->write_barrier = baseline_write_barrier;
    c->collect = baseline_collect;
    c->destroy = baseline_destroy;
    return c;
}
