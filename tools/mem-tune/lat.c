/*
 * lat -- memory latency, measured by pointer chasing.
 *
 * Walks a randomised cycle of cache lines through buffers of increasing size,
 * so the reported figure crosses L1, L2, L3 and finally main memory. Each
 * access depends on the address loaded by the previous one, so the processor
 * cannot overlap them: the number is latency, not throughput.
 *
 * Every size is measured several times and the MINIMUM is reported. Noise on a
 * running desktop only ever adds time, so the minimum is the stable estimator;
 * averaging drags in whatever else the machine happened to be doing. Reporting
 * the mean of a handful of runs gave a run-to-run spread near ten percent on a
 * test system, which cannot resolve the few percent that a memory change is
 * usually worth. The minimum of five brought that under one percent.
 *
 * The spread column is how far the worst pass of a set fell from the best.
 * Treat a size with a large spread as unusable rather than averaging it away:
 * buffers that straddle a cache boundary stay noisy no matter how many passes
 * they get, because the result depends on how the allocator happened to colour
 * the pages. Read the trend across sizes, and quote the stable points.
 *
 * Pin this to a fixed core (taskset) and compare only against runs made on the
 * same core and the same power profile.
 *
 * Environment: MT_REPS (passes per size, default 5)
 *              MT_ITERS (dependent loads per pass, default 20000000)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdint.h>

static double now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static size_t env_size(const char *name, size_t fallback)
{
	const char *v = getenv(name);
	if (!v || !*v)
		return fallback;
	return strtoul(v, NULL, 10);
}

int main(void)
{
	/* 32 KiB to 256 MiB: small enough to land inside the smallest L1 in use,
	   large enough that the last points are unambiguously main memory. */
	size_t sizes[] = { 32768, 131072, 524288, 2097152, 8388608,
			   16777216, 33554432, 67108864, 134217728, 268435456 };
	int n = sizeof(sizes) / sizeof(sizes[0]);
	size_t reps = env_size("MT_REPS", 5);
	size_t iters = env_size("MT_ITERS", 20000000);

	printf("%10s  %10s  %8s\n", "size", "ns/access", "spread");
	for (int i = 0; i < n; i++) {
		size_t sz = sizes[i], stride = 64, nelem = sz / stride;
		size_t *idx = malloc(nelem * sizeof(size_t));
		char *buf = aligned_alloc(4096, sz);
		double best = 1e30, worst = 0;
		void *p;

		if (!buf || !idx) {
			fprintf(stderr, "allocation of %zu KiB failed\n", sz / 1024);
			return 1;
		}
		memset(buf, 0, sz);

		/* Build one closed cycle visiting every cache line exactly once, in
		   random order, so neither the prefetcher nor the page walker can
		   predict the next address. */
		for (size_t j = 0; j < nelem; j++)
			idx[j] = j;
		for (size_t j = nelem - 1; j > 0; j--) {
			size_t k = ((size_t)rand() << 15 | rand()) % (j + 1);
			size_t t = idx[j];
			idx[j] = idx[k];
			idx[k] = t;
		}
		for (size_t j = 0; j < nelem; j++) {
			size_t cur = idx[j], next = idx[(j + 1) % nelem];
			*(void **)(buf + cur * stride) = (void *)(buf + next * stride);
		}

		p = (void *)(buf + idx[0] * stride);
		for (size_t r = 0; r < reps; r++) {
			double t0, d;

			for (size_t j = 0; j < nelem; j++)	/* warm the cycle */
				p = *(void **)p;
			t0 = now();
			for (size_t j = 0; j < iters; j++)
				p = *(void **)p;
			d = (now() - t0) * 1e9 / iters;
			if (d < best)
				best = d;
			if (d > worst)
				worst = d;
		}
		/* Keep the chase alive so the compiler cannot discard it. */
		if (p == (void *)1)
			printf("!");

		printf("%8zu K  %10.2f  %7.1f%%\n", sz / 1024, best,
		       (worst - best) / best * 100.0);
		free(idx);
		free(buf);
	}
	return 0;
}
