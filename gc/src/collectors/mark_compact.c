#include "gc_host.h"
#include "collectors.h"
#include <stdio.h>
#include <stdlib.h>

static gc_ref mark_compact_alloc(gc_collector *self, gc_host *host, uint32_t length,
                uint8_t is_ref) {
    (void) self;
    return gc_host_raw_alloc(host, length, is_ref);
}

static void mark_compact_collect(gc_collector *self, gc_host *host,
                gc_collect_stats *out) {
    (void) self; (void) host; (void) out;
}


static void mark_compact_destroy(gc_collector* self) {
    free(self);
}

static void mark_compact_write_barrier(gc_collector* self, gc_host* host, gc_ref obj, uint32_t index, gc_ref new_val) {
    (void)self; (void)host; (void)obj; (void)index; (void)new_val;
}

gc_collector* mark_compact_create(void) {
    gc_collector* c = calloc(1, sizeof(gc_collector));
    c->alloc = mark_compact_alloc;
    c->write_barrier = mark_compact_write_barrier;
    c->collect = mark_compact_collect;
    c->destroy = mark_compact_destroy;
    return c;
}
