#include "gc_host.h"
#include "collectors.h"
#include <stdio.h>
#include <stdlib.h>

static gc_ref generational_alloc(gc_collector *self, gc_host *host, uint32_t length,
                uint8_t is_ref) {
    (void) self;
    return gc_host_raw_alloc(host, length, is_ref);
}

static void generational_collect(gc_collector *self, gc_host *host,
                gc_collect_stats *out) {
    (void) self; (void) host; (void) out;
}

static void generational_destroy(gc_collector* self) {
    free(self);
}

static void generational_write_barrier(gc_collector* self, gc_host* host, gc_ref obj, uint32_t index, gc_ref new_val) {
    (void)self; (void)host; (void)obj; (void)index; (void)new_val;
}

gc_collector* generational_create(void) {
    printf("generational GENERATOR!");
    gc_collector* c = calloc(1, sizeof(gc_collector));
    c->alloc = generational_alloc;
    c->write_barrier = generational_write_barrier;
    c->collect = generational_collect;
    c->destroy = generational_destroy;
    return c;
}
