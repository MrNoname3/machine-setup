/*
 * cap -- how large a working set this machine can actually hold.
 *
 * Allocates a buffer, touches every page of it, then reads pages at random for
 * a fixed wall-clock window. It reports how fast the fill ran, how many pages
 * the kernel had to evict to make room, and how long the machine was *fully*
 * stalled on memory while it did so.
 *
 * Latency and bandwidth say nothing about whether a machine has enough memory.
 * This does. Below the limit the fill rate is flat and nothing is evicted;
 * above it the fill rate collapses, eviction counts jump and stall time
 * appears. The size where that happens is the answer to "do I need more RAM",
 * and it is the one figure here that maps onto how the machine actually feels.
 *
 * The buffer is filled with incompressible data on purpose. Compressed swap
 * (zram, zswap) absorbs the zero-filled or repetitive pages a naive benchmark
 * produces almost for free, which makes a machine look like it has several
 * times the memory it has. One incompressible source page, copied everywhere,
 * defeats that without costing much time to generate.
 *
 * THE TRAP, and the reason the guard below looks over-cautious:
 * an earlier version counted SwapFree as available headroom. Where swap is
 * compressed and RAM-backed, a page pushed into it frees almost nothing --
 * least of all one that was made incompressible on purpose. Counting swap as
 * headroom therefore let the test allocate far past what the machine could
 * hold, and the run ended with the OOM killer. Only MemAvailable is real
 * headroom for this workload. On a machine with ordinary disk-backed swap the
 * guard is merely conservative, which is the right way to be wrong.
 *
 * usage: cap <MiB> [seconds of random access, default 5]
 * exit:  0 measured, 2 bad usage, 3 refused as unsafe, 1 allocation failed
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdint.h>
#include <sys/mman.h>

static double now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec * 1e-9;
}

/* One counter out of /proc/vmstat, or -1 if the kernel does not export it. */
static long vmstat_get(const char *key)
{
	FILE *f = fopen("/proc/vmstat", "r");
	char k[64];
	long v, r = -1;

	while (f && fscanf(f, "%63s %ld", k, &v) == 2)
		if (!strcmp(k, key)) {
			r = v;
			break;
		}
	if (f)
		fclose(f);
	return r;
}

/* Cumulative microseconds in which *every* task was stalled on memory.
   Absent on kernels built without pressure stall information. */
static long psi_full_total(void)
{
	FILE *f = fopen("/proc/pressure/memory", "r");
	char line[256];
	long r = -1;

	while (f && fgets(line, sizeof line, f))
		if (strstr(line, "full")) {
			char *t = strstr(line, "total=");
			if (t)
				r = atol(t + 6);
		}
	if (f)
		fclose(f);
	return r;
}

static long meminfo(const char *key)
{
	FILE *f = fopen("/proc/meminfo", "r");
	char k[64], unit[16];
	long v, r = -1;

	while (f && fscanf(f, "%63s %ld %15s", k, &v, unit) >= 2)
		if (!strcmp(k, key)) {
			r = v;
			break;
		}
	if (f)
		fclose(f);
	return r;
}

int main(int argc, char **argv)
{
	size_t mb, sz, pages;
	double secs, t_fill0, t_fill1, t0, t1;
	long headroom_kb, avail0, si0, so0, p0, si1, so1, p1;
	static char src[4096];
	uint64_t s = 0x9E3779B97F4A7C15ULL;
	volatile long acc = 0;
	size_t touched = 0;
	char *buf;

	if (argc < 2) {
		fprintf(stderr, "usage: cap <MiB> [seconds]\n");
		return 2;
	}
	mb = strtoul(argv[1], NULL, 10);
	secs = (argc > 2) ? atof(argv[2]) : 5.0;

	headroom_kb = meminfo("MemAvailable:");
	if (headroom_kb < 0) {
		fprintf(stderr, "REFUSED: /proc/meminfo has no MemAvailable\n");
		return 3;
	}
	if ((long)mb * 1024 > headroom_kb * 90 / 100) {
		fprintf(stderr, "REFUSED: %zu MiB > 90%% of MemAvailable (%ld MiB)\n",
			mb, headroom_kb / 1024);
		return 3;
	}

	sz = mb * 1024UL * 1024UL;
	pages = sz / 4096;
	buf = mmap(NULL, sz, PROT_READ | PROT_WRITE,
		   MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
	if (buf == MAP_FAILED) {
		perror("mmap");
		return 1;
	}

	for (int i = 0; i < 4096; i += 8) {	/* incompressible source page */
		s ^= s << 13;
		s ^= s >> 7;
		s ^= s << 17;
		memcpy(src + i, &s, 8);
	}

	avail0 = meminfo("MemAvailable:");
	si0 = vmstat_get("pswpin");
	so0 = vmstat_get("pswpout");
	p0 = psi_full_total();

	t_fill0 = now();
	for (size_t i = 0; i < pages; i++)
		memcpy(buf + i * 4096, src, 4096);
	t_fill1 = now();

	/* Independent random reads: this is deliberately not a dependent chain,
	   so in-memory it reports throughput of a few tens of nanoseconds. What
	   makes the number jump is a page that has to come back from swap. */
	t0 = now();
	t1 = t0;
	while (t1 - t0 < secs) {
		for (int j = 0; j < 1024; j++) {
			s ^= s << 13;
			s ^= s >> 7;
			s ^= s << 17;
			acc += buf[(s % pages) * 4096];
		}
		touched += 1024;
		t1 = now();
	}

	si1 = vmstat_get("pswpin");
	so1 = vmstat_get("pswpout");
	p1 = psi_full_total();

	printf("%6zu MiB | fill %7.2f s (%6.0f MiB/s) | random %9.0f ns/acc"
	       " | swap-in %8ld | swap-out %8ld | stalled %6.2f s"
	       " | MemAvail@start %ld MiB\n",
	       mb, t_fill1 - t_fill0, sz / 1048576.0 / (t_fill1 - t_fill0),
	       (t1 - t0) * 1e9 / touched, si1 - si0, so1 - so0,
	       (p1 >= 0 && p0 >= 0) ? (p1 - p0) / 1e6 : -1.0, avail0 / 1024);
	if (acc == -1)
		printf("!");

	munmap(buf, sz);
	return 0;
}
