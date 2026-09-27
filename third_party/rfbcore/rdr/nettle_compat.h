// ZeonVNC: compatibility with Nettle 4, where digest functions always
// produce the full digest and no longer take a length argument.

#ifndef __RDR_NETTLE_COMPAT_H__
#define __RDR_NETTLE_COMPAT_H__

#include <string.h>

#include <nettle/version.h>
#include <nettle/eax.h>
#include <nettle/md5.h>
#include <nettle/sha1.h>
#include <nettle/sha2.h>

#if NETTLE_VERSION_MAJOR >= 4

static inline void zv_sha1_digest(struct sha1_ctx* ctx, size_t len, uint8_t* out)
{
  uint8_t tmp[SHA1_DIGEST_SIZE];
  nettle_sha1_digest(ctx, tmp);
  memcpy(out, tmp, len < sizeof(tmp) ? len : sizeof(tmp));
}

static inline void zv_sha256_digest(struct sha256_ctx* ctx, size_t len, uint8_t* out)
{
  uint8_t tmp[SHA256_DIGEST_SIZE];
  nettle_sha256_digest(ctx, tmp);
  memcpy(out, tmp, len < sizeof(tmp) ? len : sizeof(tmp));
}

static inline void zv_md5_digest(struct md5_ctx* ctx, size_t len, uint8_t* out)
{
  uint8_t tmp[MD5_DIGEST_SIZE];
  nettle_md5_digest(ctx, tmp);
  memcpy(out, tmp, len < sizeof(tmp) ? len : sizeof(tmp));
}

#undef sha1_digest
#define sha1_digest zv_sha1_digest
#undef sha256_digest
#define sha256_digest zv_sha256_digest
#undef md5_digest
#define md5_digest zv_md5_digest

#define ZV_EAX_DIGEST(ctx, encrypt, length, digest) do {  \
    uint8_t zv_tmp_[EAX_DIGEST_SIZE];                     \
    EAX_DIGEST(ctx, encrypt, zv_tmp_);                    \
    memcpy(digest, zv_tmp_, length);                      \
  } while (0)

#else

#define ZV_EAX_DIGEST(ctx, encrypt, length, digest) \
  EAX_DIGEST(ctx, encrypt, length, digest)

#endif

#endif
