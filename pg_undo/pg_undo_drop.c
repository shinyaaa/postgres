/*-------------------------------------------------------------------------
 *
 * pg_undo_drop.c
 *	  Recycle bin: a ProcessUtility hook that turns DROP TABLE into a move
 *	  to the undo_trash schema.
 *
 * Interception is deliberately conservative and all-or-nothing per
 * statement.  A DROP TABLE is diverted to the recycle bin only when
 *
 *	 - pg_undo.recycle_bin is on and the pg_undo extension (>= 0.2, i.e.
 *	   the undo_trash schema) is installed in the current database,
 *	 - the statement does not use CASCADE (CASCADE is the documented,
 *	   deliberate way to destroy a table for real), and
 *	 - every target is an ordinary permanent user table: not temporary,
 *	   not a partition, not owned by an extension, not a system or
 *	   pg_undo-internal table.
 *
 * Otherwise the whole statement falls through to the regular DROP.
 *
 * The caller must have the same rights the real DROP would require
 * (table owner or schema owner).  The actual ALTERs then run with
 * escalated privileges, because ordinary owners have no CREATE right on
 * undo_trash; the target relation is locked and ownership-checked before
 * escalation.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/xact.h"
#include "catalog/dependency.h"
#include "catalog/namespace.h"
#include "catalog/pg_authid.h"
#include "catalog/pg_class.h"
#include "catalog/pg_namespace.h"
#include "commands/extension.h"
#include "executor/spi.h"
#include "miscadmin.h"
#include "nodes/pg_list.h"
#include "storage/lockdefs.h"
#include "tcop/cmdtag.h"
#include "tcop/utility.h"
#include "utils/acl.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"

#include "pg_undo.h"

static ProcessUtility_hook_type prev_ProcessUtility = NULL;

static void undo_ProcessUtility(PlannedStmt *pstmt, const char *queryString,
								bool readOnlyTree,
								ProcessUtilityContext context,
								ParamListInfo params,
								QueryEnvironment *queryEnv,
								DestReceiver *dest, QueryCompletion *qc);
static bool undo_intercept_drop(DropStmt *stmt, QueryCompletion *qc);
static void undo_move_to_trash(Oid relid, Oid save_userid);

void
pg_undo_drop_init(void)
{
	prev_ProcessUtility = ProcessUtility_hook;
	ProcessUtility_hook = undo_ProcessUtility;
}

static void
undo_ProcessUtility(PlannedStmt *pstmt, const char *queryString,
					bool readOnlyTree, ProcessUtilityContext context,
					ParamListInfo params, QueryEnvironment *queryEnv,
					DestReceiver *dest, QueryCompletion *qc)
{
	Node	   *parsetree = pstmt->utilityStmt;

	if (pg_undo_recycle_bin &&
		IsA(parsetree, DropStmt) &&
		context != PROCESS_UTILITY_SUBCOMMAND &&
		!IsBinaryUpgrade &&
		IsTransactionState() &&
		!RecoveryInProgress() &&
		undo_intercept_drop((DropStmt *) parsetree, qc))
		return;

	if (prev_ProcessUtility)
		prev_ProcessUtility(pstmt, queryString, readOnlyTree, context,
							params, queryEnv, dest, qc);
	else
		standard_ProcessUtility(pstmt, queryString, readOnlyTree, context,
								params, queryEnv, dest, qc);
}

/*
 * Can this relation go to the recycle bin?
 */
static bool
undo_rel_is_binnable(Oid relid)
{
	Oid			nspoid;
	char	   *nspname;

	if (relid < FirstNormalObjectId)
		return false;
	if (get_rel_relkind(relid) != RELKIND_RELATION)
		return false;
	if (get_rel_persistence(relid) != RELPERSISTENCE_PERMANENT)
		return false;
	if (get_rel_relispartition(relid))
		return false;
	if (OidIsValid(getExtensionOfObject(RelationRelationId, relid)))
		return false;

	nspoid = get_rel_namespace(relid);
	nspname = get_namespace_name(nspoid);
	if (nspname == NULL ||
		strcmp(nspname, "undo") == 0 ||
		strcmp(nspname, "undo_trash") == 0 ||
		strcmp(nspname, "pg_catalog") == 0 ||
		strcmp(nspname, "information_schema") == 0 ||
		strncmp(nspname, "pg_", 3) == 0)
	{
		if (nspname)
			pfree(nspname);
		return false;
	}
	pfree(nspname);
	return true;
}

/*
 * Try to divert a DROP TABLE into the recycle bin.  Returns true when the
 * statement was fully handled here.
 */
static bool
undo_intercept_drop(DropStmt *stmt, QueryCompletion *qc)
{
	List	   *existing = NIL;
	List	   *missing = NIL;
	ListCell   *cell;
	Oid			save_userid;
	int			save_sec_context;

	if (stmt->removeType != OBJECT_TABLE)
		return false;
	if (stmt->behavior == DROP_CASCADE)
		return false;

	/* recycle bin objects present in this database? (extension >= 0.2) */
	if (!OidIsValid(get_namespace_oid("undo_trash", true)))
		return false;
	if (!OidIsValid(get_extension_oid("pg_undo", true)))
		return false;

	/*
	 * Resolve and vet all targets first: the statement is diverted only
	 * when every existing target can go to the bin.  This takes the same
	 * AccessExclusiveLock the real DROP would.
	 */
	foreach(cell, stmt->objects)
	{
		RangeVar   *rv = makeRangeVarFromNameList(castNode(List, lfirst(cell)));
		Oid			relid;

		relid = RangeVarGetRelidExtended(rv, AccessExclusiveLock,
										 RVR_MISSING_OK, NULL, NULL);

		if (!OidIsValid(relid))
		{
			if (!stmt->missing_ok)
				return false;	/* let the real DROP raise the error */
			missing = lappend(missing, rv);
			continue;
		}

		if (!undo_rel_is_binnable(relid))
			return false;

		/* same requirement as DROP TABLE: table owner or schema owner */
		if (!object_ownercheck(RelationRelationId, relid, GetUserId()) &&
			!object_ownercheck(NamespaceRelationId, get_rel_namespace(relid),
							   GetUserId()))
			aclcheck_error(ACLCHECK_NOT_OWNER, OBJECT_TABLE, rv->relname);

		existing = lappend_oid(existing, relid);
	}

	GetUserIdAndSecContext(&save_userid, &save_sec_context);

	foreach(cell, existing)
		undo_move_to_trash(lfirst_oid(cell), save_userid);

	foreach(cell, missing)
	{
		RangeVar   *rv = (RangeVar *) lfirst(cell);

		ereport(NOTICE,
				(errmsg("table \"%s\" does not exist, skipping",
						rv->relname)));
	}

	if (qc)
		SetQueryCompletion(qc, CMDTAG_DROP_TABLE, 0);
	return true;
}

/* run one SPI command, expecting the given result code */
static void
undo_spi_exec(const char *sql, int expected)
{
	if (SPI_execute(sql, false, 0) != expected)
		elog(ERROR, "pg_undo: recycle bin operation failed: %s", sql);
}

/*
 * Move one vetted, locked relation to undo_trash and register it.
 */
static void
undo_move_to_trash(Oid relid, Oid save_userid)
{
	char	   *relname = get_rel_name(relid);
	char	   *nspname = get_namespace_name(get_rel_namespace(relid));
	char	   *username = GetUserNameFromId(save_userid, false);
	char		trashname[NAMEDATALEN];
	int			save_sec_context;
	Oid			orig_userid;
	StringInfoData sql;

	if (relname == NULL || nspname == NULL)
		elog(ERROR, "pg_undo: cache lookup failed for relation %u", relid);

	/* unique, stable trash name: original truncated + oid */
	snprintf(trashname, sizeof(trashname), "%.*s__%u",
			 (int) (NAMEDATALEN - 1 - 12), relname, relid);

	/*
	 * Ownership was verified by the caller; escalate because ordinary
	 * owners have no CREATE right on undo_trash (nor INSERT on
	 * undo.trash_meta).
	 */
	GetUserIdAndSecContext(&orig_userid, &save_sec_context);
	SetUserIdAndSecContext(BOOTSTRAP_SUPERUSERID,
						   save_sec_context | SECURITY_LOCAL_USERID_CHANGE);

	PG_TRY();
	{
		if (SPI_connect() != SPI_OK_CONNECT)
			elog(ERROR, "pg_undo: SPI_connect failed");

		initStringInfo(&sql);

		/*
		 * Rename owned sequences (serial/identity) to an oid-suffixed name
		 * first, so that re-creating and re-dropping a same-named table
		 * cannot collide inside undo_trash.  ALTER TABLE SET SCHEMA moves
		 * owned sequences along with the table.
		 */
		{
			int			ret;
			uint64		i;

			appendStringInfo(&sql,
							 "SELECT c.oid, c.relname FROM pg_catalog.pg_depend d"
							 " JOIN pg_catalog.pg_class c ON c.oid = d.objid"
							 " WHERE d.classid = 'pg_catalog.pg_class'::pg_catalog.regclass"
							 " AND d.refclassid = 'pg_catalog.pg_class'::pg_catalog.regclass"
							 " AND d.refobjid = %u AND d.deptype IN ('a', 'i')"
							 " AND c.relkind = 'S'", relid);
			ret = SPI_execute(sql.data, true, 0);
			if (ret != SPI_OK_SELECT)
				elog(ERROR, "pg_undo: could not list owned sequences");

			for (i = 0; i < SPI_processed; i++)
			{
				bool		isnull;
				Oid			seqoid;
				char	   *seqname;
				char		newseqname[NAMEDATALEN];

				seqoid = DatumGetObjectId(SPI_getbinval(SPI_tuptable->vals[i],
														SPI_tuptable->tupdesc,
														1, &isnull));
				seqname = SPI_getvalue(SPI_tuptable->vals[i],
									   SPI_tuptable->tupdesc, 2);
				snprintf(newseqname, sizeof(newseqname), "%.*s__%u",
						 (int) (NAMEDATALEN - 1 - 12), seqname, seqoid);

				resetStringInfo(&sql);
				appendStringInfo(&sql, "ALTER SEQUENCE %s.%s RENAME TO %s",
								 quote_identifier(nspname),
								 quote_identifier(seqname),
								 quote_identifier(newseqname));
				undo_spi_exec(sql.data, SPI_OK_UTILITY);
			}
		}

		/*
		 * Same for indexes: they follow the table into undo_trash but keep
		 * their pg_class names, which would otherwise collide with an
		 * earlier trashed table's indexes (or, on restore, with a
		 * re-created table's).  Renaming a constraint's index leaves the
		 * constraint name itself untouched, and constraint names are
		 * per-table, so they cannot collide.
		 */
		{
			int			ret;
			uint64		i;

			resetStringInfo(&sql);
			appendStringInfo(&sql,
							 "SELECT c.oid, c.relname FROM pg_catalog.pg_index i"
							 " JOIN pg_catalog.pg_class c ON c.oid = i.indexrelid"
							 " WHERE i.indrelid = %u", relid);
			ret = SPI_execute(sql.data, true, 0);
			if (ret != SPI_OK_SELECT)
				elog(ERROR, "pg_undo: could not list indexes");

			for (i = 0; i < SPI_processed; i++)
			{
				bool		isnull;
				Oid			idxoid;
				char	   *idxname;
				char		newidxname[NAMEDATALEN];

				idxoid = DatumGetObjectId(SPI_getbinval(SPI_tuptable->vals[i],
														SPI_tuptable->tupdesc,
														1, &isnull));
				idxname = SPI_getvalue(SPI_tuptable->vals[i],
									   SPI_tuptable->tupdesc, 2);
				snprintf(newidxname, sizeof(newidxname), "%.*s__%u",
						 (int) (NAMEDATALEN - 1 - 12), idxname, idxoid);

				resetStringInfo(&sql);
				appendStringInfo(&sql, "ALTER INDEX %s.%s RENAME TO %s",
								 quote_identifier(nspname),
								 quote_identifier(idxname),
								 quote_identifier(newidxname));
				undo_spi_exec(sql.data, SPI_OK_UTILITY);
			}
		}

		resetStringInfo(&sql);
		appendStringInfo(&sql, "ALTER TABLE %s.%s RENAME TO %s",
						 quote_identifier(nspname),
						 quote_identifier(relname),
						 quote_identifier(trashname));
		undo_spi_exec(sql.data, SPI_OK_UTILITY);

		resetStringInfo(&sql);
		appendStringInfo(&sql, "ALTER TABLE %s.%s SET SCHEMA undo_trash",
						 quote_identifier(nspname),
						 quote_identifier(trashname));
		undo_spi_exec(sql.data, SPI_OK_UTILITY);

		resetStringInfo(&sql);
		appendStringInfo(&sql,
						 "INSERT INTO undo.trash_meta"
						 " (trash_relid, original_name, original_schema, dropped_by)"
						 " VALUES (%u::pg_catalog.regclass, %s, %s, %s)",
						 relid,
						 quote_literal_cstr(relname),
						 quote_literal_cstr(nspname),
						 quote_literal_cstr(username));
		undo_spi_exec(sql.data, SPI_OK_INSERT);

		SPI_finish();
	}
	PG_FINALLY();
	{
		SetUserIdAndSecContext(orig_userid, save_sec_context);
	}
	PG_END_TRY();

	ereport(NOTICE,
			(errmsg("pg_undo: moved table \"%s.%s\" to the recycle bin",
					nspname, relname),
			 errhint("Restore it with undo.restore_dropped('%s'); DROP TABLE ... CASCADE bypasses the recycle bin.",
					 relname)));
}
