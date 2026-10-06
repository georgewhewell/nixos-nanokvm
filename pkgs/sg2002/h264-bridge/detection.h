/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef SG2002_DETECTION_H
#define SG2002_DETECTION_H

#include <linux/videodev2.h>
#include <stddef.h>

struct sg2002_detection;

struct sg2002_detection *sg2002_detection_open(const char *model,
	const struct v4l2_pix_format *format, unsigned int width,
	unsigned int height, unsigned int fps);
/* Called while the bridge owns the completed VPSS buffer, before Coda QBUF.
 * Copies a sample if the worker is idle, then paints fresh results in place.
 * DMA-BUF CPU synchronization is performed here; no DMA buffer escapes. */
int sg2002_detection_frame(struct sg2002_detection *d, int dmabuf,
	void *pixels, size_t length);
void sg2002_detection_close(struct sg2002_detection *d);

#endif
