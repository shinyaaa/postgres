/*-------------------------------------------------------------------------
 *
 * policy.c
 *	  Commands for manipulating policies.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * src/backend/commands/policy.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/genam.h"
#include "access/htup.h"
#include "access/htup_details.h"
#include "access/relation.h"
#include "access/table.h"
#include "access/xact.h"
#include "catalog/catalog.h"
#include "catalog/dependency.h"
#include "catalog/indexing.h"
#include "catalog/namespace.h"
#include "catalog/objectaccess.h"
#include "catalog/pg_authid.h"
#include "catalog/pg_policy.h"
#include "catalog/pg_type.h"
#include "commands/policy.h"
#include "miscadmin.h"
#include "nodes/pg_list.h"
#include "optimizer/optimizer.h"
#include "parser/parse_clause.h"
#include "parser/parse_coerce.h"
#include "parser/parse_collate.h"
#include "parser/parse_expr.h"
#include "parser/parse_node.h"
#include "parser/parse_relation.h"
#include "parser/parse_target.h"
#include "rewrite/rewriteManip.h"
#include "rewrite/rowsecurity.h"
#include "utils/acl.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/fmgroids.h"
#include "utils/inval.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/syscache.h"

static void RangeVarCallbackForPolicy(const RangeVar *rv,
									  Oid relid, Oid oldrelid, void *arg);
static char parse_policy_command(const char *cmd_name);
static Datum *policy_role_list_to_array(List *roles, int *num_roles);
static List *transform_policy_mask_list(ParseState *pstate,
										Relation target_table,
										List *raw_mask_list);
static void check_mask_conflicts(Relation pg_policy_rel,
								 Relation target_table,
								 Oid excluded_policy_oid,
								 char polcmd, ArrayType *role_ids,
								 List *mask_quals);
static void record_mask_dependencies(ObjectAddress *myself,
									 Oid target_relid,
									 List *rtable, List *mask_quals);

/*
 * Callback to RangeVarGetRelidExtended().
 *
 * Checks the following:
 *	- the relation specified is a table.
 *	- current user owns the table.
 *	- the table is not a system table.
 *
 * If any of these checks fails then an error is raised.
 */
static void
RangeVarCallbackForPolicy(const RangeVar *rv, Oid relid, Oid oldrelid,
						  void *arg)
{
	HeapTuple	tuple;
	Form_pg_class classform;
	char		relkind;

	tuple = SearchSysCache1(RELOID, ObjectIdGetDatum(relid));
	if (!HeapTupleIsValid(tuple))
		return;

	classform = (Form_pg_class) GETSTRUCT(tuple);
	relkind = classform->relkind;

	/* Must own relation. */
	if (!object_ownercheck(RelationRelationId, relid, GetUserId()))
		aclcheck_error(ACLCHECK_NOT_OWNER, get_relkind_objtype(get_rel_relkind(relid)), rv->relname);

	/* No system table modifications unless explicitly allowed. */
	if (!allowSystemTableMods && IsSystemClass(relid, classform))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("permission denied: \"%s\" is a system catalog",
						rv->relname)));

	/* Relation type MUST be a table. */
	if (relkind != RELKIND_RELATION && relkind != RELKIND_PARTITIONED_TABLE)
		ereport(ERROR,
				(errcode(ERRCODE_WRONG_OBJECT_TYPE),
				 errmsg("\"%s\" is not a table", rv->relname)));

	ReleaseSysCache(tuple);
}

/*
 * parse_policy_command -
 *	 helper function to convert full command strings to their char
 *	 representation.
 *
 * cmd_name - full string command name. Valid values are 'all', 'select',
 *			  'insert', 'update' and 'delete'.
 *
 */
static char
parse_policy_command(const char *cmd_name)
{
	char		polcmd;

	if (!cmd_name)
		elog(ERROR, "unrecognized policy command");

	if (strcmp(cmd_name, "all") == 0)
		polcmd = '*';
	else if (strcmp(cmd_name, "select") == 0)
		polcmd = ACL_SELECT_CHR;
	else if (strcmp(cmd_name, "insert") == 0)
		polcmd = ACL_INSERT_CHR;
	else if (strcmp(cmd_name, "update") == 0)
		polcmd = ACL_UPDATE_CHR;
	else if (strcmp(cmd_name, "delete") == 0)
		polcmd = ACL_DELETE_CHR;
	else
		elog(ERROR, "unrecognized policy command");

	return polcmd;
}

/*
 * policy_role_list_to_array
 *	 helper function to convert a list of RoleSpecs to an array of
 *	 role id Datums.
 */
static Datum *
policy_role_list_to_array(List *roles, int *num_roles)
{
	Datum	   *role_oids;
	ListCell   *cell;
	int			i = 0;

	/* Handle no roles being passed in as being for public */
	if (roles == NIL)
	{
		*num_roles = 1;
		role_oids = palloc_array(Datum, *num_roles);
		role_oids[0] = ObjectIdGetDatum(ACL_ID_PUBLIC);

		return role_oids;
	}

	*num_roles = list_length(roles);
	role_oids = (Datum *) palloc(*num_roles * sizeof(Datum));

	foreach(cell, roles)
	{
		RoleSpec   *spec = lfirst(cell);

		/*
		 * PUBLIC covers all roles, so it only makes sense alone.
		 */
		if (spec->roletype == ROLESPEC_PUBLIC)
		{
			if (*num_roles != 1)
			{
				ereport(WARNING,
						(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
						 errmsg("ignoring specified roles other than PUBLIC"),
						 errhint("All roles are members of the PUBLIC role.")));
				*num_roles = 1;
			}
			role_oids[0] = ObjectIdGetDatum(ACL_ID_PUBLIC);

			return role_oids;
		}
		else
			role_oids[i++] =
				ObjectIdGetDatum(get_rolespec_oid(spec, false));
	}

	return role_oids;
}

/*
 * transform_policy_mask_list
 *		Parse-analyze the WITH MASK column list for a CREATE/ALTER POLICY.
 *
 * pstate must already have the target relation set up as its single RTE
 * (see caller sites in CreatePolicy/AlterPolicy).  raw_mask_list is a list of
 * PolicyColumnMaskItem nodes with colname set and expr in raw form.
 *
 * Returns a fully-resolved List of PolicyColumnMaskItem nodes suitable for
 * serialization into pg_policy.polmask.
 *
 * Errors on: missing/duplicate columns, system columns, generated columns,
 * type mismatches that cannot be coerced, and non-leakproof expressions.
 */
static List *
transform_policy_mask_list(ParseState *pstate,
						   Relation target_table,
						   List *raw_mask_list)
{
	List	   *result = NIL;
	Bitmapset  *seen = NULL;
	ListCell   *lc;
	Oid			relid = RelationGetRelid(target_table);

	foreach(lc, raw_mask_list)
	{
		PolicyColumnMaskItem *raw = lfirst_node(PolicyColumnMaskItem, lc);
		PolicyColumnMaskItem *resolved;
		AttrNumber	attnum;
		Oid			atttypid;
		int32		atttypmod;
		Oid			attcollation;
		Node	   *expr;
		Oid			exprtype;

		attnum = get_attnum(relid, raw->colname);
		if (attnum == InvalidAttrNumber)
			ereport(ERROR,
					(errcode(ERRCODE_UNDEFINED_COLUMN),
					 errmsg("column \"%s\" of relation \"%s\" does not exist",
							raw->colname,
							RelationGetRelationName(target_table)),
					 parser_errposition(pstate, raw->location)));

		if (attnum <= 0)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("cannot mask system column \"%s\"",
							raw->colname),
					 parser_errposition(pstate, raw->location)));

		if (get_attgenerated(relid, attnum) != '\0')
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("cannot mask generated column \"%s\"",
							raw->colname),
					 parser_errposition(pstate, raw->location)));

		if (bms_is_member(attnum, seen))
			ereport(ERROR,
					(errcode(ERRCODE_DUPLICATE_COLUMN),
					 errmsg("column \"%s\" specified more than once in WITH MASK",
							raw->colname),
					 parser_errposition(pstate, raw->location)));
		seen = bms_add_member(seen, attnum);

		get_atttypetypmodcoll(relid, attnum, &atttypid, &atttypmod, &attcollation);

		expr = transformExpr(pstate, raw->expr, EXPR_KIND_POLICY);
		exprtype = exprType(expr);

		expr = coerce_to_target_type(pstate, expr, exprtype,
									 atttypid, atttypmod,
									 COERCION_ASSIGNMENT,
									 COERCE_IMPLICIT_CAST,
									 -1);
		if (expr == NULL)
			ereport(ERROR,
					(errcode(ERRCODE_DATATYPE_MISMATCH),
					 errmsg("mask expression for column \"%s\" is of type %s"
							" but column has type %s",
							raw->colname,
							format_type_be(exprtype),
							format_type_be(atttypid)),
					 errhint("You will need to rewrite or cast the expression."),
					 parser_errposition(pstate, exprLocation(raw->expr))));

		assign_expr_collations(pstate, expr);

		if (contain_mutable_functions(expr))
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_OBJECT_DEFINITION),
					 errmsg("mask expression for column \"%s\" must not contain mutable functions",
							raw->colname),
					 parser_errposition(pstate, exprLocation(raw->expr))));

		/*
		 * Non-leakproof functions may leak information about the real value
		 * through error messages if the mask expression references the masked
		 * column.  This is the same trade-off Snowflake and Oracle accept, so
		 * we emit a WARNING rather than a hard error and let the DBA decide.
		 */
		if (contain_leaked_vars(expr))
			ereport(WARNING,
					(errcode(ERRCODE_WARNING),
					 errmsg("mask expression for column \"%s\" is not leakproof",
							raw->colname),
					 errdetail("Non-leakproof functions may reveal information about the masked value through error messages."),
					 parser_errposition(pstate, exprLocation(raw->expr))));

		resolved = makeNode(PolicyColumnMaskItem);
		resolved->colname = pstrdup(raw->colname);
		resolved->attnum = attnum;
		resolved->expr = expr;
		resolved->location = -1;

		result = lappend(result, resolved);
	}

	bms_free(seen);
	return result;
}

/*
 * check_mask_conflicts
 *		Enforce the "one policy masks each column per applicable role" rule.
 *
 * For every attnum appearing in mask_quals, scan pg_policy for other policies
 * on the same relation whose polcmd overlaps with polcmd and whose role set
 * intersects role_ids; if any such policy declares a mask on the same column,
 * raise an error at DDL time.  This prevents dynamic runtime conflicts that
 * could otherwise leak information through error text.
 *
 * excluded_policy_oid is the OID of the policy currently being altered; pass
 * InvalidOid during CREATE POLICY.
 */
static void
check_mask_conflicts(Relation pg_policy_rel,
					 Relation target_table,
					 Oid excluded_policy_oid,
					 char polcmd, ArrayType *role_ids,
					 List *mask_quals)
{
	ScanKeyData skey;
	SysScanDesc sscan;
	HeapTuple	tuple;
	Bitmapset  *my_attnums = NULL;
	ListCell   *lc;

	if (mask_quals == NIL)
		return;

	foreach(lc, mask_quals)
	{
		PolicyColumnMaskItem *m = lfirst_node(PolicyColumnMaskItem, lc);

		my_attnums = bms_add_member(my_attnums, m->attnum);
	}

	ScanKeyInit(&skey,
				Anum_pg_policy_polrelid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(RelationGetRelid(target_table)));

	sscan = systable_beginscan(pg_policy_rel, PolicyPolrelidPolnameIndexId,
							   true, NULL, 1, &skey);

	while (HeapTupleIsValid(tuple = systable_getnext(sscan)))
	{
		Form_pg_policy other = (Form_pg_policy) GETSTRUCT(tuple);
		Datum		datum;
		bool		isnull;
		char	   *str;
		List	   *other_mask;
		ListCell   *lc2;
		bool		cmd_overlap;
		bool		role_overlap;
		ArrayType  *other_roles;

		if (other->oid == excluded_policy_oid)
			continue;

		/* polcmd overlaps if either side is '*' or they match. */
		cmd_overlap = (other->polcmd == '*' || polcmd == '*'
					   || other->polcmd == polcmd);
		if (!cmd_overlap)
			continue;

		datum = heap_getattr(tuple, Anum_pg_policy_polmask,
							 RelationGetDescr(pg_policy_rel), &isnull);
		if (isnull)
			continue;

		datum = heap_getattr(tuple, Anum_pg_policy_polroles,
							 RelationGetDescr(pg_policy_rel), &isnull);
		if (isnull)
			continue;

		other_roles = DatumGetArrayTypeP(datum);
		role_overlap = false;
		{
			Oid		   *my_role_ids;
			Oid		   *other_role_ids;
			int			my_nr;
			int			other_nr;
			int			i,
						j;

			my_role_ids = (Oid *) ARR_DATA_PTR(role_ids);
			my_nr = ARR_DIMS(role_ids)[0];
			other_role_ids = (Oid *) ARR_DATA_PTR(other_roles);
			other_nr = ARR_DIMS(other_roles)[0];

			for (i = 0; i < my_nr && !role_overlap; i++)
			{
				if (my_role_ids[i] == ACL_ID_PUBLIC)
				{
					role_overlap = true;
					break;
				}
				for (j = 0; j < other_nr; j++)
				{
					if (other_role_ids[j] == ACL_ID_PUBLIC
						|| other_role_ids[j] == my_role_ids[i])
					{
						role_overlap = true;
						break;
					}
				}
			}
		}
		if (!role_overlap)
			continue;

		datum = heap_getattr(tuple, Anum_pg_policy_polmask,
							 RelationGetDescr(pg_policy_rel), &isnull);
		Assert(!isnull);
		str = TextDatumGetCString(datum);
		other_mask = (List *) stringToNode(str);
		pfree(str);

		foreach(lc2, other_mask)
		{
			PolicyColumnMaskItem *m = lfirst_node(PolicyColumnMaskItem, lc2);

			if (bms_is_member(m->attnum, my_attnums))
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_OBJECT_DEFINITION),
						 errmsg("column \"%s\" of relation \"%s\" is already masked by policy \"%s\"",
								m->colname,
								RelationGetRelationName(target_table),
								NameStr(other->polname)),
						 errhint("Each column may be masked by at most one applicable policy.")));
		}
	}

	systable_endscan(sscan);
	bms_free(my_attnums);
}

/*
 * record_mask_dependencies
 *		Record NORMAL dependencies of the policy on the mask expressions and
 *		on each masked column, so that DROP COLUMN cascades to the policy.
 */
static void
record_mask_dependencies(ObjectAddress *myself, Oid target_relid,
						 List *rtable, List *mask_quals)
{
	ListCell   *lc;

	foreach(lc, mask_quals)
	{
		PolicyColumnMaskItem *m = lfirst_node(PolicyColumnMaskItem, lc);
		ObjectAddress column;

		recordDependencyOnExpr(myself, m->expr, rtable, DEPENDENCY_NORMAL);

		column.classId = RelationRelationId;
		column.objectId = target_relid;
		column.objectSubId = m->attnum;
		recordDependencyOn(myself, &column, DEPENDENCY_NORMAL);
	}
}

/*
 * Load row security policy from the catalog, and store it in
 * the relation's relcache entry.
 *
 * Note that caller should have verified that pg_class.relrowsecurity
 * is true for this relation.
 */
void
RelationBuildRowSecurity(Relation relation)
{
	MemoryContext rscxt;
	MemoryContext oldcxt = CurrentMemoryContext;
	RowSecurityDesc *rsdesc;
	Relation	catalog;
	ScanKeyData skey;
	SysScanDesc sscan;
	HeapTuple	tuple;

	/*
	 * Create a memory context to hold everything associated with this
	 * relation's row security policy.  This makes it easy to clean up during
	 * a relcache flush.  However, to cover the possibility of an error
	 * partway through, we don't make the context long-lived till we're done.
	 */
	rscxt = AllocSetContextCreate(CurrentMemoryContext,
								  "row security descriptor",
								  ALLOCSET_SMALL_SIZES);
	MemoryContextCopyAndSetIdentifier(rscxt,
									  RelationGetRelationName(relation));

	rsdesc = MemoryContextAllocZero(rscxt, sizeof(RowSecurityDesc));
	rsdesc->rscxt = rscxt;

	/*
	 * Now scan pg_policy for RLS policies associated with this relation.
	 * Because we use the index on (polrelid, polname), we should consistently
	 * visit the rel's policies in name order, at least when system indexes
	 * aren't disabled.  This simplifies equalRSDesc().
	 */
	catalog = table_open(PolicyRelationId, AccessShareLock);

	ScanKeyInit(&skey,
				Anum_pg_policy_polrelid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(RelationGetRelid(relation)));

	sscan = systable_beginscan(catalog, PolicyPolrelidPolnameIndexId, true,
							   NULL, 1, &skey);

	while (HeapTupleIsValid(tuple = systable_getnext(sscan)))
	{
		Form_pg_policy policy_form = (Form_pg_policy) GETSTRUCT(tuple);
		RowSecurityPolicy *policy;
		Datum		datum;
		bool		isnull;
		char	   *str_value;

		policy = MemoryContextAllocZero(rscxt, sizeof(RowSecurityPolicy));

		/*
		 * Note: we must be sure that pass-by-reference data gets copied into
		 * rscxt.  We avoid making that context current over wider spans than
		 * we have to, though.
		 */

		/* Get policy command */
		policy->polcmd = policy_form->polcmd;

		/* Get policy, permissive or restrictive */
		policy->permissive = policy_form->polpermissive;

		/* Get policy name */
		policy->policy_name =
			MemoryContextStrdup(rscxt, NameStr(policy_form->polname));

		/* Get policy roles */
		datum = heap_getattr(tuple, Anum_pg_policy_polroles,
							 RelationGetDescr(catalog), &isnull);
		/* shouldn't be null, but let's check for luck */
		if (isnull)
			elog(ERROR, "unexpected null value in pg_policy.polroles");
		MemoryContextSwitchTo(rscxt);
		policy->roles = DatumGetArrayTypePCopy(datum);
		MemoryContextSwitchTo(oldcxt);

		/* Get policy qual */
		datum = heap_getattr(tuple, Anum_pg_policy_polqual,
							 RelationGetDescr(catalog), &isnull);
		if (!isnull)
		{
			str_value = TextDatumGetCString(datum);
			MemoryContextSwitchTo(rscxt);
			policy->qual = (Expr *) stringToNode(str_value);
			MemoryContextSwitchTo(oldcxt);
			pfree(str_value);
		}
		else
			policy->qual = NULL;

		/* Get WITH CHECK qual */
		datum = heap_getattr(tuple, Anum_pg_policy_polwithcheck,
							 RelationGetDescr(catalog), &isnull);
		if (!isnull)
		{
			str_value = TextDatumGetCString(datum);
			MemoryContextSwitchTo(rscxt);
			policy->with_check_qual = (Expr *) stringToNode(str_value);
			MemoryContextSwitchTo(oldcxt);
			pfree(str_value);
		}
		else
			policy->with_check_qual = NULL;

		/* Get column mask list */
		datum = heap_getattr(tuple, Anum_pg_policy_polmask,
							 RelationGetDescr(catalog), &isnull);
		if (!isnull)
		{
			str_value = TextDatumGetCString(datum);
			MemoryContextSwitchTo(rscxt);
			policy->mask_quals = (List *) stringToNode(str_value);
			MemoryContextSwitchTo(oldcxt);
			pfree(str_value);
		}
		else
			policy->mask_quals = NIL;

		/* We want to cache whether there are SubLinks in these expressions */
		policy->hassublinks = checkExprHasSubLink((Node *) policy->qual) ||
			checkExprHasSubLink((Node *) policy->with_check_qual);

		/*
		 * Add this object to list.  For historical reasons, the list is built
		 * in reverse order.
		 */
		MemoryContextSwitchTo(rscxt);
		rsdesc->policies = lcons(policy, rsdesc->policies);
		MemoryContextSwitchTo(oldcxt);
	}

	systable_endscan(sscan);
	table_close(catalog, AccessShareLock);

	/*
	 * Success.  Reparent the descriptor's memory context under
	 * CacheMemoryContext so that it will live indefinitely, then attach the
	 * policy descriptor to the relcache entry.
	 */
	MemoryContextSetParent(rscxt, CacheMemoryContext);

	relation->rd_rsdesc = rsdesc;
}

/*
 * RemovePolicyById -
 *	 remove a policy by its OID.  If a policy does not exist with the provided
 *	 oid, then an error is raised.
 *
 * policy_id - the oid of the policy.
 */
void
RemovePolicyById(Oid policy_id)
{
	Relation	pg_policy_rel;
	SysScanDesc sscan;
	ScanKeyData skey[1];
	HeapTuple	tuple;
	Oid			relid;
	Relation	rel;

	pg_policy_rel = table_open(PolicyRelationId, RowExclusiveLock);

	/*
	 * Find the policy to delete.
	 */
	ScanKeyInit(&skey[0],
				Anum_pg_policy_oid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(policy_id));

	sscan = systable_beginscan(pg_policy_rel, PolicyOidIndexId, true,
							   NULL, 1, skey);

	tuple = systable_getnext(sscan);

	/* If the policy exists, then remove it, otherwise raise an error. */
	if (!HeapTupleIsValid(tuple))
		elog(ERROR, "could not find tuple for policy %u", policy_id);

	/*
	 * Open and exclusive-lock the relation the policy belongs to.  (We need
	 * exclusive lock to lock out queries that might otherwise depend on the
	 * set of policies the rel has; furthermore we've got to hold the lock
	 * till commit.)
	 */
	relid = ((Form_pg_policy) GETSTRUCT(tuple))->polrelid;

	rel = table_open(relid, AccessExclusiveLock);
	if (rel->rd_rel->relkind != RELKIND_RELATION &&
		rel->rd_rel->relkind != RELKIND_PARTITIONED_TABLE)
		ereport(ERROR,
				(errcode(ERRCODE_WRONG_OBJECT_TYPE),
				 errmsg("\"%s\" is not a table",
						RelationGetRelationName(rel))));

	if (!allowSystemTableMods && IsSystemRelation(rel))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("permission denied: \"%s\" is a system catalog",
						RelationGetRelationName(rel))));

	CatalogTupleDelete(pg_policy_rel, &tuple->t_self);

	systable_endscan(sscan);

	/*
	 * Note that, unlike some of the other flags in pg_class, relrowsecurity
	 * is not just an indication of if policies exist.  When relrowsecurity is
	 * set by a user, then all access to the relation must be through a
	 * policy.  If no policy is defined for the relation then a default-deny
	 * policy is created and all records are filtered (except for queries from
	 * the owner).
	 */
	CacheInvalidateRelcache(rel);

	table_close(rel, NoLock);

	/* Clean up */
	table_close(pg_policy_rel, RowExclusiveLock);
}

/*
 * RemoveRoleFromObjectPolicy -
 *	 remove a role from a policy's applicable-roles list.
 *
 * Returns true if the role was successfully removed from the policy.
 * Returns false if the role was not removed because it would have left
 * polroles empty (which is disallowed, though perhaps it should not be).
 * On false return, the caller should instead drop the policy altogether.
 *
 * roleid - the oid of the role to remove
 * classid - should always be PolicyRelationId
 * policy_id - the oid of the policy.
 */
bool
RemoveRoleFromObjectPolicy(Oid roleid, Oid classid, Oid policy_id)
{
	Relation	pg_policy_rel;
	SysScanDesc sscan;
	ScanKeyData skey[1];
	HeapTuple	tuple;
	Oid			relid;
	ArrayType  *policy_roles;
	Datum		roles_datum;
	Oid		   *roles;
	int			num_roles;
	Datum	   *role_oids;
	bool		attr_isnull;
	bool		keep_policy = true;
	int			i,
				j;

	Assert(classid == PolicyRelationId);

	pg_policy_rel = table_open(PolicyRelationId, RowExclusiveLock);

	/*
	 * Find the policy to update.
	 */
	ScanKeyInit(&skey[0],
				Anum_pg_policy_oid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(policy_id));

	sscan = systable_beginscan(pg_policy_rel, PolicyOidIndexId, true,
							   NULL, 1, skey);

	tuple = systable_getnext(sscan);

	/* Raise an error if we don't find the policy. */
	if (!HeapTupleIsValid(tuple))
		elog(ERROR, "could not find tuple for policy %u", policy_id);

	/* Identify rel the policy belongs to */
	relid = ((Form_pg_policy) GETSTRUCT(tuple))->polrelid;

	/* Get the current set of roles */
	roles_datum = heap_getattr(tuple,
							   Anum_pg_policy_polroles,
							   RelationGetDescr(pg_policy_rel),
							   &attr_isnull);

	Assert(!attr_isnull);

	policy_roles = DatumGetArrayTypePCopy(roles_datum);
	roles = (Oid *) ARR_DATA_PTR(policy_roles);
	num_roles = ARR_DIMS(policy_roles)[0];

	/*
	 * Rebuild the polroles array, without any mentions of the target role.
	 * Ordinarily there'd be exactly one, but we must cope with duplicate
	 * mentions, since CREATE/ALTER POLICY historically have allowed that.
	 */
	role_oids = palloc_array(Datum, num_roles);
	for (i = 0, j = 0; i < num_roles; i++)
	{
		if (roles[i] != roleid)
			role_oids[j++] = ObjectIdGetDatum(roles[i]);
	}
	num_roles = j;

	/* If any roles remain, update the policy entry. */
	if (num_roles > 0)
	{
		ArrayType  *role_ids;
		Datum		values[Natts_pg_policy];
		bool		isnull[Natts_pg_policy];
		bool		replaces[Natts_pg_policy];
		HeapTuple	new_tuple;
		HeapTuple	reltup;
		ObjectAddress target;
		ObjectAddress myself;

		/* zero-clear */
		memset(values, 0, sizeof(values));
		memset(replaces, 0, sizeof(replaces));
		memset(isnull, 0, sizeof(isnull));

		/* This is the array for the new tuple */
		role_ids = construct_array_builtin(role_oids, num_roles, OIDOID);

		replaces[Anum_pg_policy_polroles - 1] = true;
		values[Anum_pg_policy_polroles - 1] = PointerGetDatum(role_ids);

		new_tuple = heap_modify_tuple(tuple,
									  RelationGetDescr(pg_policy_rel),
									  values, isnull, replaces);
		CatalogTupleUpdate(pg_policy_rel, &new_tuple->t_self, new_tuple);

		/* Remove all the old shared dependencies (roles) */
		deleteSharedDependencyRecordsFor(PolicyRelationId, policy_id, 0);

		/* Record the new shared dependencies (roles) */
		myself.classId = PolicyRelationId;
		myself.objectId = policy_id;
		myself.objectSubId = 0;

		target.classId = AuthIdRelationId;
		target.objectSubId = 0;
		for (i = 0; i < num_roles; i++)
		{
			target.objectId = DatumGetObjectId(role_oids[i]);
			/* no need for dependency on the public role */
			if (target.objectId != ACL_ID_PUBLIC)
				recordSharedDependencyOn(&myself, &target,
										 SHARED_DEPENDENCY_POLICY);
		}

		InvokeObjectPostAlterHook(PolicyRelationId, policy_id, 0);

		heap_freetuple(new_tuple);

		/* Make updates visible */
		CommandCounterIncrement();

		/*
		 * Invalidate relcache entry for rel the policy belongs to, to force
		 * redoing any dependent plans.  In case of a race condition where the
		 * rel was just dropped, we need do nothing.
		 */
		reltup = SearchSysCache1(RELOID, ObjectIdGetDatum(relid));
		if (HeapTupleIsValid(reltup))
		{
			CacheInvalidateRelcacheByTuple(reltup);
			ReleaseSysCache(reltup);
		}
	}
	else
	{
		/* No roles would remain, so drop the policy instead. */
		keep_policy = false;
	}

	/* Clean up. */
	systable_endscan(sscan);

	table_close(pg_policy_rel, RowExclusiveLock);

	return keep_policy;
}

/*
 * CreatePolicy -
 *	 handles the execution of the CREATE POLICY command.
 *
 * stmt - the CreatePolicyStmt that describes the policy to create.
 */
ObjectAddress
CreatePolicy(CreatePolicyStmt *stmt)
{
	Relation	pg_policy_rel;
	Oid			policy_id;
	Relation	target_table;
	Oid			table_id;
	char		polcmd;
	Datum	   *role_oids;
	int			nitems = 0;
	ArrayType  *role_ids;
	ParseState *qual_pstate;
	ParseState *with_check_pstate;
	ParseNamespaceItem *nsitem;
	Node	   *qual;
	Node	   *with_check_qual;
	List	   *mask_quals;
	ScanKeyData skey[2];
	SysScanDesc sscan;
	HeapTuple	policy_tuple;
	Datum		values[Natts_pg_policy];
	bool		isnull[Natts_pg_policy];
	ObjectAddress target;
	ObjectAddress myself;
	int			i;

	/* Parse command */
	polcmd = parse_policy_command(stmt->cmd_name);

	/*
	 * If the command is SELECT or DELETE then WITH CHECK should be NULL.
	 */
	if ((polcmd == ACL_SELECT_CHR || polcmd == ACL_DELETE_CHR)
		&& stmt->with_check != NULL)
		ereport(ERROR,
				(errcode(ERRCODE_SYNTAX_ERROR),
				 errmsg("WITH CHECK cannot be applied to SELECT or DELETE")));

	/*
	 * If the command is INSERT then WITH CHECK should be the only expression
	 * provided.
	 */
	if (polcmd == ACL_INSERT_CHR && stmt->qual != NULL)
		ereport(ERROR,
				(errcode(ERRCODE_SYNTAX_ERROR),
				 errmsg("only WITH CHECK expression allowed for INSERT")));

	/*
	 * WITH MASK is only meaningful for read paths (SELECT / ALL).  Rejecting
	 * mask on write-only commands avoids surprising semantics on INSERT,
	 * UPDATE (SET side) and DELETE where masking is not applied.
	 */
	if (stmt->with_mask != NIL &&
		polcmd != ACL_SELECT_CHR && polcmd != '*')
		ereport(ERROR,
				(errcode(ERRCODE_SYNTAX_ERROR),
				 errmsg("WITH MASK can only be used with FOR SELECT or FOR ALL policies")));

	/* Collect role ids */
	role_oids = policy_role_list_to_array(stmt->roles, &nitems);
	role_ids = construct_array_builtin(role_oids, nitems, OIDOID);

	/* Parse the supplied clause */
	qual_pstate = make_parsestate(NULL);
	with_check_pstate = make_parsestate(NULL);

	/* zero-clear */
	memset(values, 0, sizeof(values));
	memset(isnull, 0, sizeof(isnull));

	/* Get id of table.  Also handles permissions checks. */
	table_id = RangeVarGetRelidExtended(stmt->table, AccessExclusiveLock,
										0,
										RangeVarCallbackForPolicy,
										stmt);

	/* Open target_table to build quals. No additional lock is necessary. */
	target_table = relation_open(table_id, NoLock);

	/* Add for the regular security quals */
	nsitem = addRangeTableEntryForRelation(qual_pstate, target_table,
										   AccessShareLock,
										   NULL, false, false);
	addNSItemToQuery(qual_pstate, nsitem, false, true, true);

	/* Add for the with-check quals */
	nsitem = addRangeTableEntryForRelation(with_check_pstate, target_table,
										   AccessShareLock,
										   NULL, false, false);
	addNSItemToQuery(with_check_pstate, nsitem, false, true, true);

	qual = transformWhereClause(qual_pstate,
								stmt->qual,
								EXPR_KIND_POLICY,
								"POLICY");

	with_check_qual = transformWhereClause(with_check_pstate,
										   stmt->with_check,
										   EXPR_KIND_POLICY,
										   "POLICY");

	/* Fix up collation information */
	assign_expr_collations(qual_pstate, qual);
	assign_expr_collations(with_check_pstate, with_check_qual);

	/* Transform WITH MASK column list, if any. */
	mask_quals = transform_policy_mask_list(qual_pstate, target_table,
											stmt->with_mask);

	/* Open pg_policy catalog */
	pg_policy_rel = table_open(PolicyRelationId, RowExclusiveLock);

	/*
	 * Reject conflict with an existing policy that already masks any of the
	 * requested columns for an overlapping polcmd/role set.  Doing this now
	 * (before we insert the tuple) means DDL fails cleanly instead of
	 * producing runtime errors when the policy is later evaluated.
	 */
	check_mask_conflicts(pg_policy_rel, target_table, InvalidOid,
						 polcmd, role_ids, mask_quals);

	/* Set key - policy's relation id. */
	ScanKeyInit(&skey[0],
				Anum_pg_policy_polrelid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(table_id));

	/* Set key - policy's name. */
	ScanKeyInit(&skey[1],
				Anum_pg_policy_polname,
				BTEqualStrategyNumber, F_NAMEEQ,
				CStringGetDatum(stmt->policy_name));

	sscan = systable_beginscan(pg_policy_rel,
							   PolicyPolrelidPolnameIndexId, true, NULL, 2,
							   skey);

	policy_tuple = systable_getnext(sscan);

	/* Complain if the policy name already exists for the table */
	if (HeapTupleIsValid(policy_tuple))
		ereport(ERROR,
				(errcode(ERRCODE_DUPLICATE_OBJECT),
				 errmsg("policy \"%s\" for table \"%s\" already exists",
						stmt->policy_name, RelationGetRelationName(target_table))));

	policy_id = GetNewOidWithIndex(pg_policy_rel, PolicyOidIndexId,
								   Anum_pg_policy_oid);
	values[Anum_pg_policy_oid - 1] = ObjectIdGetDatum(policy_id);
	values[Anum_pg_policy_polrelid - 1] = ObjectIdGetDatum(table_id);
	values[Anum_pg_policy_polname - 1] = DirectFunctionCall1(namein,
															 CStringGetDatum(stmt->policy_name));
	values[Anum_pg_policy_polcmd - 1] = CharGetDatum(polcmd);
	values[Anum_pg_policy_polpermissive - 1] = BoolGetDatum(stmt->permissive);
	values[Anum_pg_policy_polroles - 1] = PointerGetDatum(role_ids);

	/* Add qual if present. */
	if (qual)
		values[Anum_pg_policy_polqual - 1] = CStringGetTextDatum(nodeToString(qual));
	else
		isnull[Anum_pg_policy_polqual - 1] = true;

	/* Add WITH CHECK qual if present */
	if (with_check_qual)
		values[Anum_pg_policy_polwithcheck - 1] = CStringGetTextDatum(nodeToString(with_check_qual));
	else
		isnull[Anum_pg_policy_polwithcheck - 1] = true;

	/* Add WITH MASK list if present */
	if (mask_quals != NIL)
		values[Anum_pg_policy_polmask - 1] =
			CStringGetTextDatum(nodeToString(mask_quals));
	else
		isnull[Anum_pg_policy_polmask - 1] = true;

	policy_tuple = heap_form_tuple(RelationGetDescr(pg_policy_rel), values,
								   isnull);

	CatalogTupleInsert(pg_policy_rel, policy_tuple);

	/* Record Dependencies */
	target.classId = RelationRelationId;
	target.objectId = table_id;
	target.objectSubId = 0;

	myself.classId = PolicyRelationId;
	myself.objectId = policy_id;
	myself.objectSubId = 0;

	recordDependencyOn(&myself, &target, DEPENDENCY_AUTO);

	recordDependencyOnExpr(&myself, qual, qual_pstate->p_rtable,
						   DEPENDENCY_NORMAL);

	recordDependencyOnExpr(&myself, with_check_qual,
						   with_check_pstate->p_rtable, DEPENDENCY_NORMAL);

	record_mask_dependencies(&myself, table_id, qual_pstate->p_rtable,
							 mask_quals);

	/* Register role dependencies */
	target.classId = AuthIdRelationId;
	target.objectSubId = 0;
	for (i = 0; i < nitems; i++)
	{
		target.objectId = DatumGetObjectId(role_oids[i]);
		/* no dependency if public */
		if (target.objectId != ACL_ID_PUBLIC)
			recordSharedDependencyOn(&myself, &target,
									 SHARED_DEPENDENCY_POLICY);
	}

	InvokeObjectPostCreateHook(PolicyRelationId, policy_id, 0);

	/* Invalidate Relation Cache */
	CacheInvalidateRelcache(target_table);

	/* Clean up. */
	heap_freetuple(policy_tuple);
	free_parsestate(qual_pstate);
	free_parsestate(with_check_pstate);
	systable_endscan(sscan);
	relation_close(target_table, NoLock);
	table_close(pg_policy_rel, RowExclusiveLock);

	return myself;
}

/*
 * AlterPolicy -
 *	 handles the execution of the ALTER POLICY command.
 *
 * stmt - the AlterPolicyStmt that describes the policy and how to alter it.
 */
ObjectAddress
AlterPolicy(AlterPolicyStmt *stmt)
{
	Relation	pg_policy_rel;
	Oid			policy_id;
	Relation	target_table;
	Oid			table_id;
	Datum	   *role_oids = NULL;
	int			nitems = 0;
	ArrayType  *role_ids = NULL;
	List	   *qual_parse_rtable = NIL;
	List	   *with_check_parse_rtable = NIL;
	List	   *mask_parse_rtable = NIL;
	Node	   *qual = NULL;
	Node	   *with_check_qual = NULL;
	List	   *mask_quals = NIL;
	bool		mask_changed = false;
	ArrayType  *effective_role_ids = NULL;
	ScanKeyData skey[2];
	SysScanDesc sscan;
	HeapTuple	policy_tuple;
	HeapTuple	new_tuple;
	Datum		values[Natts_pg_policy];
	bool		isnull[Natts_pg_policy];
	bool		replaces[Natts_pg_policy];
	ObjectAddress target;
	ObjectAddress myself;
	Datum		polcmd_datum;
	char		polcmd;
	bool		polcmd_isnull;
	int			i;

	/* Parse role_ids */
	if (stmt->roles != NULL)
	{
		role_oids = policy_role_list_to_array(stmt->roles, &nitems);
		role_ids = construct_array_builtin(role_oids, nitems, OIDOID);
	}

	/* Get id of table.  Also handles permissions checks. */
	table_id = RangeVarGetRelidExtended(stmt->table, AccessExclusiveLock,
										0,
										RangeVarCallbackForPolicy,
										stmt);

	target_table = relation_open(table_id, NoLock);

	/* Parse the using policy clause */
	if (stmt->qual)
	{
		ParseNamespaceItem *nsitem;
		ParseState *qual_pstate = make_parsestate(NULL);

		nsitem = addRangeTableEntryForRelation(qual_pstate, target_table,
											   AccessShareLock,
											   NULL, false, false);

		addNSItemToQuery(qual_pstate, nsitem, false, true, true);

		qual = transformWhereClause(qual_pstate, stmt->qual,
									EXPR_KIND_POLICY,
									"POLICY");

		/* Fix up collation information */
		assign_expr_collations(qual_pstate, qual);

		qual_parse_rtable = qual_pstate->p_rtable;
		free_parsestate(qual_pstate);
	}

	/* Parse the with-check policy clause */
	if (stmt->with_check)
	{
		ParseNamespaceItem *nsitem;
		ParseState *with_check_pstate = make_parsestate(NULL);

		nsitem = addRangeTableEntryForRelation(with_check_pstate, target_table,
											   AccessShareLock,
											   NULL, false, false);

		addNSItemToQuery(with_check_pstate, nsitem, false, true, true);

		with_check_qual = transformWhereClause(with_check_pstate,
											   stmt->with_check,
											   EXPR_KIND_POLICY,
											   "POLICY");

		/* Fix up collation information */
		assign_expr_collations(with_check_pstate, with_check_qual);

		with_check_parse_rtable = with_check_pstate->p_rtable;
		free_parsestate(with_check_pstate);
	}

	/* zero-clear */
	memset(values, 0, sizeof(values));
	memset(replaces, 0, sizeof(replaces));
	memset(isnull, 0, sizeof(isnull));

	/* Find policy to update. */
	pg_policy_rel = table_open(PolicyRelationId, RowExclusiveLock);

	/* Set key - policy's relation id. */
	ScanKeyInit(&skey[0],
				Anum_pg_policy_polrelid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(table_id));

	/* Set key - policy's name. */
	ScanKeyInit(&skey[1],
				Anum_pg_policy_polname,
				BTEqualStrategyNumber, F_NAMEEQ,
				CStringGetDatum(stmt->policy_name));

	sscan = systable_beginscan(pg_policy_rel,
							   PolicyPolrelidPolnameIndexId, true, NULL, 2,
							   skey);

	policy_tuple = systable_getnext(sscan);

	/* Check that the policy is found, raise an error if not. */
	if (!HeapTupleIsValid(policy_tuple))
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_OBJECT),
				 errmsg("policy \"%s\" for table \"%s\" does not exist",
						stmt->policy_name,
						RelationGetRelationName(target_table))));

	/* Get policy command */
	polcmd_datum = heap_getattr(policy_tuple, Anum_pg_policy_polcmd,
								RelationGetDescr(pg_policy_rel),
								&polcmd_isnull);
	Assert(!polcmd_isnull);
	polcmd = DatumGetChar(polcmd_datum);

	/*
	 * If the command is SELECT or DELETE then WITH CHECK should be NULL.
	 */
	if ((polcmd == ACL_SELECT_CHR || polcmd == ACL_DELETE_CHR)
		&& stmt->with_check != NULL)
		ereport(ERROR,
				(errcode(ERRCODE_SYNTAX_ERROR),
				 errmsg("only USING expression allowed for SELECT, DELETE")));

	/*
	 * If the command is INSERT then WITH CHECK should be the only expression
	 * provided.
	 */
	if ((polcmd == ACL_INSERT_CHR)
		&& stmt->qual != NULL)
		ereport(ERROR,
				(errcode(ERRCODE_SYNTAX_ERROR),
				 errmsg("only WITH CHECK expression allowed for INSERT")));

	/*
	 * WITH MASK requires a read-visible policy.  RESET MASK is unconditionally
	 * allowed (it just clears any existing mask).
	 */
	if (stmt->with_mask != NIL &&
		polcmd != ACL_SELECT_CHR && polcmd != '*')
		ereport(ERROR,
				(errcode(ERRCODE_SYNTAX_ERROR),
				 errmsg("WITH MASK can only be used with FOR SELECT or FOR ALL policies")));

	/* Transform new mask list, if supplied. */
	if (stmt->with_mask != NIL)
	{
		ParseNamespaceItem *nsitem;
		ParseState *mask_pstate = make_parsestate(NULL);

		nsitem = addRangeTableEntryForRelation(mask_pstate, target_table,
											   AccessShareLock,
											   NULL, false, false);
		addNSItemToQuery(mask_pstate, nsitem, false, true, true);

		mask_quals = transform_policy_mask_list(mask_pstate, target_table,
												stmt->with_mask);
		mask_parse_rtable = mask_pstate->p_rtable;
		free_parsestate(mask_pstate);
		mask_changed = true;
	}
	else if (stmt->reset_mask)
	{
		mask_quals = NIL;
		mask_changed = true;
	}

	policy_id = ((Form_pg_policy) GETSTRUCT(policy_tuple))->oid;

	if (role_ids != NULL)
	{
		replaces[Anum_pg_policy_polroles - 1] = true;
		values[Anum_pg_policy_polroles - 1] = PointerGetDatum(role_ids);
	}
	else
	{
		Oid		   *roles;
		Datum		roles_datum;
		bool		attr_isnull;
		ArrayType  *policy_roles;

		/*
		 * We need to pull the set of roles this policy applies to from what's
		 * in the catalog, so that we can recreate the dependencies correctly
		 * for the policy.
		 */

		roles_datum = heap_getattr(policy_tuple, Anum_pg_policy_polroles,
								   RelationGetDescr(pg_policy_rel),
								   &attr_isnull);
		Assert(!attr_isnull);

		policy_roles = DatumGetArrayTypePCopy(roles_datum);

		roles = (Oid *) ARR_DATA_PTR(policy_roles);

		nitems = ARR_DIMS(policy_roles)[0];

		role_oids = palloc_array(Datum, nitems);

		for (i = 0; i < nitems; i++)
			role_oids[i] = ObjectIdGetDatum(roles[i]);
	}

	if (qual != NULL)
	{
		replaces[Anum_pg_policy_polqual - 1] = true;
		values[Anum_pg_policy_polqual - 1]
			= CStringGetTextDatum(nodeToString(qual));
	}
	else
	{
		Datum		value_datum;
		bool		attr_isnull;

		/*
		 * We need to pull the USING expression and build the range table for
		 * the policy from what's in the catalog, so that we can recreate the
		 * dependencies correctly for the policy.
		 */

		/* Check if the policy has a USING expr */
		value_datum = heap_getattr(policy_tuple, Anum_pg_policy_polqual,
								   RelationGetDescr(pg_policy_rel),
								   &attr_isnull);
		if (!attr_isnull)
		{
			char	   *qual_value;
			ParseState *qual_pstate;

			/* parsestate is built just to build the range table */
			qual_pstate = make_parsestate(NULL);

			qual_value = TextDatumGetCString(value_datum);
			qual = stringToNode(qual_value);

			/* Add this rel to the parsestate's rangetable, for dependencies */
			(void) addRangeTableEntryForRelation(qual_pstate, target_table,
												 AccessShareLock,
												 NULL, false, false);

			qual_parse_rtable = qual_pstate->p_rtable;
			free_parsestate(qual_pstate);
		}
	}

	if (with_check_qual != NULL)
	{
		replaces[Anum_pg_policy_polwithcheck - 1] = true;
		values[Anum_pg_policy_polwithcheck - 1]
			= CStringGetTextDatum(nodeToString(with_check_qual));
	}
	else
	{
		Datum		value_datum;
		bool		attr_isnull;

		/*
		 * We need to pull the WITH CHECK expression and build the range table
		 * for the policy from what's in the catalog, so that we can recreate
		 * the dependencies correctly for the policy.
		 */

		/* Check if the policy has a WITH CHECK expr */
		value_datum = heap_getattr(policy_tuple, Anum_pg_policy_polwithcheck,
								   RelationGetDescr(pg_policy_rel),
								   &attr_isnull);
		if (!attr_isnull)
		{
			char	   *with_check_value;
			ParseState *with_check_pstate;

			/* parsestate is built just to build the range table */
			with_check_pstate = make_parsestate(NULL);

			with_check_value = TextDatumGetCString(value_datum);
			with_check_qual = stringToNode(with_check_value);

			/* Add this rel to the parsestate's rangetable, for dependencies */
			(void) addRangeTableEntryForRelation(with_check_pstate,
												 target_table,
												 AccessShareLock,
												 NULL, false, false);

			with_check_parse_rtable = with_check_pstate->p_rtable;
			free_parsestate(with_check_pstate);
		}
	}

	/*
	 * Determine what to write for polmask:
	 *   - user supplied a new mask list -> replace with it
	 *   - user asked to RESET MASK -> write NULL
	 *   - otherwise -> load the existing mask so dependencies can be recreated
	 */
	if (mask_changed)
	{
		replaces[Anum_pg_policy_polmask - 1] = true;
		if (mask_quals != NIL)
			values[Anum_pg_policy_polmask - 1] =
				CStringGetTextDatum(nodeToString(mask_quals));
		else
			isnull[Anum_pg_policy_polmask - 1] = true;
	}
	else
	{
		Datum		value_datum;
		bool		attr_isnull;

		value_datum = heap_getattr(policy_tuple, Anum_pg_policy_polmask,
								   RelationGetDescr(pg_policy_rel),
								   &attr_isnull);
		if (!attr_isnull)
		{
			char	   *mask_value;
			ParseState *mask_pstate = make_parsestate(NULL);

			mask_value = TextDatumGetCString(value_datum);
			mask_quals = (List *) stringToNode(mask_value);

			(void) addRangeTableEntryForRelation(mask_pstate, target_table,
												 AccessShareLock,
												 NULL, false, false);
			mask_parse_rtable = mask_pstate->p_rtable;
			free_parsestate(mask_pstate);
		}
	}

	/*
	 * Re-check mask conflicts against other policies before writing.  Use the
	 * (possibly new) role set and the existing polcmd.
	 */
	if (mask_quals != NIL)
	{
		if (role_ids != NULL)
			effective_role_ids = role_ids;
		else
		{
			Datum		roles_datum;
			bool		attr_isnull;

			roles_datum = heap_getattr(policy_tuple, Anum_pg_policy_polroles,
									   RelationGetDescr(pg_policy_rel),
									   &attr_isnull);
			Assert(!attr_isnull);
			effective_role_ids = DatumGetArrayTypeP(roles_datum);
		}

		check_mask_conflicts(pg_policy_rel, target_table, policy_id,
							 polcmd, effective_role_ids, mask_quals);
	}

	new_tuple = heap_modify_tuple(policy_tuple,
								  RelationGetDescr(pg_policy_rel),
								  values, isnull, replaces);
	CatalogTupleUpdate(pg_policy_rel, &new_tuple->t_self, new_tuple);

	/* Update Dependencies. */
	deleteDependencyRecordsFor(PolicyRelationId, policy_id, false);

	/* Record Dependencies */
	target.classId = RelationRelationId;
	target.objectId = table_id;
	target.objectSubId = 0;

	myself.classId = PolicyRelationId;
	myself.objectId = policy_id;
	myself.objectSubId = 0;

	recordDependencyOn(&myself, &target, DEPENDENCY_AUTO);

	recordDependencyOnExpr(&myself, qual, qual_parse_rtable, DEPENDENCY_NORMAL);

	recordDependencyOnExpr(&myself, with_check_qual, with_check_parse_rtable,
						   DEPENDENCY_NORMAL);

	record_mask_dependencies(&myself, table_id, mask_parse_rtable, mask_quals);

	/* Register role dependencies */
	deleteSharedDependencyRecordsFor(PolicyRelationId, policy_id, 0);
	target.classId = AuthIdRelationId;
	target.objectSubId = 0;
	for (i = 0; i < nitems; i++)
	{
		target.objectId = DatumGetObjectId(role_oids[i]);
		/* no dependency if public */
		if (target.objectId != ACL_ID_PUBLIC)
			recordSharedDependencyOn(&myself, &target,
									 SHARED_DEPENDENCY_POLICY);
	}

	InvokeObjectPostAlterHook(PolicyRelationId, policy_id, 0);

	heap_freetuple(new_tuple);

	/* Invalidate Relation Cache */
	CacheInvalidateRelcache(target_table);

	/* Clean up. */
	systable_endscan(sscan);
	relation_close(target_table, NoLock);
	table_close(pg_policy_rel, RowExclusiveLock);

	return myself;
}

/*
 * rename_policy -
 *	 change the name of a policy on a relation
 */
ObjectAddress
rename_policy(RenameStmt *stmt)
{
	Relation	pg_policy_rel;
	Relation	target_table;
	Oid			table_id;
	Oid			opoloid;
	ScanKeyData skey[2];
	SysScanDesc sscan;
	HeapTuple	policy_tuple;
	ObjectAddress address;

	/* Get id of table.  Also handles permissions checks. */
	table_id = RangeVarGetRelidExtended(stmt->relation, AccessExclusiveLock,
										0,
										RangeVarCallbackForPolicy,
										stmt);

	target_table = relation_open(table_id, NoLock);

	pg_policy_rel = table_open(PolicyRelationId, RowExclusiveLock);

	/* First pass -- check for conflict */

	/* Add key - policy's relation id. */
	ScanKeyInit(&skey[0],
				Anum_pg_policy_polrelid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(table_id));

	/* Add key - policy's name. */
	ScanKeyInit(&skey[1],
				Anum_pg_policy_polname,
				BTEqualStrategyNumber, F_NAMEEQ,
				CStringGetDatum(stmt->newname));

	sscan = systable_beginscan(pg_policy_rel,
							   PolicyPolrelidPolnameIndexId, true, NULL, 2,
							   skey);

	if (HeapTupleIsValid(systable_getnext(sscan)))
		ereport(ERROR,
				(errcode(ERRCODE_DUPLICATE_OBJECT),
				 errmsg("policy \"%s\" for table \"%s\" already exists",
						stmt->newname, RelationGetRelationName(target_table))));

	systable_endscan(sscan);

	/* Second pass -- find existing policy and update */
	/* Add key - policy's relation id. */
	ScanKeyInit(&skey[0],
				Anum_pg_policy_polrelid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(table_id));

	/* Add key - policy's name. */
	ScanKeyInit(&skey[1],
				Anum_pg_policy_polname,
				BTEqualStrategyNumber, F_NAMEEQ,
				CStringGetDatum(stmt->subname));

	sscan = systable_beginscan(pg_policy_rel,
							   PolicyPolrelidPolnameIndexId, true, NULL, 2,
							   skey);

	policy_tuple = systable_getnext(sscan);

	/* Complain if we did not find the policy */
	if (!HeapTupleIsValid(policy_tuple))
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_OBJECT),
				 errmsg("policy \"%s\" for table \"%s\" does not exist",
						stmt->subname, RelationGetRelationName(target_table))));

	opoloid = ((Form_pg_policy) GETSTRUCT(policy_tuple))->oid;

	policy_tuple = heap_copytuple(policy_tuple);

	namestrcpy(&((Form_pg_policy) GETSTRUCT(policy_tuple))->polname,
			   stmt->newname);

	CatalogTupleUpdate(pg_policy_rel, &policy_tuple->t_self, policy_tuple);

	InvokeObjectPostAlterHook(PolicyRelationId, opoloid, 0);

	ObjectAddressSet(address, PolicyRelationId, opoloid);

	/*
	 * Invalidate relation's relcache entry so that other backends (and this
	 * one too!) are sent SI message to make them rebuild relcache entries.
	 * (Ideally this should happen automatically...)
	 */
	CacheInvalidateRelcache(target_table);

	/* Clean up. */
	systable_endscan(sscan);
	table_close(pg_policy_rel, RowExclusiveLock);
	relation_close(target_table, NoLock);

	return address;
}

/*
 * get_relation_policy_oid - Look up a policy by name to find its OID
 *
 * If missing_ok is false, throw an error if policy not found.  If
 * true, just return InvalidOid.
 */
Oid
get_relation_policy_oid(Oid relid, const char *policy_name, bool missing_ok)
{
	Relation	pg_policy_rel;
	ScanKeyData skey[2];
	SysScanDesc sscan;
	HeapTuple	policy_tuple;
	Oid			policy_oid;

	pg_policy_rel = table_open(PolicyRelationId, AccessShareLock);

	/* Add key - policy's relation id. */
	ScanKeyInit(&skey[0],
				Anum_pg_policy_polrelid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(relid));

	/* Add key - policy's name. */
	ScanKeyInit(&skey[1],
				Anum_pg_policy_polname,
				BTEqualStrategyNumber, F_NAMEEQ,
				CStringGetDatum(policy_name));

	sscan = systable_beginscan(pg_policy_rel,
							   PolicyPolrelidPolnameIndexId, true, NULL, 2,
							   skey);

	policy_tuple = systable_getnext(sscan);

	if (!HeapTupleIsValid(policy_tuple))
	{
		if (!missing_ok)
			ereport(ERROR,
					(errcode(ERRCODE_UNDEFINED_OBJECT),
					 errmsg("policy \"%s\" for table \"%s\" does not exist",
							policy_name, get_rel_name(relid))));

		policy_oid = InvalidOid;
	}
	else
		policy_oid = ((Form_pg_policy) GETSTRUCT(policy_tuple))->oid;

	/* Clean up. */
	systable_endscan(sscan);
	table_close(pg_policy_rel, AccessShareLock);

	return policy_oid;
}

/*
 * relation_has_policies - Determine if relation has any policies
 */
bool
relation_has_policies(Relation rel)
{
	Relation	catalog;
	ScanKeyData skey;
	SysScanDesc sscan;
	HeapTuple	policy_tuple;
	bool		ret = false;

	catalog = table_open(PolicyRelationId, AccessShareLock);
	ScanKeyInit(&skey,
				Anum_pg_policy_polrelid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(RelationGetRelid(rel)));
	sscan = systable_beginscan(catalog, PolicyPolrelidPolnameIndexId, true,
							   NULL, 1, &skey);
	policy_tuple = systable_getnext(sscan);
	if (HeapTupleIsValid(policy_tuple))
		ret = true;

	systable_endscan(sscan);
	table_close(catalog, AccessShareLock);

	return ret;
}
