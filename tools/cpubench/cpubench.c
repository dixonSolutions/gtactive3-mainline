/* cpubench N_MILLION [CPU|-1] [PROCS]: dependent-chain loop (add/eor x4),
 * optionally pinned to CPU, in PROCS parallel processes; prints Miter/s per
 * process and the total. */
#define _GNU_SOURCE
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

static long now_us(void)
{
	struct timeval tv;
	gettimeofday(&tv, NULL);
	return tv.tv_sec * 1000000L + tv.tv_usec;
}

int main(int argc, char **argv)
{
	long n = (argc > 1 ? atol(argv[1]) : 200) * 1000000L;
	int cpu = argc > 2 ? atoi(argv[2]) : -1;
	int procs = argc > 3 ? atoi(argv[3]) : 1, p;
	long t0 = now_us();

	for (p = 0; p < procs; p++) {
		if (fork() == 0) {
			unsigned long x = 1, i;
			long s, dt;
			if (cpu >= 0) {
				cpu_set_t set;
				CPU_ZERO(&set);
				CPU_SET(cpu + (procs > 1 ? p : 0), &set);
				if (sched_setaffinity(0, sizeof(set), &set))
					perror("affinity");
			}
			s = now_us();
			for (i = 0; i < n; i++)
				__asm__ volatile("add %0, %0, #1\n\teor %0, %0, %1\n\tadd %0, %0, #3\n\teor %0, %0, %1"
						 : "+r"(x) : "r"(i));
			dt = now_us() - s;
			printf("proc %d cpu %d: %ld us, %ld Miter/s (x%lu)\n", p, sched_getcpu(), dt, n / (dt ? dt : 1), x & 1);
			fflush(stdout);
			_exit(0);
		}
	}
	while (wait(NULL) > 0)
		;
	printf("total: %d x %ld M in %ld us = %ld Miter/s\n", procs, n / 1000000, now_us() - t0,
	       procs * n / (now_us() - t0));
	return 0;
}
