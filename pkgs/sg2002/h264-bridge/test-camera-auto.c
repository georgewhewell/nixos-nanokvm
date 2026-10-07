/* SPDX-License-Identifier: GPL-2.0-only */
#define ioctl fake_ioctl
#include "camera-auto.c"
#undef ioctl
#include <assert.h>
#include <stdarg.h>

static int sync_start, sync_end, fail_sync;
int fake_ioctl(int fd, unsigned long request, ...)
{
	(void)fd;
	va_list ap;
	va_start(ap, request);
	void *arg = va_arg(ap, void *);
	va_end(ap);
	if (request == DMA_BUF_IOCTL_SYNC) {
		struct dma_buf_sync *s = arg;
		if (s->flags & DMA_BUF_SYNC_END) sync_end++; else sync_start++;
		return fail_sync ? -1 : 0;
	}
	assert(request == VIDIOC_S_EXT_CTRLS);
	return 0;
}

static void init(struct camera_auto *c)
{
	memset(c, 0, sizeof(*c));
	c->width = 64; c->height = 48; c->coded_height = 64; c->stride = 80;
	c->min_gain = 1024; c->max_gain = 77648;
	c->max_exposure = 1492; c->exposure = 1350; c->gain = 1024;
	c->quantum = 450; c->red = c->blue = 2048;
	for (int i = 0; i < 256; i++) {
		double x = i / 255.0;
		c->linear[i] = x <= .04045 ? x / 12.92 : pow((x + .055) / 1.055, 2.4);
	}
}

int main(void)
{
	struct camera_auto c;
	init(&c);
	uint8_t image[80 * 64 * 3 / 2];
	memset(image, 0xa5, sizeof(image));
	for (unsigned int y = 0; y < c.height; y++) memset(image + y * c.stride, 128, c.width);
	for (unsigned int y = 0; y < c.height / 2; y++) memset(image + (c.coded_height + y) * c.stride, 128, c.width);
	struct meter m = measure(&c, image);
	assert(m.count == 768 && m.whites == 768 && m.highlights == 0);
	assert(fabs(m.luma - 0.21586) < .0001);
	assert(fabs(m.red - m.green) < .0001 && fabs(m.blue - m.green) < .0001);
	uint8_t before[sizeof(image)]; memcpy(before, image, sizeof(image));
	assert(camera_auto_frame(&c, 99, image, sizeof(image)) == 0);
	assert(sync_start == 1 && sync_end == 1 && !memcmp(before, image, sizeof(image)));
	assert(camera_auto_frame(&c, 99, image, sizeof(image)) == 0 && sync_start == 1);
	c.next_sample = 0; fail_sync = 1;
	assert(camera_auto_frame(&c, 99, image, sizeof(image)) == -1);
	fail_sync = 0;
	assert(camera_auto_frame(&c, 99, image, sizeof(image) - 1) == -1);

	/* A bright-to-dark illumination step must converge without oscillation,
	 * preserve frame timing, and avoid gain when shutter time suffices. */
	for (unsigned int scene = 0; scene < 3; scene++) {
		init(&c);
		c.gain = scene == 0 ? c.max_gain : c.min_gain;
		double light = scene == 0 ? .0008 : scene == 1 ? .000005 : 0;
		for (int i = 0; i < 100; i++) {
			m = (struct meter){ .luma = light * c.exposure * c.gain / 1024, .count = 768 };
			exposure_target(&c, &m, &c.exposure, &c.gain);
			assert(c.exposure >= 1 && c.exposure <= 1492);
			assert(c.gain >= 1024 && c.gain <= 77648);
			assert(c.exposure < 450 || c.exposure % 450 == 0);
		}
		if (light) assert(m.luma > .14 && m.luma < .19);
		else assert(c.gain == c.max_gain && c.exposure == 1350);
	}
	init(&c); c.quantum = 375;
	m = (struct meter){ .luma = .001, .count = 768 };
	for (int i = 0; i < 100; i++) exposure_target(&c, &m, &c.exposure, &c.gain);
	assert(c.exposure == 1125 && c.gain == c.max_gain);
	/* Neutral surfaces under a warm lamp: feed each applied WB gain back
	 * into the simulated sensor RGB, and require convergence to grey. */
	init(&c);
	for (int i = 0; i < 150; i++) {
		double r = .15 * c.red / 1024.0, g = .20, b = .075 * c.blue / 1024.0;
		int rgb[3];
		double channels[] = { r, g, b };
		for (int j = 0; j < 3; j++)
			rgb[j] = (int)lround(255 * (1.055 * pow(channels[j], 1 / 2.4) - .055));
		int y = (int)lround(.299 * rgb[0] + .587 * rgb[1] + .114 * rgb[2]);
		int u = 128 + (int)lround(-.168736 * rgb[0] - .331264 * rgb[1] + .5 * rgb[2]);
		int v = 128 + (int)lround(.5 * rgb[0] - .418688 * rgb[1] - .081312 * rgb[2]);
		for (unsigned int row = 0; row < c.height; row++)
			memset(image + row * c.stride, y, c.width);
		for (unsigned int row = 0; row < c.height / 2; row++)
			for (unsigned int x = 0; x < c.width; x += 2) {
				image[(c.coded_height + row) * c.stride + x] = (uint8_t)u;
				image[(c.coded_height + row) * c.stride + x + 1] = (uint8_t)v;
			}
		c.next_sample = 0;
		assert(camera_auto_frame(&c, 99, image, sizeof(image)) == 0);
	}
	m = measure(&c, image);
	assert(m.whites == 768);
	assert(fabs(m.red / m.green - 1) < .04 && fabs(m.blue / m.green - 1) < .04);
	/* A saturated red object supplies no neutral evidence: hold WB. */
	int red = c.red, blue = c.blue;
	for (unsigned int row = 0; row < c.height; row++)
		memset(image + row * c.stride, 76, c.width);
	for (unsigned int row = 0; row < c.height / 2; row++)
		for (unsigned int x = 0; x < c.width; x += 2) {
			image[(c.coded_height + row) * c.stride + x] = 85;
			image[(c.coded_height + row) * c.stride + x + 1] = 255;
		}
	assert(measure(&c, image).whites == 0);
	c.next_sample = 0;
	assert(camera_auto_frame(&c, 99, image, sizeof(image)) == 0);
	assert(c.red == red && c.blue == blue);

	puts("camera auto: metering, padded surfaces, DMA ownership, AE/AWB convergence and limits OK");
	return 0;
}
