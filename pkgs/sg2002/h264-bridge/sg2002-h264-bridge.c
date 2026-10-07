/*
 * SG2002 hardware H.264 bridge:
 *
 * HDMI UYVY or ISP NV21 -> VPSS scaler/CSC -> NV12 -> Coda encoder.
 * Capture buffers are exported to VPSS; VPSS and Coda share DMA-BUFs.
 * The base path moves buffer descriptors without converting raw pixels.
 * Optional TPU detection samples NV12 and paints overlays before encoding.
 * Sinks: Annex-B file/stdout and/or RTSP publisher (MediaMTX).
 *
 * SPDX-License-Identifier: GPL-2.0-only
 */

#define _GNU_SOURCE
#ifdef ENABLE_PCMA
#include <alsa/asoundlib.h>
#include <pthread.h>
#endif
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/dma-buf.h>
#include <linux/dma-heap.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <netdb.h>
#include <unistd.h>
#ifdef ENABLE_DETECTION
#include "detection.h"
#endif

#define CAPTURE_BUFFERS 2
#define ENCODER_CAP_BUFFERS 3
#define SCALER_MID_BUFFERS 4
/* Probe order can swap Coda and VPSS video numbers between boots. */
#define DEFAULT_CAPTURE "/dev/v4l/by-path/platform-a0c2000.video-capture-video-index0"
#define DEFAULT_ENCODER "/dev/v4l/by-path/platform-b030000.video-codec-video-index0"
#define DEFAULT_SCALER "/dev/v4l/by-path/platform-a080000.vpss-video-index0"
/* VPSS and Coda require contiguous, single-segment DMA-BUFs. */
#define DMA_HEAP_CMA "/dev/dma_heap/default_cma_region"
/* The no-map media pool exported as a heap: contiguous by definition and
 * independent of the colonized default CMA. */
#define DMA_HEAP_RESERVED "/dev/dma_heap/reserved"

#define RTP_MTU 1400
#define RTP_PT 96
#ifdef ENABLE_PCMA
#define RTP_VIDEO_PT RTP_PT
#define RTP_AUDIO_PT 8
#define AUDIO_INPUT_RATE 48000U
#define AUDIO_INPUT_CHANNELS 2U
#define AUDIO_OUTPUT_RATE 8000U
#define AUDIO_OUTPUT_SAMPLES 160U /* 20 ms at 8 kHz */
#define AUDIO_INPUT_CHUNK 1024U
#define AUDIO_DRAIN_BUDGET 16U
#endif
#define RTSP_RECONNECT_MS 2000

static volatile sig_atomic_t stop_requested;

static void on_signal(int signal_number)
{
	(void)signal_number;
	stop_requested = 1;
}

static int xioctl(int fd, unsigned long request, void *arg)
{
	int ret;

	do
		/* musl declares the Linux ioctl command as int; Linux truncates
		 * the command to its low 32 bits on entry, so this is safe for the
		 * V4L2 _IOC values and keeps both glibc and musl builds warning-free. */
#ifdef __GLIBC__
		ret = ioctl(fd, request, arg);
#else
		ret = ioctl(fd, (int)request, arg);
#endif
	while (ret < 0 && errno == EINTR);
	return ret;
}

static void die_errno(const char *what)
{
	fprintf(stderr, "%s: %s\n", what, strerror(errno));
}

static uint64_t now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

static uint64_t now_ns(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static int frame_due(uint64_t now, uint64_t interval, uint64_t *next)
{
	if (!interval)
		return 1;
	if (!*next)
		*next = now;
	if (now < *next)
		return 0;
	/* Keep the cadence despite wakeup jitter; discard missed slots after
	 * a stall instead of admitting a burst of catch-up frames. */
	*next += ((now - *next) / interval + 1) * interval;
	return 1;
}

static int write_all(int fd, const void *data, size_t length)
{
	const uint8_t *cursor = data;

	while (length) {
		ssize_t written = write(fd, cursor, length);

		if (written < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (!written) {
			errno = EIO;
			return -1;
		}
		cursor += written;
		length -= (size_t)written;
	}
	return 0;
}

static int parse_u32(const char *text, unsigned int *value)
{
	char *end;
	unsigned long parsed;

	errno = 0;
	parsed = strtoul(text, &end, 10);
	if (errno || end == text || *end || parsed > UINT32_MAX)
		return -1;
	*value = (unsigned int)parsed;
	return 0;
}

/* ------------------------------------------------------------------ */
/* V4L2 helpers                                                        */
/* ------------------------------------------------------------------ */

struct mapped_buf {
	void *addr;
	size_t length;
	int dmabuf_fd; /* -1 for plain MMAP queues */
};

struct mapped_queue {
	struct mapped_buf *bufs;
	unsigned int count;
};

static void unmap_queue(struct mapped_queue *queue)
{
	unsigned int i;

	if (!queue->bufs)
		return;
	for (i = 0; i < queue->count; i++) {
		if (queue->bufs[i].addr && queue->bufs[i].length &&
		    queue->bufs[i].addr != MAP_FAILED)
			munmap(queue->bufs[i].addr, queue->bufs[i].length);
		if (queue->bufs[i].dmabuf_fd >= 0)
			close(queue->bufs[i].dmabuf_fd);
	}
	free(queue->bufs);
	queue->bufs = NULL;
	queue->count = 0;
}

static int map_queue(int fd, enum v4l2_buf_type type, unsigned int requested,
		     struct mapped_queue *queue)
{
	struct v4l2_requestbuffers request = {
		.count = requested,
		.type = type,
		.memory = V4L2_MEMORY_MMAP,
	};
	unsigned int i;

	if (xioctl(fd, VIDIOC_REQBUFS, &request)) {
		int saved_errno = errno;

		fprintf(stderr, "VIDIOC_REQBUFS mmap type=%u count=%u: %s\n",
			type, requested, strerror(saved_errno));
		errno = saved_errno;
		return -1;
	}
	if (request.count < 1) {
		errno = ENOBUFS;
		return -1;
	}
	queue->bufs = calloc(request.count, sizeof(*queue->bufs));
	if (!queue->bufs) {
		fprintf(stderr, "calloc V4L2 mmap queue count=%u: %s\n",
			request.count, strerror(errno));
		return -1;
	}
	queue->count = request.count;
	for (i = 0; i < queue->count; i++) {
		struct v4l2_buffer buffer = {
			.type = type,
			.memory = V4L2_MEMORY_MMAP,
			.index = i,
		};
		if (xioctl(fd, VIDIOC_QUERYBUF, &buffer)) {
			int saved_errno = errno;

			fprintf(stderr, "VIDIOC_QUERYBUF mmap type=%u index=%u: %s\n",
				type, i, strerror(saved_errno));
			errno = saved_errno;
			return -1;
		}
		queue->bufs[i].length = buffer.length;
		queue->bufs[i].dmabuf_fd = -1;
		queue->bufs[i].addr = mmap(NULL, buffer.length, PROT_READ | PROT_WRITE,
					  MAP_SHARED, fd, buffer.m.offset);
		if (queue->bufs[i].addr == MAP_FAILED) {
			int saved_errno = errno;

			queue->bufs[i].addr = NULL;
			fprintf(stderr, "mmap V4L2 buffer type=%u index=%u length=%u: %s\n",
				type, i, buffer.length, strerror(saved_errno));
			errno = saved_errno;
			return -1;
		}
	}
	return 0;
}

/* Allocate `requested` raw-frame buffers from the system dma-heap, map them
 * cached, and register them with the encoder OUTPUT queue as DMABUF. */
static int queue_buffer(int fd, enum v4l2_buf_type type, unsigned int index,
			unsigned int bytesused)
{
	struct v4l2_buffer buffer = {
		.type = type,
		.memory = V4L2_MEMORY_MMAP,
		.index = index,
		.bytesused = bytesused,
	};
	return xioctl(fd, VIDIOC_QBUF, &buffer);
}

static int queue_dmabuf(int fd, enum v4l2_buf_type type, unsigned int index,
			int dmabuf_fd, unsigned int bytesused)
{
	struct v4l2_buffer buffer = {
		.type = type,
		.memory = V4L2_MEMORY_DMABUF,
		.index = index,
		.bytesused = bytesused,
	};

	buffer.m.fd = dmabuf_fd;
	return xioctl(fd, VIDIOC_QBUF, &buffer);
}

static int dequeue_buffer_mem(int fd, enum v4l2_buf_type type,
			      unsigned int memory, struct v4l2_buffer *buffer)
{
	memset(buffer, 0, sizeof(*buffer));
	buffer->type = type;
	buffer->memory = memory;
	return xioctl(fd, VIDIOC_DQBUF, buffer);
}

static int dequeue_buffer(int fd, enum v4l2_buf_type type,
			  struct v4l2_buffer *buffer)
{
	return dequeue_buffer_mem(fd, type, V4L2_MEMORY_MMAP, buffer);
}

static int stream(int fd, enum v4l2_buf_type type, int on)
{
	return xioctl(fd, on ? VIDIOC_STREAMON : VIDIOC_STREAMOFF, &type);
}

static int get_format(int fd, enum v4l2_buf_type type,
		      struct v4l2_pix_format *pix)
{
	struct v4l2_format format = { .type = type };
	format.fmt.pix.priv = V4L2_PIX_FMT_PRIV_MAGIC;
	if (xioctl(fd, VIDIOC_G_FMT, &format))
		return -1;
	*pix = format.fmt.pix;
	return 0;
}

static int set_video_format(int fd, enum v4l2_buf_type type,
			    uint32_t pixel_format, unsigned int width,
			    unsigned int height,
			    const struct v4l2_pix_format *color,
			    struct v4l2_pix_format *actual)
{
	struct v4l2_format format = { .type = type };

	format.fmt.pix.width = width;
	format.fmt.pix.height = height;
	format.fmt.pix.pixelformat = pixel_format;
	format.fmt.pix.field = V4L2_FIELD_NONE;
	format.fmt.pix.priv = V4L2_PIX_FMT_PRIV_MAGIC;
	if (color) {
		format.fmt.pix.colorspace = color->colorspace;
		format.fmt.pix.xfer_func = color->xfer_func;
		format.fmt.pix.ycbcr_enc = color->ycbcr_enc;
		format.fmt.pix.quantization = color->quantization;
	}
	if (pixel_format == V4L2_PIX_FMT_H264)
		format.fmt.pix.sizeimage = 1024U * 1024U;
	if (xioctl(fd, VIDIOC_S_FMT, &format))
		return -1;
	*actual = format.fmt.pix;
	return 0;
}

static int set_encoder_format(int fd, enum v4l2_buf_type type,
			      uint32_t pixel_format, unsigned int width,
			      unsigned int height, struct v4l2_pix_format *actual)
{
	return set_video_format(fd, type, pixel_format, width, height, NULL, actual);
}

/* Both pipelines encode one synthetic reference picture before live input. */
static uint64_t live_encoded_frames(uint64_t encoded_frames)
{
	return encoded_frames ? encoded_frames - 1 : 0;
}

static int live_frame_limit_reached(unsigned int limit, uint64_t encoded_frames)
{
	return limit && live_encoded_frames(encoded_frames) >= limit;
}

static int report_live_frames(unsigned int limit, uint64_t encoded_frames)
{
	fprintf(stderr, "encoded provenance: %" PRIu64 " live frames, %u priming picture\n",
		live_encoded_frames(encoded_frames), encoded_frames ? 1U : 0U);
	if (limit && !live_frame_limit_reached(limit, encoded_frames)) {
		errno = ECANCELED;
		return -1;
	}
	return 0;
}

static int set_output_crop(int fd, unsigned int width, unsigned int height)
{
	struct v4l2_selection selection = {
		.type = V4L2_BUF_TYPE_VIDEO_OUTPUT,
		.target = V4L2_SEL_TGT_CROP,
		.r = {
			.width = width,
			.height = height,
		},
	};
	return xioctl(fd, VIDIOC_S_SELECTION, &selection);
}

static int set_encoder_controls(int fd, unsigned int bitrate, unsigned int gop)
{
	struct v4l2_ext_control controls[2];
	struct v4l2_ext_controls list = {
		.which = V4L2_CTRL_CLASS_CODEC,
		.count = 0,
		.controls = controls,
	};

	if (bitrate) {
		controls[list.count].id = V4L2_CID_MPEG_VIDEO_BITRATE;
		controls[list.count].value = (int32_t)bitrate;
		list.count++;
	}
	if (gop) {
		controls[list.count].id = V4L2_CID_MPEG_VIDEO_GOP_SIZE;
		controls[list.count].value = (int32_t)gop;
		list.count++;
	}
	if (!list.count)
		return 0;
	return xioctl(fd, VIDIOC_S_EXT_CTRLS, &list);
}

/* ------------------------------------------------------------------ */
/* H.264 Annex-B NAL scanning + base64                                 */
/* ------------------------------------------------------------------ */

struct nal_view {
	const uint8_t *data; /* points just past the start code */
	size_t size;
	unsigned int type;
};

/* Split one access unit into NAL views.  Returns count, or 0 when the
 * buffer does not look like Annex-B. */
static unsigned int annexb_split(const uint8_t *buf, size_t size,
				 struct nal_view *nals, unsigned int max_nals)
{
	unsigned int count = 0;
	size_t pos = 0;

	while (pos + 4 <= size && count < max_nals) {
		size_t sc = SIZE_MAX, sc_len = 0, next, i;

		for (i = pos; i + 3 <= size; i++) {
			if (buf[i] == 0 && buf[i + 1] == 0 &&
			    ((i + 3 < size && buf[i + 2] == 1) ||
			     (i + 4 <= size && buf[i + 2] == 0 && buf[i + 3] == 1))) {
				sc = i;
				sc_len = buf[i + 2] == 1 ? 3 : 4;
				break;
			}
		}
		if (sc == SIZE_MAX)
			break;
		for (next = sc + sc_len; next + 3 <= size; next++) {
			if (buf[next] == 0 && buf[next + 1] == 0 &&
			    (buf[next + 2] == 1 ||
			     (next + 3 < size && buf[next + 2] == 0 && buf[next + 3] == 1)))
				break;
		}
		if (next + 3 > size)
			next = size;
		if (sc + sc_len >= next)
			break;
		nals[count].data = buf + sc + sc_len;
		nals[count].size = next - (sc + sc_len);
		nals[count].type = nals[count].data[0] & 0x1f;
		count++;
		pos = next;
	}
	return count;
}

static const char b64_alphabet[] =
	"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static void base64_encode(const uint8_t *in, size_t len, char *out)
{
	size_t i, o = 0;

	for (i = 0; i + 3 <= len; i += 3) {
		uint32_t v = (uint32_t)in[i] << 16 | (uint32_t)in[i + 1] << 8 | in[i + 2];

		out[o++] = b64_alphabet[v >> 18];
		out[o++] = b64_alphabet[(v >> 12) & 63];
		out[o++] = b64_alphabet[(v >> 6) & 63];
		out[o++] = b64_alphabet[v & 63];
	}
	if (i < len) {
		uint32_t v = (uint32_t)in[i] << 16;

		if (i + 1 < len)
			v |= (uint32_t)in[i + 1] << 8;
		out[o++] = b64_alphabet[v >> 18];
		out[o++] = b64_alphabet[(v >> 12) & 63];
		out[o++] = i + 1 < len ? b64_alphabet[(v >> 6) & 63] : '=';
		out[o++] = '=';
	}
	out[o] = '\0';
}

/* ------------------------------------------------------------------ */
/* Minimal RTSP publisher (TCP interleaved, H.264 RTP packetization).
 * PCMA is compiled in only for the explicit camera test derivation; keeping
 * the normal bridge's RTSP path below unchanged makes its video behaviour and
 * closure independent of ALSA. */
/* ------------------------------------------------------------------ */

#ifdef ENABLE_PCMA
struct rtp_track {
	uint8_t channel;
	uint8_t payload_type;
	uint16_t sequence;
	uint32_t ssrc;
};
#endif

struct rtsp_sink {
	char url[160];
	char host[61];
	char path[81];
	uint16_t port;
	int fd;              /* -1 when disconnected */
#ifdef ENABLE_PCMA
	struct rtp_track video;
	struct rtp_track audio;
	int audio_enabled;
	uint32_t audio_epoch;
	uint64_t audio_epoch_timestamp;
#else
	uint16_t rtp_seq;
	uint32_t rtp_ssrc;
#endif
	uint32_t cseq;
	uint64_t next_retry_ms;
	/* Stashed parameter sets for the SDP offer. */
	uint8_t sps[256];
	size_t sps_len;
	uint8_t pps[256];
	size_t pps_len;
	int have_params;
};

#ifdef ENABLE_PCMA
static void rtsp_init(struct rtsp_sink *sink)
{
	memset(sink, 0, sizeof(*sink));
	sink->fd = -1;
	sink->video.channel = 0;
	sink->video.payload_type = RTP_VIDEO_PT;
	sink->video.ssrc = 0x53324732; /* "S2G2" */
	sink->audio.channel = 2;
	sink->audio.payload_type = RTP_AUDIO_PT;
	sink->audio.ssrc = 0x53324733; /* "S2G3" */
}

static uint64_t monotonic_ticks(unsigned int rate)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * rate +
		(uint64_t)ts.tv_nsec * rate / 1000000000ULL;
}

static int rtsp_make_sdp(const struct rtsp_sink *sink, const char *sps_b64,
			 const char *pps_b64, char *sdp, size_t sdp_size)
{
	int len;

	if (sink->audio_enabled)
		len = snprintf(sdp, sdp_size,
		"v=0\r\n"
		"o=- 0 0 IN IP4 127.0.0.1\r\n"
		"s=sg2002-kvm\r\n"
		"c=IN IP4 0.0.0.0\r\n"
		"t=0 0\r\n"
		"m=video 0 RTP/AVP/TCP 96\r\n"
		"a=rtpmap:96 H264/90000\r\n"
		"a=fmtp:96 packetization-mode=1;sprop-parameter-sets=%s,%s\r\n"
		"a=control:trackID=0\r\n"
		"m=audio 0 RTP/AVP/TCP 8\r\n"
		"a=rtpmap:8 PCMA/8000/1\r\n"
		"a=control:trackID=1\r\n",
		sps_b64, pps_b64);
	else
		len = snprintf(sdp, sdp_size,
		"v=0\r\n"
		"o=- 0 0 IN IP4 127.0.0.1\r\n"
		"s=sg2002-kvm\r\n"
		"c=IN IP4 0.0.0.0\r\n"
		"t=0 0\r\n"
		"m=video 0 RTP/AVP/TCP 96\r\n"
		"a=rtpmap:96 H264/90000\r\n"
		"a=fmtp:96 packetization-mode=1;sprop-parameter-sets=%s,%s\r\n"
		"a=control:trackID=0\r\n",
		sps_b64, pps_b64);
	return len < 0 || (size_t)len >= sdp_size ? -1 : 0;
}
#endif

static int rtsp_parse_url(struct rtsp_sink *sink, const char *url)
{
	const char *authority, *slash, *colon;

	if (strncmp(url, "rtsp://", 7))
		return -1;
	authority = url + 7;
	slash = strchr(authority, '/');
	if (!slash)
		return -1;
	colon = memchr(authority, ':', (size_t)(slash - authority));
	if (colon) {
		unsigned int port = 0;
		size_t host_len = (size_t)(colon - authority);
		size_t port_len = (size_t)(slash - colon - 1);
		size_t d;

		if (!host_len || host_len > 60 || !port_len || port_len > 5)
			return -1;
		for (d = 0; d < port_len; d++) {
			if (colon[1 + d] < '0' || colon[1 + d] > '9')
				return -1;
			port = port * 10 + (unsigned int)(colon[1 + d] - '0');
		}
		if (!port || port > 65535)
			return -1;
		memcpy(sink->host, authority, host_len);
		sink->host[host_len] = '\0';
		sink->port = (uint16_t)port;
	} else {
		size_t host_len = (size_t)(slash - authority);

		if (!host_len || host_len > 60)
			return -1;
		memcpy(sink->host, authority, host_len);
		sink->host[host_len] = '\0';
		sink->port = 554;
	}
	if (strlen(slash) > 80)
		return -1;
	strcpy(sink->path, slash);
	snprintf(sink->url, sizeof(sink->url), "rtsp://%s:%u%s",
		 sink->host, sink->port, sink->path);
	return 0;
}

/* Read one RTSP response (headers only); returns the status code, or -1.
 * When session_out is given, any Session: header id (before ';') is copied
 * into it for echoing back on subsequent requests. */
static int rtsp_read_reply(int fd, char *session_out, size_t session_size)
{
	char buf[1024];
	size_t used = 0;
	int status = -1;

	for (;;) {
		if (used + 1 >= sizeof(buf))
			return -1;
		ssize_t got = read(fd, buf + used, 1);

		if (got < 0 && errno == EINTR)
			continue;
		if (got <= 0)
			return -1;
		used += (size_t)got;
		buf[used] = '\0';
		if (used >= 4 && !strcmp(buf + used - 4, "\r\n\r\n"))
			break;
	}
	if (sscanf(buf, "RTSP/1.0 %d", &status) != 1)
		return -1;
	if (session_out && session_size) {
		char *line = strstr(buf, "\r\n");
		const char *end = buf + used;

		session_out[0] = '\0';
		while (line && (line += 2) < end && line[0] != '\r') {
			if (!strncasecmp(line, "Session:", 8)) {
				char *value = line + 8;
				char *stop;
				size_t len;

				while (*value == ' ')
					value++;
				stop = strchr(value, ';');
				if (!stop)
					stop = strstr(value, "\r\n");
				if (stop) {
					len = (size_t)(stop - value);
					if (len >= session_size)
						len = session_size - 1;
					memcpy(session_out, value, len);
					session_out[len] = '\0';
				}
				break;
			}
			line = strstr(line, "\r\n");
		}
	}
	return status;
}

static int rtsp_request(struct rtsp_sink *sink, const char *method,
			const char *extra_headers, const char *body)
{
	char request[2048];
	int len;

	len = snprintf(request, sizeof(request), "%s %s RTSP/1.0\r\nCSeq: %u\r\n",
		       method, sink->url, ++sink->cseq);
	if (len > 0 && extra_headers)
		len += snprintf(request + len, sizeof(request) - (size_t)len, "%s",
				extra_headers);
	if (len > 0 && body)
		len += snprintf(request + len, sizeof(request) - (size_t)len,
				"Content-Type: application/sdp\r\n"
				"Content-Length: %zu\r\n\r\n%s",
				strlen(body), body);
	else if (len > 0)
		len += snprintf(request + len, sizeof(request) - (size_t)len,
				"\r\n");
	if (len < 0 || (size_t)len >= sizeof(request))
		return -1;
	if (write_all(sink->fd, request, (size_t)len))
		return -1;
	return rtsp_read_reply(sink->fd, NULL, 0);
}

static void rtsp_close(struct rtsp_sink *sink)
{
	if (sink->fd >= 0)
		close(sink->fd);
	sink->fd = -1;
	sink->next_retry_ms = now_ms() + RTSP_RECONNECT_MS;
}

#ifdef ENABLE_PCMA
static int rtsp_setup_track(struct rtsp_sink *sink, const char *track_name,
			    const char *session_in, char *session_out,
			    size_t session_size, uint8_t channel)
{
	char track_url[sizeof(sink->url) + 16];
	char request[640];
	int len;

	snprintf(track_url, sizeof(track_url), "%s/%s", sink->url, track_name);
	len = snprintf(request, sizeof(request),
		       "SETUP %s RTSP/1.0\r\nCSeq: %u\r\n"
		       "Transport: RTP/AVP/TCP;unicast;interleaved=%u-%u;mode=record\r\n%s\r\n",
		       track_url, ++sink->cseq, channel, (unsigned int)channel + 1,
		       session_in ? session_in : "");
	if (len < 0 || (size_t)len >= sizeof(request) ||
	    write_all(sink->fd, request, (size_t)len))
		return -1;
	return rtsp_read_reply(sink->fd, session_out, session_size);
}
#endif

static int rtsp_connect(struct rtsp_sink *sink)
{
	char port_text[8];
	struct addrinfo hints = {
		.ai_family = AF_UNSPEC,
		.ai_socktype = SOCK_STREAM,
	};
	struct addrinfo *result = NULL, *it;
	char sps_b64[384], pps_b64[384];
#ifdef ENABLE_PCMA
	char sdp[1600], session[80];
#else
	char sdp[1200];
#endif
	int status = -1;

	if (!sink->have_params)
		return -1;
	snprintf(port_text, sizeof(port_text), "%u", sink->port);
	if (getaddrinfo(sink->host, port_text, &hints, &result))
		return -1;
	for (it = result; it; it = it->ai_next) {
		sink->fd = socket(it->ai_family, it->ai_socktype, it->ai_protocol);
		if (sink->fd < 0)
			continue;
		if (!connect(sink->fd, it->ai_addr, it->ai_addrlen))
			break;
		close(sink->fd);
		sink->fd = -1;
	}
	freeaddrinfo(result);
	if (sink->fd < 0)
		return -1;

	base64_encode(sink->sps, sink->sps_len, sps_b64);
	base64_encode(sink->pps, sink->pps_len, pps_b64);
#ifdef ENABLE_PCMA
	if (rtsp_make_sdp(sink, sps_b64, pps_b64, sdp, sizeof(sdp)))
		goto fail;
#else
	snprintf(sdp, sizeof(sdp),
		 "v=0\r\n"
		 "o=- 0 0 IN IP4 127.0.0.1\r\n"
		 "s=sg2002-kvm\r\n"
		 "c=IN IP4 0.0.0.0\r\n"
		 "t=0 0\r\n"
		 "m=video 0 RTP/AVP/TCP 96\r\n"
		 "a=rtpmap:96 H264/90000\r\n"
		 "a=fmtp:96 packetization-mode=1;sprop-parameter-sets=%s,%s\r\n"
		 "a=control:track1\r\n",
		 sps_b64, pps_b64);
#endif

	sink->cseq = 0;
	status = rtsp_request(sink, "ANNOUNCE", NULL, sdp);
	if (status != 200)
		goto fail;
#ifdef ENABLE_PCMA
	status = rtsp_setup_track(sink, "trackID=0", NULL, session,
				  sizeof(session), sink->video.channel);
	if (status != 200 || !session[0])
		goto fail;
	if (sink->audio_enabled) {
		char session_header[112];

		snprintf(session_header, sizeof(session_header), "Session: %s\r\n", session);
		status = rtsp_setup_track(sink, "trackID=1", session_header, NULL, 0,
					  sink->audio.channel);
		if (status != 200)
			goto fail;
	}
	{
		char request[512];
		int len = snprintf(request, sizeof(request),
			"RECORD %s RTSP/1.0\r\nCSeq: %u\r\n"
			"Session: %s\r\nRange: npt=0.000-\r\n\r\n",
			sink->url, ++sink->cseq, session);

		if (len < 0 || (size_t)len >= sizeof(request) ||
		    write_all(sink->fd, request, (size_t)len))
			goto fail;
		status = rtsp_read_reply(sink->fd, NULL, 0);
		if (status != 200)
			goto fail;
	}
	if (sink->audio_enabled) {
		sink->audio_epoch_timestamp = monotonic_ticks(AUDIO_OUTPUT_RATE);
		sink->audio_epoch++;
	}
#else
	{
		char track_url[sizeof(sink->url) + 16];
		char request[512];
		char session[80];
		int len;

		snprintf(track_url, sizeof(track_url), "%s/track1", sink->url);
		len = snprintf(request, sizeof(request),
			       "SETUP %s RTSP/1.0\r\nCSeq: %u\r\n"
			       "Transport: RTP/AVP/TCP;unicast;interleaved=0-1;mode=record\r\n\r\n",
			       track_url, ++sink->cseq);
		if (len < 0 || (size_t)len >= sizeof(request) ||
		    write_all(sink->fd, request, (size_t)len))
			goto fail;
		status = rtsp_read_reply(sink->fd, session, sizeof(session));
		if (status != 200 || !session[0])
			goto fail;
		len = snprintf(request, sizeof(request),
			       "RECORD %s RTSP/1.0\r\nCSeq: %u\r\n"
			       "Session: %s\r\nRange: npt=0.000-\r\n\r\n",
			       sink->url, ++sink->cseq, session);
		if (len < 0 || (size_t)len >= sizeof(request) ||
		    write_all(sink->fd, request, (size_t)len))
			goto fail;
		status = rtsp_read_reply(sink->fd, NULL, 0);
		if (status != 200)
			goto fail;
	}
#endif
	fprintf(stderr, "rtsp: publishing to %s\n", sink->url);
	return 0;
fail:
	rtsp_close(sink);
	return -1;
}

/* RTP-send one access unit (Annex-B).  90 kHz clock. */
#ifdef ENABLE_PCMA
static void rtp_make_headers(const struct rtp_track *track, uint32_t timestamp,
			     int marker, uint8_t rtp[12], uint8_t interleaved[4],
			     size_t payload_length)
{
	uint32_t total = 12U + (uint32_t)payload_length;

	rtp[0] = 0x80;
	rtp[1] = (uint8_t)(track->payload_type | (marker ? 0x80 : 0));
	rtp[2] = (uint8_t)(track->sequence >> 8);
	rtp[3] = (uint8_t)track->sequence;
	rtp[4] = (uint8_t)(timestamp >> 24);
	rtp[5] = (uint8_t)(timestamp >> 16);
	rtp[6] = (uint8_t)(timestamp >> 8);
	rtp[7] = (uint8_t)timestamp;
	rtp[8] = (uint8_t)(track->ssrc >> 24);
	rtp[9] = (uint8_t)(track->ssrc >> 16);
	rtp[10] = (uint8_t)(track->ssrc >> 8);
	rtp[11] = (uint8_t)track->ssrc;
	interleaved[0] = '$';
	interleaved[1] = track->channel;
	interleaved[2] = (uint8_t)(total >> 8);
	interleaved[3] = (uint8_t)total;
}

static int rtsp_send_rtp(struct rtsp_sink *sink, struct rtp_track *track,
			 const uint8_t *payload, size_t length, uint32_t timestamp,
			 int marker)
{
	uint8_t packet[12 + RTP_MTU];
	uint8_t frame[4];

	if (length > RTP_MTU)
		return -1;
	rtp_make_headers(track, timestamp, marker, packet, frame, length);
	memcpy(packet + 12, payload, length);
	if (write_all(sink->fd, frame, sizeof(frame)) ||
	    write_all(sink->fd, packet, 12 + length))
		return -1;
	track->sequence++;
	return 0;
}
#endif

static int rtsp_send_au(struct rtsp_sink *sink, const uint8_t *buf, size_t size,
			uint64_t pts_ms)
{
#ifdef ENABLE_PCMA
	struct nal_view nals[32];
	unsigned int count, n;
	uint32_t timestamp = (uint32_t)(pts_ms * 90);

	count = annexb_split(buf, size, nals, 32);
	if (!count)
		return 0;
	for (n = 0; n < count; n++) {
		const uint8_t *nal = nals[n].data;
		size_t left = nals[n].size;
		int last_nal = n == count - 1;

		if (left <= RTP_MTU) {
			if (rtsp_send_rtp(sink, &sink->video, nal, left, timestamp,
					  last_nal))
				return -1;
		} else {
			uint8_t fu_header = (uint8_t)(nal[0] & 0xe0);
			uint8_t nal_type = (uint8_t)(nal[0] & 0x1f);
			size_t offset = 1;

			while (offset < left) {
				size_t chunk = left - offset;
				uint8_t payload[2 + RTP_MTU];
				int end;

				if (chunk > RTP_MTU - 2U)
					chunk = RTP_MTU - 2U;
				end = offset + chunk >= left;
				payload[0] = fu_header | 28;
				payload[1] = (uint8_t)((offset == 1 ? 0x80 : 0) |
						       (end ? 0x40 : 0) | nal_type);
				memcpy(payload + 2, nal + offset, chunk);
				if (rtsp_send_rtp(sink, &sink->video, payload, 2 + chunk,
						  timestamp, last_nal && end))
					return -1;
				offset += chunk;
			}
		}
	}
	return 0;
#else
	struct nal_view nals[32];
	unsigned int count, n;
	uint32_t timestamp = (uint32_t)(pts_ms * 90);

	count = annexb_split(buf, size, nals, 32);
	if (!count)
		return 0;
	for (n = 0; n < count; n++) {
		const uint8_t *nal = nals[n].data;
		size_t left = nals[n].size;
		int last_nal = n == count - 1;

		if (left <= RTP_MTU) {
			uint8_t packet[12 + RTP_MTU];
			uint8_t *p = packet;

			*p++ = 0x80;
			*p++ = RTP_PT | (last_nal ? 0x80 : 0);
			*p++ = (uint8_t)(sink->rtp_seq >> 8);
			*p++ = (uint8_t)sink->rtp_seq;
			*p++ = (uint8_t)(timestamp >> 24);
			*p++ = (uint8_t)(timestamp >> 16);
			*p++ = (uint8_t)(timestamp >> 8);
			*p++ = (uint8_t)timestamp;
			*p++ = (uint8_t)(sink->rtp_ssrc >> 24);
			*p++ = (uint8_t)(sink->rtp_ssrc >> 16);
			*p++ = (uint8_t)(sink->rtp_ssrc >> 8);
			*p++ = (uint8_t)sink->rtp_ssrc;
			memcpy(p, nal, left);
			{
				uint32_t total = 12 + (uint32_t)left;
				uint8_t frame[4] = {
					'$', 0,
					(uint8_t)(total >> 8), (uint8_t)total,
				};

				if (write_all(sink->fd, frame, 4) ||
				    write_all(sink->fd, packet, total))
					return -1;
			}
			sink->rtp_seq++;
		} else {
			uint8_t fu_header = (uint8_t)(nal[0] & 0xe0); /* F/NRI */
			uint8_t nal_type = (uint8_t)(nal[0] & 0x1f);
			size_t offset = 1;

			while (offset < left) {
				size_t chunk = left - offset;
				uint8_t packet[12 + 2 + RTP_MTU];
				uint8_t *p = packet;
				int end;

				if (chunk > RTP_MTU)
					chunk = RTP_MTU;
				end = offset + chunk >= left;
				*p++ = 0x80;
				*p++ = RTP_PT | ((last_nal && end) ? 0x80 : 0);
				*p++ = (uint8_t)(sink->rtp_seq >> 8);
				*p++ = (uint8_t)sink->rtp_seq;
				*p++ = (uint8_t)(timestamp >> 24);
				*p++ = (uint8_t)(timestamp >> 16);
				*p++ = (uint8_t)(timestamp >> 8);
				*p++ = (uint8_t)timestamp;
				*p++ = (uint8_t)(sink->rtp_ssrc >> 24);
				*p++ = (uint8_t)(sink->rtp_ssrc >> 16);
				*p++ = (uint8_t)(sink->rtp_ssrc >> 8);
				*p++ = (uint8_t)sink->rtp_ssrc;
				*p++ = fu_header | 28; /* FU-A */
				*p++ = (uint8_t)((offset == 1 ? 0x80 : 0) |
						 (end ? 0x40 : 0) | nal_type);
				memcpy(p, nal + offset, chunk);
				{
					uint32_t total = 14 + (uint32_t)chunk;
					uint8_t frame[4] = {
						'$', 0,
						(uint8_t)(total >> 8), (uint8_t)total,
					};

					if (write_all(sink->fd, frame, 4) ||
					    write_all(sink->fd, packet, total))
						return -1;
				}
				sink->rtp_seq++;
				offset += chunk;
			}
		}
	}
	return 0;
#endif
}

/* Feed one coded access unit to the RTSP sink; handles (re)connect and
 * parameter-set discovery.  Never blocks the pipeline for long: failures
 * flip the sink into retry-later state and streaming continues. */
static void rtsp_offer_buffer(struct rtsp_sink *sink, const uint8_t *buf,
			      size_t size, uint64_t pts_ms)
{
	if (!sink->have_params) {
		struct nal_view nals[32];
		unsigned int count = annexb_split(buf, size, nals, 32);
		unsigned int n;

		for (n = 0; n < count; n++) {
			if (nals[n].type == 7 && nals[n].size <= sizeof(sink->sps)) {
				memcpy(sink->sps, nals[n].data, nals[n].size);
				sink->sps_len = nals[n].size;
			} else if (nals[n].type == 8 &&
				   nals[n].size <= sizeof(sink->pps)) {
				memcpy(sink->pps, nals[n].data, nals[n].size);
				sink->pps_len = nals[n].size;
			}
		}
		if (sink->sps_len && sink->pps_len) {
			sink->have_params = 1;
			fprintf(stderr, "rtsp: learned SPS (%zu) / PPS (%zu)\n",
				sink->sps_len, sink->pps_len);
		}
	}
	if (sink->fd < 0) {
		if (!sink->have_params || now_ms() < sink->next_retry_ms)
			return;
		if (rtsp_connect(sink)) {
			sink->next_retry_ms = now_ms() + RTSP_RECONNECT_MS;
			return;
		}
	}
	if (rtsp_send_au(sink, buf, size, pts_ms)) {
		fprintf(stderr, "rtsp: send failed, will retry\n");
		rtsp_close(sink);
	}
}

static void rtsp_offer(struct rtsp_sink *sink, const uint8_t *buf, size_t size,
		       uint64_t pts_ms)
{
	/* Coda's DMA output is uncached. Copy the compressed access unit once
	 * before the byte-wise Annex-B scans and RTP packetisation. Raw video
	 * frames stay in the hardware DMA-BUF pipeline. */
	uint8_t *cached = malloc(size);

	if (!cached) {
		perror("rtsp: allocate access unit");
		rtsp_close(sink);
		return;
	}
	memcpy(cached, buf, size);
	rtsp_offer_buffer(sink, cached, size, pts_ms);
	free(cached);
}

#ifdef ENABLE_PCMA
/* The opt-in onboard card is stereo S16_LE at 48 kHz.  PCMA is fixed at
 * 8 kHz mono; deterministic six-frame averaging yields 160 samples/20 ms. */
#define AUDIO_RING_PACKETS 128U /* 2.56 s maximum at 20 ms/packet */

struct audio_packet {
	uint8_t data[AUDIO_OUTPUT_SAMPLES];
	uint64_t sequence;
};

/* The capture thread owns ALSA and the resampler.  The V4L2/main thread owns
 * RTSP, so no two threads can interleave an RTSP `$` frame write. */
struct audio_source {
	snd_pcm_t *pcm;
	pthread_t thread;
	pthread_mutex_t lock;
	int lock_ready;
	int thread_started;
	int stop;
	int failed;
	int64_t sum;
	unsigned int sum_count;
	uint8_t packet[AUDIO_OUTPUT_SAMPLES];
	unsigned int packet_length;
	struct audio_packet ring[AUDIO_RING_PACKETS];
	unsigned int ring_head;
	unsigned int ring_tail;
	unsigned int ring_count;
	unsigned int ring_highwater;
	int marker_next;
	uint32_t seen_epoch;
	uint64_t next_timestamp;
	uint64_t epoch_packet_sequence;
	uint64_t packet_sequence_next;
	uint64_t read_frames;
	uint64_t recover_count;
	uint64_t packet_count;
	uint64_t sent_count;
	uint64_t ring_drops;
	uint64_t disconnect_drops;
	uint64_t last_report_ms;
	uint64_t input_samples;
	uint64_t input_sumabs;
	int16_t input_min;
	int16_t input_max;
};

static uint8_t linear_to_alaw(int16_t sample)
{
	static const int segment_end[] = {
		0x1f, 0x3f, 0x7f, 0xff, 0x1ff, 0x3ff, 0x7ff, 0xfff,
	};
	int pcm = sample >> 3;
	int mask = pcm >= 0 ? 0xd5 : 0x55;
	int segment;

	if (pcm < 0)
		pcm = -pcm - 1;
	for (segment = 0; segment < 8; segment++)
		if (pcm <= segment_end[segment])
			break;
	if (segment >= 8)
		return (uint8_t)(0x7f ^ mask);
	return (uint8_t)(((segment << 4) |
		(segment < 2 ? ((pcm >> 1) & 0x0f) :
		 ((pcm >> segment) & 0x0f))) ^ mask);
}

static int audio_resample_frame(struct audio_source *source, int16_t left,
				int16_t right, int16_t *output)
{
	source->sum += ((int32_t)left + right) / 2;
	source->sum_count++;
	if (source->sum_count != 6U)
		return 0;
	*output = (int16_t)(source->sum / 6);
	source->sum = 0;
	source->sum_count = 0;
	return 1;
}

static int audio_should_stop(struct audio_source *source)
{
	int stop;

	pthread_mutex_lock(&source->lock);
	stop = source->stop;
	pthread_mutex_unlock(&source->lock);
	return stop;
}

static void audio_fail(struct audio_source *source)
{
	pthread_mutex_lock(&source->lock);
	source->failed = 1;
	pthread_mutex_unlock(&source->lock);
}

static void audio_enqueue(struct audio_source *source, const uint8_t *packet,
			  uint64_t sequence)
{
	pthread_mutex_lock(&source->lock);
	if (source->ring_count == AUDIO_RING_PACKETS) {
		/* Keep presentation latency bounded: discard the oldest 20 ms. */
		source->ring_tail = (source->ring_tail + 1U) % AUDIO_RING_PACKETS;
		source->ring_count--;
		source->ring_drops++;
	}
	memcpy(source->ring[source->ring_head].data, packet, AUDIO_OUTPUT_SAMPLES);
	source->ring[source->ring_head].sequence = sequence;
	source->ring_head = (source->ring_head + 1U) % AUDIO_RING_PACKETS;
	source->ring_count++;
	if (source->ring_count > source->ring_highwater)
		source->ring_highwater = source->ring_count;
	source->packet_count++;
	pthread_mutex_unlock(&source->lock);
}

static void audio_observe_block(struct audio_source *source, int16_t minimum,
				int16_t maximum, uint64_t samples, uint64_t sumabs)
{
	pthread_mutex_lock(&source->lock);
	if (minimum < source->input_min)
		source->input_min = minimum;
	if (maximum > source->input_max)
		source->input_max = maximum;
	source->input_samples += samples;
	source->input_sumabs += sumabs;
	pthread_mutex_unlock(&source->lock);
}

static void *audio_capture_thread(void *opaque)
{
	struct audio_source *source = opaque;
	int16_t input[AUDIO_INPUT_CHUNK * AUDIO_INPUT_CHANNELS];

	while (!stop_requested && !audio_should_stop(source)) {
		snd_pcm_sframes_t frames = snd_pcm_readi(source->pcm, input,
							AUDIO_INPUT_CHUNK);
		unsigned int frame;
		int16_t minimum = INT16_MAX;
		int16_t maximum = INT16_MIN;
		uint64_t sumabs = 0;

		if (frames < 0) {
			int err = snd_pcm_recover(source->pcm, (int)frames, 1);

			pthread_mutex_lock(&source->lock);
			source->recover_count++;
			pthread_mutex_unlock(&source->lock);
			if (err < 0) {
				fprintf(stderr, "audio: capture recovery failed: %s\n",
					snd_strerror(err));
				audio_fail(source);
				break;
			}
			/* readi() starts a prepared capture implicitly, as in the lab probe. */
			continue;
		}
		if (!frames)
			continue;
		for (frame = 0; frame < (unsigned int)frames; frame++) {
			int16_t left = input[frame * 2U];
			int16_t right = input[frame * 2U + 1U];
			int16_t averaged;
			int32_t left_abs = left < 0 ? -(int32_t)left : left;
			int32_t right_abs = right < 0 ? -(int32_t)right : right;

			if (left < minimum)
				minimum = left;
			if (right < minimum)
				minimum = right;
			if (left > maximum)
				maximum = left;
			if (right > maximum)
				maximum = right;
			sumabs += (uint32_t)left_abs + (uint32_t)right_abs;
			if (!audio_resample_frame(source, left, right, &averaged))
				continue;
			source->packet[source->packet_length++] = linear_to_alaw(averaged);
			if (source->packet_length == AUDIO_OUTPUT_SAMPLES) {
				audio_enqueue(source, source->packet,
					source->packet_sequence_next++);
				source->packet_length = 0;
			}
		}
		pthread_mutex_lock(&source->lock);
		source->read_frames += (uint64_t)frames;
		pthread_mutex_unlock(&source->lock);
		audio_observe_block(source, minimum, maximum,
			(uint64_t)frames * AUDIO_INPUT_CHANNELS, sumabs);
	}
	return NULL;
}

static int audio_open(struct audio_source *source, const char *device)
{
	snd_pcm_hw_params_t *params;
	unsigned int rate = AUDIO_INPUT_RATE;
	int direction = 0;
	snd_pcm_uframes_t period = AUDIO_INPUT_CHUNK;
	/* The software RAW12 conversion takes about one 9 fps video interval.
	 * Keep enough PCM behind it to drain at the next visit without an XRUN. */
	snd_pcm_uframes_t buffer = 32768U;
	int err;

	memset(source, 0, sizeof(*source));
	source->input_min = INT16_MAX;
	source->input_max = INT16_MIN;
	err = snd_pcm_open(&source->pcm, device, SND_PCM_STREAM_CAPTURE, 0);
	if (err < 0) {
		fprintf(stderr, "audio: cannot open %s: %s\n", device, snd_strerror(err));
		return -1;
	}
	snd_pcm_hw_params_alloca(&params);
	if ((err = snd_pcm_hw_params_any(source->pcm, params)) < 0 ||
	    (err = snd_pcm_hw_params_set_access(source->pcm, params,
					 SND_PCM_ACCESS_RW_INTERLEAVED)) < 0 ||
	    (err = snd_pcm_hw_params_set_format(source->pcm, params,
				  SND_PCM_FORMAT_S16_LE)) < 0 ||
	    (err = snd_pcm_hw_params_set_channels(source->pcm, params,
				    AUDIO_INPUT_CHANNELS)) < 0 ||
	    (err = snd_pcm_hw_params_set_rate_near(source->pcm, params, &rate,
					     &direction)) < 0 ||
	    (err = snd_pcm_hw_params_set_period_size_near(source->pcm, params,
					    &period, &direction)) < 0 ||
	    (err = snd_pcm_hw_params_set_buffer_size_near(source->pcm, params,
					    &buffer)) < 0 ||
	    (err = snd_pcm_hw_params(source->pcm, params)) < 0) {
		fprintf(stderr, "audio: cannot configure %s: %s\n", device, snd_strerror(err));
		snd_pcm_close(source->pcm);
		source->pcm = NULL;
		return -1;
	}
	if (rate != AUDIO_INPUT_RATE) {
		fprintf(stderr, "audio: %s negotiated %u Hz, need %u Hz\n", device,
			rate, AUDIO_INPUT_RATE);
		snd_pcm_close(source->pcm);
		source->pcm = NULL;
		return -1;
	}
	if (snd_pcm_hw_params_get_period_size(params, &period, &direction) < 0 ||
	    snd_pcm_hw_params_get_buffer_size(params, &buffer) < 0) {
		fprintf(stderr, "audio: cannot read negotiated capture geometry\n");
		snd_pcm_close(source->pcm);
		source->pcm = NULL;
		return -1;
	}
	err = snd_pcm_prepare(source->pcm);
	if (err < 0) {
		fprintf(stderr, "audio: cannot prepare %s: %s\n", device, snd_strerror(err));
		snd_pcm_close(source->pcm);
		source->pcm = NULL;
		return -1;
	}
	if (pthread_mutex_init(&source->lock, NULL)) {
		fprintf(stderr, "audio: cannot initialize capture lock\n");
		snd_pcm_close(source->pcm);
		source->pcm = NULL;
		return -1;
	}
	source->lock_ready = 1;
	if (pthread_create(&source->thread, NULL, audio_capture_thread, source)) {
		fprintf(stderr, "audio: cannot start capture thread\n");
		pthread_mutex_destroy(&source->lock);
		source->lock_ready = 0;
		snd_pcm_close(source->pcm);
		source->pcm = NULL;
		return -1;
	}
	source->thread_started = 1;
	fprintf(stderr, "audio: capture %s, %u Hz stereo S16_LE period=%lu buffer=%lu -> PCMA 8 kHz mono\n",
		device, rate, (unsigned long)period, (unsigned long)buffer);
	return 0;
}

static void audio_close(struct audio_source *source)
{
	if (source->lock_ready) {
		pthread_mutex_lock(&source->lock);
		source->stop = 1;
		pthread_mutex_unlock(&source->lock);
	}
	/* Wake a capture read promptly; the thread notices stop before enqueueing. */
	if (source->pcm)
		snd_pcm_drop(source->pcm);
	if (source->thread_started)
		pthread_join(source->thread, NULL);
	if (source->pcm)
		snd_pcm_close(source->pcm);
	source->pcm = NULL;
	if (source->lock_ready)
		pthread_mutex_destroy(&source->lock);
	source->lock_ready = 0;
}

/* Returns one when a packet was removed, zero when the ring is empty. */
static int audio_pop(struct audio_source *source, struct audio_packet *packet,
			     int *failed)
{
	int have_packet;

	pthread_mutex_lock(&source->lock);
	*failed = source->failed;
	have_packet = source->ring_count != 0;
	if (have_packet) {
		memcpy(packet->data, source->ring[source->ring_tail].data,
			AUDIO_OUTPUT_SAMPLES);
		packet->sequence = source->ring[source->ring_tail].sequence;
		source->ring_tail = (source->ring_tail + 1U) % AUDIO_RING_PACKETS;
		source->ring_count--;
	}
	pthread_mutex_unlock(&source->lock);
	return have_packet;
}

static void audio_reset_epoch(struct audio_source *source,
			      const struct rtsp_sink *sink, uint64_t packet_sequence)
{
	if (source->seen_epoch == sink->audio_epoch)
		return;
	source->marker_next = 1;
	source->seen_epoch = sink->audio_epoch;
	source->next_timestamp = sink->audio_epoch_timestamp;
	source->epoch_packet_sequence = packet_sequence;
}

static uint64_t audio_discard_disconnected(struct audio_source *source,
					   uint64_t first_packet, int *failed)
{
	uint64_t dropped;

	pthread_mutex_lock(&source->lock);
	*failed = source->failed;
	dropped = source->ring_count + first_packet;
	source->ring_tail = source->ring_head;
	source->ring_count = 0;
	source->disconnect_drops += dropped;
	pthread_mutex_unlock(&source->lock);
	return dropped;
}

static void audio_report(struct audio_source *source)
{
	uint64_t now = now_ms();
	uint64_t read_frames, recover_count, packet_count, sent_count, ring_drops;
	uint64_t disconnect_drops;
	uint64_t input_samples, input_sumabs;
	unsigned int ring_count, ring_highwater;
	int16_t input_min, input_max;

	if (now - source->last_report_ms < 5000U)
		return;
	source->last_report_ms = now;
	pthread_mutex_lock(&source->lock);
	read_frames = source->read_frames;
	recover_count = source->recover_count;
	packet_count = source->packet_count;
	sent_count = source->sent_count;
	ring_drops = source->ring_drops;
	disconnect_drops = source->disconnect_drops;
	ring_count = source->ring_count;
	ring_highwater = source->ring_highwater;
	input_samples = source->input_samples;
	input_sumabs = source->input_sumabs;
	input_min = source->input_min;
	input_max = source->input_max;
	source->input_samples = 0;
	source->input_sumabs = 0;
	source->input_min = INT16_MAX;
	source->input_max = INT16_MIN;
	pthread_mutex_unlock(&source->lock);
	fprintf(stderr,
		"audio: frames=%" PRIu64 " recover=%" PRIu64
		" packets=%" PRIu64 " sent=%" PRIu64
		" queue=%u highwater=%u overflow_drops=%" PRIu64
		" disconnect_drops=%" PRIu64
		" pcm_samples=%" PRIu64 " pcm_min=%d pcm_max=%d pcm_mean_abs=%" PRIu64 "\n",
		read_frames, recover_count, packet_count, sent_count,
		ring_count, ring_highwater, ring_drops, disconnect_drops, input_samples, input_min,
		input_max, input_samples ? input_sumabs / input_samples : 0);
}

static int audio_drain(struct audio_source *source, struct rtsp_sink *sink)
{
	unsigned int budget;

	if (sink->fd < 0) {
		int failed;
		uint64_t dropped = audio_discard_disconnected(source, 0, &failed);

		if (dropped)
			fprintf(stderr, "audio: discarded %" PRIu64 " stale packets while disconnected\n",
				dropped);
		audio_report(source);
		return failed ? -1 : 0;
	}
	for (budget = 0; budget < AUDIO_DRAIN_BUDGET; budget++) {
		struct audio_packet packet;
		int failed;
		uint64_t timestamp;

		if (!audio_pop(source, &packet, &failed)) {
			if (failed)
				return -1;
			audio_report(source);
			return 0;
		}
		audio_reset_epoch(source, sink, packet.sequence);
		timestamp = source->next_timestamp +
			(packet.sequence - source->epoch_packet_sequence) * AUDIO_OUTPUT_SAMPLES;
		if (rtsp_send_rtp(sink, &sink->audio, packet.data,
				  AUDIO_OUTPUT_SAMPLES,
				  (uint32_t)timestamp, source->marker_next)) {
			fprintf(stderr, "rtsp: audio send failed, will retry\n");
			rtsp_close(sink);
			audio_discard_disconnected(source, 1, &failed);
			return failed ? -1 : 0;
		}
		pthread_mutex_lock(&source->lock);
		source->sent_count++;
		pthread_mutex_unlock(&source->lock);
		source->marker_next = 0;
	}
	audio_report(source);
	return 0;
}

static int pcma_selftest(void)
{
	struct rtsp_sink sink;
	struct rtp_track track = { .channel = 2, .payload_type = RTP_AUDIO_PT,
		.sequence = 0x1234, .ssrc = 0x01234567 };
	struct audio_source source = { 0 };
	struct audio_source ring = { 0 };
	struct audio_packet packet;
	uint8_t rtp[12], frame[4];
	char sdp[1024];
	int16_t averaged = 0;
	unsigned int i;
	int failed;

	if (linear_to_alaw(0) != 0xd5 || linear_to_alaw(100) != 0xd3 ||
	    linear_to_alaw(-100) != 0x53 || linear_to_alaw(1000) != 0xfa ||
	    linear_to_alaw(-1000) != 0x7a || linear_to_alaw(248) != 0xda ||
	    linear_to_alaw(256) != 0xc5 || linear_to_alaw(504) != 0xca ||
	    linear_to_alaw(512) != 0xf5)
		return -1;
	for (i = 0; i < 5; i++)
		if (audio_resample_frame(&source, 300, -100, &averaged))
			return -1;
	if (!audio_resample_frame(&source, 300, -100, &averaged) || averaged != 100)
		return -1;
	rtp_make_headers(&track, 0x89abcdef, 1, rtp, frame, AUDIO_OUTPUT_SAMPLES);
	if (memcmp(rtp, (const uint8_t[]){ 0x80, 0x88, 0x12, 0x34,
			0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67 }, 12) ||
	    memcmp(frame, (const uint8_t[]){ '$', 2, 0, 172 }, 4))
		return -1;
	rtsp_init(&sink);
	/* PCMA build without --audio-pcma is intentionally video-only. */
	if (rtsp_make_sdp(&sink, "AQ==", "Ag==", sdp, sizeof(sdp)) ||
	    strstr(sdp, "m=audio") || !strstr(sdp, "a=control:trackID=0\r\n"))
		return -1;
	sink.audio_enabled = 1;
	if (rtsp_make_sdp(&sink, "AQ==", "Ag==", sdp, sizeof(sdp)) ||
	    !strstr(sdp, "m=audio 0 RTP/AVP/TCP 8\r\n") ||
	    !strstr(sdp, "a=control:trackID=1\r\n"))
		return -1;
	if (pthread_mutex_init(&ring.lock, NULL))
		return -1;
	ring.lock_ready = 1;
	for (i = 0; i <= AUDIO_RING_PACKETS; i++) {
		memset(packet.data, (int)i, sizeof(packet.data));
		audio_enqueue(&ring, packet.data, i);
	}
	if (ring.ring_count != AUDIO_RING_PACKETS || ring.ring_drops != 1 ||
	    ring.ring[ring.ring_tail].sequence != 1)
		goto fail_ring;
	for (i = 1; i <= AUDIO_DRAIN_BUDGET; i++) {
		if (!audio_pop(&ring, &packet, &failed) || failed || packet.sequence != i)
			goto fail_ring;
	}
	if (ring.ring_count != AUDIO_RING_PACKETS - AUDIO_DRAIN_BUDGET ||
	    audio_discard_disconnected(&ring, 0, &failed) !=
		AUDIO_RING_PACKETS - AUDIO_DRAIN_BUDGET || ring.disconnect_drops !=
		AUDIO_RING_PACKETS - AUDIO_DRAIN_BUDGET || failed)
		goto fail_ring;
	ring.failed = 1;
	sink.fd = -1;
	if (audio_drain(&ring, &sink) != -1)
		goto fail_ring;
	sink.audio_epoch = 7;
	sink.audio_epoch_timestamp = 1000;
	audio_reset_epoch(&ring, &sink, 11);
	if (ring.epoch_packet_sequence != 11 || ring.next_timestamp != 1000 ||
	    ring.next_timestamp + (14 - ring.epoch_packet_sequence) *
		AUDIO_OUTPUT_SAMPLES != 1480)
		goto fail_ring;
	pthread_mutex_destroy(&ring.lock);
	fprintf(stderr, "pcma selftest: ok\n");
	return 0;
fail_ring:
	pthread_mutex_destroy(&ring.lock);
	return -1;
}
#endif

/* ------------------------------------------------------------------ */
/* Live bridge                                                         */
/* ------------------------------------------------------------------ */

struct bridge_options {
	const char *capture_path;
	const char *encoder_path;
	const char *scaler_path;
	const char *output_path;
	const char *rtsp_url;
#ifdef ENABLE_DETECTION
	const char *detect_model;
	unsigned int detect_fps;
#endif
#ifdef ENABLE_PCMA
	const char *audio_pcma_device;
#endif
	unsigned int bitrate;
	unsigned int gop;
	unsigned int max_fps;
	unsigned int mid_buffers;
	unsigned int capture_buffers;
	unsigned int frame_limit;
	int half_scale;
	int use_isp;
	int mid_heap_reserved;
};

static const char *init_step;

static void die_step(void)
{
	fprintf(stderr, "live bridge at %s: %s\n", init_step ? init_step : "?",
		strerror(errno));
}

/* ------------------------------------------------------------------ */
/* Live bridge through the VPSS scaler/CSC (zero-copy)                 */
/* ------------------------------------------------------------------ */

/* capture (UYVY, pool buffers, exported) -> VPSS OUTPUT (dmabuf import)
 * -> hardware CSC/scale -> VPSS CAPTURE (shared CMA-heap dmabuf)
 * -> encoder OUTPUT (same dmabuf imported again) -> H.264.
 *
 * Without detection, the bridge only moves dmabuf fds between the three
 * queues. The VPSS CAPTURE format carries the
 * encoder's macroblock-padded geometry (e.g. 1920x1088) while the
 * CAPTURE-side crop selection marks the visible image (1920x1080), so
 * the scaler DMA lands exactly in the surface layout Coda980 expects.
 */

enum mid_state { MID_FREE, MID_AT_VPSS, MID_AT_ENCODER };

static int live_bridge_vpss(const struct bridge_options *opts)
{
	int capture_fd = -1, encoder_fd = -1, scaler_fd = -1, heap_fd = -1;
	int output_fd = -1;
	struct mapped_queue capture_queue = { 0 }, mid = { 0 }, encoder_cap = { 0 };
	int *cap_fds = NULL;
	uint8_t *mid_state = NULL;
	struct v4l2_pix_format capture_fmt, scaler_in_fmt, scaler_out_fmt;
	struct v4l2_pix_format encoder_out_fmt, encoder_cap_fmt;
	unsigned int i, free_mid = 0, held_capture = UINT32_MAX;
	unsigned int visible_width, visible_height, coded_height;
	uint64_t frames = 0, encoded_frames = 0, encoded_bytes = 0;
	uint64_t start_ms = 0, last_stats_ms = 0, last_stats_frames = 0;
	uint64_t skipped_frames = 0, last_stats_skipped = 0, next_frame_ns = 0;
	uint64_t frame_interval_ns = opts->max_fps ?
		1000000000ULL / opts->max_fps : 0;
	int capture_on = 0, encoder_out_on = 0, encoder_cap_on = 0;
	int scaler_out_on = 0, scaler_cap_on = 0, ret = -1;
	struct rtsp_sink rtsp;
#ifdef ENABLE_DETECTION
	struct sg2002_detection *detection = NULL;
#endif
#ifdef ENABLE_PCMA
	struct audio_source audio = { 0 };
#endif

#ifdef ENABLE_PCMA
	rtsp_init(&rtsp);
	rtsp.audio_enabled = opts->audio_pcma_device != NULL;
#else
	memset(&rtsp, 0, sizeof(rtsp));
	rtsp.fd = -1;
#endif
	if (opts->rtsp_url && rtsp_parse_url(&rtsp, opts->rtsp_url)) {
		fprintf(stderr, "bad rtsp url: %s\n", opts->rtsp_url);
		return -1;
	}
#ifndef ENABLE_PCMA
	rtsp.rtp_ssrc = 0x53324732; /* "S2G2" */
#endif

	capture_fd = open(opts->capture_path, O_RDWR | O_NONBLOCK | O_CLOEXEC);
	if (capture_fd < 0) {
		die_errno(opts->capture_path);
		goto out;
	}
	encoder_fd = open(opts->encoder_path, O_RDWR | O_NONBLOCK | O_CLOEXEC);
	if (encoder_fd < 0) {
		die_errno(opts->encoder_path);
		goto out;
	}
	scaler_fd = open(opts->scaler_path, O_RDWR | O_NONBLOCK | O_CLOEXEC);
	if (scaler_fd < 0) {
		die_errno(opts->scaler_path);
		goto out;
	}
	if (opts->output_path) {
		if (!strcmp(opts->output_path, "-"))
			output_fd = STDOUT_FILENO;
		else
			output_fd = open(opts->output_path,
					 O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
					 0644);
		if (output_fd < 0) {
			die_errno(opts->output_path);
			goto out;
		}
	}

	init_step = "capture G_FMT";
	if (get_format(capture_fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, &capture_fmt))
		goto out_errno;
	if (opts->use_isp) {
		init_step = "capture ISP NV21 S_FMT";
		if (set_encoder_format(capture_fd, V4L2_BUF_TYPE_VIDEO_CAPTURE,
				       V4L2_PIX_FMT_NV21, capture_fmt.width,
				       capture_fmt.height, &capture_fmt))
			goto out_errno;
		if (capture_fmt.pixelformat != V4L2_PIX_FMT_NV21) {
			fprintf(stderr, "capture driver did not accept hardware ISP NV21\n");
			goto out;
		}
	}
	if ((capture_fmt.pixelformat != V4L2_PIX_FMT_UYVY &&
	     capture_fmt.pixelformat != V4L2_PIX_FMT_NV21 &&
	     capture_fmt.pixelformat != V4L2_PIX_FMT_NV12) ||
	    capture_fmt.width < 4 || capture_fmt.height < 2 ||
	    capture_fmt.bytesperline < capture_fmt.width *
		(capture_fmt.pixelformat == V4L2_PIX_FMT_UYVY ? 2U : 1U)) {
		fprintf(stderr, "capture must provide UYVY/NV12/NV21 with a valid stride\n");
		goto out;
	}
	{
		unsigned int scale = opts->half_scale ? 2U : opts->use_isp ? 4U : 1U;

		if (capture_fmt.width % (scale * 2) || capture_fmt.height % (scale * 2)) {
			fprintf(stderr, "capture geometry cannot produce aligned %ux YUV420\n", scale);
			goto out;
		}
		visible_width = capture_fmt.width / scale;
		visible_height = capture_fmt.height / scale;
	}
	coded_height = (visible_height + 15U) & ~15U;

	/* Encoder first: its padded OUTPUT geometry dictates the VPSS
	 * CAPTURE surface layout. */
	init_step = "encoder OUTPUT S_FMT";
	if (set_video_format(encoder_fd, V4L2_BUF_TYPE_VIDEO_OUTPUT,
			       V4L2_PIX_FMT_NV12, visible_width,
			       coded_height, &capture_fmt, &encoder_out_fmt))
		goto out_errno;
	init_step = "encoder OUTPUT crop";
	if (set_output_crop(encoder_fd, visible_width, visible_height))
		goto out_errno;
	init_step = "encoder OUTPUT G_FMT";
	if (get_format(encoder_fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, &encoder_out_fmt))
		goto out_errno;
	init_step = "encoder CAPTURE S_FMT";
	if (set_video_format(encoder_fd, V4L2_BUF_TYPE_VIDEO_CAPTURE,
			     V4L2_PIX_FMT_H264, visible_width,
			     visible_height, &capture_fmt, &encoder_cap_fmt))
		goto out_errno;
	if (encoder_cap_fmt.pixelformat != V4L2_PIX_FMT_H264)
		goto out;
#ifdef ENABLE_DETECTION
	if (opts->detect_model) {
		detection = sg2002_detection_open(opts->detect_model, &encoder_out_fmt,
			visible_width, visible_height, opts->detect_fps);
		if (!detection)
			goto out;
	}
#endif
	if (set_encoder_controls(encoder_fd, opts->bitrate, opts->gop))
		fprintf(stderr, "warning: encoder controls rejected, running firmware defaults\n");
	fprintf(stderr, "init: encoder formats ok\n");

	/* VPSS: OUTPUT = the capture frame, CAPTURE = the encoder surface. */
	init_step = "scaler OUTPUT S_FMT";
	if (set_video_format(scaler_fd, V4L2_BUF_TYPE_VIDEO_OUTPUT,
			       capture_fmt.pixelformat, capture_fmt.width,
			       capture_fmt.height, &capture_fmt, &scaler_in_fmt))
		goto out_errno;
	if (scaler_in_fmt.bytesperline != capture_fmt.bytesperline) {
		fprintf(stderr, "capture stride %u unsupported by scaler (wants %u)\n",
			capture_fmt.bytesperline, scaler_in_fmt.bytesperline);
		goto out;
	}
	init_step = "scaler CAPTURE S_FMT";
	if (set_video_format(scaler_fd, V4L2_BUF_TYPE_VIDEO_CAPTURE,
			       V4L2_PIX_FMT_NV12, encoder_out_fmt.width,
			       encoder_out_fmt.height, &capture_fmt, &scaler_out_fmt))
		goto out_errno;
	if (scaler_out_fmt.bytesperline != encoder_out_fmt.bytesperline ||
	    scaler_out_fmt.sizeimage > encoder_out_fmt.sizeimage) {
		fprintf(stderr, "scaler/encoder surface mismatch (%u@%u vs %u@%u)\n",
			scaler_out_fmt.bytesperline, scaler_out_fmt.sizeimage,
			encoder_out_fmt.bytesperline, encoder_out_fmt.sizeimage);
		goto out;
	}
	init_step = "scaler CAPTURE crop";
	{
		struct v4l2_selection selection = {
			.type = V4L2_BUF_TYPE_VIDEO_CAPTURE,
			.target = V4L2_SEL_TGT_CROP,
			.r = {
				.width = visible_width,
				.height = visible_height,
			},
		};

		if (xioctl(scaler_fd, VIDIOC_S_SELECTION, &selection))
			goto out_errno;
	}

	/* Middle buffers: heap-allocated, imported by both the scaler
	 * CAPTURE queue and the encoder OUTPUT queue. */
	init_step = opts->mid_heap_reserved ? "open " DMA_HEAP_RESERVED :
		"open " DMA_HEAP_CMA;
	heap_fd = open(opts->mid_heap_reserved ? DMA_HEAP_RESERVED : DMA_HEAP_CMA,
		       O_RDONLY | O_CLOEXEC);
	if (heap_fd < 0 && !opts->mid_heap_reserved) {
		init_step = "open " DMA_HEAP_RESERVED;
		heap_fd = open(DMA_HEAP_RESERVED, O_RDONLY | O_CLOEXEC);
	}
	if (heap_fd < 0)
		goto out_errno;
	init_step = "middle buffer allocation";
	{
		struct v4l2_requestbuffers request = {
			.count = opts->mid_buffers,
			.type = V4L2_BUF_TYPE_VIDEO_CAPTURE,
			.memory = V4L2_MEMORY_DMABUF,
		};

		if (xioctl(scaler_fd, VIDIOC_REQBUFS, &request) || !request.count)
			goto out_errno;
		mid.count = request.count;
		request.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
		if (xioctl(encoder_fd, VIDIOC_REQBUFS, &request) ||
		    request.count < mid.count)
			goto out_errno;
		mid.bufs = calloc(mid.count, sizeof(*mid.bufs));
		if (!mid.bufs)
			goto out_errno;
		for (i = 0; i < mid.count; i++) {
			struct dma_heap_allocation_data alloc = {
				.len = encoder_out_fmt.sizeimage,
				.fd_flags = O_CLOEXEC | O_RDWR,
			};

			if (xioctl(heap_fd, DMA_HEAP_IOCTL_ALLOC, &alloc))
				goto out_errno;
			mid.bufs[i].dmabuf_fd = (int)alloc.fd;
			mid.bufs[i].length = encoder_out_fmt.sizeimage;
			mid.bufs[i].addr = mmap(NULL, encoder_out_fmt.sizeimage,
						PROT_READ | PROT_WRITE, MAP_SHARED,
						(int)alloc.fd, 0);
			if (mid.bufs[i].addr == MAP_FAILED) {
				mid.bufs[i].addr = NULL;
				goto out_errno;
			}
		}
	}
	mid_state = calloc(mid.count, sizeof(*mid_state));
	if (!mid_state)
		goto out_errno;
	fprintf(stderr, "init: scaler formats + %u middle buffers ok\n", mid.count);

	/* Encoder CAPTURE queue + priming frame (first claim on the media
	 * pool, and a valid reference picture for the first live frame). */
	init_step = "encoder CAPTURE buffers";
	if (map_queue(encoder_fd, V4L2_BUF_TYPE_VIDEO_CAPTURE,
		      ENCODER_CAP_BUFFERS, &encoder_cap))
		goto out_errno;
	for (i = 0; i < encoder_cap.count; i++)
		if (queue_buffer(encoder_fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, i, 0))
			goto out_errno;
	init_step = "encoder priming";
	{
		size_t luma_size = (size_t)encoder_out_fmt.bytesperline *
			encoder_out_fmt.height;
		size_t frame_size = luma_size * 3 / 2;
		struct dma_buf_sync sync = {
			.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
		};

		if (frame_size > UINT32_MAX || frame_size > mid.bufs[0].length)
			goto out;
		memset(mid.bufs[0].addr, 16, luma_size);
		memset((uint8_t *)mid.bufs[0].addr + luma_size, 128,
		       frame_size - luma_size);
		if (xioctl(mid.bufs[0].dmabuf_fd, DMA_BUF_IOCTL_SYNC, &sync))
			goto out_errno;
		if (queue_dmabuf(encoder_fd, V4L2_BUF_TYPE_VIDEO_OUTPUT,
				 0, mid.bufs[0].dmabuf_fd, (unsigned int)frame_size))
			goto out_errno;
		mid_state[0] = MID_AT_ENCODER;
	}
	free_mid = mid.count - 1;
	fprintf(stderr, "init: encoder primed\n");

	init_step = "encoder STREAMON";
	if (stream(encoder_fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, 1))
		goto out_errno;
	encoder_cap_on = 1;
	if (stream(encoder_fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, 1))
		goto out_errno;
	encoder_out_on = 1;

	/* Capture buffers: driver-owned (media pool), exported for the
	 * scaler OUTPUT queue. */
	init_step = "capture buffers";
	if (map_queue(capture_fd, V4L2_BUF_TYPE_VIDEO_CAPTURE,
		      opts->capture_buffers, &capture_queue))
		goto out_errno;
	cap_fds = calloc(capture_queue.count, sizeof(*cap_fds));
	if (!cap_fds)
		goto out_errno;
	for (i = 0; i < capture_queue.count; i++) {
		struct v4l2_exportbuffer export = {
			.type = V4L2_BUF_TYPE_VIDEO_CAPTURE,
			.index = i,
			.flags = O_CLOEXEC | O_RDWR,
		};

		init_step = "capture EXPBUF (scaler must not be pool-bound)";
		if (xioctl(capture_fd, VIDIOC_EXPBUF, &export))
			goto out_errno;
		cap_fds[i] = export.fd;
	}

	for (i = 0; i < capture_queue.count; i++)
		if (queue_buffer(capture_fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, i, 0))
			goto out_errno;
	/* Capture first: while the CSI driver streams, the VIP fabric
	 * clocks are on and VPSS register access is safe (the 6-clock DT
	 * leaves the fabric clocks to the capture driver; with them the
	 * order is merely hygienic). */
	init_step = "capture STREAMON";
	if (stream(capture_fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, 1))
		goto out_errno;
	capture_on = 1;
	fprintf(stderr, "init: capture streaming\n");
#ifdef ENABLE_PCMA
	if (opts->audio_pcma_device && audio_open(&audio, opts->audio_pcma_device))
		goto out;
#endif

	/* Scaler OUTPUT imports the capture buffers 1:1 by index. */
	init_step = "scaler OUTPUT REQBUFS";
	{
		struct v4l2_requestbuffers request = {
			.count = capture_queue.count,
			.type = V4L2_BUF_TYPE_VIDEO_OUTPUT,
			.memory = V4L2_MEMORY_DMABUF,
		};

		if (xioctl(scaler_fd, VIDIOC_REQBUFS, &request) ||
		    request.count < capture_queue.count) {
			fprintf(stderr, "scaler OUTPUT queue too shallow (%u < %u)\n",
				request.count, capture_queue.count);
			goto out;
		}
	}
	if (stream(scaler_fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, 1))
		goto out_errno;
	scaler_out_on = 1;
	if (stream(scaler_fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, 1))
		goto out_errno;
	scaler_cap_on = 1;

	fprintf(stderr, "bridge %s (%ux%u) -> %s (%s %ux%u crop %ux%u) -> %s %s io=vpss-dmabuf bitrate=%u gop=%u\n",
		opts->capture_path, capture_fmt.width, capture_fmt.height,
		opts->scaler_path,
		"NV12",
		scaler_out_fmt.width, scaler_out_fmt.height,
		visible_width, visible_height,
		opts->encoder_path, encoder_cap_fmt.pixelformat == V4L2_PIX_FMT_H264 ? "h264" : "?",
		opts->bitrate, opts->gop);
	start_ms = now_ms();
	last_stats_ms = start_ms;

	while (!stop_requested) {
		struct v4l2_buffer buffer;
		int progress = 0;

#ifdef ENABLE_PCMA
		if (audio.pcm && audio_drain(&audio, &rtsp))
			goto out;
#endif
		/* Drain encoded CAPTURE buffers and forward to the sinks. */
		for (;;) {
			uint64_t pts_ms;

			if (dequeue_buffer(encoder_fd, V4L2_BUF_TYPE_VIDEO_CAPTURE,
					   &buffer)) {
				if (errno == EAGAIN)
					break;
				goto out_errno;
			}
			if (buffer.index >= encoder_cap.count ||
			    buffer.bytesused > encoder_cap.bufs[buffer.index].length ||
			    (buffer.flags & V4L2_BUF_FLAG_ERROR) || !buffer.bytesused) {
				fprintf(stderr, "encoder returned an invalid capture buffer\n");
				goto out;
			}
			pts_ms = (uint64_t)buffer.timestamp.tv_sec * 1000ULL +
				(uint64_t)buffer.timestamp.tv_usec / 1000;
			if (!pts_ms)
				pts_ms = now_ms();
			if (output_fd >= 0 && buffer.bytesused &&
			    write_all(output_fd, encoder_cap.bufs[buffer.index].addr,
				      buffer.bytesused))
				goto out_errno;
			if (opts->rtsp_url && buffer.bytesused)
				rtsp_offer(&rtsp, encoder_cap.bufs[buffer.index].addr,
					   buffer.bytesused, pts_ms);
			encoded_frames++;
			encoded_bytes += buffer.bytesused;
			if (live_frame_limit_reached(opts->frame_limit, encoded_frames)) {
				stop_requested = 1;
				break;
			}
			if (queue_buffer(encoder_fd, V4L2_BUF_TYPE_VIDEO_CAPTURE,
					 buffer.index, 0))
				goto out_errno;
			progress = 1;
		}
		if (stop_requested)
			break;
		/* Encoder OUTPUT done -> middle buffer back to free. */
		for (;;) {
			if (dequeue_buffer_mem(encoder_fd, V4L2_BUF_TYPE_VIDEO_OUTPUT,
					       V4L2_MEMORY_DMABUF, &buffer)) {
				if (errno == EAGAIN)
					break;
				goto out_errno;
			}
			if (buffer.index >= mid.count || mid_state[buffer.index] != MID_AT_ENCODER) {
				fprintf(stderr, "encoder returned an unexpected output buffer\n");
				goto out;
			}
			mid_state[buffer.index] = MID_FREE;
			free_mid++;
			progress = 1;
		}
		/* Scaler CAPTURE done -> filled middle buffer to the encoder. */
		for (;;) {
			if (dequeue_buffer_mem(scaler_fd, V4L2_BUF_TYPE_VIDEO_CAPTURE,
					       V4L2_MEMORY_DMABUF, &buffer)) {
				if (errno == EAGAIN)
					break;
				goto out_errno;
			}
			if (buffer.index >= mid.count || mid_state[buffer.index] != MID_AT_VPSS) {
				fprintf(stderr, "scaler returned an unexpected capture buffer\n");
				goto out;
			}
#ifdef ENABLE_DETECTION
			if (detection && sg2002_detection_frame(detection,
				mid.bufs[buffer.index].dmabuf_fd, mid.bufs[buffer.index].addr,
				mid.bufs[buffer.index].length)) {
				fprintf(stderr, "detection: frame processing failed\n");
				goto out;
			}
#endif
			if (queue_dmabuf(encoder_fd, V4L2_BUF_TYPE_VIDEO_OUTPUT,
					 buffer.index, mid.bufs[buffer.index].dmabuf_fd,
					 encoder_out_fmt.sizeimage))
				goto out_errno;
			mid_state[buffer.index] = MID_AT_ENCODER;
			progress = 1;
		}
		/* Scaler OUTPUT done -> capture buffer back to the CSI queue. */
		for (;;) {
			if (dequeue_buffer_mem(scaler_fd, V4L2_BUF_TYPE_VIDEO_OUTPUT,
					       V4L2_MEMORY_DMABUF, &buffer)) {
				if (errno == EAGAIN)
					break;
				goto out_errno;
			}
			if (buffer.index >= capture_queue.count) {
				fprintf(stderr, "scaler returned an invalid output buffer\n");
				goto out;
			}
			if (queue_buffer(capture_fd, V4L2_BUF_TYPE_VIDEO_CAPTURE,
					 buffer.index, 0))
				goto out_errno;
			progress = 1;
		}
		if (held_capture == UINT32_MAX) {
			if (!dequeue_buffer(capture_fd, V4L2_BUF_TYPE_VIDEO_CAPTURE,
					    &buffer))
				held_capture = buffer.index;
			else if (errno != EAGAIN)
				goto out_errno;
		}
		if (held_capture != UINT32_MAX && free_mid) {
			unsigned int mid_index;

			/* Return excess frames before VPSS or Coda sees them. Do not
			 * sleep while holding one of the shallow capture buffers. */
			if (frame_interval_ns &&
			    !frame_due(now_ns(), frame_interval_ns, &next_frame_ns)) {
				if (queue_buffer(capture_fd, V4L2_BUF_TYPE_VIDEO_CAPTURE,
						 held_capture, 0))
					goto out_errno;
				held_capture = UINT32_MAX;
				skipped_frames++;
				progress = 1;
				continue;
			}

			for (mid_index = 0; mid_index < mid.count; mid_index++)
				if (mid_state[mid_index] == MID_FREE)
					break;
			if (mid_index == mid.count) {
				fprintf(stderr, "no usable free middle buffer\n");
				goto out;
			}
			if (queue_dmabuf(scaler_fd, V4L2_BUF_TYPE_VIDEO_OUTPUT,
					 held_capture, cap_fds[held_capture],
					 capture_fmt.sizeimage))
				goto out_errno;
			if (queue_dmabuf(scaler_fd, V4L2_BUF_TYPE_VIDEO_CAPTURE,
					 mid_index, mid.bufs[mid_index].dmabuf_fd, 0))
				goto out_errno;
			mid_state[mid_index] = MID_AT_VPSS;
			free_mid--;
			held_capture = UINT32_MAX;
			frames++;
			progress = 1;
		}
		{
			uint64_t now = now_ms();

			if (now - last_stats_ms >= 5000) {
				uint64_t delta = now - last_stats_ms;
				uint64_t df = encoded_frames - last_stats_frames;

				fprintf(stderr, "stats: %.1f fps encoded (%" PRIu64
					" total, %.1f kB/s, %" PRIu64 " max-fps skips)\n",
					delta ? (double)df * 1000.0 / (double)delta : 0,
					encoded_frames,
					delta ? (double)encoded_bytes / 1024.0 *
					1000.0 / (double)(now - start_ms) : 0,
					skipped_frames - last_stats_skipped);
				last_stats_ms = now;
				last_stats_frames = encoded_frames;
				last_stats_skipped = skipped_frames;
			}
		}
		if (!progress) {
			int scaler_pending = 0;
			for (i = 0; i < mid.count; i++)
				scaler_pending |= mid_state[i] == MID_AT_VPSS;
			/* An empty mem2mem queue reports POLLERR immediately. Only
			 * wait on VPSS while it owns a buffer, and on capture while
			 * we can dequeue its next frame. */
			struct pollfd fds[3] = {
				{ .fd = held_capture == UINT32_MAX ? capture_fd : -1,
				  .events = POLLIN },
				{ .fd = scaler_pending ? scaler_fd : -1,
				  .events = POLLIN | POLLOUT },
				{ .fd = encoder_fd, .events = POLLIN | POLLOUT },
			};
			if (poll(fds, 3,
#ifdef ENABLE_PCMA
				 audio.pcm ? 20 : 1000
#else
				 1000
#endif
				 ) < 0 && errno != EINTR)
				goto out_errno;
		}
	}
	fprintf(stderr, "stopped after %" PRIu64 " scaled frames, %" PRIu64
		" encoded frames, %" PRIu64 " encoded bytes\n",
		frames, encoded_frames, encoded_bytes);
	init_step = "bounded capture completion";
	ret = report_live_frames(opts->frame_limit, encoded_frames);
out_errno:
	if (ret)
		die_step();
out:
#ifdef ENABLE_DETECTION
	sg2002_detection_close(detection);
#endif
	if (scaler_out_on)
		stream(scaler_fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, 0);
	if (scaler_cap_on)
		stream(scaler_fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, 0);
	if (capture_on)
		stream(capture_fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, 0);
	if (encoder_out_on)
		stream(encoder_fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, 0);
	if (encoder_cap_on)
		stream(encoder_fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, 0);
	unmap_queue(&encoder_cap);
	unmap_queue(&mid);
	unmap_queue(&capture_queue);
	if (cap_fds) {
		for (i = 0; i < capture_queue.count; i++)
			if (cap_fds[i] > 0)
				close(cap_fds[i]);
		free(cap_fds);
	}
	free(mid_state);
#ifdef ENABLE_PCMA
	audio_close(&audio);
#endif
	rtsp_close(&rtsp);
	if (heap_fd >= 0)
		close(heap_fd);
	if (scaler_fd >= 0)
		close(scaler_fd);
	if (encoder_fd >= 0)
		close(encoder_fd);
	if (capture_fd >= 0)
		close(capture_fd);
	if (output_fd >= 0 && output_fd != STDOUT_FILENO)
		close(output_fd);
	return ret;
}

static void usage(const char *program)
{
	fprintf(stderr,
		"usage: %s [capture-node] [encoder-node] [options]\n"
		"default nodes use stable /dev/v4l/by-path platform links\n"
		"\n"
		"options:\n"
		"  --output PATH|-      write the Annex-B stream (repeatable with --rtsp)\n"
		"  --rtsp URL           publish via RTSP (rtsp://host[:8554]/hdmi)\n"
		"  --size full|half     HDMI: full resolution or 2x downscale (default full)\n"
		"  --scaler-node PATH   VPSS mem2mem node (default " DEFAULT_SCALER ")\n"
		"  --isp               select hardware Bayer->NV21 capture and VPSS->NV12;\n"
		"                       quarter size (640x360 on GC4653), or --size half\n"
		"  --frames N          stop after N encoded live frames, excluding the one\n"
		"                       priming picture retained in the stream (default unlimited)\n"
		"  --mid-buffers N      shared scaler/encoder buffers (default 4)\n"
		"  --heap auto|reserved middle-buffer heap (default auto: CMA,\n"
		"                       then the reserved media pool)\n"
		"  --capture-buffers N  CSI queue depth (default 2 for the camera's\n"
		"                       shared capture/Coda media-pool budget)\n"
		"  --bitrate N          encoder bitrate bit/s (default 4000000)\n"
		"  --gop N              encoder GOP size (default 30)\n"
		"  --max-fps N          cap scaling and encode rate; requeue\n"
		"                       excess capture frames (default unlimited)\n",
		program);
#ifdef ENABLE_DETECTION
	fputs("  --detect-model PATH YOLOv5n model: sample NV12 frames, overlay boxes/labels\n"
	      "  --detect-fps N      maximum inference rate, 1..10 (default 2); video\n"
	      "                       continues independently; stale boxes expire\n", stderr);
#endif
#ifdef ENABLE_PCMA
	fputs("  --audio-pcma DEVICE  opt-in ALSA capture: 48 kHz stereo S16_LE to\n"
	      "                       PCMA/8 kHz mono RTP (requires --rtsp)\n"
	      "  --selftest-pcma      exercise SDP, RTP headers, A-law, and resampling\n",
	      stderr);
#endif
}

int main(int argc, char **argv)
{
	struct bridge_options opts = {
		.capture_path = DEFAULT_CAPTURE,
		.encoder_path = DEFAULT_ENCODER,
		.scaler_path = DEFAULT_SCALER,
		.output_path = NULL,
		.rtsp_url = NULL,
#ifdef ENABLE_DETECTION
		.detect_fps = 2,
#endif
#ifdef ENABLE_PCMA
		.audio_pcma_device = NULL,
#endif
		.bitrate = 4000000,
		.gop = 30,
		.max_fps = 0,
		.mid_buffers = SCALER_MID_BUFFERS,
		.capture_buffers = CAPTURE_BUFFERS,
		.half_scale = 0,
	};
	struct sigaction action = { .sa_handler = on_signal };
	int i;
	int positional = 0;

#ifdef ENABLE_PCMA
	if (argc == 2 && !strcmp(argv[1], "--selftest-pcma"))
		return pcma_selftest() ? EXIT_FAILURE : EXIT_SUCCESS;
#endif
	for (i = 1; i < argc; i++) {
		const char *arg = argv[i];

		if (!strcmp(arg, "--output") && i + 1 < argc)
			opts.output_path = argv[++i];
		else if (!strcmp(arg, "--rtsp") && i + 1 < argc)
			opts.rtsp_url = argv[++i];
#ifdef ENABLE_DETECTION
		else if (!strcmp(arg, "--detect-model") && i + 1 < argc)
			opts.detect_model = argv[++i];
		else if (!strcmp(arg, "--detect-fps") && i + 1 < argc) {
			if (parse_u32(argv[++i], &opts.detect_fps) ||
			    !opts.detect_fps || opts.detect_fps > 10)
				goto bad_usage;
		}
#endif
#ifdef ENABLE_PCMA
		else if (!strcmp(arg, "--audio-pcma") && i + 1 < argc)
			opts.audio_pcma_device = argv[++i];
#endif
		else if (!strcmp(arg, "--size") && i + 1 < argc) {
			if (strcmp(argv[++i], "half") == 0)
				opts.half_scale = 1;
			else if (strcmp(argv[i], "full"))
				goto bad_usage;
		} else if (!strcmp(arg, "--isp")) {
			opts.use_isp = 1;
		} else if (!strcmp(arg, "--frames") && i + 1 < argc) {
			if (parse_u32(argv[++i], &opts.frame_limit) || !opts.frame_limit)
				goto bad_usage;
		} else if (!strcmp(arg, "--scaler-node") && i + 1 < argc) {
			opts.scaler_path = argv[++i];
		} else if (!strcmp(arg, "--mid-buffers") && i + 1 < argc) {
			if (parse_u32(argv[++i], &opts.mid_buffers) ||
			    opts.mid_buffers < 2 || opts.mid_buffers > 16)
				goto bad_usage;
		} else if (!strcmp(arg, "--heap") && i + 1 < argc) {
			if (!strcmp(argv[++i], "reserved"))
				opts.mid_heap_reserved = 1;
			else if (strcmp(argv[i], "auto"))
				goto bad_usage;
		} else if (!strcmp(arg, "--capture-buffers") && i + 1 < argc) {
			if (parse_u32(argv[++i], &opts.capture_buffers) ||
			    opts.capture_buffers < 2 || opts.capture_buffers > 16)
				goto bad_usage;
		} else if (!strcmp(arg, "--bitrate") && i + 1 < argc) {
			if (parse_u32(argv[++i], &opts.bitrate))
				goto bad_usage;
		} else if (!strcmp(arg, "--gop") && i + 1 < argc) {
			if (parse_u32(argv[++i], &opts.gop))
				goto bad_usage;
		} else if (!strcmp(arg, "--max-fps") && i + 1 < argc) {
			if (parse_u32(argv[++i], &opts.max_fps) ||
			    opts.max_fps == 0 || opts.max_fps > 120)
				goto bad_usage;
		} else if (arg[0] != '-' && positional == 0) {
			opts.capture_path = arg;
			positional++;
		} else if (arg[0] != '-' && positional == 1) {
			opts.encoder_path = arg;
			positional++;
		} else {
			goto bad_usage;
		}
	}
	if (!opts.output_path && !opts.rtsp_url) {
		fprintf(stderr, "nothing to do: pass --output and/or --rtsp\n");
		goto bad_usage;
	}
#ifdef ENABLE_PCMA
	if (opts.audio_pcma_device && !opts.rtsp_url) {
		fprintf(stderr, "--audio-pcma requires --rtsp\n");
		goto bad_usage;
	}
#endif
	if (sigemptyset(&action.sa_mask) || sigaction(SIGINT, &action, NULL) ||
	    sigaction(SIGTERM, &action, NULL))
		return EXIT_FAILURE;
	return live_bridge_vpss(&opts) ? EXIT_FAILURE : EXIT_SUCCESS;

bad_usage:
	usage(argv[0]);
	return EXIT_FAILURE;
}
