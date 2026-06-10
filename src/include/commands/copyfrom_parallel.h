/*-------------------------------------------------------------------------
 *
 * copyfrom_parallel.h
 *	  Internal definitions for parallel COPY FROM.
 *
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * src/include/commands/copyfrom_parallel.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef COPYFROM_PARALLEL_H
#define COPYFROM_PARALLEL_H

#include "commands/copyfrom_internal.h"

/* in copyfrom_linescan.c */
extern EolType ParallelCopyDetectEol(FILE *file, int64 file_size);
extern int	ParallelCopyFindSplitPoints(FILE *file, int64 file_size,
										EolType eol_type, int nranges,
										int64 *offsets);

#endif							/* COPYFROM_PARALLEL_H */
