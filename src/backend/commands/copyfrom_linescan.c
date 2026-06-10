/*-------------------------------------------------------------------------
 *
 * copyfrom_linescan.c
 *	  Line boundary scanner for parallel COPY FROM.
 *
 * This file provides the functions used by parallel COPY FROM to divide a
 * text-format input file into byte ranges that are aligned with line
 * boundaries, so that each participating process can parse its range
 * independently with the regular COPY FROM machinery.
 *
 * Finding a line boundary near an arbitrary byte offset requires some care
 * because, in text format, a backslash escapes the immediately following
 * character; in particular a newline preceded by an odd number of
 * consecutive backslashes does not terminate the line (see
 * CopyReadLineText()).  We therefore track the parity of backslash runs
 * while scanning forward, and never declare a boundary whose preceding
 * backslash run extends beyond the start of our scan window, where its
 * length is unknown.  Skipping such a boundary is always safe: it merely
 * moves the split point to the next line.
 *
 * CSV format is not handled here.  In CSV, a quoted field can contain bare
 * newlines, and whether a given byte is inside quotes cannot be determined
 * by a forward scan from an arbitrary offset, so parallel COPY FROM does
 * not support CSV at all.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * IDENTIFICATION
 *	  src/backend/commands/copyfrom_linescan.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "commands/copyfrom_internal.h"
#include "commands/copyfrom_parallel.h"
#include "port/simd.h"

#define LINE_SCAN_BUF_SIZE	65536

/*
 * Read the byte at the given offset, or -1 at end of file.  The file
 * position is left right after the byte read.
 */
static int
PeekByteAt(FILE *file, int64 offset)
{
	unsigned char c;

	if (fseeko(file, offset, SEEK_SET) != 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not seek in COPY file: %m")));
	if (fread(&c, 1, 1, file) != 1)
	{
		if (ferror(file))
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not read from COPY file: %m")));
		return -1;
	}
	return c;
}

/*
 * FindNextLineStart
 *
 * Starting from the given file offset, scan forward for the first
 * end-of-line sequence of the given type that certainly terminates a line,
 * and return the byte offset just after it, i.e. the start of the next
 * line.  Returns file_size if no such end-of-line is found before EOF.
 *
 * An offset of 0 is returned as-is; the file start is always a line start.
 */
static int64
FindNextLineStart(FILE *file, int64 offset, int64 file_size, EolType eol_type)
{
	char		buf[LINE_SCAN_BUF_SIZE];
	int64		pos = offset;
	char		eol_first;
	int64		bs_run = 0;		/* consecutive backslashes just before the
								 * current position */
	bool		bs_run_open = true; /* might the run extend before the scan
									 * window? */

	if (offset == 0)
		return 0;

	/* The byte that (possibly) terminates a line, per EOL type */
	eol_first = (eol_type == EOL_NL) ? '\n' : '\r';

	if (fseeko(file, offset, SEEK_SET) != 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not seek in COPY file: %m")));

	while (pos < file_size)
	{
		int			bytes_to_read;
		int			nread;
		int			i;

		bytes_to_read = (int) Min((int64) LINE_SCAN_BUF_SIZE, file_size - pos);
		nread = fread(buf, 1, bytes_to_read, file);
		if (nread <= 0)
		{
			if (ferror(file))
				ereport(ERROR,
						(errcode_for_file_access(),
						 errmsg("could not read from COPY file: %m")));
			break;
		}

		i = 0;
		while (i < nread)
		{
			char		c;

			/*
			 * Skip over vector-sized chunks that contain neither the
			 * end-of-line byte nor a backslash.  Such a chunk cannot contain
			 * a boundary, and leaves no backslash run pending.
			 */
			if (i + (int) sizeof(Vector8) <= nread)
			{
				Vector8		chunk;

				vector8_load(&chunk, (const uint8 *) &buf[i]);
				if (!vector8_has(chunk, (uint8) eol_first) &&
					!vector8_has(chunk, (uint8) '\\'))
				{
					i += sizeof(Vector8);
					bs_run = 0;
					bs_run_open = false;
					continue;
				}
			}

			c = buf[i];
			if (c == '\\')
			{
				bs_run++;
				i++;
				continue;
			}

			if (c == eol_first && bs_run % 2 == 0 && !bs_run_open)
			{
				/*
				 * An unescaped end-of-line byte.  For EOL_CRNL, it must be
				 * followed by \n to actually terminate the line; a bare \r
				 * would draw an error from the parser anyway, so it is fine
				 * to not treat it as a boundary here.
				 */
				if (eol_type != EOL_CRNL)
					return pos + i + 1;
				else
				{
					int			c2;

					if (i + 1 < nread)
						c2 = (unsigned char) buf[i + 1];
					else
					{
						/* \r at the end of the buffer; peek at next byte */
						c2 = PeekByteAt(file, pos + i + 1);
						/* re-seek for the next outer-loop read */
						if (fseeko(file, pos + nread, SEEK_SET) != 0)
							ereport(ERROR,
									(errcode_for_file_access(),
									 errmsg("could not seek in COPY file: %m")));
					}
					if (c2 == '\n')
						return pos + i + 2;
				}
			}

			/* Not a boundary; any backslash run is now closed and reset */
			bs_run = 0;
			bs_run_open = false;
			i++;
		}

		pos += nread;
	}

	/* No line boundary found before EOF */
	return file_size;
}

/*
 * ParallelCopyDetectEol
 *
 * Determine the end-of-line style of a text-format COPY input file by
 * scanning from the beginning for the first unescaped \n or \r.  Returns
 * EOL_UNKNOWN if the file contains no line terminator at all (i.e. it
 * consists of at most one line), in which case there is no point in
 * splitting it.
 *
 * The result is used both for finding split points and to preset
 * cstate->eol_type in each participant, so that the existing consistency
 * checks in CopyReadLineText() apply across range boundaries just as they
 * would in a serial COPY.
 */
EolType
ParallelCopyDetectEol(FILE *file, int64 file_size)
{
	char		buf[LINE_SCAN_BUF_SIZE];
	int64		pos = 0;
	int64		bs_run = 0;

	if (fseeko(file, 0, SEEK_SET) != 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not seek in COPY file: %m")));

	while (pos < file_size)
	{
		int			bytes_to_read;
		int			nread;

		bytes_to_read = (int) Min((int64) LINE_SCAN_BUF_SIZE, file_size - pos);
		nread = fread(buf, 1, bytes_to_read, file);
		if (nread <= 0)
		{
			if (ferror(file))
				ereport(ERROR,
						(errcode_for_file_access(),
						 errmsg("could not read from COPY file: %m")));
			break;
		}

		for (int i = 0; i < nread; i++)
		{
			char		c = buf[i];

			if (c == '\\')
			{
				bs_run++;
				continue;
			}

			if ((c == '\n' || c == '\r') && bs_run % 2 == 0)
			{
				if (c == '\n')
					return EOL_NL;

				/* \r: check whether a \n follows */
				if (i + 1 < nread)
					return (buf[i + 1] == '\n') ? EOL_CRNL : EOL_CR;
				else
					return (PeekByteAt(file, pos + i + 1) == '\n') ?
						EOL_CRNL : EOL_CR;
			}

			bs_run = 0;
		}

		pos += nread;
	}

	return EOL_UNKNOWN;
}

/*
 * ParallelCopyFindSplitPoints
 *
 * Divide a text-format COPY input file into up to 'nranges' byte ranges of
 * roughly equal size, each beginning at the start of a line.
 *
 * The output array 'offsets' must have room for nranges + 1 entries.  On
 * return, offsets[0] is 0, offsets[m] is file_size, and offsets[0..m] is
 * strictly increasing, where m <= nranges is the number of usable ranges
 * returned.  m can fall short of nranges when split points collide, e.g.
 * because lines are very long.
 */
int
ParallelCopyFindSplitPoints(FILE *file, int64 file_size, EolType eol_type,
							int nranges, int64 *offsets)
{
	int64		range_size;
	int			m = 0;

	Assert(nranges > 0);
	Assert(eol_type == EOL_NL || eol_type == EOL_CR || eol_type == EOL_CRNL);

	offsets[0] = 0;
	range_size = file_size / nranges;

	for (int i = 1; i < nranges; i++)
	{
		int64		candidate;

		candidate = FindNextLineStart(file, range_size * i, file_size,
									  eol_type);

		/* Keep only split points that produce a non-empty range */
		if (candidate > offsets[m] && candidate < file_size)
			offsets[++m] = candidate;
	}

	offsets[++m] = file_size;

	return m;
}
