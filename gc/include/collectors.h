#ifndef COLLECTORS_H
#define COLLECTORS_H

#include "gc_host.h"

gc_collector* baseline_create(void);
gc_collector* mark_sweep_create(void);
gc_collector* mark_compact_create(void);
gc_collector* cheney_create(void);
gc_collector* generational_create(void);

#endif
