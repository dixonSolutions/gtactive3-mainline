/* mem ADDR [N]       read N 32-bit words at physical ADDR (/dev/mem)
 * mem -w ADDR VALUE   write one 32-bit word, print old/new */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
int main(int argc, char **argv)
{
	int wr = argc > 1 && !strcmp(argv[1], "-w"), i, n, fd;
	unsigned long a, pg;
	volatile unsigned int *p;
	if (argc < 2 + wr) { fprintf(stderr, "usage: mem ADDR [N] | mem -w ADDR VALUE\n"); return 2; }
	a = strtoul(argv[1 + wr], 0, 0); pg = a & ~0xfffUL;
	fd = open("/dev/mem", (wr ? O_RDWR : O_RDONLY) | O_SYNC);
	if (fd < 0) { perror("/dev/mem"); return 1; }
	p = mmap(0, 0x2000, wr ? PROT_READ | PROT_WRITE : PROT_READ, MAP_SHARED, fd, pg);
	if (p == MAP_FAILED) { perror("mmap"); return 1; }
	p += (a - pg) / 4;
	if (wr) {
		unsigned int v = strtoul(argv[3], 0, 0), o = p[0];
		p[0] = v;
		printf("%08lx 0x%08x -> 0x%08x (read back 0x%08x)\n", a, o, v, p[0]);
		return 0;
	}
	n = argc > 2 ? atoi(argv[2]) : 1;
	for (i = 0; i < n; i++)
		printf("%08lx 0x%08x\n", a + 4 * i, p[i]);
	return 0;
}
