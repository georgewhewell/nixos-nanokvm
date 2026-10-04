/* SPDX-License-Identifier: GPL-2.0-only */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static unsigned char src[16384], dst[16384], expected[16384];
static int fds[2];
static void fail(const char *what)
{
    fprintf(stderr, "FAIL: %s (errno=%d)\n", what, errno);
    exit(1);
}

static void transfer(const void *a, void *b, size_t n)
{
    if (write(fds[1], a, n) != (ssize_t)n)
        fail("write");
    if (read(fds[0], b, n) != (ssize_t)n)
        fail("read");
}

static void drain(void)
{
    while (read(fds[0], dst, sizeof(dst)) > 0) {
    }
    if (errno != EAGAIN)
        fail("drain");
}

static void faults(void)
{
    long page = sysconf(_SC_PAGESIZE);
    if (page != 4096) {
        fprintf(stderr, "requires 4 KiB pages\n");
        exit(1);
    }
    unsigned char *map =
        mmap(NULL, page * 2, PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
    if (map == MAP_FAILED)
        fail("mmap");
    if (mprotect(map + page, page, PROT_NONE))
        fail("mprotect");
    const size_t prefixes[] = {0, 1, 127, 128, 767, 768, 4095, 4096};
    for (size_t i = 0; i < sizeof(prefixes) / sizeof(*prefixes); i++) {
        size_t prefix = prefixes[i], len = prefix + 1024;
        unsigned char *ptr = map + page - prefix;
        memcpy(ptr, src, prefix);
        ssize_t n = write(fds[1], ptr, len);
        if (n < 0) {
            if (errno != EFAULT)
                fail("source fault");
        } else {
            if (!n || n > (ssize_t)prefix)
                fail("source over-copy");
            if (read(fds[0], dst, n) != n || memcmp(dst, src, n))
                fail("source data");
        }
        drain();
        memset(map, 0xa5, page);
        if (write(fds[1], src, len) != (ssize_t)len)
            fail("fault prepare");
        n = read(fds[0], ptr, len);
        if (n < 0) {
            if (errno != EFAULT)
                fail("destination fault");
        } else if (!n || n > (ssize_t)prefix || memcmp(ptr, src, n))
            fail("destination data");
        for (size_t k = 0; k < (size_t)page - prefix; k++) {
            if (map[k] != 0xa5)
                fail("destination underrun");
        }
        drain();
    }
    if (mprotect(map + page, page, PROT_READ | PROT_WRITE))
        fail("mprotect restore");
    /* Offset one also exercises the vector path on demand-faulted pages. */
    for (size_t offset = 0; offset <= 1; offset++) {
        size_t len = page * 2 - offset;
        if (madvise(map, page * 2, MADV_DONTNEED))
            fail("madvise source");
        transfer(map + offset, dst, len);
        for (size_t i = 0; i < len; i++) {
            if (dst[i])
                fail("demand-zero source");
        }
        if (madvise(map, page * 2, MADV_DONTNEED))
            fail("madvise destination");
        transfer(src, map + offset, len);
        if (memcmp(src, map + offset, len))
            fail("demand-zero destination");
    }
    munmap(map, page * 2);
    puts("PASS: source/destination guard-page faults and demand paging");
}

static void correctness(void)
{
    const size_t sizes[] = {0,   1,   7,   15,   63,   64,   127,  128,  255, 511,
                            767, 768, 769, 1023, 1024, 1025, 4095, 4096, 8192};
    unsigned int cases = 0;
    for (size_t i = 0; i < sizeof(sizes) / sizeof(*sizes); i++) {
        size_t n = sizes[i];
        for (size_t a = 0; a < 16; a++)
            for (size_t b = 0; b < 16; b++) {
                memset(dst, 0xa5, sizeof(dst));
                memset(expected, 0xa5, sizeof(expected));
                memcpy(expected + 16 + b, src + a, n);
                transfer(src + a, dst + 16 + b, n);
                if (memcmp(dst, expected, sizeof(dst)))
                    fail("copy/canary mismatch");
                cases++;
            }
    }
    printf("PASS: %u size/alignment/canary cases\n", cases);
}

static void benchmark(void)
{
    const size_t sizes[] = {64, 512, 768, 1024, 4096, 8192};
    const int repeats = 20000;
    for (int trial = 0; trial < 3; trial++) {
        for (int offset = 0; offset <= 1; offset++) {
            for (size_t i = 0; i < sizeof(sizes) / sizeof(*sizes); i++) {
                size_t n = sizes[i];
                struct timespec start, end;
                for (int k = 0; k < 100; k++)
                    transfer(src + offset, dst + offset * 3, n);
                clock_gettime(CLOCK_MONOTONIC, &start);
                for (int k = 0; k < repeats; k++)
                    transfer(src + offset, dst + offset * 3, n);
                clock_gettime(CLOCK_MONOTONIC, &end);
                double seconds = (end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) * 1e-9;
                if (memcmp(src + offset, dst + offset * 3, n))
                    fail("benchmark data");
                printf("trial=%d offset=%d size=%zu roundtrip_ns=%.0f payload_MiB_s=%.2f\n", trial,
                       offset, n, seconds * 1e9 / repeats, n * repeats / seconds / 1048576.0);
                fflush(stdout);
            }
        }
    }
}

int main(int argc, char **argv)
{
    for (size_t i = 0; i < sizeof(src); i++)
        src[i] = i * 17 + (i >> 8);
    if (pipe2(fds, O_NONBLOCK))
        fail("pipe");
    if (fcntl(fds[0], F_SETPIPE_SZ, 8192) < 8192)
        fail("pipe capacity");
    if (argc == 2 && !strcmp(argv[1], "--bench"))
        benchmark();
    else if (argc == 1) {
        correctness();
        faults();
    } else
        return 2;
    return 0;
}
