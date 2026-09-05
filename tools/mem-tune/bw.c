/*
 * bw -- memory bandwidth, STREAM-style, at one thread count.
 *
 *   copy   c[i] = a[i]              1 read  + 1 write per element
 *   triad  a[i] = b[i] + k * c[i]   2 reads + 1 write per element
 *   read   sum of c[i]              1 read  per element
 *
 * The best of several passes is reported, because a slow pass only ever means
 * something else got in the way.
 *
 * Two things decide whether the number means anything:
 *
 * The working set must be far larger than last-level cache, or this measures
 * cache bandwidth and reports an impossible figure. The default is sized for
 * ordinary desktop caches; raise it on parts with a very large last level.
 *
 * The thread count matters more than it looks. One thread cannot keep enough
 * requests in flight to saturate a modern memory controller, so it understates
 * the ceiling badly. Far too many threads contend with each other and can also
 * read below the peak. Sweep the count rather than quoting a single figure.
 *
 * Arrays are initialised by the same threads that later read them, so pages
 * land near the thread that uses them on machines where that distinction
 * exists. Build with -fopenmp.
 *
 * usage: bw <threads> [MiB per array, default 192]
 */
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <omp.h>

static double now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec * 1e-9;
}

int main(int argc, char **argv)
{
	int nt = (argc > 1) ? atoi(argv[1]) : 1;
	size_t mib = (argc > 2) ? strtoul(argv[2], NULL, 10) : 192;
	size_t n = mib * 1024 * 1024 / sizeof(double);
	double *a, *b, *c;
	double best_copy = 1e30, best_triad = 1e30, best_read = 1e30, sink = 0;

	if (nt < 1) {
		fprintf(stderr, "usage: bw <threads> [MiB per array]\n");
		return 2;
	}
	omp_set_num_threads(nt);

	a = malloc(n * sizeof(double));
	b = malloc(n * sizeof(double));
	c = malloc(n * sizeof(double));
	if (!a || !b || !c) {
		fprintf(stderr, "allocation of 3 x %zu MiB failed\n", mib);
		return 1;
	}

	/* First touch from the worker threads, not from thread 0. */
#pragma omp parallel for
	for (size_t i = 0; i < n; i++) {
		a[i] = 1.0;
		b[i] = 2.0;
		c[i] = 0.0;
	}

	for (int r = 0; r < 5; r++) {
		double t0, d, acc = 0.0;

		t0 = now();
#pragma omp parallel for
		for (size_t i = 0; i < n; i++)
			c[i] = a[i];
		d = now() - t0;
		if (d < best_copy)
			best_copy = d;

		t0 = now();
#pragma omp parallel for
		for (size_t i = 0; i < n; i++)
			a[i] = b[i] + 3.0 * c[i];
		d = now() - t0;
		if (d < best_triad)
			best_triad = d;

		t0 = now();
#pragma omp parallel for reduction(+ : acc)
		for (size_t i = 0; i < n; i++)
			acc += c[i];
		d = now() - t0;
		if (d < best_read)
			best_read = d;
		sink += acc;
	}

	printf("threads=%-3d copy %6.1f GB/s   triad %6.1f GB/s   read %6.1f GB/s\n",
	       nt,
	       2.0 * n * sizeof(double) / best_copy / 1e9,
	       3.0 * n * sizeof(double) / best_triad / 1e9,
	       1.0 * n * sizeof(double) / best_read / 1e9);
	if (sink < 0)			/* keep the reduction from being optimised out */
		printf("!");

	free(a);
	free(b);
	free(c);
	return 0;
}
