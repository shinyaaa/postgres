/*-------------------------------------------------------------------------
 *
 * pg_undo_worker.c
 *	  Background worker that consumes the pg_undo logical replication slot
 *	  in-process and applies captured changes to undo.history.
 *
 * The overall cycle, repeated every pg_undo.naptime seconds:
 *
 *	 1. refresh the in-memory set of tracked relations (own transaction)
 *	 2. decode WAL through the pg_undo slot; the output plugin buffers
 *		old/new row images of committed transactions in memory
 *	 3. between WAL records (i.e. outside any historic snapshot), insert
 *		buffered rows into undo.history in an ordinary transaction, and
 *		only after that commits, confirm the slot so WAL can be recycled
 *	 4. occasionally run the janitor: retention GC and the size failsafe
 *
 * Deduplication: decoding restarts at the slot's restart_lsn after a
 * crash, so transactions whose slot confirmation was lost can be decoded
 * again.  undo.progress.last_commit_end_lsn is advanced in the same
 * transaction that inserts the history rows, and transactions at or below
 * it are skipped, making application effectively exactly-once.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/xact.h"
#include "access/xlog.h"
#include "access/xlogreader.h"
#include "access/xlogutils.h"
#include "catalog/pg_type.h"
#include "executor/spi.h"
#include "miscadmin.h"
#include "pgstat.h"
#include "postmaster/bgworker.h"
#include "postmaster/interrupt.h"
#include "replication/decode.h"
#include "replication/logical.h"
#include "replication/slot.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "storage/proc.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/inval.h"
#include "utils/memutils.h"
#include "utils/pg_lsn.h"
#include "utils/snapmgr.h"
#include "utils/timestamp.h"
#include "utils/wait_event.h"

#include "pg_undo.h"

#define UNDO_FLUSH_BATCH_ROWS	1000

/* capture buffer, shared with the output plugin (see pg_undo.h) */
MemoryContext undo_buffer_cxt = NULL;
List	   *undo_completed_txns = NIL;
long		undo_buffered_rows = 0;
HTAB	   *undo_tracked_rels = NULL;

static MemoryContext undo_hash_cxt = NULL;
static bool undo_capture_paused = false;
static TimestampTz undo_last_janitor = 0;
static uint32 undo_wait_event = 0;

/*
 * The plugin never writes to the output stream, but CreateDecodingContext
 * requires writer callbacks.
 */
static void
undo_output_prepare_write(LogicalDecodingContext *ctx, XLogRecPtr lsn,
						  TransactionId xid, bool last_write)
{
}

static void
undo_output_write(LogicalDecodingContext *ctx, XLogRecPtr lsn,
				  TransactionId xid, bool last_write)
{
}

/* wait on the latch; returns false when shutdown was requested */
static bool
undo_wait(long ms)
{
	(void) WaitLatch(MyLatch,
					 WL_LATCH_SET | WL_TIMEOUT | WL_EXIT_ON_PM_DEATH,
					 ms,
					 undo_wait_event);
	ResetLatch(MyLatch);
	CHECK_FOR_INTERRUPTS();
	if (ConfigReloadPending)
	{
		ConfigReloadPending = false;
		ProcessConfigFile(PGC_SIGHUP);
	}
	return !ShutdownRequestPending;
}

/*
 * Wait until CREATE EXTENSION pg_undo has been run in our database.
 */
static void
ensure_extension_ready(void)
{
	bool		logged = false;

	for (;;)
	{
		bool		found = false;

		StartTransactionCommand();
		SPI_connect();
		PushActiveSnapshot(GetTransactionSnapshot());
		if (SPI_execute("SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'pg_undo'",
						true, 1) == SPI_OK_SELECT && SPI_processed > 0)
			found = true;
		SPI_finish();
		PopActiveSnapshot();
		CommitTransactionCommand();

		if (found)
			return;

		if (!logged)
		{
			ereport(LOG,
					(errmsg("pg_undo: waiting for CREATE EXTENSION pg_undo in database \"%s\"",
							pg_undo_database)));
			logged = true;
		}

		if (!undo_wait(1000))
			proc_exit(0);
	}
}

/*
 * Create the replication slot if it does not exist yet.  Modeled on
 * create_logical_replication_slot(); running in the worker guarantees we
 * are not inside a transaction that has written anything.
 */
static void
ensure_slot(void)
{
	LogicalDecodingContext *ctx;

	if (SearchNamedReplicationSlot(PG_UNDO_SLOT_NAME, true) != NULL)
		return;

	ereport(LOG,
			(errmsg("pg_undo: creating logical replication slot \"%s\"",
					PG_UNDO_SLOT_NAME)));

	StartTransactionCommand();

	CheckLogicalDecodingRequirements(false);

	/* ephemeral first so that errors during initialization drop it */
	ReplicationSlotCreate(PG_UNDO_SLOT_NAME, true, RS_EPHEMERAL,
						  false, false, false, false);

	PushActiveSnapshot(GetTransactionSnapshot());
	ctx = CreateInitDecodingContext("pg_undo", NIL, false, false,
									InvalidXLogRecPtr,
									XL_ROUTINE(.page_read = read_local_xlog_page,
											   .segment_open = wal_segment_open,
											   .segment_close = wal_segment_close),
									undo_output_prepare_write,
									undo_output_write,
									NULL);
	DecodingContextFindStartpoint(ctx);
	FreeDecodingContext(ctx);
	PopActiveSnapshot();

	ReplicationSlotPersist();
	ReplicationSlotRelease();

	CommitTransactionCommand();
}

/*
 * Reload the set of tracked relations (and the paused flag) from the
 * extension's tables.  Returns false when the extension is missing, in
 * which case the capture cycle is skipped.
 */
static bool
refresh_tracked_rels(void)
{
	bool		ready = false;
	HTAB	   *newhash;
	HASHCTL		hctl;

	if (undo_hash_cxt == NULL)
		undo_hash_cxt = AllocSetContextCreate(TopMemoryContext,
											  "pg_undo tracked relations",
											  ALLOCSET_SMALL_SIZES);

	StartTransactionCommand();
	SPI_connect();
	PushActiveSnapshot(GetTransactionSnapshot());

	if (SPI_execute("SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'pg_undo'",
					true, 1) == SPI_OK_SELECT && SPI_processed > 0)
		ready = true;

	if (ready)
	{
		/* rebuild the hash from scratch; the old one lives in undo_hash_cxt */
		undo_tracked_rels = NULL;
		MemoryContextReset(undo_hash_cxt);

		memset(&hctl, 0, sizeof(hctl));
		hctl.keysize = sizeof(Oid);
		hctl.entrysize = sizeof(Oid);
		hctl.hcxt = undo_hash_cxt;
		newhash = hash_create("pg_undo tracked relations", 64, &hctl,
							  HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);

		if (SPI_execute("SELECT relid::pg_catalog.oid FROM undo.tracked_tables",
						true, 0) == SPI_OK_SELECT)
		{
			for (uint64 i = 0; i < SPI_processed; i++)
			{
				bool		isnull;
				Datum		d;
				Oid			relid;

				d = SPI_getbinval(SPI_tuptable->vals[i],
								  SPI_tuptable->tupdesc, 1, &isnull);
				if (isnull)
					continue;
				relid = DatumGetObjectId(d);
				(void) hash_search(newhash, &relid, HASH_ENTER, NULL);
			}
		}
		undo_tracked_rels = newhash;

		if (SPI_execute("SELECT capture_paused FROM undo.progress",
						true, 1) == SPI_OK_SELECT && SPI_processed > 0)
		{
			bool		isnull;
			Datum		d;

			d = SPI_getbinval(SPI_tuptable->vals[0],
							  SPI_tuptable->tupdesc, 1, &isnull);
			if (!isnull)
				undo_capture_paused = DatumGetBool(d);
		}
	}

	SPI_finish();
	PopActiveSnapshot();
	CommitTransactionCommand();

	return ready;
}

/* read undo.progress.last_commit_end_lsn; call within SPI */
static XLogRecPtr
read_progress_lsn(void)
{
	XLogRecPtr	result = InvalidXLogRecPtr;

	if (SPI_execute("SELECT last_commit_end_lsn FROM undo.progress",
					true, 1) == SPI_OK_SELECT && SPI_processed > 0)
	{
		bool		isnull;
		Datum		d;

		d = SPI_getbinval(SPI_tuptable->vals[0],
						  SPI_tuptable->tupdesc, 1, &isnull);
		if (!isnull)
			result = DatumGetLSN(d);
	}
	return result;
}

/* insert one buffered change into undo.history; call within SPI */
static void
insert_history_row(UndoBufferedTxn *utxn, UndoBufferedChange *chg)
{
	Oid			argtypes[8] = {OIDOID, LSNOID, LSNOID, INT8OID,
	TIMESTAMPTZOID, CHAROID, TEXTOID, TEXTOID};
	Datum		values[8];
	char		nulls[8] = {' ', ' ', ' ', ' ', ' ', ' ', ' ', ' '};

	values[0] = ObjectIdGetDatum(chg->relid);
	values[1] = LSNGetDatum(chg->change_lsn);
	values[2] = LSNGetDatum(utxn->commit_end_lsn);
	values[3] = Int64GetDatum((int64) utxn->xid);
	values[4] = TimestampTzGetDatum(utxn->commit_time);
	values[5] = CharGetDatum(chg->op);
	if (chg->old_row != NULL)
		values[6] = CStringGetTextDatum(chg->old_row);
	else
		nulls[6] = 'n';
	if (chg->new_row != NULL)
		values[7] = CStringGetTextDatum(chg->new_row);
	else
		nulls[7] = 'n';

	if (SPI_execute_with_args("INSERT INTO undo.history"
							  " (relid, change_lsn, commit_lsn, xid, changed_at, changed_by, op, old_row, new_row)"
							  " VALUES ($1, $2, $3, $4, $5, NULL, $6, $7::pg_catalog.jsonb, $8::pg_catalog.jsonb)",
							  8, argtypes, values, nulls,
							  false, 0) != SPI_OK_INSERT)
		elog(ERROR, "pg_undo: could not insert into undo.history");
}

/*
 * Apply all buffered completed transactions to undo.history in one
 * ordinary transaction, then confirm the slot up to the newest applied
 * commit.  Called between WAL records, never from decoding callbacks.
 *
 * Buffered memory of flushed transactions is freed individually here;
 * UndoBufferedTxn structs of transactions still being decoded stay valid.
 */
static void
flush_completed_txns(void)
{
	XLogRecPtr	batch_max = InvalidXLogRecPtr;
	XLogRecPtr	last_done;
	ListCell   *lc;

	if (undo_completed_txns == NIL)
		return;

	StartTransactionCommand();
	SPI_connect();
	PushActiveSnapshot(GetTransactionSnapshot());

	last_done = read_progress_lsn();

	foreach(lc, undo_completed_txns)
	{
		UndoBufferedTxn *utxn = (UndoBufferedTxn *) lfirst(lc);

		/* already applied before a crash/restart */
		if (utxn->commit_end_lsn <= last_done)
			continue;

		if (!undo_capture_paused)
		{
			ListCell   *lc2;

			foreach(lc2, utxn->changes)
				insert_history_row(utxn, (UndoBufferedChange *) lfirst(lc2));
		}

		if (utxn->commit_end_lsn > batch_max)
			batch_max = utxn->commit_end_lsn;
	}

	if (!XLogRecPtrIsInvalid(batch_max))
	{
		Oid			argtypes[1] = {LSNOID};
		Datum		values[1];

		values[0] = LSNGetDatum(batch_max);
		if (SPI_execute_with_args("UPDATE undo.progress SET last_commit_end_lsn = $1",
								  1, argtypes, values, NULL,
								  false, 0) != SPI_OK_UPDATE)
			elog(ERROR, "pg_undo: could not update undo.progress");
	}

	SPI_finish();
	PopActiveSnapshot();
	CommitTransactionCommand();

	/* WAL up to here is durably applied; now the slot may move */
	if (!XLogRecPtrIsInvalid(batch_max))
	{
		LogicalConfirmReceivedLocation(batch_max);
		ReplicationSlotMarkDirty();
	}

	/* free flushed transactions; in-flight ones are untouched */
	foreach(lc, undo_completed_txns)
	{
		UndoBufferedTxn *utxn = (UndoBufferedTxn *) lfirst(lc);
		ListCell   *lc2;

		foreach(lc2, utxn->changes)
		{
			UndoBufferedChange *chg = (UndoBufferedChange *) lfirst(lc2);

			if (chg->old_row)
				pfree(chg->old_row);
			if (chg->new_row)
				pfree(chg->new_row);
			pfree(chg);
		}
		list_free(utxn->changes);
		pfree(utxn);
	}
	list_free(undo_completed_txns);
	undo_completed_txns = NIL;
	undo_buffered_rows = 0;
}

/*
 * One capture cycle: decode available WAL through the slot, flushing
 * buffered transactions along the way.
 */
static void
run_capture_cycle(void)
{
	LogicalDecodingContext *ctx;
	XLogRecPtr	end_of_wal;
	MemoryContext cycle_cxt;
	MemoryContext oldcxt;
	ReplicationSlot *slot;

	end_of_wal = GetFlushRecPtr(NULL);

	/* cheap idle check: fully caught up? */
	slot = SearchNamedReplicationSlot(PG_UNDO_SLOT_NAME, true);
	if (slot != NULL)
	{
		XLogRecPtr	confirmed;

		SpinLockAcquire(&slot->mutex);
		confirmed = slot->data.confirmed_flush;
		SpinLockRelease(&slot->mutex);
		if (confirmed >= end_of_wal)
			return;
	}

	/*
	 * Decoding state must survive the transactions committed by
	 * flush_completed_txns(), so it lives in its own context, not in a
	 * transaction context.
	 */
	cycle_cxt = AllocSetContextCreate(TopMemoryContext,
									  "pg_undo decoding cycle",
									  ALLOCSET_DEFAULT_SIZES);
	oldcxt = MemoryContextSwitchTo(cycle_cxt);

	ReplicationSlotAcquire(PG_UNDO_SLOT_NAME, true, true);

	PG_TRY();
	{
		ReadLocalXLogPageNoWaitPrivate read_private;

		memset(&read_private, 0, sizeof(read_private));

		/*
		 * Use the non-blocking page reader: this worker polls, so it must
		 * never sit inside XLogReadRecord() waiting for WAL (that would
		 * starve the janitor and shutdown handling).
		 */
		ctx = CreateDecodingContext(InvalidXLogRecPtr, NIL, false,
									XL_ROUTINE(.page_read = read_local_xlog_page_no_wait,
											   .segment_open = wal_segment_open,
											   .segment_close = wal_segment_close),
									undo_output_prepare_write,
									undo_output_write,
									NULL);

		/* nothing in decoding reads this; see pg_walinspect for the idiom */
		ctx->reader->private_data = &read_private;

		/*
		 * Start reading at restart_lsn, not confirmed_flush: the reorder
		 * buffer must reassemble whole transactions.  Only transactions
		 * committing after confirmed_flush are emitted.
		 */
		XLogBeginRead(ctx->reader, MyReplicationSlot->data.restart_lsn);

		InvalidateSystemCaches();

		while (ctx->reader->EndRecPtr < end_of_wal && !ShutdownRequestPending)
		{
			XLogRecord *record;
			char	   *errm = NULL;

			record = XLogReadRecord(ctx->reader, &errm);
			if (record == NULL)
			{
				if (read_private.end_of_wal)
					break;
				if (errm)
					elog(ERROR, "pg_undo: could not read WAL: %s", errm);
				break;
			}
			LogicalDecodingProcessRecord(ctx, ctx->reader);

			if (undo_buffered_rows >= UNDO_FLUSH_BATCH_ROWS &&
				undo_completed_txns != NIL)
				flush_completed_txns();

			CHECK_FOR_INTERRUPTS();
		}

		flush_completed_txns();

		/*
		 * Also advance over WAL that produced no history (untracked tables,
		 * empty transactions); otherwise an idle tracked set would retain
		 * WAL forever.  Safe only because everything buffered has been
		 * applied and committed above.
		 */
		if (!XLogRecPtrIsInvalid(ctx->reader->EndRecPtr))
		{
			LogicalConfirmReceivedLocation(ctx->reader->EndRecPtr);
			ReplicationSlotMarkDirty();
		}

		FreeDecodingContext(ctx);
		InvalidateSystemCaches();
	}
	PG_CATCH();
	{
		InvalidateSystemCaches();
		PG_RE_THROW();
	}
	PG_END_TRY();

	ReplicationSlotRelease();

	MemoryContextSwitchTo(oldcxt);
	MemoryContextDelete(cycle_cxt);

	/*
	 * No decoding state references the buffer anymore (in-flight
	 * transactions died with the decoding context), so reclaim everything,
	 * including transactions that never got tracked changes.
	 */
	undo_completed_txns = NIL;
	undo_buffered_rows = 0;
	MemoryContextReset(undo_buffer_cxt);
}

/*
 * Retention GC and the history-size failsafe.
 */
static void
maybe_run_janitor(void)
{
	TimestampTz now = GetCurrentTimestamp();
	int64		history_bytes = 0;
	bool		should_pause;

	if (undo_last_janitor != 0 &&
		!TimestampDifferenceExceeds(undo_last_janitor, now,
									pg_undo_janitor_interval * 1000))
		return;
	undo_last_janitor = now;

	StartTransactionCommand();
	SPI_connect();
	PushActiveSnapshot(GetTransactionSnapshot());

	/* retention GC */
	{
		Oid			argtypes[1] = {TEXTOID};
		Datum		values[1];

		values[0] = CStringGetTextDatum(pg_undo_retention);
		if (SPI_execute_with_args("DELETE FROM undo.history"
								  " WHERE changed_at < pg_catalog.now() - $1::pg_catalog.interval",
								  1, argtypes, values, NULL,
								  false, 0) != SPI_OK_DELETE)
			elog(ERROR, "pg_undo: retention cleanup failed");
		elog(DEBUG1, "pg_undo janitor: retention=%s deleted=" UINT64_FORMAT,
			 pg_undo_retention, (uint64) SPI_processed);
	}

	/* recycle bin GC (0.2 objects may not exist yet after an upgrade) */
	if (SPI_execute("SELECT pg_catalog.to_regclass('undo.trash_meta') IS NOT NULL",
					true, 1) == SPI_OK_SELECT && SPI_processed > 0)
	{
		bool		isnull;
		Datum		d;

		d = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc,
						  1, &isnull);
		if (!isnull && DatumGetBool(d))
		{
			Oid			argtypes[1] = {TEXTOID};
			Datum		values[1];
			int			nexpired = 0;
			Oid		   *expired_oids = NULL;
			char	  **expired_names = NULL;

			elog(DEBUG1, "pg_undo janitor: trash GC entered, trash_retention=%s",
				 pg_undo_trash_retention);
			values[0] = CStringGetTextDatum(pg_undo_trash_retention);
			if (SPI_execute_with_args("SELECT m.trash_relid::pg_catalog.oid,"
									  " m.trash_relid::pg_catalog.text"
									  " FROM undo.trash_meta m"
									  " WHERE m.dropped_at < pg_catalog.now() - $1::pg_catalog.interval",
									  1, argtypes, values, NULL,
									  true, 0) == SPI_OK_SELECT &&
				SPI_processed > 0)
			{
				nexpired = (int) SPI_processed;
				expired_oids = palloc(nexpired * sizeof(Oid));
				expired_names = palloc(nexpired * sizeof(char *));
				for (int i = 0; i < nexpired; i++)
				{
					bool		oidnull;

					expired_oids[i] =
						DatumGetObjectId(SPI_getbinval(SPI_tuptable->vals[i],
													   SPI_tuptable->tupdesc,
													   1, &oidnull));
					expired_names[i] = SPI_getvalue(SPI_tuptable->vals[i],
													SPI_tuptable->tupdesc, 2);
				}
			}

			for (int i = 0; i < nexpired; i++)
			{
				StringInfoData sql;
				Oid			dargtypes[1] = {OIDOID};
				Datum		dvalues[1];

				initStringInfo(&sql);
				appendStringInfo(&sql, "DROP TABLE IF EXISTS %s CASCADE",
								 expired_names[i]);
				(void) SPI_execute(sql.data, false, 0);
				pfree(sql.data);

				dvalues[0] = ObjectIdGetDatum(expired_oids[i]);
				(void) SPI_execute_with_args("DELETE FROM undo.trash_meta"
											 " WHERE trash_relid = $1::pg_catalog.regclass",
											 1, dargtypes, dvalues, NULL,
											 false, 0);
				ereport(LOG,
						(errmsg("pg_undo: purged expired table %s from the recycle bin",
								expired_names[i])));
			}

			/* forget entries whose table disappeared some other way */
			(void) SPI_execute("DELETE FROM undo.trash_meta"
							   " WHERE trash_relid::pg_catalog.oid NOT IN"
							   " (SELECT oid FROM pg_catalog.pg_class)",
							   false, 0);
		}
	}

	/* size failsafe */
	if (SPI_execute("SELECT pg_catalog.pg_total_relation_size('undo.history'::pg_catalog.regclass)",
					true, 1) == SPI_OK_SELECT && SPI_processed > 0)
	{
		bool		isnull;
		Datum		d;

		d = SPI_getbinval(SPI_tuptable->vals[0],
						  SPI_tuptable->tupdesc, 1, &isnull);
		if (!isnull)
			history_bytes = DatumGetInt64(d);
	}
	should_pause = history_bytes > (int64) pg_undo_max_history_size * 1024 * 1024;

	if (should_pause != undo_capture_paused)
	{
		Oid			argtypes[2] = {BOOLOID, TEXTOID};
		Datum		values[2];
		char		nulls[2] = {' ', ' '};

		values[0] = BoolGetDatum(should_pause);
		if (should_pause)
			values[1] = CStringGetTextDatum("undo.history exceeds pg_undo.max_history_size");
		else
			nulls[1] = 'n';

		if (SPI_execute_with_args("UPDATE undo.progress SET capture_paused = $1, paused_reason = $2",
								  2, argtypes, values, nulls,
								  false, 0) != SPI_OK_UPDATE)
			elog(ERROR, "pg_undo: could not update undo.progress");

		undo_capture_paused = should_pause;
		if (should_pause)
			ereport(WARNING,
					(errmsg("pg_undo: history capture paused: undo.history exceeds pg_undo.max_history_size (%d MB)",
							pg_undo_max_history_size),
					 errdetail("New changes will not be recorded, but WAL consumption continues so the server is not endangered."),
					 errhint("Reduce pg_undo.retention, raise pg_undo.max_history_size, or delete rows from undo.history.")));
		else
			ereport(LOG,
					(errmsg("pg_undo: history capture resumed")));
	}

	SPI_finish();
	PopActiveSnapshot();
	CommitTransactionCommand();
}

void
pg_undo_worker_main(Datum main_arg)
{
	pqsignal(SIGHUP, SignalHandlerForConfigReload);
	pqsignal(SIGTERM, SignalHandlerForShutdownRequest);
	BackgroundWorkerUnblockSignals();

	BackgroundWorkerInitializeConnection(pg_undo_database, NULL, 0);

	undo_wait_event = WaitEventExtensionNew("PgUndoMain");
	undo_buffer_cxt = AllocSetContextCreate(TopMemoryContext,
											"pg_undo capture buffer",
											ALLOCSET_DEFAULT_SIZES);

	ereport(LOG,
			(errmsg("pg_undo: capture worker started (database \"%s\")",
					pg_undo_database)));

	ensure_extension_ready();
	ensure_slot();

	while (!ShutdownRequestPending)
	{
		if (!undo_wait(pg_undo_naptime * 1000L))
			break;

		if (!pg_undo_enabled)
			continue;

		if (!refresh_tracked_rels())
			continue;

		run_capture_cycle();
		maybe_run_janitor();
	}

	ereport(LOG, (errmsg("pg_undo: capture worker shutting down")));
	proc_exit(0);
}
