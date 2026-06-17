#include "gc_host.h"
#include "collectors.h"
#include <stdio.h>
#include <stdlib.h>

static gc_ref cheney_alloc(gc_collector *self, gc_host *host, uint32_t length,
                uint8_t is_ref) {
    (void) self;
    return gc_host_raw_alloc(host, length, is_ref);
}

static void cheney_collect(gc_collector *self, gc_host *host,
                gc_collect_stats *out) {
    (void) self; (void) host; (void) out;
    fprintf(stderr, "cheney\n");
}

static void cheney_destroy(gc_collector* self) {
    free(self);
}

static void cheney_write_barrier(gc_collector* self, gc_host* host, gc_ref obj, uint32_t index, gc_ref new_val) {
    (void)self; (void)host; (void)obj; (void)index; (void)new_val;
}


gc_collector* cheney_create(void) {
    printf("CHENEY GENERATOR!");
    gc_collector* c = calloc(1, sizeof(gc_collector));
    c->alloc = cheney_alloc;
    c->write_barrier = cheney_write_barrier;
    c->collect = cheney_collect;
    c->destroy = cheney_destroy;
    return c;
}
