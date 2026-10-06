/* SPDX-License-Identifier: GPL-2.0-only */
#define _GNU_SOURCE
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <linux/dma-buf.h>
#include <cviruntime.h>
#include "detection.h"

#define MODEL_SIZE 640U
#define MAX_BOXES 32U
#define MAX_CANDIDATES 25200U

struct box { float x, y, w, h, score; unsigned int cls; };
struct result { struct box boxes[MAX_BOXES]; unsigned int count; uint64_t sampled; };

struct sg2002_detection {
	CVI_MODEL_HANDLE model;
	CVI_TENSOR *input, *output;
	int input_count, output_count;
	unsigned int width, height, stride, coded_height, resized_w, resized_h;
	unsigned int fps;
	int cy, rv, gu, gv, bu, offset;
	uint8_t *snapshot;
	struct box *candidates;
	pthread_t thread;
	pthread_mutex_t lock;
	pthread_cond_t ready;
	int started, stopping, busy, pending, failed;
	uint64_t next_sample, sampled, completed, total_ms;
	struct result latest;
};

static const char *const names[] = {
	"PERSON", "BICYCLE", "CAR", "MOTORCYCLE", "AIRPLANE", "BUS", "TRAIN", "TRUCK",
	"BOAT", "TRAFFIC LIGHT", "FIRE HYDRANT", "STOP SIGN", "PARKING METER", "BENCH",
	"BIRD", "CAT", "DOG", "HORSE", "SHEEP", "COW", "ELEPHANT", "BEAR", "ZEBRA",
	"GIRAFFE", "BACKPACK", "UMBRELLA", "HANDBAG", "TIE", "SUITCASE", "FRISBEE",
	"SKIS", "SNOWBOARD", "SPORTS BALL", "KITE", "BASEBALL BAT", "BASEBALL GLOVE",
	"SKATEBOARD", "SURFBOARD", "TENNIS RACKET", "BOTTLE", "WINE GLASS", "CUP",
	"FORK", "KNIFE", "SPOON", "BOWL", "BANANA", "APPLE", "SANDWICH", "ORANGE",
	"BROCCOLI", "CARROT", "HOT DOG", "PIZZA", "DONUT", "CAKE", "CHAIR", "COUCH",
	"POTTED PLANT", "BED", "DINING TABLE", "TOILET", "TV", "LAPTOP", "MOUSE",
	"REMOTE", "KEYBOARD", "CELL PHONE", "MICROWAVE", "OVEN", "TOASTER", "SINK",
	"REFRIGERATOR", "BOOK", "CLOCK", "VASE", "SCISSORS", "TEDDY BEAR",
	"HAIR DRIER", "TOOTHBRUSH"
};

static uint64_t milliseconds(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (uint64_t)t.tv_sec * 1000U + (uint64_t)t.tv_nsec / 1000000U;
}

static uint8_t clip(int value)
{
	return (uint8_t)(value < 0 ? 0 : value > 255 ? 255 : value);
}

/* Bilinear sampling in pixel-centre coordinates, with edge replication.
 * step=2 selects one component of interleaved NV12 chroma. */
static int sample(const uint8_t *p, unsigned int width, unsigned int height,
	unsigned int stride, unsigned int step, int x, int y)
{
	unsigned int ix, iy, fx, fy, nx, ny;
	x = x < 0 ? 0 : x;
	y = y < 0 ? 0 : y;
	ix = (unsigned int)x >> 8;
	iy = (unsigned int)y >> 8;
	if (ix >= width) ix = width - 1;
	if (iy >= height) iy = height - 1;
	fx = (unsigned int)x & 255U;
	fy = (unsigned int)y & 255U;
	nx = ix + 1 < width ? ix + 1 : ix;
	ny = iy + 1 < height ? iy + 1 : iy;
	return (int)((p[iy * stride + ix * step] * (256U - fx) * (256U - fy) +
		p[iy * stride + nx * step] * fx * (256U - fy) +
		p[ny * stride + ix * step] * (256U - fx) * fy +
		p[ny * stride + nx * step] * fx * fy + 32768U) >> 16);
}

static void prepare_input(struct sg2002_detection *d)
{
	uint8_t *rgb = CVI_NN_TensorPtr(d->input);
	const uint8_t *uv = d->snapshot + (size_t)d->width * d->height;
	unsigned int top = (MODEL_SIZE - d->resized_h) / 2;
	unsigned int left = (MODEL_SIZE - d->resized_w) / 2;
	const unsigned int plane = MODEL_SIZE * MODEL_SIZE;

	memset(rgb, 0, d->input->mem_size);
	for (unsigned int y = 0; y < d->resized_h; y++) {
		int sy = (int)(((uint64_t)y * 2 + 1) * d->height * 128 / d->resized_h) - 128;
		for (unsigned int x = 0; x < d->resized_w; x++) {
			int sx = (int)(((uint64_t)x * 2 + 1) * d->width * 128 / d->resized_w) - 128;
			int luma = sample(d->snapshot, d->width, d->height, d->width, 1, sx, sy);
			int u = sample(uv, d->width / 2, d->height / 2, d->width, 2, sx / 2, sy / 2) - 128;
			int v = sample(uv + 1, d->width / 2, d->height / 2, d->width, 2, sx / 2, sy / 2) - 128;
			unsigned int pos = (y + top) * MODEL_SIZE + x + left;
			int base = (luma - d->offset) * d->cy;
			rgb[pos] = clip((base + d->rv * v + 8192) >> 14);
			rgb[plane + pos] = clip((base - d->gu * u - d->gv * v + 8192) >> 14);
			rgb[2 * plane + pos] = clip((base + d->bu * u + 8192) >> 14);
		}
	}
}

static float sigmoid(float x) { return 1.0f / (1.0f + expf(-x)); }

static float iou(const struct box *a, const struct box *b)
{
	float w = fmaxf(0, fminf(a->x + a->w, b->x + b->w) - fmaxf(a->x, b->x));
	float h = fmaxf(0, fminf(a->y + a->h, b->y + b->h) - fmaxf(a->y, b->y));
	float intersection = w * h;
	return intersection / (a->w * a->h + b->w * b->h - intersection);
}

static int compare_boxes(const void *a, const void *b)
{
	float x = ((const struct box *)a)->score, y = ((const struct box *)b)->score;
	return x < y ? 1 : x > y ? -1 : 0;
}

static void decode(struct sg2002_detection *d, struct result *result)
{
	/* YOLOv5 v6.0 head layout and decoding reference:
	 * https://github.com/ultralytics/yolov5/blob/v6.0/models/yolo.py */
	static const float anchors[3][3][2] = {
		{{10,13}, {16,30}, {33,23}}, {{30,61}, {62,45}, {59,119}},
		{{116,90}, {156,198}, {373,326}}
	};
	unsigned int count = 0;
	/* YOLOv5 v6.0 defaults: confidence 0.25, class-aware NMS IoU 0.45. */
	for (unsigned int layer = 0; layer < 3; layer++) {
		unsigned int side = 80U >> layer, plane = side * side;
		const float *output = CVI_NN_TensorPtr(&d->output[layer]);
		for (unsigned int a = 0; a < 3; a++) {
			const float *p = output + a * 85 * plane;
			for (unsigned int i = 0; i < plane; i++) {
				float objectness = sigmoid(p[4 * plane + i]);
				unsigned int cls = 0;
				if (!(objectness > 0.25f)) continue;
				for (unsigned int c = 1; c < 80; c++)
					if (p[(5 + c) * plane + i] > p[(5 + cls) * plane + i]) cls = c;
				float score = objectness * sigmoid(p[(5 + cls) * plane + i]);
				if (!(score > 0.25f)) continue;
				float w = 2 * sigmoid(p[2 * plane + i]);
				float h = 2 * sigmoid(p[3 * plane + i]);
				w = w * w * anchors[layer][a][0];
				h = h * h * anchors[layer][a][1];
				float x = (sigmoid(p[i]) * 2 + (float)(i % side) - 0.5f) * (float)(8U << layer) - w / 2;
				float y = (sigmoid(p[plane + i]) * 2 + (float)(i / side) - 0.5f) * (float)(8U << layer) - h / 2;
				if (!isfinite(x) || !isfinite(y) || !isfinite(w) || !isfinite(h) || !isfinite(score)) continue;
				d->candidates[count++] = (struct box){x, y, w, h, score, cls};
			}
		}
	}
	qsort(d->candidates, count, sizeof(*d->candidates), compare_boxes);
	result->count = 0;
	for (unsigned int i = 0; i < count && result->count < MAX_BOXES; i++) {
		struct box b = d->candidates[i];
		if (!b.score) continue;
		for (unsigned int j = i + 1; j < count; j++)
			if (b.cls == d->candidates[j].cls && iou(&b, &d->candidates[j]) > 0.45f)
				d->candidates[j].score = 0;
		b.x = (b.x - (float)((MODEL_SIZE - d->resized_w) / 2)) * (float)d->width / (float)d->resized_w;
		b.y = (b.y - (float)((MODEL_SIZE - d->resized_h) / 2)) * (float)d->height / (float)d->resized_h;
		b.w *= (float)d->width / (float)d->resized_w;
		b.h *= (float)d->height / (float)d->resized_h;
		result->boxes[result->count++] = b;
	}
}

static void *worker(void *opaque)
{
	struct sg2002_detection *d = opaque;
	pthread_mutex_lock(&d->lock);
	while (!d->stopping) {
		while (!d->pending && !d->stopping) pthread_cond_wait(&d->ready, &d->lock);
		if (d->stopping) break;
		struct result result = { .sampled = d->sampled };
		d->pending = 0;
		pthread_mutex_unlock(&d->lock);
		uint64_t start = milliseconds();
		prepare_input(d);
		int status = CVI_NN_Forward(d->model, d->input, d->input_count, d->output, d->output_count);
		if (status == CVI_RC_SUCCESS) decode(d, &result);
		pthread_mutex_lock(&d->lock);
		d->busy = 0;
		if (status != CVI_RC_SUCCESS) {
			fprintf(stderr, "detection: hardware inference failed (%d)\n", status);
			d->failed = 1;
			break;
		}
		d->latest = result;
		d->completed++;
		d->total_ms += milliseconds() - start;
		if (d->completed == 1 || d->completed % (d->fps * 5U) == 0)
			fprintf(stderr, "detection: %llu samples, %.1f ms/sample, %u objects, age %llu ms\n",
				(unsigned long long)d->completed, (double)d->total_ms / (double)d->completed,
				result.count, (unsigned long long)(milliseconds() - result.sampled));
	}
	pthread_mutex_unlock(&d->lock);
	return NULL;
}

/* Five columns per glyph, low bit at the top; uppercase labels and digits. */
static const uint8_t font[][5] = {
	{0x7e,0x09,0x09,0x09,0x7e}, {0x7f,0x49,0x49,0x49,0x36},
	{0x3e,0x41,0x41,0x41,0x22}, {0x7f,0x41,0x41,0x22,0x1c},
	{0x7f,0x49,0x49,0x49,0x41}, {0x7f,0x09,0x09,0x09,0x01},
	{0x3e,0x41,0x49,0x49,0x7a}, {0x7f,0x08,0x08,0x08,0x7f},
	{0x00,0x41,0x7f,0x41,0x00}, {0x20,0x40,0x41,0x3f,0x01},
	{0x7f,0x08,0x14,0x22,0x41}, {0x7f,0x40,0x40,0x40,0x40},
	{0x7f,0x02,0x0c,0x02,0x7f}, {0x7f,0x04,0x08,0x10,0x7f},
	{0x3e,0x41,0x41,0x41,0x3e}, {0x7f,0x09,0x09,0x09,0x06},
	{0x3e,0x41,0x51,0x21,0x5e}, {0x7f,0x09,0x19,0x29,0x46},
	{0x46,0x49,0x49,0x49,0x31}, {0x01,0x01,0x7f,0x01,0x01},
	{0x3f,0x40,0x40,0x40,0x3f}, {0x1f,0x20,0x40,0x20,0x1f},
	{0x3f,0x40,0x38,0x40,0x3f}, {0x63,0x14,0x08,0x14,0x63},
	{0x07,0x08,0x70,0x08,0x07}, {0x61,0x51,0x49,0x45,0x43},
	{0x3e,0x51,0x49,0x45,0x3e}, {0x00,0x42,0x7f,0x40,0x00},
	{0x62,0x51,0x49,0x49,0x46}, {0x22,0x41,0x49,0x49,0x36},
	{0x18,0x14,0x12,0x7f,0x10}, {0x27,0x45,0x45,0x45,0x39},
	{0x3c,0x4a,0x49,0x49,0x30}, {0x01,0x71,0x09,0x05,0x03},
	{0x36,0x49,0x49,0x49,0x36}, {0x06,0x49,0x49,0x29,0x1e},
	{0x00,0x60,0x60,0x00,0x00}
};

static void rectangle(struct sg2002_detection *d, uint8_t *image,
	int x, int y, int width, int height, uint8_t luma, uint8_t u, uint8_t v)
{
	int right = x + width, bottom = y + height;
	x = x < 0 ? 0 : x; y = y < 0 ? 0 : y;
	if (right > (int)d->width) right = (int)d->width;
	if (bottom > (int)d->height) bottom = (int)d->height;
	if (right <= x || bottom <= y) return;
	for (int row = y; row < bottom; row++)
		memset(image + (size_t)row * d->stride + (unsigned int)x, luma, (size_t)(right - x));
	uint8_t *uv = image + (size_t)d->stride * d->coded_height;
	for (int row = y / 2; row < (bottom + 1) / 2; row++)
		for (int col = x & ~1; col < right; col += 2) {
			uv[(size_t)row * d->stride + (unsigned int)col] = u;
			uv[(size_t)row * d->stride + (unsigned int)col + 1] = v;
		}
}

static void paint(struct sg2002_detection *d, uint8_t *image, const struct result *result)
{
	for (unsigned int i = 0; i < result->count; i++) {
		const struct box *b = &result->boxes[i];
		int x = (int)fmaxf(0, fminf((float)d->width, b->x));
		int y = (int)fmaxf(0, fminf((float)d->height, b->y));
		int right = (int)fmaxf(0, fminf((float)d->width, b->x + b->w));
		int bottom = (int)fmaxf(0, fminf((float)d->height, b->y + b->h));
		if (right <= x || bottom <= y) continue;
		rectangle(d, image, x, y, right - x, 2, 145, 54, 34);
		rectangle(d, image, x, bottom - 2, right - x, 2, 145, 54, 34);
		rectangle(d, image, x, y, 2, bottom - y, 145, 54, 34);
		rectangle(d, image, right - 2, y, 2, bottom - y, 145, 54, 34);
		char label[40];
		snprintf(label, sizeof(label), "%s %.2f", names[b->cls], (double)b->score);
		int top = y >= 18 ? y - 18 : y;
		rectangle(d, image, x, top, (int)strlen(label) * 12 + 4, 18, 16, 128, 128);
		for (unsigned int c = 0; label[c]; c++) {
			int index = label[c] >= 'A' && label[c] <= 'Z' ? label[c] - 'A' :
				label[c] >= '0' && label[c] <= '9' ? label[c] - '0' + 26 :
				label[c] == '.' ? 36 : -1;
			if (index < 0) continue;
			for (int col = 0; col < 5; col++)
				for (int row = 0; row < 7; row++)
					if (font[index][col] & (1U << row))
						rectangle(d, image, x + 2 + (int)c * 12 + col * 2,
							top + 2 + row * 2, 2, 2, 235, 128, 128);
		}
	}
}

struct sg2002_detection *sg2002_detection_open(const char *model,
	const struct v4l2_pix_format *format, unsigned int width,
	unsigned int height, unsigned int fps)
{
	struct sg2002_detection *d = calloc(1, sizeof(*d));
	if (!d) return NULL;
	if (!width || !height || width > 8192 || height > 8192 || (width | height) & 1U ||
	    format->pixelformat != V4L2_PIX_FMT_NV12 || format->bytesperline < width ||
	    format->height < height || !fps || fps > 10) goto fail;
	d->width = width; d->height = height; d->stride = format->bytesperline;
	d->coded_height = format->height; d->fps = fps;
	d->resized_w = width >= height ? MODEL_SIZE : width * MODEL_SIZE / height;
	d->resized_h = height >= width ? MODEL_SIZE : height * MODEL_SIZE / width;
	if (!d->resized_w || !d->resized_h) goto fail;
	unsigned int encoding = format->ycbcr_enc;
	unsigned int range = format->quantization;
	if (encoding == V4L2_YCBCR_ENC_DEFAULT) encoding = V4L2_MAP_YCBCR_ENC_DEFAULT(format->colorspace);
	if (range == V4L2_QUANTIZATION_DEFAULT) range = V4L2_MAP_QUANTIZATION_DEFAULT(0, format->colorspace, encoding);
	if ((encoding != V4L2_YCBCR_ENC_601 && encoding != V4L2_YCBCR_ENC_709) ||
	    (range != V4L2_QUANTIZATION_FULL_RANGE && range != V4L2_QUANTIZATION_LIM_RANGE)) {
		fprintf(stderr, "detection: unsupported YUV colour encoding/range\n");
		goto fail;
	}
	int limited = range == V4L2_QUANTIZATION_LIM_RANGE;
	d->offset = limited ? 16 : 0; d->cy = limited ? 19077 : 16384;
	if (encoding == V4L2_YCBCR_ENC_601) {
		d->rv = limited ? 26149 : 22970; d->gu = limited ? 6419 : 5638;
		d->gv = limited ? 13320 : 11700; d->bu = limited ? 33050 : 29032;
	} else {
		d->rv = limited ? 29372 : 25802; d->gu = limited ? 3494 : 3069;
		d->gv = limited ? 8731 : 7670; d->bu = limited ? 34610 : 30402;
	}
	if (CVI_NN_RegisterModel(model, &d->model) != CVI_RC_SUCCESS) goto fail;
	if (CVI_NN_GetInputOutputTensors(d->model, &d->input, &d->input_count,
		&d->output, &d->output_count) != CVI_RC_SUCCESS || d->input_count != 1 || d->output_count != 3) goto fail;
	if (d->input->fmt != CVI_FMT_UINT8 || d->input->pixel_format != CVI_NN_PIXEL_RGB_PLANAR ||
	    d->input->aligned || d->input->mem_size != 3 * MODEL_SIZE * MODEL_SIZE ||
	    d->input->shape.dim[0] != 1 || d->input->shape.dim[1] != 3 ||
	    d->input->shape.dim[2] != MODEL_SIZE || d->input->shape.dim[3] != MODEL_SIZE) goto fail;
	for (unsigned int i = 0; i < 3; i++)
		if (d->output[i].fmt != CVI_FMT_FP32 || d->output[i].shape.dim[0] != 1 ||
		    d->output[i].shape.dim[1] != 255 || d->output[i].shape.dim[2] != (int)(80U >> i) ||
		    d->output[i].shape.dim[3] != (int)(80U >> i) ||
		    d->output[i].mem_size < 255U * (80U >> i) * (80U >> i) * sizeof(float)) goto fail;
	d->snapshot = malloc((size_t)width * height * 3 / 2);
	d->candidates = calloc(MAX_CANDIDATES, sizeof(*d->candidates));
	if (!d->snapshot || !d->candidates) goto fail;
	if (pthread_mutex_init(&d->lock, NULL)) goto fail;
	if (pthread_cond_init(&d->ready, NULL)) {
		pthread_mutex_destroy(&d->lock); goto fail;
	}
	if (pthread_create(&d->thread, NULL, worker, d)) {
		pthread_cond_destroy(&d->ready); pthread_mutex_destroy(&d->lock); goto fail;
	}
	d->started = 1;
	fprintf(stderr, "detection: YOLOv5 640x640, up to %u fps, confidence 0.25, NMS 0.45\n", fps);
	return d;
fail:
	fprintf(stderr, "detection: cannot initialize model or NV12 input\n");
	if (d->model) CVI_NN_CleanupModel(d->model);
	free(d->snapshot); free(d->candidates); free(d);
	return NULL;
}

int sg2002_detection_frame(struct sg2002_detection *d, int dmabuf,
	void *pixels, size_t length)
{
	uint64_t now = milliseconds();
	struct dma_buf_sync sync = { .flags = DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW };
	if (length < (size_t)d->stride * d->coded_height * 3 / 2) return -1;
	pthread_mutex_lock(&d->lock);
	if (d->failed) { pthread_mutex_unlock(&d->lock); return -1; }
	int copy = !d->busy && now >= d->next_sample;
	uint64_t max_age = d->fps == 1 ? 2000U : 1000U;
	int fresh = d->latest.sampled && now - d->latest.sampled <= max_age;
	if (!copy && (!fresh || !d->latest.count)) { pthread_mutex_unlock(&d->lock); return 0; }
	if (ioctl(dmabuf, DMA_BUF_IOCTL_SYNC, &sync)) { pthread_mutex_unlock(&d->lock); return -1; }
	if (copy) {
		const uint8_t *image = pixels;
		for (unsigned int y = 0; y < d->height; y++)
			memcpy(d->snapshot + (size_t)y * d->width, image + (size_t)y * d->stride, d->width);
		for (unsigned int y = 0; y < d->height / 2; y++)
			memcpy(d->snapshot + (size_t)d->width * (d->height + y),
				image + (size_t)d->stride * (d->coded_height + y), d->width);
		d->sampled = now;
		d->next_sample = now + 1000U / d->fps;
	}
	/* Sample before drawing, so labels cannot feed back into the model. */
	if (fresh) paint(d, pixels, &d->latest);
	sync.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW;
	int status = ioctl(dmabuf, DMA_BUF_IOCTL_SYNC, &sync);
	if (!status && copy) {
		d->busy = 1; d->pending = 1;
		pthread_cond_signal(&d->ready);
	}
	pthread_mutex_unlock(&d->lock);
	return status;
}

void sg2002_detection_close(struct sg2002_detection *d)
{
	if (!d) return;
	if (d->started) {
		pthread_mutex_lock(&d->lock); d->stopping = 1;
		pthread_cond_signal(&d->ready); pthread_mutex_unlock(&d->lock);
		pthread_join(d->thread, NULL);
		pthread_cond_destroy(&d->ready); pthread_mutex_destroy(&d->lock);
	}
	CVI_NN_CleanupModel(d->model);
	free(d->snapshot); free(d->candidates); free(d);
}
