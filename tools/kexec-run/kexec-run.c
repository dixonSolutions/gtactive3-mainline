/* SPDX-License-Identifier: GPL-2.0 */
/*
 * kexec-run IMAGE: start a kernel Image (with its own built-in initramfs and
 * command line) through kexec_file_load. For the bring-up console's
 * "run" command; built with the kernel's nolibc like initramfs/init.c.
 */
#include <linux/reboot.h>

#define KEXEC_FILE_NO_INITRAMFS	0x4

int main(int argc, char **argv)
{
	long r;
	int fd;

	if (argc < 2) {
		printf("usage: kexec-run IMAGE\n");
		return 1;
	}
	fd = open(argv[1], O_RDONLY);
	if (fd < 0) {
		printf("kexec-run: cannot open %s\n", argv[1]);
		return 1;
	}
	r = __nolibc_syscall5(__NR_kexec_file_load, fd, -1, 1, "", KEXEC_FILE_NO_INITRAMFS);
	close(fd);
	if (r) {
		printf("kexec-run: kexec_file_load failed: errno %ld\n", -r);
		return 1;
	}
	printf("kexec-run: loaded, starting it\n");
	__nolibc_syscall0(__NR_sync);
	__nolibc_syscall4(__NR_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
			  LINUX_REBOOT_CMD_KEXEC, 0);
	printf("kexec-run: reboot(KEXEC) returned\n");
	return 1;
}
