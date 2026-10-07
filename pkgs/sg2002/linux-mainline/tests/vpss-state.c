#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <linux/videodev2.h>

typedef uint64_t u64;
typedef uint64_t dma_addr_t;
typedef uint32_t u32;
typedef uint8_t u8;
#define BIT(n) (1U << (n))
#define DIV_ROUND_CLOSEST(x, d) (((x) + (d) / 2) / (d))
#define lower_32_bits(x) ((u32)(x))
#define upper_32_bits(x) ((u32)((u64)(x) >> 32))
#define container_of(p, t, m) ((t *)((char *)(p) - offsetof(t, m)))
#define spin_lock_irqsave(lock, flags) do { \
	(flags) = 0; assert(!*(lock)); *(lock) = 1; \
} while (0)
#define spin_unlock_irqrestore(lock, flags) do { \
	(void)(flags); assert(*(lock)); *(lock) = 0; \
} while (0)
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define clamp_t(t, x, lo, hi) ((t)(x) < (t)(lo) ? (t)(lo) : \
	((t)(x) > (t)(hi) ? (t)(hi) : (t)(x)))
#define round_down(x, a) ((x) / (a) * (a))
struct v4l2_ctrl_handler { int error; };
struct v4l2_ctrl { struct v4l2_ctrl_handler *handler; u32 id; int val; };
struct v4l2_fh { void *m2m_ctx; };
struct vpss_dev { unsigned int irq_lock, reads, writes; u32 regs[0x6000 / 4]; };
static void vpss_write(struct vpss_dev *dev, u32 reg, u32 value)
{
	assert(reg % 4 == 0 && reg / 4 < ARRAY_SIZE(dev->regs));
	dev->writes++;
	dev->regs[reg / 4] = value;
}
static u32 vpss_read(struct vpss_dev *dev, u32 reg)
{
	assert(reg % 4 == 0 && reg / 4 < ARRAY_SIZE(dev->regs));
	dev->reads++;
	return dev->regs[reg / 4];
}
static void vpss_load_coef(struct vpss_dev *dev, bool identity) {}
struct file { void *private_data; };
struct vb2_queue { bool busy; };
static struct vb2_queue queues[V4L2_BUF_TYPE_VIDEO_OUTPUT + 1];
static struct vb2_queue *v4l2_m2m_get_vq(void *ctx, enum v4l2_buf_type type)
{
	assert(type == V4L2_BUF_TYPE_VIDEO_CAPTURE || type == V4L2_BUF_TYPE_VIDEO_OUTPUT);
	return &queues[type];
}
static bool vb2_is_busy(struct vb2_queue *queue) { return queue->busy; }

/* DRIVER_STATE */

static void test_flips(struct vpss_ctx *ctx)
{
	struct vpss_dev dev = { 0 };
	struct vpss_ctx other = { .dev = &dev };
	struct v4l2_ctrl ctrl = { .handler = &ctx->ctrl_handler };
	u32 baseline[ARRAY_SIZE(dev.regs)];
	unsigned int fmt, mode, reg;

	ctx->dev = &dev;
	ctx->crop.width = 640;
	ctx->crop.height = 360;
	for (fmt = 0; fmt < ARRAY_SIZE(vpss_cap_fmts); fmt++) {
		ctx->q_data[V4L2_BUF_TYPE_VIDEO_CAPTURE].fmt = &vpss_cap_fmts[fmt];
		for (mode = 0; mode < 4; mode++) {
			u32 flip;

			memset(dev.regs, 0, sizeof(dev.regs));
			dev.reads = dev.writes = 0;
			ctrl.id = V4L2_CID_HFLIP;
			ctrl.val = mode & 1;
			assert(!vpss_s_ctrl(&ctrl));
			ctrl.id = V4L2_CID_VFLIP;
			ctrl.val = (mode >> 1) & 1;
			assert(!vpss_s_ctrl(&ctrl));
			assert(ctx->flip == mode << 16);
			assert(!other.flip && !dev.irq_lock);
			/* Setting controls while clocks are off performs no MMIO. */
			assert(!dev.reads && !dev.writes);

			flip = ctx->flip;
			/* Later control updates cannot change the job's snapshot. */
			ctrl.val = !ctrl.val;
			assert(!vpss_s_ctrl(&ctrl));
			vpss_job_hw(&dev, ctx, 0x81000000, 0x82000000, flip);
			assert(vpss_read(&dev, ODMA_HEIGHT) == 359);
			assert(vpss_read(&dev, ODMA_WIDTH) == 639);
			assert(vpss_read(&dev, ODMA_OFFSET_X) == 0);
			assert(vpss_read(&dev, ODMA_OFFSET_Y) == 0);
			assert(vpss_read(&dev, ODMA_PITCH_Y) == 640);
			assert(vpss_read(&dev, ODMA_PITCH_C) == 640);
			assert(vpss_read(&dev, ODMA_ADDR0_L) == 0x82000000);
			assert(vpss_read(&dev, ODMA_ADDR1_L) == 0x82000000 + 640 * 368);
			assert(vpss_read(&dev, ODMA_CFG) ==
			       (mode << 16 | vpss_cap_fmts[fmt].hw_fmt << 8 | 7));
			if (!mode)
				memcpy(baseline, dev.regs, sizeof(baseline));
			/* Flips must preserve every other part of job programming. */
			for (reg = 0; reg < ARRAY_SIZE(dev.regs); reg++)
				if (reg != ODMA_CFG / 4)
					assert(dev.regs[reg] == baseline[reg]);
		}
	}
	ctrl.id = V4L2_CID_BRIGHTNESS;
	assert(vpss_s_ctrl(&ctrl) == -EINVAL);
	ctx->dev = NULL;
}

static void full601(const struct v4l2_pix_format *pix)
{
	assert(pix->colorspace == V4L2_COLORSPACE_SRGB);
	assert(pix->ycbcr_enc == V4L2_YCBCR_ENC_601);
	assert(pix->quantization == V4L2_QUANTIZATION_FULL_RANGE);
	assert(pix->xfer_func == V4L2_XFER_FUNC_NONE);
}

int main(void)
{
	struct vpss_ctx ctx = { 0 };
	struct file file = { .private_data = &ctx };
	struct v4l2_format source = {
		.type = V4L2_BUF_TYPE_VIDEO_OUTPUT,
		.fmt.pix = { .width = 2560, .height = 1440,
			.pixelformat = V4L2_PIX_FMT_NV21,
			.colorspace = V4L2_COLORSPACE_SRGB,
			.ycbcr_enc = V4L2_YCBCR_ENC_601,
			.quantization = V4L2_QUANTIZATION_FULL_RANGE,
			.xfer_func = V4L2_XFER_FUNC_NONE },
	};
	struct v4l2_format capture = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE,
		.fmt.pix = { .width = 640, .height = 368,
			.pixelformat = V4L2_PIX_FMT_NV12 } };
	struct v4l2_format actual = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE };
	struct v4l2_rect saved_crop = { 2, 4, 640, 360 };
	struct v4l2_fmtdesc enumerated;
	unsigned int type, index, expected;

	ctx.crop = saved_crop;
	assert(!vpss_s_fmt(&file, NULL, &source));
	/* OUTPUT index 2 must not overwrite adjacent context state. */
	assert(!memcmp(&ctx.crop, &saved_crop, sizeof(saved_crop)));
	assert(ctx.q_data[V4L2_BUF_TYPE_VIDEO_OUTPUT].width == 2560);
	assert(!vpss_s_fmt(&file, NULL, &capture));
	full601(&capture.fmt.pix);
	assert(!vpss_g_fmt(&file, NULL, &actual));
	full601(&actual.fmt.pix);
	assert(actual.fmt.pix.width == 640 && actual.fmt.pix.height == 368);
	assert(ctx.q_data[V4L2_BUF_TYPE_VIDEO_OUTPUT].width == 2560);
	assert(ctx.crop.width == 640 && ctx.crop.height == 368);

	queues[V4L2_BUF_TYPE_VIDEO_CAPTURE].busy = true;
	source.fmt.pix.quantization = V4L2_QUANTIZATION_LIM_RANGE;
	assert(vpss_s_fmt(&file, NULL, &source) == -EBUSY);
	assert(ctx.quantization == V4L2_QUANTIZATION_FULL_RANGE);
	source.fmt.pix.quantization = V4L2_QUANTIZATION_FULL_RANGE;
	assert(!vpss_s_fmt(&file, NULL, &source));
	queues[V4L2_BUF_TYPE_VIDEO_OUTPUT].busy = true;
	assert(vpss_s_fmt(&file, NULL, &source) == -EBUSY);
	memset(queues, 0, sizeof(queues));

	for (type = V4L2_BUF_TYPE_VIDEO_CAPTURE; type <= V4L2_BUF_TYPE_VIDEO_OUTPUT; type++) {
		expected = type == V4L2_BUF_TYPE_VIDEO_OUTPUT ? 4 : 2;
		for (index = 0; index < expected; index++) {
			memset(&enumerated, 0, sizeof(enumerated));
			enumerated.type = type;
			enumerated.index = index;
			assert(!vpss_enum_fmt(&file, NULL, &enumerated));
			actual.type = type;
			actual.fmt.pix.pixelformat = enumerated.pixelformat;
			assert(!vpss_try_fmt(&file, NULL, &actual));
			assert(actual.fmt.pix.pixelformat == enumerated.pixelformat);
		}
		enumerated.index = expected;
		assert(vpss_enum_fmt(&file, NULL, &enumerated) == -EINVAL);
	}
	memset(&source.fmt.pix, 0, sizeof(source.fmt.pix));
	source.fmt.pix.width = 1920;
	source.fmt.pix.height = 1080;
	source.fmt.pix.pixelformat = V4L2_PIX_FMT_UYVY;
	assert(!vpss_s_fmt(&file, NULL, &source));
	assert(source.fmt.pix.pixelformat == V4L2_PIX_FMT_UYVY);
	assert(source.fmt.pix.bytesperline == 3840);
	assert(source.fmt.pix.colorspace == V4L2_COLORSPACE_REC709);
	assert(source.fmt.pix.ycbcr_enc == V4L2_YCBCR_ENC_709);
	assert(source.fmt.pix.quantization == V4L2_QUANTIZATION_LIM_RANGE);
	assert(source.fmt.pix.xfer_func == V4L2_XFER_FUNC_709);
	/* Restore the padded camera layout used by the live encoder bridge. */
	source.fmt.pix.width = 2560;
	source.fmt.pix.height = 1440;
	source.fmt.pix.pixelformat = V4L2_PIX_FMT_NV21;
	assert(!vpss_s_fmt(&file, NULL, &source));
	assert(!vpss_s_fmt(&file, NULL, &capture));
	test_flips(&ctx);
	puts("VPSS state: formats, colour, busy guards, flip isolation and padded DMA geometry OK");
	return 0;
}
