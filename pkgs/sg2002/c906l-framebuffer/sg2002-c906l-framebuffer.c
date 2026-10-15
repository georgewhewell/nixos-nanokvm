// SPDX-License-Identifier: GPL-2.0-only
/*
 * Atomic DRM/KMS with GEM shmem buffers and fbdev emulation. RGB565 pixels
 * are copied unchanged into reserved RGB565 slots; userspace never maps
 * those slots. A flip completes only after C906L acknowledges the scanout.
 * This transport has no periodic vblank or promised display refresh rate.
 * No peripheral registers or arbitrary physical addresses are exposed.
 */
#include <linux/backlight.h>
#include <linux/delay.h>
#include <linux/dma-fence.h>
#include <linux/fs.h>
#include <linux/io.h>
#include <linux/jiffies.h>
#include <linux/math64.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/of_address.h>
#include <linux/platform_device.h>
#include <linux/sched/signal.h>
#include <linux/slab.h>
#include <linux/workqueue.h>

#include <drm/clients/drm_client_setup.h>
#include <drm/drm_atomic.h>
#include <drm/drm_atomic_helper.h>
#include <drm/drm_atomic_state_helper.h>
#include <drm/drm_connector.h>
#include <drm/drm_drv.h>
#include <drm/drm_encoder.h>
#include <drm/drm_fbdev_shmem.h>
#include <drm/drm_file.h>
#include <drm/drm_fourcc.h>
#include <drm/drm_format_helper.h>
#include <drm/drm_framebuffer.h>
#include <drm/drm_gem_atomic_helper.h>
#include <drm/drm_gem_framebuffer_helper.h>
#include <drm/drm_gem_shmem_helper.h>
#include <drm/drm_managed.h>
#include <drm/drm_modes.h>
#include <drm/drm_modeset_helper.h>
#include <drm/drm_modeset_helper_vtables.h>
#include <drm/drm_probe_helper.h>
#include <drm/drm_damage_helper.h>
#include <drm/drm_rect.h>
#include <drm/drm_vblank.h>

#include "sg2002-c906l-kernel-contract.h"

#define LCD(name) SG2002_C906L_PICOCLAW_LCD_##name
#define WAIT_MS 20000U

struct frame_record {
	__le32 magic, generation, sequence, result;
	__le16 x, y, width, height;
	u8 reserved[LCD(RECORD_RESERVED_SIZE)];
	__le32 commit;
};
static_assert(sizeof(struct frame_record) == 64);
static_assert(offsetof(struct frame_record, commit) == 60);
static_assert(offsetof(struct frame_record, x) == LCD(RECORD_RECT_OFFSET));
static_assert(LCD(RECORD_RECT_SIZE) == 8);

struct lcd_frames {
	struct drm_device drm;
	struct drm_plane primary;
	struct drm_crtc crtc;
	struct drm_encoder encoder;
	struct drm_connector connector;
	struct work_struct fault_work;
	struct backlight_device *backlight;
	u8 __iomem *shared;
	struct mutex lock;
	int fault;
	u32 generation;
	u32 sequence[2];
	u32 completed[2];
	u8 next_slot;
};

static const u8 contract_digest[32] = SG2002_C906L_CONTRACT_SHA256_BYTES;

static bool manifest_valid(const struct sg2002_c906l_manifest *m)
{
	return le32_to_cpu(m->magic) == SG2002_C906L_MANIFEST_MAGIC &&
		le16_to_cpu(m->format_major) == SG2002_C906L_MANIFEST_FORMAT_MAJOR &&
		le16_to_cpu(m->format_minor) == SG2002_C906L_MANIFEST_FORMAT_MINOR &&
		le32_to_cpu(m->struct_size) == SG2002_C906L_MANIFEST_SIZE &&
		le32_to_cpu(m->contract_epoch) == SG2002_C906L_CONTRACT_EPOCH &&
		le32_to_cpu(m->profile_id) == SG2002_C906L_PROFILE_ID &&
		le16_to_cpu(m->abi_major) == SG2002_C906L_ABI_MAJOR &&
		le16_to_cpu(m->abi_minor) == SG2002_C906L_ABI_MINOR &&
		le16_to_cpu(m->capability_width) == SG2002_C906L_CAPABILITY_WIRE_WIDTH &&
		le16_to_cpu(m->lease_width) == SG2002_C906L_LEASE_WIRE_WIDTH &&
		le64_to_cpu(m->final_capabilities) == SG2002_C906L_EXPECTED_CAPABILITIES &&
		le64_to_cpu(m->dormant_capabilities) == SG2002_C906L_DORMANT_CAPABILITIES &&
		le64_to_cpu(m->lease_mask) == SG2002_C906L_LEASE_MASK &&
		le32_to_cpu(m->flags) == SG2002_C906L_MANIFEST_FLAGS &&
		!le32_to_cpu(m->reserved0) &&
		!memchr_inv(m->reserved1, 0, sizeof(m->reserved1)) &&
		!memcmp(m->contract_sha256, contract_digest, sizeof(contract_digest)) &&
		le32_to_cpu(m->commit) == SG2002_C906L_MANIFEST_COMMIT;
}

static void __iomem *slot_record(struct lcd_frames *fb, unsigned int slot)
{
	return fb->shared + LCD(OWNERSHIP0_ADDRESS) - SG2002_C906L_SHMEM_ADDRESS +
		slot * LCD(OWNERSHIP_SIZE);
}

static void read_record(void __iomem *address, struct frame_record *record)
{
	memcpy_fromio(record, address, sizeof(*record));
	rmb();
}

/* A changing cache line is not an error: retry within the caller's deadline. */
static int frame_completed(struct lcd_frames *fb, unsigned int slot)
{
	struct frame_record first, second;
	void __iomem *address = slot_record(fb, slot) + LCD(COMPLETION_OFFSET);

	if (!fb->sequence[slot] || fb->completed[slot] == fb->sequence[slot])
		return 1;
	read_record(address, &first);
	read_record(address, &second);
	if (memcmp(&first, &second, sizeof(first)))
		return 0;
	if (le32_to_cpu(first.magic) != LCD(COMPLETION_MAGIC) ||
	    le32_to_cpu(first.generation) != fb->generation ||
	    le32_to_cpu(first.sequence) != fb->sequence[slot] ||
	    le32_to_cpu(first.commit) != fb->sequence[slot])
		return 0;
	/* A completion carries no rectangle: every byte after result is zero,
	 * as it was before the request gained one. */
	if (first.x || first.y || first.width || first.height ||
	    memchr_inv(first.reserved, 0, sizeof(first.reserved)))
		return -EPROTO;
	if (le32_to_cpu(first.result))
		return -EIO;
	fb->completed[slot] = fb->sequence[slot];
	return 1;
}

static int check_generation(struct lcd_frames *fb)
{
	struct sg2002_c906l_status status, again;

	memcpy_fromio(&status, fb->shared + SG2002_C906L_STATUS_REGION_OFFSET,
		      sizeof(status));
	rmb();
	memcpy_fromio(&again, fb->shared + SG2002_C906L_STATUS_REGION_OFFSET,
		      sizeof(again));
	rmb();
	if (memcmp(&status, &again, sizeof(status)))
		return -EAGAIN;
	if (le32_to_cpu(status.generation) != fb->generation)
		return -ESTALE;
	if (le32_to_cpu(status.magic) != SG2002_C906L_SHMEM_MAGIC ||
	    le16_to_cpu(status.abi_major) != SG2002_C906L_ABI_MAJOR ||
	    le16_to_cpu(status.abi_minor) != SG2002_C906L_ABI_MINOR ||
	    le32_to_cpu(status.struct_size) != SG2002_C906L_STATUS_SIZE ||
	    le32_to_cpu(status.state) != SG2002_C906L_STATE_RUNNING ||
	    status.activation_state != SG2002_C906L_ACTIVATION_STATE_ACTIVE ||
	    le64_to_cpu(status.capabilities) != SG2002_C906L_EXPECTED_CAPABILITIES ||
	    le32_to_cpu(status.flags))
		return -EIO;
	return 0;
}

/* Shortest useful poll interval, and the cap it backs off to. */
#define POLL_US 250u
#define POLL_MAX_US 2000u
/* A full frame needs 78.64 ms at the panel's supported SPI clock. */
#define WIRE_TIME_MAX_US 100000u

/* Bit time on the panel bus is exact and dominates every transfer, so the
 * completion poll can sleep through almost all of it instead of waking on the
 * timer tick. Deliberately an underestimate: it ignores the C906L's per-job
 * command and scheduling overhead, so the fine poll below still decides. */
static unsigned int wire_time_us(u32 pixels)
{
	u64 us = div_u64((u64)pixels * 16 * USEC_PER_SEC,
			 LCD(SPI_CLOCK_HZ) / LCD(SPI_DIVIDER));

	return clamp_t(u64, us, POLL_US, WIRE_TIME_MAX_US);
}

static int wait_slot(struct lcd_frames *fb, unsigned int slot,
		     unsigned long deadline, bool nonblock, unsigned int predicted_us)
{
	unsigned int sleep_us = POLL_US;
	bool slept = false;
	int ret;

	for (;;) {
		if (time_after_eq(jiffies, deadline))
			return -ETIMEDOUT;
		ret = check_generation(fb);
		if (ret && ret != -EAGAIN)
			return ret;
		if (!ret) {
			ret = frame_completed(fb, slot);
			if (ret)
				return ret < 0 ? ret : 0;
		}
		if (nonblock)
			return -EAGAIN;
		if (time_after_eq(jiffies, deadline))
			return -ETIMEDOUT;
		/* Not interruptible: a pending signal in the committing task must
		 * not abandon an acknowledged frame and latch a permanent fault. */
		/* Sleep through the predicted transfer once, then poll finely and
		 * back off, so a stalled C906L cannot spin out the whole deadline. */
		if (!slept && predicted_us > sleep_us)
			sleep_us = predicted_us;
		usleep_range(sleep_us, sleep_us + sleep_us / 8 + 1);
		sleep_us = slept ? umin(sleep_us * 2, POLL_MAX_US) : POLL_US;
		slept = true;
	}
}

static int lock_until(struct lcd_frames *fb, unsigned long deadline, bool nonblock)
{
	while (!mutex_trylock(&fb->lock)) {
		if (nonblock)
			return -EAGAIN;
		if (time_after_eq(jiffies, deadline))
			return -ETIMEDOUT;
		msleep(5);
	}
	return 0;
}

/* A NULL plane blanks the panel on disable. No shared slot is user-mappable. */
static int lcd_scanout(struct lcd_frames *fb, struct drm_plane_state *old_plane,
		       struct drm_plane_state *plane)
{
	struct frame_record record = { 0 };
	struct drm_shadow_plane_state *shadow = plane ?
		to_drm_shadow_plane_state(plane) : NULL;
	struct drm_rect clip = DRM_RECT_INIT(0, 0, LCD(WIDTH), LCD(HEIGHT));
	struct iosys_map destination;
	unsigned int pitch;
	void __iomem *request, *pixels;
	unsigned long deadline = jiffies + msecs_to_jiffies(WAIT_MS);
	unsigned int slot;
	u32 sequence;
	int ret;

	ret = READ_ONCE(fb->fault);
	if (ret)
		return ret;
	ret = lock_until(fb, deadline, false);
	if (ret)
		return ret;
	/* Keep the fault latch and slot ownership under one lock even if future
	 * callers do not share the atomic helper's hw_done serialization. */
	ret = READ_ONCE(fb->fault);
	if (ret)
		goto unlock;
	slot = fb->next_slot;
	/* The frame two commits ago; normally long finished, so poll, don't
	 * predict. */
	ret = wait_slot(fb, slot, deadline, false, POLL_US);
	if (ret)
		goto unlock;
	if (plane) {
		ret = drm_gem_fb_begin_cpu_access(plane->fb, DMA_FROM_DEVICE);
		if (ret)
			goto unlock;
	}
	sequence = fb->sequence[slot] + 1;
	if (!sequence)
		sequence = 1;
	request = slot_record(fb, slot);
	pixels = fb->shared + LCD(FRAME_SLOT0_ADDRESS) - SG2002_C906L_SHMEM_ADDRESS +
		slot * LCD(FRAME_SLOT_STRIDE);
	/* Revoke the old commit before writing pixels or the new record. */
	writel(0, request + offsetof(struct frame_record, commit));
	wmb();
	if (plane) {
		/* Send only what changed. The firmware addresses the panel with
		 * this rectangle and reads exactly its pixels, packed from the
		 * start of the slot, so the destination pitch is the rectangle's
		 * own width rather than the panel's. */
		if (!drm_atomic_helper_damage_merged(old_plane, plane, &clip))
			clip = (struct drm_rect)DRM_RECT_INIT(0, 0, LCD(WIDTH),
							      LCD(HEIGHT));
		pitch = drm_rect_width(&clip) * 2;
		iosys_map_set_vaddr_iomem(&destination, pixels);
		drm_fb_memcpy(&destination, &pitch, shadow->data, plane->fb, &clip);
		drm_gem_fb_end_cpu_access(plane->fb, DMA_FROM_DEVICE);
	} else {
		memset_io(pixels, 0, LCD(FRAME_SIZE));
	}
	record.magic = cpu_to_le32(LCD(REQUEST_MAGIC));
	record.generation = cpu_to_le32(fb->generation);
	record.sequence = cpu_to_le32(sequence);
	record.x = cpu_to_le16(clip.x1);
	record.y = cpu_to_le16(clip.y1);
	record.width = cpu_to_le16(drm_rect_width(&clip));
	record.height = cpu_to_le16(drm_rect_height(&clip));
	record.result = cpu_to_le32(drm_rect_width(&clip) * drm_rect_height(&clip) * 2);
	memcpy_toio(request, &record, sizeof(record));
	wmb();
	writel(sequence, request + offsetof(struct frame_record, commit));
	wmb();
	fb->sequence[slot] = sequence;
	fb->next_slot ^= 1;
	/* Commit-last transfers immutable slot ownership until this acknowledgement.
	 * A timeout never revokes ownership or permits another write to that slot. */
	ret = wait_slot(fb, slot, deadline, false,
			wire_time_us(drm_rect_width(&clip) * drm_rect_height(&clip)));
unlock:
	if (ret)
		WRITE_ONCE(fb->fault, ret);
	mutex_unlock(&fb->lock);
	return ret;
}

/* One nominal 1 Hz mode describes geometry, not a periodic refresh promise. */
static const struct drm_display_mode lcd_mode = {
	.clock = 63,
	.hdisplay = 240, .hsync_start = 244, .hsync_end = 246, .htotal = 250,
	.vdisplay = 240, .vsync_start = 244, .vsync_end = 246, .vtotal = 250,
	.type = DRM_MODE_TYPE_DRIVER | DRM_MODE_TYPE_PREFERRED,
};

static int lcd_get_modes(struct drm_connector *connector)
{
	struct drm_display_mode *mode = drm_mode_duplicate(connector->dev, &lcd_mode);

	if (!mode)
		return 0;
	drm_mode_set_name(mode);
	drm_mode_probed_add(connector, mode);
	return 1;
}

static enum drm_connector_status lcd_detect(struct drm_connector *connector,
					    bool force)
{
	struct lcd_frames *fb = container_of(connector, struct lcd_frames, connector);

	return READ_ONCE(fb->fault) ? connector_status_disconnected :
		connector_status_connected;
}

static enum drm_mode_status lcd_mode_valid(struct drm_crtc *crtc,
					   const struct drm_display_mode *mode)
{
	return drm_mode_equal(mode, &lcd_mode) ? MODE_OK : MODE_BAD;
}

static const struct drm_connector_funcs lcd_connector_funcs = {
	.reset = drm_atomic_helper_connector_reset,
	.detect = lcd_detect,
	.fill_modes = drm_helper_probe_single_connector_modes,
	.destroy = drm_connector_cleanup,
	.atomic_duplicate_state = drm_atomic_helper_connector_duplicate_state,
	.atomic_destroy_state = drm_atomic_helper_connector_destroy_state,
};

static const struct drm_connector_helper_funcs lcd_connector_helpers = {
	.get_modes = lcd_get_modes,
};

static int lcd_plane_check(struct drm_plane *plane, struct drm_atomic_commit *state)
{
	struct drm_plane_state *new = drm_atomic_get_new_plane_state(state, plane);
	struct drm_crtc_state *crtc;
	int ret;

	if (!new->crtc)
		return 0;
	crtc = drm_atomic_get_new_crtc_state(state, new->crtc);
	ret = drm_atomic_helper_check_plane_state(new, crtc, DRM_PLANE_NO_SCALING,
						DRM_PLANE_NO_SCALING, false, false);
	if (ret || !new->visible)
		return ret;
	if (new->src_x || new->src_y || new->src_w != 240 << 16 ||
	    new->src_h != 240 << 16 || new->crtc_x || new->crtc_y ||
	    new->crtc_w != 240 || new->crtc_h != 240 ||
	    new->fb->width != 240 || new->fb->height != 240)
		return -EINVAL;
	return 0;
}

static const struct drm_plane_funcs lcd_plane_funcs = {
	.update_plane = drm_atomic_helper_update_plane,
	.disable_plane = drm_atomic_helper_disable_plane,
	.destroy = drm_plane_cleanup,
	DRM_GEM_SHADOW_PLANE_FUNCS,
};

static void lcd_plane_update(struct drm_plane *plane, struct drm_atomic_commit *state)
{
	/* The commit tail performs the bounded copy and remote completion wait
	 * after all generic modeset bookkeeping, before sending any flip event. */
}

static int lcd_begin_fb_access(struct drm_plane *plane, struct drm_plane_state *state)
{
	struct drm_shadow_plane_state *shadow = to_drm_shadow_plane_state(state);
	int ret = drm_gem_begin_shadow_fb_access(plane, state);

	if (ret)
		return ret;
	/* The kernel copy helper accepts only RAM sources, including
	 * imported dma-bufs. Reject an I/O mapping before swapping atomic state. */
	if (state->fb && shadow->data[0].is_iomem) {
		drm_gem_end_shadow_fb_access(plane, state);
		return -EOPNOTSUPP;
	}
	return 0;
}

static const struct drm_plane_helper_funcs lcd_plane_helpers = {
	.prepare_fb = drm_gem_plane_helper_prepare_fb,
	.atomic_check = lcd_plane_check,
	.atomic_update = lcd_plane_update,
	.begin_fb_access = lcd_begin_fb_access,
	.end_fb_access = drm_gem_end_shadow_fb_access,
};

static int lcd_crtc_check(struct drm_crtc *crtc, struct drm_atomic_commit *state)
{
	struct drm_crtc_state *new = drm_atomic_get_new_crtc_state(state, crtc);
	int ret;

	new->no_vblank = true;
	if (new->enable) {
		ret = drm_atomic_helper_check_crtc_primary_plane(new);
		if (ret)
			return ret;
	}
	return drm_atomic_add_affected_planes(state, crtc);
}

static const struct drm_crtc_funcs lcd_crtc_funcs = {
	.reset = drm_atomic_helper_crtc_reset,
	.destroy = drm_crtc_cleanup,
	.set_config = drm_atomic_helper_set_config,
	.page_flip = drm_atomic_helper_page_flip,
	.atomic_duplicate_state = drm_atomic_helper_crtc_duplicate_state,
	.atomic_destroy_state = drm_atomic_helper_crtc_destroy_state,
};

static const struct drm_crtc_helper_funcs lcd_crtc_helpers = {
	.mode_valid = lcd_mode_valid,
	.atomic_check = lcd_crtc_check,
};

static const struct drm_encoder_funcs lcd_encoder_funcs = {
	.destroy = drm_encoder_cleanup,
};

static void lcd_fault_work(struct work_struct *work)
{
	struct lcd_frames *fb = container_of(work, struct lcd_frames, fault_work);

	drm_kms_helper_hotplug_event(&fb->drm);
}

/* Atomic tails cannot return an I/O error. Error the out-fence, retire the
 * helper dependency, and cancel (never send) the success-only flip event. */
static void lcd_cancel_events(struct drm_atomic_commit *state, int error)
{
	struct drm_device *drm = state->dev;
	struct drm_crtc *crtc;
	struct drm_crtc_state *new;
	int i;

	for_each_new_crtc_in_state(state, crtc, new, i) {
		struct drm_pending_vblank_event *event;
		unsigned long flags;

		spin_lock_irqsave(&drm->event_lock, flags);
		event = new->event;
		new->event = NULL;
		if (event) {
			if (event->base.completion) {
				complete_all(event->base.completion);
				if (event->base.completion_release)
					event->base.completion_release(event->base.completion);
				event->base.completion = NULL;
			}
			if (event->base.fence) {
				dma_fence_set_error(event->base.fence, error);
				dma_fence_signal(event->base.fence);
			}
		}
		spin_unlock_irqrestore(&drm->event_lock, flags);
		if (event)
			drm_event_cancel_free(drm, &event->base);
	}
}

static void lcd_commit_tail(struct drm_atomic_commit *state)
{
	struct drm_device *drm = state->dev;
	struct lcd_frames *fb = container_of(drm, struct lcd_frames, drm);
	struct drm_crtc_state *new = drm_atomic_get_new_crtc_state(state, &fb->crtc);
	struct drm_crtc_state *old = drm_atomic_get_old_crtc_state(state, &fb->crtc);
	struct drm_plane_state *plane = drm_atomic_get_new_plane_state(state, &fb->primary);
	struct drm_plane_state *old_plane = drm_atomic_get_old_plane_state(state, &fb->primary);
	int ret = READ_ONCE(fb->fault);

	drm_atomic_helper_commit_modeset_disables(drm, state);
	drm_atomic_helper_commit_planes(drm, state, 0);
	drm_atomic_helper_commit_modeset_enables(drm, state);
	if (!ret && new && (new->active || (old && old->active)))
		ret = lcd_scanout(fb, old_plane, new->active ? plane : NULL);
	if (ret) {
		WRITE_ONCE(fb->fault, ret);
		/* The C906L cannot reach the backlight pad, so blanking a torn or
		 * stale frame is ours to do. */
		backlight_disable(fb->backlight);
		dev_err(drm->dev, "C906L scanout failed: %d; ownership retained, reboot required\n", ret);
		lcd_cancel_events(state, ret);
		schedule_work(&fb->fault_work);
	} else {
		/* pwm-backlight boots dark because our phandle tells it another
		 * driver owns power-on; light it only once a frame is really up.
		 * Only on an active transition: a plain page flip must not undo a
		 * brightness or bl_power setting, nor add work to the frame path. */
		if (new && (!old || old->active != new->active))
			(new->active ? backlight_enable : backlight_disable)(fb->backlight);
		/* One completion notification, strictly after actual remote scanout.
		 * There is deliberately no periodic vblank emulation/timer. */
		drm_atomic_helper_fake_vblank(state);
	}
	/* Standard atomic_commit swaps with stall=true: retain hw_done until the
	 * remote wait finishes so the next commit cannot retire our plane mapping. */
	drm_atomic_helper_commit_hw_done(state);
	drm_atomic_helper_cleanup_planes(drm, state);
}

static int lcd_atomic_check(struct drm_device *drm, struct drm_atomic_commit *state)
{
	struct lcd_frames *fb = container_of(drm, struct lcd_frames, drm);
	int ret = READ_ONCE(fb->fault);

	return ret ? ret : drm_atomic_helper_check(drm, state);
}

static const struct drm_mode_config_funcs lcd_mode_config_funcs = {
	.fb_create = drm_gem_fb_create_with_dirty,
	.atomic_check = lcd_atomic_check,
	.atomic_commit = drm_atomic_helper_commit,
};

static const struct drm_mode_config_helper_funcs lcd_mode_config_helpers = {
	.atomic_commit_tail = lcd_commit_tail,
};

DEFINE_DRM_GEM_FOPS(lcd_fops);

static const struct drm_driver lcd_drm_driver = {
	.driver_features = DRIVER_GEM | DRIVER_MODESET | DRIVER_ATOMIC,
	.fops = &lcd_fops,
	DRM_GEM_SHMEM_DRIVER_OPS,
	DRM_FBDEV_SHMEM_DRIVER_OPS,
	.name = "sg2002-c906l",
	.desc = "C906L remote ST7789 scanout",
	.major = 1,
	.minor = 0,
};

static ssize_t transport_status_show(struct device *dev,
				     struct device_attribute *attr, char *buf)
{
	struct lcd_frames *fb = dev_get_drvdata(dev);

	return sysfs_emit(buf, "generation=%u fault=%d submitted=%u,%u completed=%u,%u\n",
		fb->generation, READ_ONCE(fb->fault),
		READ_ONCE(fb->sequence[0]), READ_ONCE(fb->sequence[1]),
		READ_ONCE(fb->completed[0]), READ_ONCE(fb->completed[1]));
}
static DEVICE_ATTR_RO(transport_status);

static struct attribute *lcd_attrs[] = {
	&dev_attr_transport_status.attr,
	NULL,
};
static const struct attribute_group lcd_group = { .attrs = lcd_attrs };

static void lcd_cancel_fault_work(void *data)
{
	struct lcd_frames *fb = data;

	cancel_work_sync(&fb->fault_work);
}

static int lcd_probe(struct platform_device *pdev)
{
	static const u32 formats[] = { DRM_FORMAT_RGB565 };
	static const u64 modifiers[] = { DRM_FORMAT_MOD_LINEAR, DRM_FORMAT_MOD_INVALID };
	struct sg2002_c906l_manifest manifest, again;
	struct sg2002_c906l_status status;
	struct device_node *node;
	struct resource memory;
	struct lcd_frames *fb;
	u8 digest[32];
	int ret;

	if (!of_machine_is_compatible("sipeed,licheerv-nano-picoclaw"))
		return -ENODEV;
	if (of_property_read_u8_array(pdev->dev.of_node, "sophgo,contract-sha256",
				      digest, sizeof(digest)) ||
	    memcmp(digest, contract_digest, sizeof(digest)))
		return -EPROTO;
	node = of_parse_phandle(pdev->dev.of_node, "memory-region", 0);
	if (!node)
		return -EINVAL;
	ret = of_address_to_resource(node, 0, &memory);
	of_node_put(node);
	if (ret)
		return ret;
	if (memory.start != SG2002_C906L_SHMEM_ADDRESS ||
	    resource_size(&memory) != SG2002_C906L_SHMEM_SIZE)
		return -EINVAL;
	fb = devm_drm_dev_alloc(&pdev->dev, &lcd_drm_driver, struct lcd_frames, drm);
	if (IS_ERR(fb))
		return PTR_ERR(fb);
	fb->shared = devm_ioremap_wc(&pdev->dev, memory.start, resource_size(&memory));
	if (!fb->shared)
		return -ENOMEM;
	memcpy_fromio(&manifest, fb->shared + SG2002_C906L_MANIFEST_OFFSET, sizeof(manifest));
	rmb();
	memcpy_fromio(&again, fb->shared + SG2002_C906L_MANIFEST_OFFSET, sizeof(again));
	rmb();
	memcpy_fromio(&status, fb->shared + SG2002_C906L_STATUS_REGION_OFFSET, sizeof(status));
	if (memcmp(&manifest, &again, sizeof(manifest)) ||
	    !manifest_valid(&manifest))
		return -EPROBE_DEFER;
	if (le32_to_cpu(status.magic) != SG2002_C906L_SHMEM_MAGIC ||
	    status.activation_state != SG2002_C906L_ACTIVATION_STATE_ACTIVE ||
	    le64_to_cpu(status.capabilities) != SG2002_C906L_EXPECTED_CAPABILITIES ||
	    status.generation != manifest.generation || !le32_to_cpu(status.generation))
		return -EPROBE_DEFER;
	fb->generation = le32_to_cpu(status.generation);
	ret = check_generation(fb);
	if (ret)
		return ret == -EAGAIN ? -EPROBE_DEFER : ret;
	fb->backlight = devm_of_find_backlight(&pdev->dev);
	if (IS_ERR(fb->backlight))
		return PTR_ERR(fb->backlight);
	mutex_init(&fb->lock);
	INIT_WORK(&fb->fault_work, lcd_fault_work);
	ret = devm_add_action_or_reset(&pdev->dev, lcd_cancel_fault_work, fb);
	if (ret)
		return ret;
	/* Never reset existing same-generation ownership: runtime rebind is not
	 * supported. A cold boot has a new generation and ignores old records. */
	for (unsigned int slot = 0; slot < 2; slot++) {
		struct frame_record old;
		read_record(slot_record(fb, slot), &old);
		if (le32_to_cpu(old.magic) == LCD(REQUEST_MAGIC) &&
		    le32_to_cpu(old.generation) == fb->generation &&
		    le32_to_cpu(old.sequence))
			return -EBUSY;
	}
	ret = drmm_mode_config_init(&fb->drm);
	if (ret)
		return ret;
	fb->drm.mode_config.funcs = &lcd_mode_config_funcs;
	fb->drm.mode_config.helper_private = &lcd_mode_config_helpers;
	fb->drm.mode_config.min_width = fb->drm.mode_config.max_width = 240;
	fb->drm.mode_config.min_height = fb->drm.mode_config.max_height = 240;
	fb->drm.mode_config.preferred_depth = 16;
	ret = drm_universal_plane_init(&fb->drm, &fb->primary, 0, &lcd_plane_funcs,
		formats, ARRAY_SIZE(formats), modifiers, DRM_PLANE_TYPE_PRIMARY, NULL);
	if (ret)
		return ret;
	drm_plane_helper_add(&fb->primary, &lcd_plane_helpers);
	/* The scanout path merges damage, so advertise FB_DAMAGE_CLIPS: without
	 * it an atomic client cannot describe what changed and every update
	 * costs a whole frame, and drm_plane_get_damage_clips() warns. DIRTYFB
	 * sets the blob directly and works either way. */
	drm_plane_enable_fb_damage_clips(&fb->primary);
	ret = drm_crtc_init_with_planes(&fb->drm, &fb->crtc, &fb->primary, NULL,
					&lcd_crtc_funcs, NULL);
	if (ret)
		return ret;
	drm_crtc_helper_add(&fb->crtc, &lcd_crtc_helpers);
	ret = drm_encoder_init(&fb->drm, &fb->encoder, &lcd_encoder_funcs,
			       DRM_MODE_ENCODER_NONE, NULL);
	if (ret)
		return ret;
	fb->encoder.possible_crtcs = drm_crtc_mask(&fb->crtc);
	ret = drm_connector_init(&fb->drm, &fb->connector, &lcd_connector_funcs,
				 DRM_MODE_CONNECTOR_SPI);
	if (ret)
		return ret;
	drm_connector_helper_add(&fb->connector, &lcd_connector_helpers);
	ret = drm_connector_attach_encoder(&fb->connector, &fb->encoder);
	if (ret)
		return ret;
	drm_mode_config_reset(&fb->drm);
	platform_set_drvdata(pdev, fb);
	ret = devm_device_add_group(&pdev->dev, &lcd_group);
	if (ret)
		return ret;
	ret = drm_dev_register(&fb->drm, 0);
	if (ret)
		return ret;
	/* Attach-only lab device: do not release mappings during remote scanout. */
	__module_get(THIS_MODULE);
	drm_client_setup_with_fourcc(&fb->drm, DRM_FORMAT_RGB565);
	dev_info(&pdev->dev, "C906L DRM: 240x240 RGB565, acknowledged remote scanout, generation %u\n",
		 fb->generation);
	return 0;
}

static const struct of_device_id lcd_match[] = {
	{ .compatible = "sophgo,sg2002-c906l-framebuffer" },
	{ }
};
MODULE_DEVICE_TABLE(of, lcd_match);
static struct platform_driver lcd_driver = {
	.probe = lcd_probe,
	.driver = {
		.name = "sg2002-c906l-framebuffer",
		.of_match_table = lcd_match,
		.suppress_bind_attrs = true,
	},
};
module_platform_driver(lcd_driver);
MODULE_DESCRIPTION("SG2002 C906L DRM/KMS remote LCD with GEM shmem and fbdev");
MODULE_LICENSE("GPL");
