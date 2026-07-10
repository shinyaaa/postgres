/*-------------------------------------------------------------------------
 *
 * explain_copy.c
 *	  Explain a COPY statement
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994-5, Regents of the University of California
 *
 * IDENTIFICATION
 *	  src/backend/commands/explain_copy.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/table.h"
#include "access/xact.h"
#include "commands/copy.h"
#include "commands/explain.h"
#include "commands/explain_format.h"
#include "commands/explain_state.h"
#include "executor/instrument.h"
#include "miscadmin.h"
#include "tcop/tcopprot.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/ruleutils.h"

static void ExplainCopyToQuery(const CopyStmt *stmt, RawStmt *raw_query,
							   Oid queryRelId, ExplainState *es,
							   ParseState *pstate, ParamListInfo params);
static void ExplainCopyFromExec(const CopyStmt *stmt, Relation rel,
								Node *whereClause,
								const CopyFormatOptions *opts,
								ExplainState *es, ParseState *pstate);
static void ExplainCopyGeneric(const CopyStmt *stmt, Relation rel,
							   const CopyFormatOptions *opts,
							   ExplainState *es);
static void show_copy_properties(const CopyStmt *stmt,
								 const CopyFormatOptions *opts,
								 ExplainState *es);
static void show_copy_trigger_stats(const CopyFromInstrumentation *ci,
									ExplainState *es);

/*
 * ExplainCopyStmt -
 *	  print out the execution "plan" for one COPY statement
 *
 * This is called back from ExplainOneUtility.
 */
void
ExplainCopyStmt(CopyStmt *stmt, ExplainState *es,
				ParseState *pstate, ParamListInfo params)
{
	Relation	rel;
	Oid			relid;
	RawStmt    *query;
	Node	   *whereClause;
	CopyFormatOptions opts = {0};	/* ProcessCopyOptions expects zeroes */

	/*
	 * Perform the same permission checks and preparatory transformations as
	 * the execution of the COPY statement would, so that EXPLAIN reports the
	 * same errors.  This opens and locks the target relation, and converts
	 * the statement to a query-based COPY if row-level security applies.
	 */
	ProcessCopyTarget(pstate, stmt, -1, 0,
					  &rel, &relid, &query, &whereClause);

	/* Likewise, validate the options; we also need them for the output */
	ProcessCopyOptions(pstate, &opts, stmt->is_from, stmt->options);

	if (stmt->is_from)
	{
		if (es->analyze)
			ExplainCopyFromExec(stmt, rel, whereClause, &opts, es, pstate);
		else
			ExplainCopyGeneric(stmt, rel, &opts, es);
	}
	else if (query != NULL)
	{
		/*
		 * COPY (query) TO, or COPY relation TO converted because of RLS.
		 *
		 * With ANALYZE, the source query is executed, but the COPY output is
		 * not produced: no file is written, and no data is sent to the
		 * client.  This parallels EXPLAIN ANALYZE discarding the rows a
		 * SELECT would return.
		 */
		ExplainCopyToQuery(stmt, query, relid, es, pstate, params);
	}
	else
	{
		/* COPY relation TO, no plan to show */
		if (es->analyze)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("EXPLAIN ANALYZE is not supported for COPY relation TO"),
					 errhint("Try the COPY (SELECT ...) TO variant.")));

		ExplainCopyGeneric(stmt, rel, &opts, es);
	}

	if (rel != NULL)
		table_close(rel, NoLock);
}

/*
 * ExplainCopyToQuery -
 *	  print the plan of the source query of a query-based COPY TO
 *
 * This parallels standard_ExplainOneQuery, but starts from the raw source
 * query of the COPY statement and validates it as BeginCopyTo would.
 */
static void
ExplainCopyToQuery(const CopyStmt *stmt, RawStmt *raw_query, Oid queryRelId,
				   ExplainState *es, ParseState *pstate, ParamListInfo params)
{
	Query	   *query;
	PlannedStmt *plan;
	instr_time	planstart,
				planduration;
	BufferUsage bufusage_start,
				bufusage;
	MemoryContextCounters mem_counters;
	MemoryContext planner_ctx = NULL;
	MemoryContext saved_ctx = NULL;

	/*
	 * Run parse analysis, rewrite and COPY-specific validation.  Note that
	 * parse analysis also computes the query identifier and invokes the
	 * post_parse_analyze_hook, as the execution of the COPY statement would.
	 */
	query = CopyToTransformQuery(pstate, raw_query);

	if (es->memory)
	{
		/* See standard_ExplainOneQuery for the reasoning here */
		planner_ctx = AllocSetContextCreate(CurrentMemoryContext,
											"explain analyze planner context",
											ALLOCSET_DEFAULT_SIZES);
		saved_ctx = MemoryContextSwitchTo(planner_ctx);
	}

	if (es->buffers)
		bufusage_start = pgBufferUsage;
	INSTR_TIME_SET_CURRENT(planstart);

	/* plan the query */
	plan = pg_plan_query(query, pstate->p_sourcetext, CURSOR_OPT_PARALLEL_OK,
						 params, es);

	INSTR_TIME_SET_CURRENT(planduration);
	INSTR_TIME_SUBTRACT(planduration, planstart);

	if (es->memory)
	{
		MemoryContextSwitchTo(saved_ctx);
		MemoryContextMemConsumed(planner_ctx, &mem_counters);
	}

	/* calc differences of buffer counters. */
	if (es->buffers)
	{
		memset(&bufusage, 0, sizeof(BufferUsage));
		BufferUsageAccumDiff(&bufusage, &pgBufferUsage, &bufusage_start);
	}

	/*
	 * When a relation-based COPY TO was converted to a query because of
	 * row-level security, check that the planner resolved the same relation
	 * we originally locked, as BeginCopyTo does.
	 */
	if (OidIsValid(queryRelId) &&
		!list_member_oid(plan->relationOids, queryRelId))
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("relation referenced by COPY statement has changed")));

	/* produce output (and run the query, if ANALYZE was given) */
	ExplainOnePlan(plan, NULL, es, pstate->p_sourcetext, params,
				   pstate->p_queryEnv, &planduration,
				   (es->buffers ? &bufusage : NULL),
				   (es->memory ? &mem_counters : NULL),
				   stmt);
}

/*
 * ExplainCopyFromExec -
 *	  execute a COPY FROM statement under EXPLAIN ANALYZE and print the
 *	  collected statistics, including the per-phase timing breakdown
 */
static void
ExplainCopyFromExec(const CopyStmt *stmt, Relation rel, Node *whereClause,
					const CopyFormatOptions *opts, ExplainState *es,
					ParseState *pstate)
{
	CopyFromInstrumentation ci = {0};
	CopyFromState cstate;
	BufferUsage bufusage_start,
				bufusage;
	WalUsage	walusage_start,
				walusage;
	instr_time	starttime,
				totaltime;
	uint64		processed;

	/*
	 * COPY FROM STDIN cannot be executed under EXPLAIN: the CopyInResponse
	 * protocol message would be sent while the client expects the result of
	 * the EXPLAIN statement.
	 */
	if (stmt->filename == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("EXPLAIN ANALYZE cannot be used with COPY FROM STDIN"),
				 errhint("Use COPY FROM a file or PROGRAM.")));

	/* check read-only transaction, as the execution of COPY FROM would */
	if (XactReadOnly && !rel->rd_islocaltemp)
		PreventCommandIfReadOnly("COPY FROM");

	ci.collect_timing = es->timing;

	if (es->buffers)
		bufusage_start = pgBufferUsage;
	if (es->wal)
		walusage_start = pgWalUsage;
	INSTR_TIME_SET_CURRENT(starttime);

	/* run the COPY as DoCopy would, with the instrumentation attached */
	cstate = BeginCopyFrom(pstate, rel, whereClause, stmt->filename,
						   stmt->is_program, NULL, stmt->attlist,
						   stmt->options);
	CopyFromSetInstrumentation(cstate, &ci);
	processed = CopyFrom(cstate);
	EndCopyFrom(cstate);

	/* as in ExplainOnePlan, in case this is used in a multi-command string */
	CommandCounterIncrement();

	INSTR_TIME_SET_CURRENT(totaltime);
	INSTR_TIME_SUBTRACT(totaltime, starttime);

	/* calc differences of buffer and WAL counters */
	if (es->buffers)
	{
		memset(&bufusage, 0, sizeof(BufferUsage));
		BufferUsageAccumDiff(&bufusage, &pgBufferUsage, &bufusage_start);
	}
	if (es->wal)
	{
		memset(&walusage, 0, sizeof(WalUsage));
		WalUsageAccumDiff(&walusage, &pgWalUsage, &walusage_start);
	}

	/* produce the output */
	ExplainOpenGroup("Query", NULL, true, es);
	ExplainOpenGroup("Copy From", "Copy From", true, es);

	if (es->format == EXPLAIN_FORMAT_TEXT)
	{
		ExplainIndentText(es);
		if (es->verbose)
			appendStringInfo(es->str, "Copy From on %s.%s",
							 quote_identifier(get_namespace_name(RelationGetNamespace(rel))),
							 quote_identifier(RelationGetRelationName(rel)));
		else
			appendStringInfo(es->str, "Copy From on %s",
							 quote_identifier(RelationGetRelationName(rel)));
		appendStringInfo(es->str, " (actual rows=%" PRIu64 ")\n", processed);
		es->indent++;
	}
	else
	{
		ExplainPropertyText("Relation Name",
							RelationGetRelationName(rel), es);
		if (es->verbose)
			ExplainPropertyText("Schema",
								get_namespace_name(RelationGetNamespace(rel)),
								es);
		ExplainPropertyUInteger("Actual Rows", NULL, processed, es);
	}

	show_copy_properties(stmt, opts, es);

	/* the per-phase timing breakdown */
	if (es->timing)
	{
		ExplainPropertyFloat("Input Time", "ms",
							 INSTR_TIME_GET_MILLISEC(ci.phase_time[COPY_FROM_PHASE_INPUT]),
							 3, es);
		ExplainPropertyFloat("Insert Time", "ms",
							 INSTR_TIME_GET_MILLISEC(ci.phase_time[COPY_FROM_PHASE_INSERT]),
							 3, es);
		ExplainPropertyFloat("Index Update Time", "ms",
							 INSTR_TIME_GET_MILLISEC(ci.phase_time[COPY_FROM_PHASE_INDEX]),
							 3, es);
	}

	if (whereClause != NULL)
		ExplainPropertyUInteger("Rows Excluded by Filter", NULL,
								ci.excluded, es);
	if (opts->on_error != COPY_ON_ERROR_STOP)
		ExplainPropertyUInteger("Rows Skipped", NULL, ci.skipped, es);

	if (es->buffers)
		show_buffer_usage(es, &bufusage);
	if (es->wal)
		show_wal_usage(es, &walusage);

	if (es->format == EXPLAIN_FORMAT_TEXT)
		es->indent--;

	ExplainCloseGroup("Copy From", "Copy From", true, es);

	/* Print info about runtime of triggers */
	show_copy_trigger_stats(&ci, es);

	/*
	 * As in ExplainOnePlan, total execution time is only reported when
	 * summary reporting is enabled.
	 */
	if (es->summary)
		ExplainPropertyFloat("Execution Time", "ms",
							 INSTR_TIME_GET_MILLISEC(totaltime), 3, es);

	ExplainCloseGroup("Query", NULL, true, es);
}

/*
 * ExplainCopyGeneric -
 *	  print the description of a COPY statement that has no plan to show
 *	  (COPY ... FROM ..., or table-based COPY ... TO ...)
 */
static void
ExplainCopyGeneric(const CopyStmt *stmt, Relation rel,
				   const CopyFormatOptions *opts, ExplainState *es)
{
	const char *label = stmt->is_from ? "Copy From" : "Copy To";

	ExplainOpenGroup("Query", NULL, true, es);
	ExplainOpenGroup(label, label, true, es);

	if (es->format == EXPLAIN_FORMAT_TEXT)
	{
		ExplainIndentText(es);
		if (es->verbose)
			appendStringInfo(es->str, "%s on %s.%s\n", label,
							 quote_identifier(get_namespace_name(RelationGetNamespace(rel))),
							 quote_identifier(RelationGetRelationName(rel)));
		else
			appendStringInfo(es->str, "%s on %s\n", label,
							 quote_identifier(RelationGetRelationName(rel)));
		es->indent++;
	}
	else
	{
		ExplainPropertyText("Relation Name",
							RelationGetRelationName(rel), es);
		if (es->verbose)
			ExplainPropertyText("Schema",
								get_namespace_name(RelationGetNamespace(rel)),
								es);
	}

	show_copy_properties(stmt, opts, es);

	if (es->format == EXPLAIN_FORMAT_TEXT)
		es->indent--;

	ExplainCloseGroup(label, label, true, es);
	ExplainCloseGroup("Query", NULL, true, es);
}

/*
 * ExplainPrintCopyInfo -
 *	  print the details of the COPY statement being explained within the
 *	  output of its source query's plan
 *
 * This is called back from ExplainOnePlan when explaining a query-based
 * COPY TO, inside the "Query" output group.
 */
void
ExplainPrintCopyInfo(const CopyStmt *copystmt, ExplainState *es)
{
	CopyFormatOptions opts = {0};	/* ProcessCopyOptions expects zeroes */
	ParseState *tmp_pstate = make_parsestate(NULL);

	/* Re-extract the options; this cannot fail, they were checked before */
	ProcessCopyOptions(tmp_pstate, &opts, copystmt->is_from,
					   copystmt->options);
	free_parsestate(tmp_pstate);

	ExplainOpenGroup("Copy", "Copy", true, es);

	if (es->format == EXPLAIN_FORMAT_TEXT)
	{
		ExplainIndentText(es);
		appendStringInfo(es->str, "%s\n",
						 copystmt->is_from ? "Copy From" : "Copy To");
		es->indent++;
	}

	show_copy_properties(copystmt, &opts, es);

	if (es->format == EXPLAIN_FORMAT_TEXT)
		es->indent--;

	ExplainCloseGroup("Copy", "Copy", true, es);
}

/*
 * show_copy_properties -
 *	  print the properties of a COPY statement that are common to all
 *	  EXPLAIN COPY output variants
 */
static void
show_copy_properties(const CopyStmt *stmt, const CopyFormatOptions *opts,
					 ExplainState *es)
{
	const char *format_name;

	switch (opts->format)
	{
		case COPY_FORMAT_TEXT:
			format_name = "text";
			break;
		case COPY_FORMAT_BINARY:
			format_name = "binary";
			break;
		case COPY_FORMAT_CSV:
			format_name = "csv";
			break;
		case COPY_FORMAT_JSON:
			format_name = "json";
			break;
		default:
			format_name = "???";
			break;
	}
	ExplainPropertyText("Format", format_name, es);

	if (stmt->filename == NULL)
		ExplainPropertyText(stmt->is_from ? "Source" : "Target",
							stmt->is_from ? "stdin" : "stdout", es);
	else if (stmt->is_program)
	{
		ExplainPropertyText(stmt->is_from ? "Source" : "Target",
							"program", es);
		ExplainPropertyText("Program", stmt->filename, es);
	}
	else
	{
		ExplainPropertyText(stmt->is_from ? "Source" : "Target",
							"file", es);
		ExplainPropertyText("File", stmt->filename, es);
	}

	if (opts->freeze)
		ExplainPropertyBool("Freeze", true, es);

	if (opts->on_error != COPY_ON_ERROR_STOP)
		ExplainPropertyText("On Error",
							opts->on_error == COPY_ON_ERROR_IGNORE ?
							"ignore" : "set_null", es);
}

/*
 * show_copy_trigger_stats -
 *	  print the per-trigger statistics collected by CopyFrom
 *
 * This mirrors the output of report_triggers() in explain.c, which cannot
 * be used directly because the executor state of the COPY has already been
 * destroyed by the time we get here.
 */
static void
show_copy_trigger_stats(const CopyFromInstrumentation *ci, ExplainState *es)
{
	ListCell   *lc;

	ExplainOpenGroup("Triggers", "Triggers", false, es);

	foreach(lc, ci->triggers)
	{
		CopyFromTriggerStats *stats = (CopyFromTriggerStats *) lfirst(lc);

		ExplainOpenGroup("Trigger", NULL, true, es);

		/*
		 * In text format, we avoid printing both the trigger name and the
		 * constraint name unless VERBOSE is specified.  In non-text formats
		 * we just print everything.
		 */
		if (es->format == EXPLAIN_FORMAT_TEXT)
		{
			if (es->verbose || stats->constraint_name == NULL)
				appendStringInfo(es->str, "Trigger %s", stats->trigger_name);
			else
				appendStringInfoString(es->str, "Trigger");
			if (stats->constraint_name)
				appendStringInfo(es->str, " for constraint %s",
								 stats->constraint_name);
			if (ci->show_relname)
				appendStringInfo(es->str, " on %s", stats->relation_name);
			if (es->timing)
				appendStringInfo(es->str, ": time=%.3f calls=%" PRId64 "\n",
								 INSTR_TIME_GET_MILLISEC(stats->total),
								 stats->firings);
			else
				appendStringInfo(es->str, ": calls=%" PRId64 "\n",
								 stats->firings);
		}
		else
		{
			ExplainPropertyText("Trigger Name", stats->trigger_name, es);
			if (stats->constraint_name)
				ExplainPropertyText("Constraint Name", stats->constraint_name,
									es);
			ExplainPropertyText("Relation", stats->relation_name, es);
			if (es->timing)
				ExplainPropertyFloat("Time", "ms",
									 INSTR_TIME_GET_MILLISEC(stats->total), 3,
									 es);
			ExplainPropertyInteger("Calls", NULL, stats->firings, es);
		}

		ExplainCloseGroup("Trigger", NULL, true, es);
	}

	ExplainCloseGroup("Triggers", "Triggers", false, es);
}
