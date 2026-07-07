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
	List	   *changes;		/* in-memory changes (after any spill) */
	Size		nbytes;			/* approximate size of "changes" */
	bool		spilled;		/* a spill file exists for this xid */
	int64		nspilled;		/* number of changes in the spill file */
} UndoBufferedTxn;

/*
 * Spill files live in base/pgsql_tmp with a PG_TEMP_FILE_PREFIX name, so
 * leftovers are removed at every server start; the worker sweeps them at
 * runtime.  Serialized record layout (packed, host byte order):
 *	 Oid relid, char op, XLogRecPtr change_lsn,
 *	 int32 old_len (-1 = NULL), int32 new_len (-1 = NULL),
 *	 old bytes, new bytes
 */
#define UNDO_SPILL_DIR			"base/pgsql_tmp"
#define UNDO_SPILL_FILE_PREFIX	"pgsql_tmp.pg_undo."

extern void undo_spill_path(char *path, size_t len, TransactionId xid);
extern void undo_spill_txn(UndoBufferedTxn *utxn);

/* GUCs (defined in pg_undo.c) */
extern char *pg_undo_database;
extern bool pg_undo_enabled;
extern int	pg_undo_naptime;
extern int	pg_undo_janitor_interval;
extern char *pg_undo_retention;
extern int	pg_undo_max_history_size;
extern int	pg_undo_spill_threshold;
extern bool pg_undo_recycle_bin;
extern char *pg_undo_trash_retention;

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

/* pg_undo_drop.c */
extern void pg_undo_drop_init(void);

#endif							/* PG_UNDO_H */
