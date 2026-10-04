// SPDX-License-Identifier: GPL-2.0-only
/* SG2002 hardware/software differential tests; load on the board, not a host. */
#include <crypto/aead.h>
#include <crypto/hash.h>
#include <crypto/skcipher.h>
#include <linux/crypto.h>
#include <linux/kernel_stat.h>
#include <linux/ktime.h>
#include <linux/module.h>
#include <linux/slab.h>

static bool hold;
module_param(hold, bool, 0400);
static struct crypto_skcipher *held;
static bool templates;
module_param(templates, bool, 0400);
static bool kat_only;
module_param(kat_only, bool, 0400);
static bool benchmark;
module_param(benchmark, bool, 0400);
static unsigned int bench_ms = 500;
module_param(bench_ms, uint, 0400);
static unsigned int keybits;
module_param(keybits, uint, 0400);
static char *only;
module_param(only, charp, 0400);
static const unsigned int sizes[] = {
	0, 1, 7, 8, 15, 16, 17, 31, 63, 64, 65, 255, 256, 257,
	4095, 4096, 16383, 16384, 16385, 32768, 65537,
};
static u8 *plain, *actual, *expected;
#define CAPACITY 65600

static void make_sg(struct scatterlist sg[3], u8 *buffer, unsigned int len)
{
	unsigned int first = min(len, 7U), second = min(len - first, 4093U);

	sg_init_table(sg, 3);
	sg_set_buf(&sg[0], buffer, first);
	sg_set_buf(&sg[1], buffer + first, second);
	sg_set_buf(&sg[2], buffer + first + second, len - first - second);
}

static int crypt(struct crypto_skcipher *tfm, u8 *src, u8 *dst,
		 unsigned int len, u8 *iv, bool decrypt, bool split)
{
	DECLARE_CRYPTO_WAIT(wait);
	struct skcipher_request *req = skcipher_request_alloc(tfm, GFP_KERNEL);
	struct scatterlist in[3], out[3];
	int err;

	if (!req)
		return -ENOMEM;
	if (split) {
		make_sg(in, src, len);
		make_sg(out, dst, len);
	} else {
		sg_init_one(in, src, len);
		sg_init_one(out, dst, len);
	}
	skcipher_request_set_callback(req, CRYPTO_TFM_REQ_MAY_SLEEP |
				      CRYPTO_TFM_REQ_MAY_BACKLOG, crypto_req_done, &wait);
	skcipher_request_set_crypt(req, in, src == dst ? in : out, len, iv);
	err = crypto_wait_req(decrypt ? crypto_skcipher_decrypt(req) :
			     crypto_skcipher_encrypt(req), &wait);
	skcipher_request_free(req);
	return err;
}

static int test_kat(void)
{
	static const u8 key[] = {
		0x2b,0x7e,0x15,0x16,0x28,0xae,0xd2,0xa6,
		0xab,0xf7,0x15,0x88,0x09,0xcf,0x4f,0x3c
	};
	static const u8 plain[] = {
		0x6b,0xc1,0xbe,0xe2,0x2e,0x40,0x9f,0x96,
		0xe9,0x3d,0x7e,0x11,0x73,0x93,0x17,0x2a
	};
	static const u8 cipher[] = {
		0x76,0x49,0xab,0xac,0x81,0x19,0xb2,0x46,
		0xce,0xe9,0x8e,0x9b,0x12,0xe9,0x19,0x7d
	};
	struct crypto_skcipher *tfm = held ?: crypto_alloc_skcipher("cbc-aes-sg2002", 0, 0);
	u8 *input, *output, iv[16];
	u64 start;
	int err, i;

	if (IS_ERR(tfm))
		return PTR_ERR(tfm);
	input = kmemdup(plain, sizeof(plain), GFP_KERNEL);
	output = kzalloc(sizeof(cipher), GFP_KERNEL);
	if (!input || !output) {
		err = -ENOMEM;
		goto out;
	}
	err = crypto_skcipher_setkey(tfm, key, sizeof(key));
	if (err)
		goto out;
	for (i = 0; i < 16; i++) iv[i] = i;
	start = ktime_get_ns();
	err = crypt(tfm, input, output, 16, iv, false, false);
	pr_info("sg-crypto-kat AES128CBC err=%d duration_ns=%llu output=%*phN\n",
		err, ktime_get_ns() - start, 16, output);
	if (!err && memcmp(output, cipher, sizeof(cipher))) err = -EBADMSG;
 out:
	kfree_sensitive(input);
	kfree_sensitive(output);
	if (!held)
		crypto_free_skcipher(tfm);
	return err;
}

static int held_run(const char *value, const struct kernel_param *kp)
{
	return held ? test_kat() : -ENODEV;
}

static const struct kernel_param_ops held_ops = { .set = held_run };
module_param_cb(run, &held_ops, NULL, 0200);

static u64 cpu_busy(void)
{
	u64 total = 0;
	int cpu, field;

	for_each_online_cpu(cpu)
		for (field = 0; field < NR_STATS; field++)
			if (field != CPUTIME_IDLE && field != CPUTIME_IOWAIT &&
			    field != CPUTIME_GUEST && field != CPUTIME_GUEST_NICE)
				total += kcpustat_cpu(cpu).cpustat[field];
	return total;
}

static int bench_cipher(struct crypto_skcipher *tfm, const char *name)
{
	static const unsigned int lengths[] = {16, 64, 256, 1024, 4096, 16384, 65536};
	DECLARE_CRYPTO_WAIT(wait);
	struct skcipher_request *req = skcipher_request_alloc(tfm, GFP_KERNEL);
	struct scatterlist sg;
	u8 iv[16] = {};
	u64 start, elapsed, count, busy;
	int i, err = 0;

	if (!req)
		return -ENOMEM;
	skcipher_request_set_callback(req, CRYPTO_TFM_REQ_MAY_SLEEP |
		CRYPTO_TFM_REQ_MAY_BACKLOG, crypto_req_done, &wait);
	for (i = 0; i < ARRAY_SIZE(lengths); i++) {
		sg_init_one(&sg, actual, lengths[i]);
		skcipher_request_set_crypt(req, &sg, &sg, lengths[i], iv);
		busy = cpu_busy();
		start = ktime_get_ns();
		count = 0;
		do {
			err = crypto_wait_req(crypto_skcipher_encrypt(req), &wait);
			if (err)
				goto out;
			count++;
			cond_resched();
			elapsed = ktime_get_ns() - start;
		} while (elapsed < (u64)bench_ms * NSEC_PER_MSEC);
		busy = cpu_busy() - busy;
		pr_info("sg-crypto-bench %s bytes=%u count=%llu wall_ns=%llu cpu_ns=%llu\n",
			name, lengths[i], count, elapsed, busy);
	}
 out:
	skcipher_request_free(req);
	return err;
}

static int test_cipher(const char *hwname, const char *swname,
		       unsigned int keylen, unsigned int bs, bool ctr)
{
	struct crypto_skcipher *hw, *sw;
	u8 key[64], iv[16], hwiv[16], swiv[16];
	unsigned int i, len, checks = 0;
	int err;

	hw = crypto_alloc_skcipher(hwname, 0, 0);
	if (IS_ERR(hw))
		return PTR_ERR(hw);
	sw = crypto_alloc_skcipher(swname, 0, 0);
	if (IS_ERR(sw)) {
		err = PTR_ERR(sw);
		goto hw;
	}
	for (i = 0; i < sizeof(key); i++)
		key[i] = i * 31 + 17;
	/* Exercise carry propagation in CTR, including the 32-bit boundary. */
	memset(iv, 0xff, sizeof(iv));
	iv[bs - 1] = 0xf9;
	err = crypto_skcipher_setkey(hw, key, keylen);
	if (err)
		goto out;
	err = crypto_skcipher_setkey(sw, key, keylen);
	if (err)
		goto out;
	for (i = 0; i < ARRAY_SIZE(sizes); i++) {
		len = ctr ? sizes[i] : round_up(sizes[i], bs);
		if (!strncmp(hwname, "xts(", 4) && len < 16)
			continue;
		memcpy(hwiv, iv, sizeof(iv));
		memcpy(swiv, iv, sizeof(iv));
		err = crypt(hw, plain + 1, actual + 1, len, hwiv, false, true);
		if (err)
			goto failed;
		err = crypt(sw, plain + 1, expected + 1, len, swiv, false, false);
		if (err || memcmp(actual + 1, expected + 1, len) ||
		    memcmp(hwiv, swiv, crypto_skcipher_ivsize(hw))) {
			err = err ?: -EBADMSG;
			goto failed;
		}
		memcpy(hwiv, iv, sizeof(iv));
		memcpy(swiv, iv, sizeof(iv));
		err = crypt(hw, actual + 1, actual + 1, len, hwiv, true, true);
		if (err)
			goto failed;
		err = crypt(sw, expected + 1, expected + 1, len, swiv, true, false);
		if (err || memcmp(actual + 1, plain + 1, len) ||
		    memcmp(hwiv, swiv, crypto_skcipher_ivsize(hw))) {
			err = err ?: -EBADMSG;
			goto failed;
		}
		checks += 2;
	}
	if (!ctr && crypt(hw, plain, actual, 1, hwiv, false, false) != -EINVAL) {
		err = -EINVAL;
		goto out;
	}
	pr_info("sg-crypto-test %s keybits=%u PASS checks=%u\n", hwname, keylen * 8, checks);
	if (benchmark) {
		err = bench_cipher(hw, hwname);
		if (!err)
			err = bench_cipher(sw, swname);
	}
	goto out;
 failed:
	pr_err("sg-crypto-test %s keybits=%u len=%u FAIL %d hw=%*phN sw=%*phN\n",
	       hwname, keylen * 8, len, err, min(len, 32U), actual + 1,
	       min(len, 32U), expected + 1);
 out:
	crypto_free_skcipher(sw);
 hw:
	crypto_free_skcipher(hw);
	return err;
}

static int bench_hash(struct crypto_ahash *hw, struct shash_desc *sw)
{
	static const unsigned int lengths[] = {16, 64, 256, 1024, 4096, 16384, 65536};
	DECLARE_CRYPTO_WAIT(wait);
	struct ahash_request *req = ahash_request_alloc(hw, GFP_KERNEL);
	struct scatterlist sg;
	u8 digest[32];
	u64 start, elapsed, count, busy;
	unsigned int i, software;
	int err = 0;

	if (!req)
		return -ENOMEM;
	ahash_request_set_callback(req, CRYPTO_TFM_REQ_MAY_SLEEP |
		CRYPTO_TFM_REQ_MAY_BACKLOG, crypto_req_done, &wait);
	for (software = 0; software < 2; software++) {
		for (i = 0; i < ARRAY_SIZE(lengths); i++) {
			sg_init_one(&sg, plain, lengths[i]);
			ahash_request_set_crypt(req, &sg, digest, lengths[i]);
			busy = cpu_busy();
			start = ktime_get_ns();
			count = 0;
			do {
				err = software ? crypto_shash_digest(sw, plain, lengths[i], digest) :
					crypto_wait_req(crypto_ahash_digest(req), &wait);
				if (err)
					goto out;
				count++;
				cond_resched();
				elapsed = ktime_get_ns() - start;
			} while (elapsed < (u64)bench_ms * NSEC_PER_MSEC);
			busy = cpu_busy() - busy;
			pr_info("sg-crypto-bench %s bytes=%u count=%llu wall_ns=%llu cpu_ns=%llu\n",
				software ? crypto_tfm_alg_driver_name(crypto_shash_tfm(sw->tfm)) :
				crypto_tfm_alg_driver_name(crypto_ahash_tfm(hw)),
				lengths[i], count, elapsed, busy);
		}
	}
 out:
	ahash_request_free(req);
	return err;
}

static int test_hash(const char *hwname, const char *swname)
{
	DECLARE_CRYPTO_WAIT(wait);
	struct crypto_ahash *hw;
	struct crypto_shash *sw;
	struct ahash_request *req;
	struct shash_desc *desc;
	struct scatterlist sg[3];
	u8 digest[32], reference[32];
	void *state;
	unsigned int i, j, len, offset, part;
	int err;

	hw = crypto_alloc_ahash(hwname, 0, 0);
	if (IS_ERR(hw))
		return PTR_ERR(hw);
	sw = crypto_alloc_shash(swname, 0, 0);
	if (IS_ERR(sw)) {
		err = PTR_ERR(sw);
		goto hw;
	}
	desc = kmalloc(sizeof(*desc) + crypto_shash_descsize(sw), GFP_KERNEL);
	state = kmalloc(crypto_ahash_statesize(hw), GFP_KERNEL);
	req = ahash_request_alloc(hw, GFP_KERNEL);
	if (!desc || !req || !state) {
		err = -ENOMEM;
		goto out;
	}
	desc->tfm = sw;
	ahash_request_set_callback(req, CRYPTO_TFM_REQ_MAY_SLEEP |
		CRYPTO_TFM_REQ_MAY_BACKLOG, crypto_req_done, &wait);
	for (i = 0; i < ARRAY_SIZE(sizes); i++) {
		len = sizes[i];
		err = crypto_shash_digest(desc, plain + 1, len, reference);
		if (err)
			goto out;
		make_sg(sg, plain + 1, len);
		ahash_request_set_crypt(req, sg, digest, len);
		err = crypto_wait_req(crypto_ahash_digest(req), &wait);
		if (err || memcmp(digest, reference, crypto_ahash_digestsize(hw)))
			goto failed;
		err = crypto_ahash_init(req);
		if (err)
			goto out;
		offset = 0;
		for (j = 1; offset < len; j++) {
			part = min(len - offset, (j % 3 == 0 ? 4093U : j % 67));
			make_sg(sg, plain + 1 + offset, part);
			ahash_request_set_crypt(req, sg, digest, part);
			err = crypto_wait_req(crypto_ahash_update(req), &wait);
			if (err)
				goto out;
			offset += part;
			/* Re-create request state, rather than round-trip onto itself. */
			err = crypto_ahash_export(req, state);
			if (err)
				goto out;
			crypto_ahash_init(req);
			err = crypto_ahash_import(req, state);
			if (err)
				goto out;
		}
		ahash_request_set_crypt(req, NULL, digest, 0);
		err = crypto_wait_req(crypto_ahash_final(req), &wait);
		if (err || memcmp(digest, reference, crypto_ahash_digestsize(hw)))
			goto failed;
	}
	pr_info("sg-crypto-test %s PASS digest/multipart/export/import cases=%zu\n",
		hwname, ARRAY_SIZE(sizes));
	err = benchmark ? bench_hash(hw, desc) : 0;
	goto out;
 failed:
	err = err ?: -EBADMSG;
	pr_err("sg-crypto-test %s len=%u FAIL %d actual=%*phN expected=%*phN\n",
	       hwname, len, err, crypto_ahash_digestsize(hw), digest,
	       crypto_ahash_digestsize(hw), reference);
 out:
	ahash_request_free(req);
	kfree_sensitive(desc);
	kfree_sensitive(state);
	crypto_free_shash(sw);
 hw:
	crypto_free_ahash(hw);
	return err;
}

static int gcm_crypt(struct crypto_aead *tfm, unsigned int len, bool decrypt,
		     u8 *buffer)
{
	DECLARE_CRYPTO_WAIT(wait);
	struct aead_request *req = aead_request_alloc(tfm, GFP_KERNEL);
	struct scatterlist sg[3];
	u8 iv[12] = { 1, 2, 3, 4 };
	int err;

	if (!req)
		return -ENOMEM;
	make_sg(sg, buffer, len + 23 + (decrypt ? 0 : 16));
	aead_request_set_callback(req, CRYPTO_TFM_REQ_MAY_SLEEP |
		CRYPTO_TFM_REQ_MAY_BACKLOG, crypto_req_done, &wait);
	aead_request_set_ad(req, 23);
	aead_request_set_crypt(req, sg, sg, len, iv);
	err = crypto_wait_req(decrypt ? crypto_aead_decrypt(req) :
		crypto_aead_encrypt(req), &wait);
	aead_request_free(req);
	return err;
}

static int test_gcm(void)
{
	struct crypto_aead *hw, *sw;
	u8 key[16] = {1};
	unsigned int i, len;
	int err;

	hw = crypto_alloc_aead("gcm_base(ctr-aes-sg2002,ghash-lib)", 0, 0);
	if (IS_ERR(hw))
		return PTR_ERR(hw);
	sw = crypto_alloc_aead("gcm_base(ctr(aes-lib),ghash-lib)", 0, 0);
	if (IS_ERR(sw)) {
		err = PTR_ERR(sw);
		goto hw;
	}
	err = crypto_aead_setkey(hw, key, sizeof(key));
	if (!err)
		err = crypto_aead_setkey(sw, key, sizeof(key));
	if (!err)
		err = crypto_aead_setauthsize(hw, 16);
	if (!err)
		err = crypto_aead_setauthsize(sw, 16);
	if (err)
		goto out;
	for (i = 0; i < ARRAY_SIZE(sizes); i++) {
		len = sizes[i];
		memcpy(actual, plain, len + 23);
		memcpy(expected, plain, len + 23);
		err = gcm_crypt(hw, len, false, actual);
		if (!err)
			err = gcm_crypt(sw, len, false, expected);
		if (err || memcmp(actual, expected, len + 23 + 16)) {
			err = err ?: -EBADMSG;
			goto out;
		}
		err = gcm_crypt(hw, len + 16, true, actual);
		if (err || memcmp(actual, plain, len + 23)) {
			err = err ?: -EBADMSG;
			goto out;
		}
		memcpy(actual, expected, len + 23 + 16);
		actual[len + 23] ^= 1;
		if (gcm_crypt(hw, len + 16, true, actual) != -EBADMSG) {
			err = -EINVAL;
			goto out;
		}
	}
	pr_info("sg-crypto-test GCM template PASS encryption/decryption/auth rejection\n");
 out:
	crypto_free_aead(sw);
 hw:
	crypto_free_aead(hw);
	return err;
}

static int __init sg_test_init(void)
{
	static const struct {
		const char *name, *generic;
		unsigned int keylen, bs;
	} ciphers[] = {
		{"aes", "aes-lib", 16, 16}, {"aes", "aes-lib", 24, 16},
		{"aes", "aes-lib", 32, 16}, {"sm4", "sm4-generic", 16, 16},
		{"des", "des-generic", 8, 8}, {"des3_ede", "des3_ede-generic", 24, 8},
	};
	static const char * const modes[] = {"ecb", "cbc", "ctr"};
	char hw[64], sw[64];
	unsigned int i, j;
	int err = -ENOMEM;

	if (hold) {
		held = crypto_alloc_skcipher("cbc-aes-sg2002", 0, 0);
		if (IS_ERR(held)) {
			err = PTR_ERR(held);
			held = NULL;
			return err;
		}
		err = test_kat();
		if (err) {
			crypto_free_skcipher(held);
			held = NULL;
		}
		return err;
	}
	if (kat_only)
		return test_kat();
	plain = kmalloc(CAPACITY, GFP_KERNEL);
	actual = kmalloc(CAPACITY, GFP_KERNEL);
	expected = kmalloc(CAPACITY, GFP_KERNEL);
	if (!plain || !actual || !expected)
		goto out;
	for (i = 0; i < CAPACITY; i++)
		plain[i] = i * 13 + i / 251;
	if (templates) {
		err = test_cipher("xts(ecb-aes-sg2002)", "xts(ecb(aes-lib))", 32, 16, true);
		if (!err)
			err = test_cipher("xts(ecb-aes-sg2002)", "xts(ecb(aes-lib))", 64, 16, true);
		if (!err)
			err = test_gcm();
		goto out;
	}
	for (i = 0; i < ARRAY_SIZE(ciphers); i++)
		for (j = 0; j < ARRAY_SIZE(modes); j++) {
			snprintf(hw, sizeof(hw), "%s-%s-sg2002", modes[j], ciphers[i].name);
			snprintf(sw, sizeof(sw), "%s(%s)", modes[j], ciphers[i].generic);
			if (keybits && keybits != ciphers[i].keylen * 8)
				continue;
			if (only && strcmp(only, hw))
				continue;
			err = test_cipher(hw, sw, ciphers[i].keylen, ciphers[i].bs, j == 2);
			if (err)
				goto out;
		}
	if (!only || !strcmp(only, "sha1-sg2002")) {
		err = test_hash("sha1-sg2002", "sha1-lib");
		if (err)
			goto out;
	}
	if (!only || !strcmp(only, "sha256-sg2002"))
		err = test_hash("sha256-sg2002", "sha256-lib");
 out:
	kfree_sensitive(plain);
	kfree_sensitive(actual);
	kfree_sensitive(expected);
	pr_info("sg-crypto-test complete: %s (%d)\n", err ? "FAIL" : "PASS", err);
	return err;
}

static void __exit sg_test_exit(void)
{
	if (held)
		crypto_free_skcipher(held);
}
module_init(sg_test_init);
module_exit(sg_test_exit);
MODULE_LICENSE("GPL");

MODULE_DESCRIPTION("SG2002 Crypto API hardware validation");
