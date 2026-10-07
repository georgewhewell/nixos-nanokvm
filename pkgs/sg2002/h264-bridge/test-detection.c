/* SPDX-License-Identifier: GPL-2.0-only */
/* Host checks for pixel layout and YOLO postprocessing; no hardware emulation. */
#define ioctl detection_test_ioctl
#include "detection.c"
#undef ioctl
#include <assert.h>
#include <stdarg.h>

static unsigned int sync_calls;
int detection_test_ioctl(int fd, unsigned long request, ...)
{
	va_list args;
	va_start(args, request);
	struct dma_buf_sync *sync = va_arg(args, struct dma_buf_sync *);
	va_end(args);
	assert(fd == 123 && request == DMA_BUF_IOCTL_SYNC);
	assert(sync->flags == (DMA_BUF_SYNC_RW | (sync_calls % 2 ? DMA_BUF_SYNC_END : DMA_BUF_SYNC_START)));
	sync_calls++;
	return 0;
}

void *CVI_NN_TensorPtr(CVI_TENSOR *t) { return t->sys_mem; }
CVI_RC CVI_NN_RegisterModel(const char *path, CVI_MODEL_HANDLE *model)
{ (void)path; (void)model; abort(); }
CVI_RC CVI_NN_GetInputOutputTensors(CVI_MODEL_HANDLE model, CVI_TENSOR **in,
	int32_t *nin, CVI_TENSOR **out, int32_t *nout)
{ (void)model; (void)in; (void)nin; (void)out; (void)nout; abort(); }
CVI_RC CVI_NN_Forward(CVI_MODEL_HANDLE model, CVI_TENSOR in[], int32_t nin,
	CVI_TENSOR out[], int32_t nout)
{ (void)model; (void)in; (void)nin; (void)out; (void)nout; abort(); }
CVI_RC CVI_NN_CleanupModel(CVI_MODEL_HANDLE model) { (void)model; abort(); }

static void input_colours(void)
{
	uint8_t snapshot[8 * 4 * 3 / 2];
	CVI_TENSOR input = { .mem_size = 3 * 640 * 640 };
	input.sys_mem = malloc(input.mem_size);
	assert(input.sys_mem);
	struct sg2002_detection d = { .width = 8, .height = 4,
		.resized_w = 640, .resized_h = 320, .input = &input,
		.snapshot = snapshot, .cy = 16384, .rv = 22970,
		.gu = 5638, .gv = 11700, .bu = 29032 };
	assert(!input_transfer(&d, V4L2_XFER_FUNC_SRGB));
	/* Full-range BT.601 red, including the first/last interpolated pixels. */
	memset(snapshot, 76, 32);
	for (size_t i = 32; i < sizeof(snapshot); i += 2) {
		snapshot[i] = 85; snapshot[i + 1] = 255;
	}
	prepare_input(&d);
	for (unsigned int y = 0; y < 640; y++)
		for (unsigned int x = 0; x < 640; x++) {
			unsigned int pos = y * 640 + x;
			if (y >= 160 && y < 480) {
				assert(input.sys_mem[pos] >= 252);
				assert(input.sys_mem[640 * 640 + pos] <= 2);
				assert(input.sys_mem[2 * 640 * 640 + pos] <= 2);
			} else {
				assert(input.sys_mem[pos] == 0);
				assert(input.sys_mem[640 * 640 + pos] == 0);
				assert(input.sys_mem[2 * 640 * 640 + pos] == 0);
			}
		}
	/* Limited-range black/white must not be interpreted as full range. */
	d.cy = 19077; d.offset = 16; d.rv = 26149;
	d.gu = 6419; d.gv = 13320; d.bu = 33050;
	memset(snapshot + 32, 128, 16);
	for (int white = 0; white < 2; white++) {
		memset(snapshot, white ? 235 : 16, 32);
		prepare_input(&d);
		assert(input.sys_mem[320 * 640 + 320] == (white ? 255 : 0));
	}
	/* Linear camera grey must reach the model as sRGB, not dark linear RGB. */
	d.cy = 16384; d.offset = 0;
	memset(snapshot, 128, sizeof(snapshot));
	assert(!input_transfer(&d, V4L2_XFER_FUNC_NONE));
	prepare_input(&d);
	assert(input.sys_mem[320 * 640 + 320] == 188);
	assert(d.to_srgb[0] == 0 && d.to_srgb[255] == 255);
	assert(!input_transfer(&d, V4L2_XFER_FUNC_709));
	assert(d.to_srgb[128] == 140);
	assert(input_transfer(&d, V4L2_XFER_FUNC_SMPTE2084) == -1);
	free(input.sys_mem);
}

static void overlay_bounds(void)
{
	/* Visible 8x6, stride 16, coded height 16: chroma is NOT after row 6. */
	uint8_t guard[16 + 16 * 16 * 3 / 2 + 16];
	memset(guard, 0xa5, sizeof(guard));
	struct sg2002_detection d = { .width = 8, .height = 6, .stride = 16, .coded_height = 16 };
	struct result r = { .count = 2, .boxes = {
		{ -200, -200, 210, 210, .9f, 0 }, { 800, 800, 20, 20, .5f, 79 }
	} };
	paint(&d, guard + 16, &r);
	for (size_t i = 0; i < sizeof(guard); i++) {
		int y_plane = i >= 16 && i < 16 + 16 * 6 && (i - 16) % 16 < 8;
		int uv_plane = i >= 16 + 16 * 16 && i < 16 + 16 * 16 + 16 * 3 && (i - 16) % 16 < 8;
		if (!y_plane && !uv_plane) assert(guard[i] == 0xa5);
	}
}

static void postprocessing(void)
{
	CVI_TENSOR output[3] = { 0 };
	struct sg2002_detection d = { .width = 640, .height = 360,
		.resized_w = 640, .resized_h = 360, .output = output };
	d.candidates = calloc(MAX_CANDIDATES, sizeof(*d.candidates));
	assert(d.candidates);
	for (unsigned int i = 0; i < 3; i++) {
		size_t count = 255U * (80U >> i) * (80U >> i);
		float *values = malloc(count * sizeof(*values)); assert(values);
		for (size_t j = 0; j < count; j++) values[j] = -20;
		output[i].sys_mem = (uint8_t *)values;
	}
	struct result r = { 0 };
	decode(&d, &r); assert(r.count == 0);
	/* Two overlapping bicycles should collapse, while an overlapping dog
	 * must survive class-aware NMS. All have a 0.5*0.5 score initially. */
	float *v = (float *)output[2].sys_mem;
	for (unsigned int i = 0; i < 3; i++) {
		unsigned int cell = 10 * 20 + 10 + i;
		for (unsigned int field = 0; field < 5; field++) v[(2 * 85 + field) * 400 + cell] = 0;
		v[(2 * 85 + 5 + (i == 2 ? 16U : 1U)) * 400 + cell] = 0;
	}
	decode(&d, &r); assert(r.count == 0); /* Strict confidence > 0.25. */
	for (unsigned int i = 0; i < 3; i++) v[(2 * 85 + 4) * 400 + 10 * 20 + 10 + i] = 2;
	decode(&d, &r); assert(r.count == 2);
	assert(r.boxes[0].cls != r.boxes[1].cls);
	/* Padding is removed when mapping the 640x640 head to 640x360 video. */
	assert(fabsf(r.boxes[0].y - (336.0f - 326.0f / 2 - 140)) < .01f);
	for (unsigned int i = 0; i < 3; i++) free(output[i].sys_mem);
	free(d.candidates);
}

static void frame_ownership(void)
{
	uint8_t image[16 * 16 * 3 / 2], snapshot[8 * 4 * 3 / 2];
	struct sg2002_detection d = { .width = 8, .height = 4, .stride = 16,
		.coded_height = 16, .fps = 2, .snapshot = snapshot,
		.latest = { .count = 1, .boxes = { { 0, 0, 6, 4, .8f, 16 } } } };
	assert(!pthread_mutex_init(&d.lock, NULL));
	assert(!pthread_cond_init(&d.ready, NULL));
	memset(image, 69, 16 * 16);
	memset(image + 16 * 16, 128, sizeof(image) - 16 * 16);
	d.latest.sampled = milliseconds();
	assert(!sg2002_detection_frame(&d, 123, image, sizeof(image)));
	assert(d.busy && d.pending && sync_calls == 2);
	/* Snapshot precedes overlay writes and excludes stride/coded padding. */
	for (unsigned int i = 0; i < 32; i++) assert(snapshot[i] == 69);
	for (unsigned int i = 32; i < sizeof(snapshot); i++) assert(snapshot[i] == 128);
	memset(image, 84, 16 * 16);
	d.next_sample = 0;
	assert(!sg2002_detection_frame(&d, 123, image, sizeof(image)));
	assert(sync_calls == 4);
	for (unsigned int i = 0; i < 32; i++) assert(snapshot[i] == 69); /* Busy sample cannot be overwritten. */
	d.busy = 0; d.next_sample = milliseconds() + 10000;
	d.latest.sampled = milliseconds() - 5000;
	memset(image, 84, sizeof(image));
	assert(!sg2002_detection_frame(&d, 123, image, sizeof(image)));
	assert(sync_calls == 4);
	for (size_t i = 0; i < sizeof(image); i++) assert(image[i] == 84); /* Stale boxes expire. */
	assert(sg2002_detection_frame(&d, 123, image, sizeof(image) - 1) == -1);
	d.failed = 1;
	assert(sg2002_detection_frame(&d, 123, image, sizeof(image)) == -1);
	assert(sync_calls == 4);
	pthread_cond_destroy(&d.ready); pthread_mutex_destroy(&d.lock);
}

int main(void)
{
	input_colours(); overlay_bounds(); postprocessing(); frame_ownership();
	puts("PASS: NV12 colour/letterbox, plane/stride guards, NMS, sample ownership and stale results");
	return 0;
}
