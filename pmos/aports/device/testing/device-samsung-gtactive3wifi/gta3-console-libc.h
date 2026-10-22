/*
 * Build init.c as the standalone debug console (CONSOLE_STDIO) against a
 * normal libc (musl in the Duranium image) instead of nolibc: map nolibc's
 * raw syscall macros to libc's syscall(). Both return a negative value on
 * error, which is all init.c checks.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

#define __nolibc_syscall0(n)			syscall(n)
#define __nolibc_syscall1(n, a)			syscall(n, a)
#define __nolibc_syscall2(n, a, b)		syscall(n, a, b)
#define __nolibc_syscall3(n, a, b, c)		syscall(n, a, b, c)
#define __nolibc_syscall4(n, a, b, c, d)	syscall(n, a, b, c, d)
#define __nolibc_syscall5(n, a, b, c, d, e)	syscall(n, a, b, c, d, e)

/* nolibc provides this for getdents64(); libc does not */
struct linux_dirent64 {
	unsigned long long	d_ino;
	long long		d_off;
	unsigned short		d_reclen;
	unsigned char		d_type;
	char			d_name[];
};
