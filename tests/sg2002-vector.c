/* SPDX-License-Identifier: GPL-2.0-only */
#define _GNU_SOURCE
#include <asm/hwprobe.h>
#include <asm/vendor/thead.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/auxv.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

extern long vector_roundtrip(const void *, void *, long, unsigned long);
extern void vector_signal_clobber(int);

static volatile sig_atomic_t signals;
static void handler(int sig)
{
    signals++;
    vector_signal_clobber(sig);
}

static int worker(int id)
{
    unsigned char src[512] __attribute__((aligned(16)));
    unsigned char dst[544] __attribute__((aligned(16)));
    struct sigaction sa = { .sa_handler = handler };
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGALRM, &sa, NULL)) return 1;
    struct itimerval timer = { .it_interval = {0, 5000}, .it_value = {0, 5000} };
    struct rusage before, after;
    if (getrusage(RUSAGE_SELF, &before) || setitimer(ITIMER_REAL, &timer, NULL)) return 1;
    for (int n = 0; n < 1000; n++) {
        for (int i = 0; i < 512; i++) src[i] = id * 47 + i * 13 + n;
        memset(dst, 0xa5, sizeof(dst));
        long rc = vector_roundtrip(src, dst + 16, 500000,
                                   (((id + n) & 3) << 1) | (id & 1));
        if (rc || memcmp(src, dst + 16, sizeof(src))) {
            fprintf(stderr, "worker=%d round=%d mismatch rc=%ld signals=%d\n",
                    id, n, rc, (int)signals);
            /* rc -1/-2/-3/-4 denotes VL/VTYPE/VXRM/VXSAT respectively. */
            for (int k = 0; k < 512; k++) {
                if (src[k] != dst[k + 16]) {
                    fprintf(stderr, "byte=%d expected=%u actual=%u\n",
                            k, src[k], dst[k + 16]);
                    break;
                }
            }
            return 1;
        }
        for (int i = 0; i < 16; i++) {
            if (dst[i] != 0xa5 || dst[528 + i] != 0xa5) return 1;
        }
    }
    timer = (struct itimerval){0};
    if (setitimer(ITIMER_REAL, &timer, NULL) || getrusage(RUSAGE_SELF, &after)) return 1;
    long switches = after.ru_nivcsw - before.ru_nivcsw;
    fprintf(stderr, "worker=%d rounds=1000 signals=%d involuntary_switches=%ld\n",
            id, (int)signals, switches);
    return !signals || switches < 1;
}

int main(int argc, char **argv)
{
    if (argc > 2 || (argc == 2 && strcmp(argv[1], "--expect-disabled"))) {
        fprintf(stderr, "usage: %s [--expect-disabled]\n", argv[0]);
        return 2;
    }
    struct rlimit limit = {0, 0};
    setrlimit(RLIMIT_CORE, &limit);
    struct riscv_hwprobe pairs[] = {
        {RISCV_HWPROBE_KEY_IMA_EXT_0, 0},
        {RISCV_HWPROBE_KEY_VENDOR_EXT_THEAD_0, 0},
    };
    if (syscall(SYS_riscv_hwprobe, pairs, 2, 0, NULL, 0)) { perror("hwprobe"); return 1; }
    printf("hwprobe IMA=%#lx THead=%#lx HWCAP=%#lx\n",
           (unsigned long)pairs[0].value, (unsigned long)pairs[1].value,
           getauxval(AT_HWCAP));
    fflush(stdout);
    if ((pairs[0].value & RISCV_HWPROBE_IMA_V) || (getauxval(AT_HWCAP) & (1UL << ('V'-'A')))) {
        fprintf(stderr, "incorrectly advertises standard V\n"); return 1;
    }
    if (argc == 2 && !strcmp(argv[1], "--expect-disabled")) {
        if (pairs[1].key != RISCV_HWPROBE_KEY_VENDOR_EXT_THEAD_0 || pairs[1].value) return 1;
        pid_t child = fork();
        if (child < 0) return 1;
        if (!child) {
            asm volatile(".4byte 0x000072d7" ::: "t0", "memory");
            _exit(1);
        }
        int status;
        if (waitpid(child, &status, 0) != child) return 1;
        if (!WIFSIGNALED(status) || WTERMSIG(status) != SIGILL) return 1;
        puts("PASS: XTheadVector is unavailable and vector instructions SIGILL");
        return 0;
    }
    if (pairs[1].key != RISCV_HWPROBE_KEY_VENDOR_EXT_THEAD_0 || !(pairs[1].value & RISCV_HWPROBE_VENDOR_EXT_XTHEADVECTOR)) {
        fprintf(stderr, "XTheadVector is not available to userspace\n"); return 1;
    }
    unsigned long vl, vlenb;
    asm volatile(".4byte 0x000072d7\n mv %0,t0\n csrr %1,vlenb"
                 : "=r"(vl), "=r"(vlenb) :: "t0", "memory");
    printf("VL(e8,m1)=%lu VLENB=%lu\n", vl, vlenb);
    if (vl != 16 || vlenb != 16) return 1;
    fflush(stdout);
    pid_t children[4];
    for (int i = 0; i < 4; i++) {
        children[i] = fork();
        if (children[i] < 0) return 1;
        if (!children[i]) _exit(worker(i));
    }
    int failed = 0;
    for (int i = 0; i < 4; i++) {
        int status;
        if (waitpid(children[i], &status, 0) != children[i] ||
            !WIFEXITED(status) || WEXITSTATUS(status)) failed = 1;
    }
    if (!failed) puts("PASS: 4000 all-register/CSR checks under involuntary preemption and signals");
    return failed;
}
