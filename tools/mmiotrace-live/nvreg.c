/*
 * nvreg - read and write NVIDIA GPU registers through BAR0.
 *
 *   nvreg [-d 0000:01:00.0] r <off> [count]
 *   nvreg [-d ...] w <off> <val>
 *   nvreg [-d ...] m <off> <mask> <val>        read-modify-write
 *   nvreg [-d ...] wait <off> <mask> <val> <ms>  poll until (reg & mask) == val
 *   nvreg [-d ...] -                           the same commands, one per line, from stdin;
 *                                              "sleep <us>" pauses, '#' starts a comment
 *
 * Every access is a single aligned 32-bit load or store, as the hardware needs.
 * A failed wait ends a script with exit status 2.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define BAR0_SIZE 0x1000000u

static volatile uint32_t *bar0;

static uint32_t rd(uint32_t off) { return bar0[off / 4]; }
static void wr(uint32_t off, uint32_t val) { bar0[off / 4] = val; }

static uint32_t num(const char *s)
{
	char *end;
	unsigned long v = strtoul(s, &end, 0);
	if (*s == '\0' || *end != '\0') {
		fprintf(stderr, "nvreg: not a number: %s\n", s);
		exit(1);
	}
	return (uint32_t)v;
}

static void check_off(uint32_t off)
{
	if (off % 4 || off >= BAR0_SIZE) {
		fprintf(stderr, "nvreg: bad offset 0x%06x\n", off);
		exit(1);
	}
}

static double now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

/* Runs one command; returns 0, or 2 for a wait that timed out. */
static int run(int argc, char **argv)
{
	const char *cmd = argv[0];
	uint32_t off;

	if (!strcmp(cmd, "sleep") && argc == 2) {
		usleep(num(argv[1]));
		return 0;
	}
	if (argc < 2)
		goto usage;
	off = num(argv[1]);
	check_off(off);

	if (!strcmp(cmd, "r") && (argc == 2 || argc == 3)) {
		uint32_t n = argc == 3 ? num(argv[2]) : 1;
		for (uint32_t i = 0; i < n; i++) {
			check_off(off + 4 * i);
			printf("%06x %08x\n", off + 4 * i, rd(off + 4 * i));
		}
	} else if (!strcmp(cmd, "w") && argc == 3) {
		wr(off, num(argv[2]));
	} else if (!strcmp(cmd, "m") && argc == 4) {
		uint32_t mask = num(argv[2]);
		wr(off, (rd(off) & ~mask) | (num(argv[3]) & mask));
	} else if (!strcmp(cmd, "wait") && argc == 5) {
		uint32_t mask = num(argv[2]), val = num(argv[3]);
		double end = now_ms() + num(argv[4]);
		while ((rd(off) & mask) != val) {
			if (now_ms() > end) {
				fprintf(stderr, "nvreg: timeout: %06x & %08x = %08x, want %08x\n",
					off, mask, rd(off) & mask, val);
				return 2;
			}
			usleep(10);
		}
	} else {
		goto usage;
	}
	return 0;
usage:
	fprintf(stderr, "nvreg: bad command: %s\n", cmd);
	exit(1);
}

int main(int argc, char **argv)
{
	const char *dev = "0000:01:00.0";
	char path[128];
	int fd;

	if (argc > 2 && !strcmp(argv[1], "-d")) {
		dev = argv[2];
		argc -= 2;
		argv += 2;
	}
	if (argc < 2) {
		fprintf(stderr, "usage: nvreg [-d bdf] r|w|m|wait|- ...\n");
		return 1;
	}

	snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/resource0", dev);
	fd = open(path, O_RDWR | O_SYNC);
	if (fd < 0) {
		fprintf(stderr, "nvreg: %s: %s\n", path, strerror(errno));
		return 1;
	}
	bar0 = mmap(NULL, BAR0_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (bar0 == MAP_FAILED) {
		fprintf(stderr, "nvreg: mmap: %s\n", strerror(errno));
		return 1;
	}

	if (strcmp(argv[1], "-"))
		return run(argc - 1, argv + 1);

	char line[256];
	while (fgets(line, sizeof(line), stdin)) {
		char *args[8];
		int n = 0;
		char *hash = strchr(line, '#');
		if (hash)
			*hash = '\0';
		for (char *t = strtok(line, " \t\r\n"); t && n < 8; t = strtok(NULL, " \t\r\n"))
			args[n++] = t;
		if (n && run(n, args))
			return 2;
	}
	return 0;
}
