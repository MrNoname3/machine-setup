/*
 * vramtest [render node] [textures] [passes] [hold seconds]
 *
 * Fills VRAM with a pseudo-random pattern through 16 MiB RGBA8 textures,
 * waits, reads each texture back and counts the bits that changed. It renders
 * on the render node through GBM (default /dev/dri/renderD129); built with
 * -DVRAMTEST_X it takes the EGL display of the X server in DISPLAY instead,
 * which is how it runs on the NVIDIA driver. HIST=1 prints every changed bit
 * as "E texture word bit written-value"; REREAD=1 reads the first texture
 * twice more, and errors that differ between those reads happen on the read.
 *
 *   gcc -O2 -o vramtest vramtest.c -lEGL -lGLESv2 -lgbm
 *   gcc -O2 -DVRAMTEST_X -o vramtest-x vramtest.c -lEGL -lGLESv2
 */
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#ifndef VRAMTEST_X
#include <gbm.h>
#endif
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define W 2048
#define H 2048

static uint32_t rng(uint64_t *s)
{
	*s ^= *s << 13; *s ^= *s >> 7; *s ^= *s << 17;
	return (uint32_t)*s;
}

static void fill(uint32_t *p, int tex, int pass)
{
	uint64_t s = 0x9e3779b97f4a7c15ULL ^ ((uint64_t)tex << 32) ^ (uint64_t)pass;
	for (size_t i = 0; i < (size_t)W * H; i++)
		p[i] = rng(&s);
}

int main(int argc, char **argv)
{
	const char *node = argc > 1 ? argv[1] : "/dev/dri/renderD129";
	int ntex = argc > 2 ? atoi(argv[2]) : 40;
	int passes = argc > 3 ? atoi(argv[3]) : 3;
	int hold = argc > 4 ? atoi(argv[4]) : 10;
#ifdef VRAMTEST_X
	(void)node;
	EGLDisplay dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
#else
	int fd = open(node, O_RDWR);
	if (fd < 0) { perror(node); return 2; }
	struct gbm_device *gbm = gbm_create_device(fd);
	PFNEGLGETPLATFORMDISPLAYEXTPROC gpd =
		(void *)eglGetProcAddress("eglGetPlatformDisplayEXT");
	EGLDisplay dpy = gpd(EGL_PLATFORM_GBM_MESA, gbm, NULL);
#endif
	if (!eglInitialize(dpy, NULL, NULL)) { fprintf(stderr, "eglInitialize\n"); return 2; }
	eglBindAPI(EGL_OPENGL_ES_API);
	EGLint cfga[] = { EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
#ifdef VRAMTEST_X
			  EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
#endif
			  EGL_NONE };
	EGLConfig cfg; EGLint n;
	eglChooseConfig(dpy, cfga, &cfg, 1, &n);
	EGLint ctxa[] = { EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE };
	EGLContext ctx = eglCreateContext(dpy, n ? cfg : EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, ctxa);
	EGLSurface surf = EGL_NO_SURFACE;
#ifdef VRAMTEST_X
	EGLint pba[] = { EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE };
	surf = eglCreatePbufferSurface(dpy, cfg, pba);
#endif
	if (ctx == EGL_NO_CONTEXT || !eglMakeCurrent(dpy, surf, surf, ctx)) {
		fprintf(stderr, "context\n"); return 2;
	}
	printf("renderer %s, %d x %d MiB, %d passes, %d s hold\n",
	       glGetString(GL_RENDERER), ntex, W * H * 4 >> 20, passes, hold);
	GLuint *tex = calloc(ntex, sizeof(*tex)), fbo;
	uint32_t *src = malloc((size_t)W * H * 4), *dst = malloc((size_t)W * H * 4);
	glGenTextures(ntex, tex);
	glGenFramebuffers(1, &fbo);
	glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	long total = 0;
	for (int pass = 0; pass < passes; pass++) {
		for (int t = 0; t < ntex; t++) {
			glBindTexture(GL_TEXTURE_2D, tex[t]);
			if (pass == 0)
				glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, W, H);
			fill(src, t, pass);
			glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, src);
		}
		glFinish();
		if (glGetError()) { fprintf(stderr, "GL error while filling\n"); return 2; }
		sleep(hold);
		long bad = 0, words = 0;
		for (int t = 0; t < ntex; t++) {
			glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex[t], 0);
			glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, dst);
			fill(src, t, pass);
			for (size_t i = 0; i < (size_t)W * H; i++) {
				uint32_t x = src[i] ^ dst[i];
				if (x && getenv("HIST")) {
					for (int b = 0; b < 32; b++)
						if (x >> b & 1)
							printf("E %d %zu %d %d\n", t, i, b, (src[i] >> b) & 1);
				}
				if (x) {
					if (words < 8 && !getenv("HIST"))
						printf("  tex %d word %zu: wrote %08x read %08x\n", t, i, src[i], dst[i]);
					words++;
					bad += __builtin_popcount(x);
				}
			}
		}
		printf("pass %d: %ld bad words, %ld bad bits\n", pass, words, bad);
		/* the same data read twice more: errors that move are read errors */
		for (int r = 0; r < 2 && getenv("REREAD"); r++) {
			long rbad = 0;
			uint32_t *prev = malloc((size_t)W * H * 4);
			glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex[0], 0);
			glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, prev);
			glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, dst);
			fill(src, 0, pass);
			long e1 = 0, e2 = 0;
			for (size_t i = 0; i < (size_t)W * H; i++) {
				e1 += src[i] != prev[i];
				e2 += src[i] != dst[i];
				rbad += prev[i] != dst[i];
			}
			printf("  reread %d of tex 0: %ld and %ld bad words, %ld differ between the reads\n", r, e1, e2, rbad);
			free(prev);
		}
		fflush(stdout);
		total += bad;
	}
	printf("total bad bits: %ld\n", total);
	return total ? 1 : 0;
}
