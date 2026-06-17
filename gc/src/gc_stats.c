#include "gc_stats.h"
#include <stdint.h>
#include <stdlib.h>
#include <time.h>

#define NS_PER_SEC 1000000000ull
#define DEFAULT_COLLECTION_CAP 256

typedef struct {
    uint64_t start_ns;
    uint64_t dur_ns;
    gc_collect_stats out;
} collection_record;

static struct {
    uint64_t run_start_ns;

    uint64_t bytes_allocated;
    uint64_t alloc_count;
    uint64_t peak_watermark;

    collection_record *collections;
    size_t collection_count;
    size_t collection_cap;
} g;

void gc_stats_init(void) {
    g.run_start_ns = gc_now_ns();
}

void gc_stats_count_alloc(uint64_t bytes, uint64_t watermark) {
    g.bytes_allocated += bytes;
    g.alloc_count++;
    if(watermark > g.peak_watermark) {
        g.peak_watermark = watermark;
    }
}

void gc_stats_record_collection(uint64_t start_ns, uint64_t dur_ns, const gc_collect_stats *out) {
    if(g.collection_count == g.collection_cap) {
        size_t new_cap = g.collection_cap ? g.collection_cap * 2 : 64;
        collection_record* tmp = realloc(g.collections, new_cap * sizeof(*tmp));
        if(tmp == NULL) {
            fprintf(stderr, "gc_stats: out of memory recording collection %zu\n",
                    g.collection_count);
            abort();
        }
        g.collections = tmp;
        g.collection_cap = new_cap;
    }

    g.collections[g.collection_count++] = (collection_record){ start_ns, dur_ns, *out };
}

void gc_stats_dump(FILE* summary, FILE* series, uint64_t instruction_count, gc_exit_cause exit_status) {
    uint64_t run_ns = (gc_now_ns() - g.run_start_ns);

    uint64_t total_pause_ns = 0;
    uint64_t max_pause_ns = 0;
    uint64_t bytes_freed_total = 0;
    uint64_t bytes_moved_total = 0;
    uint64_t peak_live_bytes = 0;

    for(size_t i = 0; i < g.collection_count; i++) {
        const collection_record *rec = &g.collections[i];
        total_pause_ns += rec->dur_ns;
        if(rec->dur_ns > max_pause_ns) max_pause_ns = rec->dur_ns;
        if(rec->out.live_bytes > peak_live_bytes) peak_live_bytes = rec->out.live_bytes;
        bytes_freed_total += rec->out.bytes_freed;
        bytes_moved_total += rec->out.bytes_moved;
    }
    uint64_t mutator_ns = (run_ns - total_pause_ns);

    fprintf(summary,
        "run_ns,mutator_ns,instructions,bytes_allocated,alloc_count,"
        "peak_watermark,peak_live_bytes,collections,total_pause_ns,"
        "max_pause_ns,bytes_freed_total,bytes_moved_total,exit_status\n");
    fprintf(
        summary,
        "%llu,%llu,%llu,%llu,%llu,%llu,%llu,%zu,%llu,%llu,%llu,%llu,%d\n",
        (unsigned long long) run_ns,
        (unsigned long long) mutator_ns,
        (unsigned long long) instruction_count,
        (unsigned long long) g.bytes_allocated,
        (unsigned long long) g.alloc_count,
        (unsigned long long) g.peak_watermark,
        (unsigned long long) peak_live_bytes,
        g.collection_count,
        (unsigned long long) total_pause_ns,
        (unsigned long long) max_pause_ns,
        (unsigned long long) bytes_freed_total,
        (unsigned long long) bytes_moved_total,
        exit_status
    );

    fprintf(series,
        "t_ns,dur_ns,bytes_freed,bytes_moved,live_bytes,"
        "free_bytes,largest_free_chunk\n");
    for(size_t i = 0; i < g.collection_count; i++) {
        const collection_record *rec = &g.collections[i];
        fprintf(series,
            "%llu,%llu,%llu,%llu,%llu,%llu,%llu\n",
            (unsigned long long) (rec->start_ns - g.run_start_ns),
            (unsigned long long) rec->dur_ns,
            (unsigned long long) rec->out.bytes_freed,
            (unsigned long long) rec->out.bytes_moved,
            (unsigned long long) rec->out.live_bytes,
            (unsigned long long) rec->out.free_bytes,
            (unsigned long long) rec->out.largest_free_chunk
        );
    }

    fflush(summary);
    fflush(series);

    free(g.collections);
    g.collections = NULL;
    g.collection_count = g.collection_cap = 0;
}

uint64_t gc_now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * NS_PER_SEC + (uint64_t)ts.tv_nsec;
}
