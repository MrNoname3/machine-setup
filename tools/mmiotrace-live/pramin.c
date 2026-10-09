/*
 * pramin - read VRAM through the BAR0 PRAMIN window: 1 MiB at 0x700000, placed
 * by 0x1700 in 64 KiB units. The window's place is restored on exit; a driver
 * using the window at the same moment would read the wrong VRAM.
 *
 *   pramin [-d 0000:01:00.0] r <phys> [count]      32-bit words, one a line
 *   pramin [-d ...] dump <phys> <len>              raw bytes to stdout
 *   pramin [-d ...] find <hex bytes> [MiB]         4-byte aligned matches
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define WIN 0x700000u
#define WSZ 0x100000u

static volatile uint32_t *bar0;
static uint64_t placed = ~0ull;

static uint32_t rd(uint64_t phys)
{
	uint64_t base = phys & ~(uint64_t)(WSZ - 1);

	if (base != placed) {
		bar0[0x1700 / 4] = (uint32_t)(base >> 16);
		(void)bar0[0x1700 / 4];
		placed = base;
	}
	return bar0[(WIN + (phys - base)) / 4];
}

static uint64_t num(const char *s)
{
	char *end;
	uint64_t v = strtoull(s, &end, 0);

	if (*s == '\0' || *end != '\0') {
		fprintf(stderr, "pramin: not a number: %s\n", s);
		exit(1);
	}
	return v;
}

int main(int argc, char **argv)
{
	const char *bdf = "0000:01:00.0";
	char path[128];
	uint32_t old;
	int fd, a = 1;

	if (argc > 2 && !strcmp(argv[1], "-d")) {
		bdf = argv[2];
		a = 3;
	}
	if (argc - a < 2) {
		fprintf(stderr, "usage: pramin [-d bdf] r <phys> [count] | dump <phys> <len> | find <hex> [MiB]\n");
		return 1;
	}
	snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/resource0", bdf);
	fd = open(path, O_RDWR | O_SYNC);
	if (fd < 0) {
		perror(path);
		return 1;
	}
	bar0 = mmap(NULL, 0x1000000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (bar0 == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	old = bar0[0x1700 / 4];

	if (!strcmp(argv[a], "r")) {
		uint64_t p = num(argv[a + 1]) & ~3ull;
		uint64_t n = argc - a > 2 ? num(argv[a + 2]) : 1;

		for (; n--; p += 4)
			printf("%09llx %08x\n", (unsigned long long)p, rd(p));
	} else if (!strcmp(argv[a], "dump") && argc - a > 2) {
		uint64_t p = num(argv[a + 1]) & ~3ull, end = num(argv[a + 1]) + num(argv[a + 2]);

		for (; p < end; p += 4) {
			uint32_t v = rd(p);

			fwrite(&v, 4, 1, stdout);
		}
	} else if (!strcmp(argv[a], "find")) {
		static uint8_t buf[WSZ];
		uint8_t pat[64];
		size_t n = strlen(argv[a + 1]) / 2, i;
		uint64_t mib = argc - a > 2 ? num(argv[a + 2]) : 1024, base;

		if (n == 0 || n > sizeof(pat)) {
			fprintf(stderr, "pramin: 1 to 64 bytes to find\n");
			return 1;
		}
		for (i = 0; i < n; i++)
			sscanf(argv[a + 1] + 2 * i, "%2hhx", &pat[i]);
		for (base = 0; base < mib << 20; base += WSZ) {
			for (i = 0; i < WSZ; i += 4) {
				uint32_t v = rd(base + i);

				memcpy(buf + i, &v, 4);
			}
			/* a match that crosses a window boundary is missed */
			for (i = 0; i + n <= WSZ; i += 4)
				if (buf[i] == pat[0] && !memcmp(buf + i, pat, n))
					printf("0x%09llx\n", (unsigned long long)(base + i));
		}
	} else {
		fprintf(stderr, "pramin: unknown command %s\n", argv[a]);
		return 1;
	}
	bar0[0x1700 / 4] = old;
	return 0;
}
