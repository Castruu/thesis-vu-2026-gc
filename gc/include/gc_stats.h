#ifndef GC_STATS_H
#define GC_STATS_H

#include "gc_host.h"
#include <stdio.h>
#include <stdint.h>

void gc_stats_init(void);

void gc_stats_count_alloc(uint64_t bytes, uint64_t watermark);

void gc_stats_record_collection(uint64_t start_ns, uint64_t dur_ns, const gc_collect_stats *out);

void gc_stats_dump(FILE* summary, FILE* series, uint64_t instruction_count, gc_exit_cause exit_status);

uint64_t gc_now_ns(void);

#endif
