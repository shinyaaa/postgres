/*-------------------------------------------------------------------------
 *
 * pg_undo.h
 *	  Shared declarations for the pg_undo extension.
 *
 * The capture background worker (pg_undo_worker.c) and the logical
 * decoding output plugin (pg_undo_plugin.c) are compiled into the same
 * shared library and always run in the same process, so they communicate
 * through the plain globals declared here.
 *
 *-------------------------------------------------------------------------
 */
#ifndef PG_UNDO_H
#define PG_UNDO_H

#include "postgres.h"

#if PG_VERSION_NUM < 190000 || PG_VERSION_NUM >= 200000
#error "pg_undo targets PostgreSQL 19 (19devel/19beta) only"
#endif

#include "access/xlogdefs.h"
#include "datatype/timestamp.h"
#include "nodes/pg_list.h"
#include "utils/hsearch.h"
#include "utils/memutils.h"

#define PG_UNDO_SLOT_NAME	"pg_undo"

/* one captured row change, buffered until the decode batch is applied */
typedef struct UndoBufferedChange
{
	Oid			relid;
	char		op;				/* 'I', 'U', 'D' or 'T' */
	XLogRecPtr	change_lsn;
	char	   *old_row;		/* JSON text, or NULL */
	char	   *new_row;		/* JSON text, or NULL */
} UndoBufferedChange;

/* all captured changes of one committed transaction */
typedef struct UndoBufferedTxn
{
	TransactionId xid;
	XLogRecPtr	commit_end_lsn;
	TimestampTz commit_time;
	List	   *changes;		/* list of UndoBufferedChange * */
} UndoBufferedTxn;

/* GUCs (defined in pg_undo.c) */
extern char *pg_undo_database;
extern bool pg_undo_enabled;
extern int	pg_undo_naptime;
extern int	pg_undo_janitor_interval;
extern char *pg_undo_retention;
extern int	pg_undo_max_history_size;

/*
 * Capture buffer state (owned by pg_undo_worker.c, filled by the output
 * plugin callbacks in pg_undo_plugin.c).
 *
 * Decoding callbacks run under a historic snapshot inside a transaction
 * that is deliberately aborted, so they must not write to any table; they
 * only append to these structures.  The worker applies the buffer to
 * undo.history in its own transaction after decoding.
 */
extern MemoryContext undo_buffer_cxt;
extern List *undo_completed_txns;	/* list of UndoBufferedTxn * */
extern long undo_buffered_rows;
extern HTAB *undo_tracked_rels; /* Oid -> (present); may be NULL */

extern PGDLLEXPORT void pg_undo_worker_main(Datum main_arg);

#endif							/* PG_UNDO_H */
