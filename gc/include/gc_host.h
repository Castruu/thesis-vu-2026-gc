#ifndef GC_HOST_H
#define GC_HOST_H

#include <stdint.h>
#include <stdio.h>

struct IJVM;

typedef uint32_t gc_ref;
typedef struct IJVM gc_host;
typedef struct gc_collector gc_collector;
#define GC_NULL 0u
#define GC_HOST_FULL_SENTINEL UINT32_MAX

// vm implemented
gc_ref gc_host_raw_alloc(gc_host *host, uint32_t length, uint8_t is_ref);
void gc_host_enumerate_roots(gc_host *host,
                             void (*visit)(gc_host *host, gc_ref *slot, void *ctx), void *ctx);
void gc_host_enumerate_object_refs(gc_host *, gc_ref obj,
                                   void (*visit)(gc_host *host, uint32_t *slot, void *ctx),
                                   void *ctx);

gc_ref gc_host_heap_first(gc_host *host);
gc_ref gc_host_heap_next(gc_host *host, gc_ref obj);
uint32_t gc_host_heap_budget(gc_host *host);
gc_ref gc_host_watermark(gc_host *host);
void gc_host_set_watermark(gc_host *host, gc_ref watermark);
uint8_t gc_host_is_ref_array(gc_host *host, gc_ref obj);
uint8_t gc_host_is_marked(gc_host *host, gc_ref obj);
void gc_host_set_marked(gc_host *host, gc_ref obj);
void gc_host_clear_marked(gc_host *host, gc_ref obj);
uint8_t gc_host_is_free(gc_host *host, gc_ref obj);
void gc_host_set_free(gc_host *host, gc_ref obj);
void gc_host_clear_free(gc_host* host, gc_ref obj);
void gc_host_move_object(gc_host* host, gc_ref from, gc_ref to);
void gc_host_init_object(gc_host* host, gc_ref ref, uint32_t length, uint32_t tags);
gc_ref gc_host_split_block(gc_host* host, gc_ref ref, uint32_t length, uint8_t is_ref);
gc_ref gc_host_make_free_block(gc_host *host, gc_ref start, gc_ref end);

uint32_t gc_host_object_length(gc_host *host, gc_ref obj);
uint64_t gc_host_object_bytes(gc_host *host, gc_ref obj);
gc_ref gc_host_heap_base(gc_host* host);

// gc implemented

typedef enum {
  GC_EXIT_UNSET,
  GC_EXIT_COMPLETED,
  GC_EXIT_OOM,
  GC_EXIT_FAULT
} gc_exit_cause;

typedef struct {
  uint64_t bytes_moved;
  uint64_t bytes_freed;
  uint64_t live_bytes;
  uint64_t free_bytes;
  uint64_t largest_free_chunk;
} gc_collect_stats;

// collector implemented

typedef struct gc_collector {
  gc_ref (*alloc)(gc_collector *collector, gc_host *host, uint32_t length,
                  uint8_t is_ref);
  void (*collect)(gc_collector *collector, gc_host *host,
                  gc_collect_stats *out);
  void (*write_barrier)(gc_collector *collector, gc_host *host, gc_ref obj,
                        uint32_t index, gc_ref new_val);
  void (*destroy)(gc_collector *collector);

  void *state;
} gc_collector;

gc_ref gc_alloc(gc_collector *collector, gc_host *host, uint32_t length,
                uint8_t is_ref);
void gc_collect(gc_collector *collector, gc_host *host);
void gc_write_barrier(gc_collector *collector, gc_host *host, gc_ref obj,
                      uint32_t index, gc_ref new_val);

gc_collector *gc_create(char *type);
void gc_dump_stats(FILE *summary, FILE *series, uint64_t instruction_count,
                   gc_exit_cause exit_status);

#endif
