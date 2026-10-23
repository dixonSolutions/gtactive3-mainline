# Static aarch64 test tools for the tablet (copy to /run and run there).
#   cpubench N_MILLION [CPU|-1] [PROCS]   dependent add/eor loop, Miter/s
#   mem ADDR [N] | mem -w ADDR VALUE       /dev/mem register read/write
CC = aarch64-linux-gnu-gcc
SYSROOT ?= /usr/aarch64-redhat-linux/sys-root/fc44
CFLAGS = -O2 -static --sysroot=$(SYSROOT) -L ../../build/console/lib

all: cpubench mem
%: %.c
	$(CC) $(CFLAGS) -o $@ $<
clean:
	rm -f cpubench mem
