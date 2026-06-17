CC = clang
IDIR = include
CFLAGS = -I$(IDIR) -g -Wall -Wextra -Wpedantic -std=c11

SRCDIR = src
ODIR = obj

SRCS = $(shell find $(SRCDIR) -name '*.c')
OBJS = $(patsubst $(SRCDIR)/%.c,$(ODIR)/%.o,$(SRCS))

.PHONY: all clean

all: libgc.a

libgc.a: $(OBJS)
	ar rcs $@ $^

$(ODIR)/%.o: $(SRCDIR)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -rf $(ODIR) libgc.a
