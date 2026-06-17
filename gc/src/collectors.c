#include "collectors.h"
#include "gc_host.h"
#include "gc_stats.h"
#include <stdlib.h>
#include <string.h>

gc_ref gc_alloc(gc_collector *collector, gc_host *host, uint32_t length, uint8_t is_ref) {
    gc_ref alloc_pos = collector->alloc(collector, host, length, is_ref);
    if(alloc_pos == GC_HOST_FULL_SENTINEL) {
        gc_collect(collector, host);
        alloc_pos = collector->alloc(collector, host, length, is_ref);
    }

    if(alloc_pos != GC_HOST_FULL_SENTINEL) {
        gc_stats_count_alloc(gc_host_object_bytes(host, alloc_pos), gc_host_watermark(host));
    }
    return alloc_pos;
}

void gc_collect(gc_collector *collector, gc_host *host) {
    gc_collect_stats out = { 0 };
    uint64_t start_ns = gc_now_ns();
    collector->collect(collector, host, &out);
    uint64_t end_ns = gc_now_ns();

    gc_stats_record_collection(start_ns, (end_ns - start_ns), &out);
}

void gc_write_barrier(gc_collector *collector, gc_host *host, gc_ref obj, uint32_t index, gc_ref new_val) {
    collector->write_barrier(collector, host, obj, index, new_val);
}

gc_collector* gc_create(char *type) {
    gc_stats_init();
    if(strcmp(type, "baseline") == 0) {
        return baseline_create();
    }
    if(strcmp(type, "mark_sweep") == 0) {
        return mark_sweep_create();
    }
    if(strcmp(type, "mark_compact") == 0) {
        return mark_compact_create();
    }
    if(strcmp(type, "cheney") == 0) {
        return cheney_create();
    }
    if(strcmp(type, "generational") == 0) {
        return generational_create();
    }

    fprintf(stderr, "Invalid garbage collector!");
    abort();
}

void gc_dump_stats(FILE *summary, FILE *series, uint64_t instruction_count, gc_exit_cause exit_status) {
    gc_stats_dump(summary, series, instruction_count, exit_status);
}
