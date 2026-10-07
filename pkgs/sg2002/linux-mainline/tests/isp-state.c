/* SPDX-License-Identifier: GPL-2.0-only */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <math.h>
#define __iomem
#define BIT(n) (1U << (n))
#define GENMASK(h, l) ((~0U << (l)) & (~0U >> (31 - (h))))
#define ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))
#define FIELD_PREP(m, v) (((v) << __builtin_ctz(m)) & (m))
#define lower_32_bits(x) ((uint32_t)(x))
#define upper_32_bits(x) ((uint32_t)((x) >> 32))
typedef uint32_t u32;
typedef uint16_t u16;
typedef uint64_t dma_addr_t;
static u32 regs[0x80000 / 4], lut[256], n;
static u32 readl(void *p) { return *(u32 *)p; }
static void writel(u32 value, void *p)
{
	if (p == (void *)((char *)regs + 0x5220c)) {
		assert(n < 256 && (value & BIT(31)));
		lut[n++] = value & 4095;
		lut[n++] = (value >> 16) & 4095;
	}
	*(u32 *)p = value;
}

#include "sg2002-isp.h"

int main(void)
{
	sg2002_isp_configure(regs, 2560, 1440, 2560, 0, 0x81000000);
	assert(n == 256 && lut[0] == 0 && regs[0x52210 / 4] == 4096);
	for (unsigned int i = 0; i < 256; i++) {
		double x = i / 256.0;
		double y = x <= .0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - .055;

		assert(fabs(lut[i] - y * 4096) <= .51);
		if (i) assert(lut[i] >= lut[i - 1]);
	}
	assert(regs[0x52204 / 4] == 0 && (regs[0x52200 / 4] & 3) == 3);
	sg2002_isp_set_wb(regs, 2048, 3072);
	assert(regs[0x40010 / 4] == (2048 | (1024 << 16)));
	assert(regs[0x40014 / 4] == (3072 | (1024 << 16)));
	assert(regs[0x40034 / 4] == 2048 && regs[0x40038 / 4] == 4096);
	assert(regs[0x4003c / 4] == 1365);
	sg2002_isp_black_level(regs);
	assert(regs[0x1980c / 4] == (256 | (256 << 16)));
	assert(regs[0x19808 / 4] & 1);
	assert(regs[0x19814 / 4] == (1092 | (1092 << 16)));
	puts("ISP LUT/black-level/WB register sequence OK");
}
