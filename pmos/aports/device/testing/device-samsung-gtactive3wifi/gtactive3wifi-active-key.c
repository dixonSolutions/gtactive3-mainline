// SPDX-License-Identifier: MIT
/*
 * SM-T570 Active key (the programmable key on the side, KEY_PROG1 on
 * gpio-keys): held for HOLD_MS (default 3000) it suspends the tablet. A
 * short press stays with the shell (screenshot binding); the device is not
 * grabbed. Runs as root so the explicit hold works whatever the session
 * is doing: systemctl suspend --check-inhibitors=no.
 *
 *   gtactive3wifi-active-key [HOLD_MS]
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define KEY KEY_PROG1

static long long now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000LL + ts.tv_nsec / 1000000;
}

static int open_keys(void)
{
	char path[300], name[64];
	struct dirent *e;
	DIR *d = opendir("/dev/input");
	int fd = -1;

	if (!d)
		return -1;
	while ((e = readdir(d))) {
		if (strncmp(e->d_name, "event", 5))
			continue;
		snprintf(path, sizeof(path), "/dev/input/%s", e->d_name);
		fd = open(path, O_RDONLY | O_CLOEXEC);
		if (fd < 0)
			continue;
		memset(name, 0, sizeof(name));
		if (ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name) >= 0 &&
		    !strcmp(name, "gpio-keys"))
			break;
		close(fd);
		fd = -1;
	}
	closedir(d);
	return fd;
}

static void suspend_now(void)
{
	pid_t pid = fork();

	if (pid == 0) {
		execl("/usr/bin/systemctl", "systemctl", "suspend",
		      "--check-inhibitors=no", (char *)NULL);
		_exit(127);
	}
	if (pid > 0)
		waitpid(pid, NULL, 0);
}

int main(int argc, char **argv)
{
	long hold = argc > 1 ? strtol(argv[1], NULL, 10) : 3000;
	long long deadline = -1;
	struct input_event ev;
	struct pollfd p;
	int fd = open_keys();

	if (fd < 0) {
		fprintf(stderr, "gpio-keys input device not found\n");
		return 1;
	}
	p.fd = fd;
	p.events = POLLIN;
	printf("Active key held %ld ms = suspend\n", hold);
	fflush(stdout);

	for (;;) {
		int timeout = -1, r;

		if (deadline >= 0) {
			long long left = deadline - now_ms();

			timeout = left > 0 ? (int)left : 0;
		}
		r = poll(&p, 1, timeout);
		if (r < 0) {
			if (errno == EINTR)
				continue;
			perror("poll");
			return 1;
		}
		if (r == 0) {
			/* held long enough; wait for the release before re-arming */
			deadline = -2;
			printf("Active key held: suspending\n");
			fflush(stdout);
			suspend_now();
			continue;
		}
		if (read(fd, &ev, sizeof(ev)) != sizeof(ev)) {
			perror("read");
			return 1;
		}
		if (ev.type != EV_KEY || ev.code != KEY)
			continue;
		if (ev.value == 1 && deadline == -1)
			deadline = now_ms() + hold;
		else if (ev.value == 0)
			deadline = -1;
	}
}
