# Root Makefile — builds the IJVM (vm/) against the GC library (gc/).
# The produced binary is vm/ijvm.
#
# `make`            build vm/ijvm (rebuilds gc/libgc.a as needed)
# `make clean`      clean BOTH gc and vm
# `make asan`       clean + rebuild everything with AddressSanitizer
# `make gc`         build just the GC library

.PHONY: all ijvm gc clean asan

all: ijvm

# vm's own Makefile already rebuilds ../gc/libgc.a via its prerequisite,
# so building ijvm transitively builds the GC library.
ijvm:
	$(MAKE) -C vm ijvm

gc:
	$(MAKE) -C gc

# Clean both sides. This matters: the gc Makefile does not track compiler
# flag changes, so a stale libgc.a (e.g. an ASan-instrumented one) will
# poison a later plain link with undefined ___asan_* symbols. Always clean
# both when switching build modes.
clean:
	$(MAKE) -C gc clean
	$(MAKE) -C vm clean

# AddressSanitizer must be all-or-nothing across the link, so clean first
# and instrument both the library and the VM.
asan: clean
	$(MAKE) -C gc CFLAGS="-Iinclude -g -Wall -Wextra -Wpedantic -fsanitize=address -fno-omit-frame-pointer -std=c11"
	$(MAKE) -C vm ijvm USERFLAGS="-fsanitize=address -fno-omit-frame-pointer -I ../gc/include"
