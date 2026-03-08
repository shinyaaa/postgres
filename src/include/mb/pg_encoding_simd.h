/*-------------------------------------------------------------------------
 *
 * pg_encoding_simd.h
 *	  SIMD-accelerated helpers for encoding conversion.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * src/include/mb/pg_encoding_simd.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef PG_ENCODING_SIMD_H
#define PG_ENCODING_SIMD_H

#include "port/simd.h"

/*
 * SIMD-accelerated bulk copy of ASCII bytes during encoding conversion.
 *
 * Copies contiguous bytes in the range 0x01-0x7F from src to dst, stopping
 * at the first zero byte or byte with the high bit set (>= 0x80).  Returns
 * the number of bytes copied.
 *
 * This exploits the fact that ASCII characters are represented identically
 * in all PostgreSQL-supported encodings, so they can be bulk-copied without
 * per-character conversion.  On platforms with SIMD support (SSE2 or NEON),
 * this processes 16 bytes per iteration; on other platforms it uses uint64
 * arithmetic to process 8 bytes at a time.
 *
 * The caller must ensure that src has at least 'len' readable bytes, and
 * that dst has sufficient space for the output.
 */
static inline int
encoding_copy_ascii(const unsigned char *src, unsigned char *dst, int len)
{
	const unsigned char *start = src;

	/*
	 * Process chunks of sizeof(Vector8) bytes at a time.  We check for
	 * high-bit-set bytes first: if none are set, we know all bytes are less
	 * than 0x80.  This also allows vector8_has_zero() to take its fast path
	 * on non-SIMD platforms.
	 */
	while (len >= (int) sizeof(Vector8))
	{
		Vector8		chunk;

		vector8_load(&chunk, src);

		if (vector8_is_highbit_set(chunk) || vector8_has_zero(chunk))
			break;

		memcpy(dst, src, sizeof(Vector8));
		src += sizeof(Vector8);
		dst += sizeof(Vector8);
		len -= sizeof(Vector8);
	}

	/* Process remaining bytes one at a time */
	while (len > 0 && *src != '\0' && !IS_HIGHBIT_SET(*src))
	{
		*dst++ = *src++;
		len--;
	}

	return src - start;
}

#endif							/* PG_ENCODING_SIMD_H */
