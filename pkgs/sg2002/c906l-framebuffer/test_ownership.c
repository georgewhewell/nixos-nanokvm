/* Host fakes surround unmodified production transport, independent of DRM. */
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "sg2002-c906l-contract.h"

#define __iomem
#define ERESTARTSYS 512
#define LCD(name) SG2002_C906L_PICOCLAW_LCD_##name
#define le32_to_cpu(value) ((uint32_t)(value))
#define le16_to_cpu(value) ((uint16_t)(value))
#define cpu_to_le16(value) ((uint16_t)(value))
#define le64_to_cpu(value) ((uint64_t)(value))
#define current NULL
#define signal_pending(task) pending_signal
#define time_after_eq(a, b) ((long)((a) - (b)) >= 0)
#define USEC_PER_SEC 1000000L
#define umin(a, b) ((a) < (b) ? (a) : (b))
#define clamp_t(type, value, low, high) \
	((type)(value) < (type)(low) ? (type)(low) : \
	 (type)(value) > (type)(high) ? (type)(high) : (type)(value))
typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;
typedef uint32_t __le32;
typedef uint16_t __le16;
struct mutex { bool locked; };
/* Only members accessed by the extracted transport; kernel/DRM owns lifetime. */
struct lcd_frames {
	u8 *shared;
	struct mutex lock;
	u32 generation, sequence[2], completed[2];
};
static const u8 contract_digest[32] = SG2002_C906L_CONTRACT_SHA256_BYTES;
static unsigned long jiffies;
static bool pending_signal;
static unsigned int sleeps, io_reads, mutate_read;
/* Requested sleep lengths, so the poll backoff itself can be asserted. */
static unsigned int slept_us[8];
static void *mutate_address;
static u8 memory[SG2002_C906L_SHMEM_SIZE];
static void rmb(void) { }
static void memcpy_fromio(void *destination, const void *source, size_t size)
{
	if (++io_reads == mutate_read && mutate_address)
		*(u32 *)mutate_address ^= 1;
	memcpy(destination, source, size);
}
static void *memchr_inv(const void *address, int value, size_t size)
{
	const u8 *bytes = address;
	for (size_t index = 0; index < size; index++)
		if (bytes[index] != value)
			return (void *)(bytes + index);
	return NULL;
}
static bool mutex_trylock(struct mutex *lock)
{
	if (lock->locked)
		return false;
	lock->locked = true;
	return true;
}
static void msleep(unsigned int delay) { jiffies += delay; sleeps++; }
static uint64_t div_u64(uint64_t dividend, uint32_t divisor) { return dividend / divisor; }
/* One deadline unit per wait regardless of the requested range: these tests
 * cover loop structure, deadline handling and backoff, not real timing. */
static void usleep_range(unsigned int low, unsigned int high)
{
	assert(low > 0 && high >= low);
	if (sleeps < sizeof(slept_us) / sizeof(*slept_us))
		slept_us[sleeps] = low;
	jiffies++;
	sleeps++;
}

/* Model only event ownership/refcounts; ordering is the production callback. */
struct completion { unsigned int done, released; };
struct dma_fence { int error; unsigned int signaled, put; };
struct drm_pending_event {
	struct completion *completion;
	void (*completion_release)(struct completion *);
	struct dma_fence *fence;
};
struct drm_pending_vblank_event { struct drm_pending_event base; };
struct drm_device { int event_lock; };
struct drm_crtc { int unused; };
struct drm_crtc_state { struct drm_pending_vblank_event *event; };
struct drm_atomic_commit {
	struct drm_device *dev;
	struct drm_crtc *crtc;
	struct drm_crtc_state *new_state;
};
static bool event_locked;
static unsigned int canceled;
#define for_each_new_crtc_in_state(state, crtc, new, i) \
	for ((i) = 0, (crtc) = (state)->crtc, (new) = (state)->new_state; \
	     (i) < 1; (i)++, (void)(crtc))
#define spin_lock_irqsave(lock, flags) do { \
	(void)(lock); (flags) = 0; assert(!event_locked); event_locked = true; \
} while (0)
#define spin_unlock_irqrestore(lock, flags) do { \
	(void)(lock); (void)(flags); assert(event_locked); event_locked = false; \
} while (0)
static void complete_all(struct completion *value)
{
	assert(event_locked); value->done++;
}
static void completion_release(struct completion *value)
{
	assert(event_locked && value->done == 1); value->released++;
}
static void dma_fence_set_error(struct dma_fence *fence, int error)
{
	assert(event_locked && error < 0 && !fence->signaled); fence->error = error;
}
static void dma_fence_signal(struct dma_fence *fence)
{
	assert(event_locked && fence->error < 0); fence->signaled++;
}
static void drm_event_cancel_free(struct drm_device *dev, struct drm_pending_event *event)
{
	assert(!event_locked && !event->completion);
	if (event->fence) event->fence->put++;
	canceled++;
}

/* @PRODUCTION@ */

static struct lcd_frames fb;
static struct sg2002_c906l_status *status;

static void reset(void)
{
	memset(memory, 0, sizeof(memory));
	memset(&fb, 0, sizeof(fb));
	fb.shared = memory;
	fb.generation = 7;
	status = (void *)(memory + SG2002_C906L_STATUS_REGION_OFFSET);
	status->magic = SG2002_C906L_SHMEM_MAGIC;
	status->abi_major = SG2002_C906L_ABI_MAJOR;
	status->abi_minor = SG2002_C906L_ABI_MINOR;
	status->struct_size = sizeof(*status);
	status->state = SG2002_C906L_STATE_RUNNING;
	status->generation = 7;
	status->activation_state = SG2002_C906L_ACTIVATION_STATE_ACTIVE;
	status->capabilities = SG2002_C906L_EXPECTED_CAPABILITIES;
	io_reads = mutate_read = sleeps = 0;
	memset(slept_us, 0, sizeof(slept_us));
	mutate_address = NULL;
	jiffies = 0;
	pending_signal = false;
}
static struct frame_record *completion(unsigned int slot)
{
	return slot_record(&fb, slot) + LCD(COMPLETION_OFFSET);
}
static void finish(unsigned int slot, u32 sequence, u32 error)
{
	*completion(slot) = (struct frame_record) {
		.magic = LCD(COMPLETION_MAGIC), .generation = 7,
		.sequence = sequence, .commit = sequence, .result = error,
	};
}
static struct sg2002_c906l_manifest manifest(void)
{
	struct sg2002_c906l_manifest m = {
		.magic = SG2002_C906L_MANIFEST_MAGIC,
		.format_major = SG2002_C906L_MANIFEST_FORMAT_MAJOR,
		.format_minor = SG2002_C906L_MANIFEST_FORMAT_MINOR,
		.struct_size = SG2002_C906L_MANIFEST_SIZE,
		.generation = 7,
		.contract_epoch = SG2002_C906L_CONTRACT_EPOCH,
		.profile_id = SG2002_C906L_PROFILE_ID,
		.abi_major = SG2002_C906L_ABI_MAJOR,
		.abi_minor = SG2002_C906L_ABI_MINOR,
		.capability_width = SG2002_C906L_CAPABILITY_WIRE_WIDTH,
		.lease_width = SG2002_C906L_LEASE_WIRE_WIDTH,
		.final_capabilities = SG2002_C906L_EXPECTED_CAPABILITIES,
		.dormant_capabilities = SG2002_C906L_DORMANT_CAPABILITIES,
		.lease_mask = SG2002_C906L_LEASE_MASK,
		.flags = SG2002_C906L_MANIFEST_FLAGS,
		.commit = SG2002_C906L_MANIFEST_COMMIT,
	};
	memcpy(m.contract_sha256, contract_digest, sizeof(contract_digest));
	return m;
}

int main(void)
{
	_Static_assert(sizeof(struct frame_record) == 64, "cacheline size changed");
	_Static_assert(offsetof(struct frame_record, commit) == 60, "commit offset changed");
	struct sg2002_c906l_manifest good = manifest();
	assert(manifest_valid(&good));
	for (size_t offset = 0; offset < sizeof(good); offset++) {
		/* Live generation is separately compared against status by probe. */
		if (offset >= offsetof(struct sg2002_c906l_manifest, generation) &&
		    offset < offsetof(struct sg2002_c906l_manifest, generation) + 4)
			continue;
		struct sg2002_c906l_manifest bad = good;
		((u8 *)&bad)[offset] ^= 1;
		assert(!manifest_valid(&bad));
	}
	reset();
	assert(frame_completed(&fb, 0) == 1);
	fb.sequence[0] = 1;
	assert(frame_completed(&fb, 0) == 0);
	finish(0, 1, 0);
	completion(0)->generation = 8;
	assert(frame_completed(&fb, 0) == 0);
	completion(0)->generation = 7;
	completion(0)->commit = 0;
	assert(frame_completed(&fb, 0) == 0);
	completion(0)->commit = 1;
	io_reads = 0; mutate_read = 2; mutate_address = &completion(0)->result;
	assert(frame_completed(&fb, 0) == 0);
	mutate_read = 0;
	assert(frame_completed(&fb, 0) == -EIO);
	assert(fb.completed[0] == 0); /* Error completion never reclaims. */
	finish(0, 1, 0); completion(0)->reserved[LCD(RECORD_RESERVED_SIZE) - 1] = 1;
	assert(frame_completed(&fb, 0) == -EPROTO);
	finish(0, 1, 0); completion(0)->width = 1;
	assert(frame_completed(&fb, 0) == -EPROTO);
	completion(0)->width = 0;
	assert(frame_completed(&fb, 0) == 1 && fb.completed[0] == 1);

	reset(); fb.sequence[0] = fb.sequence[1] = 1;
	finish(0, 1, 0);
	assert(frame_completed(&fb, 0) == 1);
	assert(frame_completed(&fb, 1) == 0); /* Same seq, distinct ownership line. */
	finish(1, 1, 0);
	assert(frame_completed(&fb, 1) == 1);
	assert((u8 *)completion(1) - (u8 *)completion(0) == LCD(OWNERSHIP_SIZE));
	reset(); fb.sequence[0] = 1; fb.completed[0] = UINT32_MAX;
	finish(0, UINT32_MAX, 0);
	assert(frame_completed(&fb, 0) == 0);
	finish(0, 1, 0);
	assert(frame_completed(&fb, 0) == 1); /* Wrap requires new completion. */

	reset();
	assert(check_generation(&fb) == 0);
	status->activation_state = SG2002_C906L_ACTIVATION_STATE_DORMANT;
	assert(check_generation(&fb) == -EIO);
	status->activation_state = SG2002_C906L_ACTIVATION_STATE_ACTIVE;
	status->capabilities ^= 1;
	assert(check_generation(&fb) == -EIO);
	status->capabilities ^= 1;
	io_reads = 0; mutate_read = 2; mutate_address = &status->heartbeat;
	assert(check_generation(&fb) == -EAGAIN);
	mutate_read = 0;
	fb.sequence[0] = 1;
	/* Sleep through the predicted transfer first, then poll finely and back
	 * off, so a stalled C906L cannot spin out the whole deadline. */
	assert(wait_slot(&fb, 0, 10, false, 19000) == -ETIMEDOUT);
	assert(jiffies == 10 && sleeps == 10);
	assert(slept_us[0] == 19000 && slept_us[1] == POLL_US);
	assert(slept_us[2] == 500 && slept_us[3] == 1000);
	assert(slept_us[4] == POLL_MAX_US && slept_us[5] == POLL_MAX_US);
	/* A pending signal never abandons a committed frame: wait to the deadline. */
	pending_signal = true;
	assert(wait_slot(&fb, 0, 15, false, POLL_US) == -ETIMEDOUT && jiffies == 15 && sleeps == 15);
	pending_signal = false; status->generation = 8;
	assert(wait_slot(&fb, 0, 20, true, POLL_US) == -ESTALE);
	status->generation = 7; status->flags = 1;
	assert(wait_slot(&fb, 0, 20, true, POLL_US) == -EIO);
	/* Full and partial frames use the supported 11.71875 MHz panel clock.
	 * The prediction must cover the whole transfer, not cap it at 32 ms. */
	assert(wire_time_us(SG2002_C906L_PICOCLAW_LCD_WIDTH *
			    SG2002_C906L_PICOCLAW_LCD_HEIGHT) == 78643);
	assert(wire_time_us(240 * 16) == 5242);
	assert(wire_time_us(0) == POLL_US && wire_time_us(~0u) == WIRE_TIME_MAX_US);

	reset(); fb.lock.locked = true;
	assert(lock_until(&fb, 10, true) == -EAGAIN && jiffies == 0);
	assert(lock_until(&fb, 10, false) == -ETIMEDOUT && jiffies == 10);
	pending_signal = true;
	assert(lock_until(&fb, 20, false) == -ETIMEDOUT && jiffies == 20);
	pending_signal = false; fb.lock.locked = false;
	assert(lock_until(&fb, 20, false) == 0 && fb.lock.locked);

	struct drm_device drm = { 0 };
	struct drm_crtc crtc = { 0 };
	struct completion done = { 0 };
	struct dma_fence fence = { 0 };
	struct drm_pending_vblank_event event = {
		.base = { .completion = &done, .completion_release = completion_release,
			  .fence = &fence },
	};
	struct drm_crtc_state new = { .event = &event };
	struct drm_atomic_commit state = { .dev = &drm, .crtc = &crtc, .new_state = &new };
	lcd_cancel_events(&state, -ETIMEDOUT);
	assert(!new.event && !event.base.completion && !event_locked);
	assert(done.done == 1 && done.released == 1);
	assert(fence.error == -ETIMEDOUT && fence.signaled == 1 && fence.put == 1);
	assert(canceled == 1);
	lcd_cancel_events(&state, -EIO); /* An already-consumed event is untouched. */
	assert(canceled == 1 && fence.put == 1);
	event = (struct drm_pending_vblank_event) { 0 };
	new.event = &event;
	lcd_cancel_events(&state, -EIO); /* File-close/no-fence paths remain safe. */
	assert(!new.event && canceled == 2);
	puts("framebuffer ownership: identity, torn reads, faults, slots, wrap, deadlines passed");
	return 0;
}
