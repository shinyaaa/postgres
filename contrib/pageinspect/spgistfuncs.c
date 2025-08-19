/*
 * spgistfuncs.c
 *
 * Functions to investigate the content of SP-GiST indexes
 *
 * Copyright (c) 2025, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *	contrib/pageinspect/spgistfuncs.c
 */
#include "postgres.h"

#include "access/spgist_private.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "pageinspect.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"

PG_FUNCTION_INFO_V1(spgist_page_type);
PG_FUNCTION_INFO_V1(spgist_metapage_info);

static Page verify_spgist_page(bytea *raw_page);

/*
 * Verify that the given bytea contains an SPGiST page or die trying.
 * A pointer to the page is returned.
 */
static Page
verify_spgist_page(bytea *raw_page)
{
 	Page		page = get_page_from_raw(raw_page);

	if (PageIsNew(page))
		return page;

	/* verify the special space has the expected size */
	if (PageGetSpecialSize(page) != MAXALIGN(sizeof(SpGistPageOpaqueData)))
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("input page is not a valid %s page", "SP-GiST"),
				 errdetail("Expected special size %d, got %d.",
					   (int) MAXALIGN(sizeof(SpGistPageOpaqueData)),
					   (int) PageGetSpecialSize(page))));

	if (SpGistPageGetOpaque(page)->spgist_page_id != SPGIST_PAGE_ID)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("input page is not a valid %s page", "SP-GiST"),
				 errdetail("Expected %08x, got %08x.",
					   SPGIST_PAGE_ID,
					   SpGistPageGetOpaque(page)->spgist_page_id)));

	return page;
}

Datum
spgist_page_type(PG_FUNCTION_ARGS)
{
 	bytea      *raw_page = PG_GETARG_BYTEA_P(0);
	Page		page;
	char		*type;

	if (!superuser())
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("must be superuser to use raw page functions")));

	page = get_page_from_raw(raw_page);

	if (PageIsNew(page))
		PG_RETURN_NULL();

	/* verify the special space has the expected size */
	if (PageGetSpecialSize(page) != MAXALIGN(sizeof(SpGistPageOpaqueData)))
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("input page is not a valid %s page", "SP-GiST"),
				 errdetail("Expected special size %d, got %d.",
					   (int) MAXALIGN(sizeof(SpGistPageOpaqueData)),
					   (int) PageGetSpecialSize(page))));

	if (SpGistPageIsMeta(page))
		type = "meta";
	else if (SpGistPageIsLeaf(page))
		type = "leaf";
	else
		type = "inner";

	PG_RETURN_TEXT_P(cstring_to_text(type));
}

Datum
spgist_metapage_info(PG_FUNCTION_ARGS)
{
 	bytea		*raw_page = PG_GETARG_BYTEA_P(0);
	TupleDesc	tupdesc;
	Page		page;
	SpGistMetaPageData *metadata;
	HeapTuple	resultTuple;
	Datum		values[2];
	bool		nulls[2];

	if (!superuser())
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("must be superuser to use raw page functions")));

	page = verify_spgist_page(raw_page);

	if (PageIsNew(page))
		PG_RETURN_NULL();

	/* Build a tuple descriptor for our result type */
	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		elog(ERROR, "return type must be a row type");

	/* verify this is actually a metapage */
	if (!SpGistPageIsMeta(page))
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("page is not a SP-GiST meta page")));

	metadata = SpGistPageGetMeta(page);

	memset(nulls, 0, sizeof(nulls));

	/* magic number in meta is a uint32; return as bigint for safety */
	values[0] = Int64GetDatum((int64) metadata->magicNumber);
	/* No explicit version field in SP-GiST meta; report format version 1 */
	values[1] = Int32GetDatum(1);

	/* Build and return the result tuple. */
	resultTuple = heap_form_tuple(tupdesc, values, nulls);

	return HeapTupleGetDatum(resultTuple);
}
