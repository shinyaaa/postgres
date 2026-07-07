/*-------------------------------------------------------------------------
 *
 * pg_undo_plugin.c
 *	  Logical decoding output plugin that buffers row images in memory.
 *
 * Unlike ordinary output plugins, this one never emits anything through
 * the output stream: the pg_undo background worker consumes the slot
 * in-process, and the callbacks here append decoded old/new row images
 * to the in-memory buffer declared in pg_undo.h.  The worker later
 * applies that buffer to undo.history in its own transaction (decoding
 * callbacks themselves run under a historic snapshot inside a transaction
 * that is deliberately aborted, so writing from here is not possible).
 *
 * Catalog access (type output functions and the like) is fine here; this
 * is exactly what historic snapshots provide.  User tables must not be
 * touched, which is why the set of tracked relations is consulted from an
 * in-memory hash maintained by the worker rather than from
 * undo.tracked_tables.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/htup_details.h"
#include "replication/logical.h"
#include "replication/output_plugin.h"
#include "utils/json.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "varatt.h"

#include "pg_undo.h"

static void undo_startup_cb(LogicalDecodingContext *ctx,
							OutputPluginOptions *opt, bool is_init);
static void undo_begin_cb(LogicalDecodingContext *ctx, ReorderBufferTXN *txn);
static void undo_change_cb(LogicalDecodingContext *ctx, ReorderBufferTXN *txn,
						   Relation relation, ReorderBufferChange *change);
static void undo_truncate_cb(LogicalDecodingContext *ctx, ReorderBufferTXN *txn,
							 int nrelations, Relation relations[],
							 ReorderBufferChange *change);
static void undo_commit_cb(LogicalDecodingContext *ctx, ReorderBufferTXN *txn,
						   XLogRecPtr commit_lsn);
static void undo_shutdown_cb(LogicalDecodingContext *ctx);

void
_PG_output_plugin_init(OutputPluginCallbacks *cb)
{
	cb->startup_cb = undo_startup_cb;
	cb->begin_cb = undo_begin_cb;
	cb->change_cb = undo_change_cb;
	cb->truncate_cb = undo_truncate_cb;
	cb->commit_cb = undo_commit_cb;
	cb->shutdown_cb = undo_shutdown_cb;
}

static void
undo_startup_cb(LogicalDecodingContext *ctx, OutputPluginOptions *opt,
				bool is_init)
{
	/*
	 * The buffer context only exists in the pg_undo background worker.
	 * Refuse use through pg_logical_slot_get_changes() and friends: they
	 * would consume (and thus lose) changes the worker needs.
	 */
	if (undo_buffer_cxt == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("the pg_undo output plugin can only be used by the pg_undo background worker")));

	opt->output_type = OUTPUT_PLUGIN_BINARY_OUTPUT;
	opt->receive_rewrites = false;
}

static void
undo_begin_cb(LogicalDecodingContext *ctx, ReorderBufferTXN *txn)
{
	UndoBufferedTxn *utxn;

	utxn = MemoryContextAllocZero(undo_buffer_cxt, sizeof(UndoBufferedTxn));
	utxn->xid = txn->xid;
	utxn->changes = NIL;
	txn->output_plugin_private = utxn;
}

/*
 * Is this relation currently tracked?  The hash is refreshed by the worker
 * before every capture cycle.
 */
static bool
undo_rel_is_tracked(Oid relid)
{
	if (undo_tracked_rels == NULL)
		return false;
	return hash_search(undo_tracked_rels, &relid, HASH_FIND, NULL) != NULL;
}

/*
 * Convert a heap tuple to a JSON object string, with every non-NULL value
 * rendered through its type output function as a JSON string.  Restoring
 * goes through jsonb_populate_record(), i.e. the type input functions, so
 * this round-trips losslessly.
 *
 * toast_fallback, when given, is a complete row image (the old tuple of an
 * UPDATE, flattened thanks to REPLICA IDENTITY FULL) used to fill in
 * unchanged TOASTed values, which are not WAL-logged in the new tuple.
 *
 * The result is allocated in CurrentMemoryContext.
 */
static char *
undo_tuple_to_json(TupleDesc tupdesc, HeapTuple tuple, HeapTuple toast_fallback)
{
	StringInfoData buf;
	bool		first = true;

	initStringInfo(&buf);
	appendStringInfoChar(&buf, '{');

	for (int natt = 0; natt < tupdesc->natts; natt++)
	{
		Form_pg_attribute attr = TupleDescAttr(tupdesc, natt);
		Datum		val;
		bool		isnull;

		if (attr->attisdropped || attr->attnum < 0)
			continue;

		val = heap_getattr(tuple, natt + 1, tupdesc, &isnull);

		/*
		 * An unchanged TOASTed value is represented by an on-disk TOAST
		 * pointer that must not be followed during decoding.  Take the value
		 * from the fallback (old) tuple instead.
		 */
		if (!isnull && attr->attlen == -1 &&
			VARATT_IS_EXTERNAL_ONDISK(DatumGetPointer(val)))
		{
			if (toast_fallback != NULL)
				val = heap_getattr(toast_fallback, natt + 1, tupdesc, &isnull);

			if (!isnull && attr->attlen == -1 &&
				VARATT_IS_EXTERNAL_ONDISK(DatumGetPointer(val)))
			{
				/* shouldn't happen for tracked tables; don't lose the row */
				elog(WARNING, "pg_undo: could not resolve TOASTed value of column \"%s\", storing NULL",
					 NameStr(attr->attname));
				isnull = true;
			}
		}

		if (!first)
			appendStringInfoChar(&buf, ',');
		first = false;

		escape_json(&buf, NameStr(attr->attname));
		appendStringInfoChar(&buf, ':');

		if (isnull)
			appendStringInfoString(&buf, "null");
		else
		{
			Oid			typoutput;
			bool		typisvarlena;
			char	   *outstr;

			getTypeOutputInfo(attr->atttypid, &typoutput, &typisvarlena);
			if (typisvarlena)
				val = PointerGetDatum(PG_DETOAST_DATUM(val));
			outstr = OidOutputFunctionCall(typoutput, val);
			escape_json(&buf, outstr);
		}
	}

	appendStringInfoChar(&buf, '}');
	return buf.data;
}

static void
undo_change_cb(LogicalDecodingContext *ctx, ReorderBufferTXN *txn,
			   Relation relation, ReorderBufferChange *change)
{
	UndoBufferedTxn *utxn = (UndoBufferedTxn *) txn->output_plugin_private;
	UndoBufferedChange *uchg;
	TupleDesc	tupdesc = RelationGetDescr(relation);
	Oid			relid = RelationGetRelid(relation);
	MemoryContext oldcxt;

	if (utxn == NULL)
		return;
	if (!undo_rel_is_tracked(relid))
		return;

	oldcxt = MemoryContextSwitchTo(undo_buffer_cxt);

	uchg = palloc0(sizeof(UndoBufferedChange));
	uchg->relid = relid;
	uchg->change_lsn = change->lsn;

	switch (change->action)
	{
		case REORDER_BUFFER_CHANGE_INSERT:
			uchg->op = 'I';
			if (change->data.tp.newtuple != NULL)
				uchg->new_row = undo_tuple_to_json(tupdesc,
												   change->data.tp.newtuple,
												   NULL);
			break;
		case REORDER_BUFFER_CHANGE_UPDATE:
			uchg->op = 'U';
			if (change->data.tp.oldtuple != NULL)
				uchg->old_row = undo_tuple_to_json(tupdesc,
												   change->data.tp.oldtuple,
												   NULL);
			if (change->data.tp.newtuple != NULL)
				uchg->new_row = undo_tuple_to_json(tupdesc,
												   change->data.tp.newtuple,
												   change->data.tp.oldtuple);
			break;
		case REORDER_BUFFER_CHANGE_DELETE:
			uchg->op = 'D';
			if (change->data.tp.oldtuple != NULL)
				uchg->old_row = undo_tuple_to_json(tupdesc,
												   change->data.tp.oldtuple,
												   NULL);
			break;
		default:
			pfree(uchg);
			MemoryContextSwitchTo(oldcxt);
			return;
	}

	utxn->changes = lappend(utxn->changes, uchg);
	undo_buffered_rows++;

	MemoryContextSwitchTo(oldcxt);
}

static void
undo_truncate_cb(LogicalDecodingContext *ctx, ReorderBufferTXN *txn,
				 int nrelations, Relation relations[],
				 ReorderBufferChange *change)
{
	UndoBufferedTxn *utxn = (UndoBufferedTxn *) txn->output_plugin_private;
	MemoryContext oldcxt;

	if (utxn == NULL)
		return;

	oldcxt = MemoryContextSwitchTo(undo_buffer_cxt);

	for (int i = 0; i < nrelations; i++)
	{
		Oid			relid = RelationGetRelid(relations[i]);
		UndoBufferedChange *uchg;

		if (!undo_rel_is_tracked(relid))
			continue;

		uchg = palloc0(sizeof(UndoBufferedChange));
		uchg->relid = relid;
		uchg->op = 'T';
		uchg->change_lsn = change->lsn;
		utxn->changes = lappend(utxn->changes, uchg);
		undo_buffered_rows++;
	}

	MemoryContextSwitchTo(oldcxt);
}

static void
undo_commit_cb(LogicalDecodingContext *ctx, ReorderBufferTXN *txn,
			   XLogRecPtr commit_lsn)
{
	UndoBufferedTxn *utxn = (UndoBufferedTxn *) txn->output_plugin_private;
	MemoryContext oldcxt;

	if (utxn == NULL)
		return;
	txn->output_plugin_private = NULL;

	/*
	 * Transactions without tracked changes are dropped; their memory is
	 * reclaimed when the worker resets the buffer context.
	 */
	if (utxn->changes == NIL)
		return;

	utxn->commit_end_lsn = txn->end_lsn;
	utxn->commit_time = txn->commit_time;

	oldcxt = MemoryContextSwitchTo(undo_buffer_cxt);
	undo_completed_txns = lappend(undo_completed_txns, utxn);
	MemoryContextSwitchTo(oldcxt);
}

static void
undo_shutdown_cb(LogicalDecodingContext *ctx)
{
	/* nothing to do */
}
