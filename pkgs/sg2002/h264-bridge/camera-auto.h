/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef SG2002_CAMERA_AUTO_H
#define SG2002_CAMERA_AUTO_H

#include <stddef.h>
#include <linux/videodev2.h>

struct camera_auto;
struct camera_auto *camera_auto_open(const char *sensor, int capture,
	const struct v4l2_pix_format *format, unsigned int width,
	unsigned int height, unsigned int mains);
int camera_auto_frame(struct camera_auto *camera, int dmabuf,
	const void *pixels, size_t length);
void camera_auto_close(struct camera_auto *camera);
#endif
