# SPDX-License-Identifier: GPL-2.0-only
obj-m += sg2002_memcpy_test.o
sg2002_memcpy_test-y := test.o memcpy.o memcpy_vector.o nested.o

# Compile the actual candidate under private names, without replacing the
# running kernel's memcpy. Its scalar entry is the unchanged upstream baseline.
rename := -D__memcpy=test_memcpy -Dmemcpy=test_memcpy_weak \
	-D__memcpy_scalar=test_memcpy_scalar -D__memcpy_vector=test_memcpy_vector \
	-D__memcpy_thead=test_memcpy_thead \
	-D__pi_memcpy=test_pi_memcpy -D__pi___memcpy=test_pi___memcpy
AFLAGS_memcpy.o += $(rename)
CFLAGS_memcpy_vector.o += $(rename)
KASAN_SANITIZE_memcpy_vector.o := n
KCSAN_SANITIZE_memcpy_vector.o := n
KCOV_INSTRUMENT_memcpy_vector.o := n
