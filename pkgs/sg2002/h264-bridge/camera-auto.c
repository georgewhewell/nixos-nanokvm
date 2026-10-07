/* SPDX-License-Identifier: GPL-2.0-only */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <time.h>
#include <unistd.h>
#include <linux/dma-buf.h>
#include <linux/v4l2-subdev.h>
#include "camera-auto.h"

struct camera_auto {
	int sensor, capture;
	unsigned int width, height, stride, coded_height;
	int exposure, gain, red, blue, max_exposure, min_gain, max_gain;
	unsigned int quantum;
	uint64_t next_sample, next_log;
	double linear[256];
};

struct meter {
	double luma, red, green, blue;
	unsigned int whites, highlights, count;
};

static uint64_t now_ms(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (uint64_t)t.tv_sec * 1000U + (uint64_t)t.tv_nsec / 1000000U;
}

static int call(int fd, unsigned long request, void *arg)
{
	int ret;
	do ret = ioctl(fd, request, arg); while (ret < 0 && errno == EINTR);
	return ret;
}

static double clamp(double x, double lo, double hi)
{
	return x < lo ? lo : x > hi ? hi : x;
}

static int byte(int x) { return x < 0 ? 0 : x > 255 ? 255 : x; }

/* Meter a sparse grid before overlays. Gamma is undone for exposure/WB
 * arithmetic; no full-frame conversion or copy is needed. */
static struct meter measure(const struct camera_auto *c, const uint8_t *image)
{
	const uint8_t *uv = image + (size_t)c->stride * c->coded_height;
	struct meter m = { 0 };
	double weighted = 0, weights = 0;
	for (unsigned int row = 0; row < 24; row++) {
		unsigned int y = (2 * row + 1) * c->height / 48;
		for (unsigned int col = 0; col < 32; col++) {
			unsigned int x = (2 * col + 1) * c->width / 64;
			int l = image[(size_t)y * c->stride + x];
			size_t off = (size_t)(y / 2) * c->stride + (x & ~1U);
			int u = (int)uv[off] - 128, v = (int)uv[off + 1] - 128;
			double r = c->linear[byte(l + ((22970 * v + 8192) >> 14))];
			double g = c->linear[byte(l - ((5638 * u + 11700 * v + 8192) >> 14))];
			double b = c->linear[byte(l + ((29032 * u + 8192) >> 14))];
			double high = fmax(r, fmax(g, b)), low = fmin(r, fmin(g, b));
			/* Centre-weighted metering, with the whole scene represented. */
			double weight = row >= 6 && row < 18 && col >= 8 && col < 24 ? 2 : 1;
			weighted += weight * (0.2126 * r + 0.7152 * g + 0.0722 * b);
			weights += weight;
			m.count++;
			m.highlights += high > 0.95;
			/* Grey-world WB uses moderately neutral, adequately exposed
			 * samples. Reject saturated lights, deep shadows and strongly
			 * coloured objects instead of forcing every scene to grey. */
			if (low > 0.015 && high < 0.8 && high < low * 2.5) {
				m.red += r; m.green += g; m.blue += b;
				m.whites++;
			}
		}
	}
	m.luma = weighted / weights;
	return m;
}

static void exposure_target(const struct camera_auto *c, const struct meter *m,
	int *exposure, int *gain)
{
	double ratio = 0.16 / fmax(m->luma, 0.001);
	/* A few specular highlights must not darken the whole picture. */
	if (m->highlights > m->count / 20 && ratio > 0.75) ratio = 0.75;
	if (ratio >= 0.88 && ratio <= 1.12) {
		*exposure = c->exposure; *gain = c->gain;
		return;
	}
	double total = c->exposure * (double)c->gain * sqrt(clamp(ratio, 0.5, 2.0));
	int lines = (int)clamp(total / c->min_gain, 1, c->max_exposure);
	/* GC4653's 1440p mode is 45,000 lines/s. At long exposures use
	 * complete 100/120 Hz lighting periods; retain continuous control
	 * below one period. Gain fills the gaps between shutter steps. */
	if (c->quantum && lines >= (int)c->quantum)
		lines = lines / (int)c->quantum * (int)c->quantum;
	*exposure = lines;
	*gain = (int)lround(clamp(total / lines, c->min_gain, c->max_gain));
}

static int set_pair(int fd, unsigned int a, int av, unsigned int b, int bv)
{
	struct v4l2_ext_control values[] = { { .id = a, .value = av }, { .id = b, .value = bv } };
	struct v4l2_ext_controls controls = { .count = 2, .controls = values };
	return call(fd, VIDIOC_S_EXT_CTRLS, &controls);
}

static int get_value(int fd, unsigned int id, int *value)
{
	struct v4l2_control control = { .id = id };
	if (call(fd, VIDIOC_G_CTRL, &control)) return -1;
	*value = control.value;
	return 0;
}

struct camera_auto *camera_auto_open(const char *sensor, int capture,
	const struct v4l2_pix_format *format, unsigned int width,
	unsigned int height, unsigned int mains)
{
	struct camera_auto *c = calloc(1, sizeof(*c));
	struct v4l2_subdev_capability cap = { 0 };
	struct v4l2_queryctrl exposure = { .id = V4L2_CID_EXPOSURE };
	struct v4l2_queryctrl gain = { .id = V4L2_CID_ANALOGUE_GAIN };
	if (!c) return NULL;
	c->sensor = -1;
	if (!width || !height || ((width | height) & 1U) ||
	    format->bytesperline < width || format->height < height ||
	    format->pixelformat != V4L2_PIX_FMT_NV12 ||
	    format->xfer_func != V4L2_XFER_FUNC_SRGB ||
	    format->ycbcr_enc != V4L2_YCBCR_ENC_601 ||
	    format->quantization != V4L2_QUANTIZATION_FULL_RANGE ||
	    (mains != 0 && mains != 50 && mains != 60)) {
		fprintf(stderr, "camera auto: requires hardware sRGB/full-range BT.601 NV12\n");
		goto fail;
	}
	c->sensor = open(sensor, O_RDWR | O_CLOEXEC);
	if (c->sensor < 0 || call(c->sensor, VIDIOC_SUBDEV_QUERYCAP, &cap)) goto fail;
	/* The exposure timebase belongs to this fixed GC4653 mode. */
	char name[128];
	struct stat st;
	if (fstat(c->sensor, &st)) goto fail;
	snprintf(name, sizeof(name), "/sys/dev/char/%u:%u/name", major(st.st_rdev), minor(st.st_rdev));
	FILE *f = fopen(name, "r");
	if (!f) goto fail;
	char driver[128] = { 0 };
	int identified = fgets(driver, sizeof(driver), f) && !strncmp(driver, "gc4653 ", 7);
	fclose(f);
	if (!identified) { fprintf(stderr, "camera auto: expected a GC4653 subdevice\n"); goto fail; }
	if (call(c->sensor, VIDIOC_QUERYCTRL, &exposure) ||
	    call(c->sensor, VIDIOC_QUERYCTRL, &gain) ||
	    get_value(c->sensor, V4L2_CID_EXPOSURE, &c->exposure) ||
	    get_value(c->sensor, V4L2_CID_ANALOGUE_GAIN, &c->gain)) goto fail;
	c->capture = capture;
	c->width = width; c->height = height;
	c->stride = format->bytesperline; c->coded_height = format->height;
	/* Preserve the user's frame interval; automatic exposure never lowers fps. */
	c->max_exposure = exposure.maximum;
	c->min_gain = gain.minimum; c->max_gain = gain.maximum;
	c->quantum = mains ? 45000U / (2U * mains) : 0;
	/* Starting point only; measured neutral samples refine both gains. */
	c->red = c->blue = 2048;
	if (set_pair(capture, V4L2_CID_RED_BALANCE, c->red, V4L2_CID_BLUE_BALANCE, c->blue)) goto fail;
	for (int i = 0; i < 256; i++) {
		double x = i / 255.0;
		c->linear[i] = x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4);
	}
	fprintf(stderr, "camera auto: GC4653 AE/AWB, %u Hz lighting, exposure <= %d lines\n",
		mains, c->max_exposure);
	return c;
fail:
	fprintf(stderr, "camera auto: initialization failed: %s\n", strerror(errno));
	camera_auto_close(c);
	return NULL;
}

int camera_auto_frame(struct camera_auto *c, int dmabuf, const void *pixels, size_t length)
{
	uint64_t now = now_ms();
	if (now < c->next_sample) return 0;
	if (length < (size_t)c->stride * c->coded_height * 3 / 2) return -1;
	struct dma_buf_sync sync = { .flags = DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ };
	if (call(dmabuf, DMA_BUF_IOCTL_SYNC, &sync)) return -1;
	struct meter m = measure(c, pixels);
	sync.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ;
	if (call(dmabuf, DMA_BUF_IOCTL_SYNC, &sync)) return -1;
	c->next_sample = now + 200;
	int exposure, gain;
	exposure_target(c, &m, &exposure, &gain);
	if ((exposure != c->exposure || gain != c->gain) &&
	    set_pair(c->sensor, V4L2_CID_EXPOSURE, exposure, V4L2_CID_ANALOGUE_GAIN, gain)) return -1;
	c->exposure = exposure; c->gain = gain;
	if (m.whites >= 32) {
		int red = (int)lround(clamp(c->red * clamp(m.green / m.red, 0.98, 1.02), 512, 4096));
		int blue = (int)lround(clamp(c->blue * clamp(m.green / m.blue, 0.98, 1.02), 512, 4096));
		if ((red != c->red || blue != c->blue) &&
		    set_pair(c->capture, V4L2_CID_RED_BALANCE, red, V4L2_CID_BLUE_BALANCE, blue)) return -1;
		c->red = red; c->blue = blue;
	}
	if (now >= c->next_log) {
		fprintf(stderr, "camera auto: luma %.3f, exposure %.1f ms, gain %.1fx, WB %.2f/1/%.2f, %u neutral samples\n",
			m.luma, c->exposure / 45.0, c->gain / 1024.0, c->red / 1024.0, c->blue / 1024.0, m.whites);
		c->next_log = now + 5000;
	}
	return 0;
}

void camera_auto_close(struct camera_auto *c)
{
	if (!c) return;
	if (c->sensor >= 0) close(c->sensor);
	free(c);
}
