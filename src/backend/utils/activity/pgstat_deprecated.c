/* -------------------------------------------------------------------------
 *
 * pgstat_deprecated.c
 *	  Implementation of deprecated feature usage statistics.
 *
 * This file contains the implementation of deprecated feature usage
 * statistics. It is kept separate from pgstat.c to enforce the line between
 * the statistics access / storage implementation and the details about
 * individual types of statistics.
 *
 * Copyright (c) 2001-2026, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *	  src/backend/utils/activity/pgstat_deprecated.c
 * -------------------------------------------------------------------------
 */

#include "postgres.h"

#include "utils/pgstat_internal.h"
#include "utils/timestamp.h"


/* GUC variable */
bool		track_deprecated_features = true;

static inline PgStat_DeprecatedFeaturesStats *get_deprecated_entry(int feature_idx);
static void pgstat_reset_deprecated_counter_internal(int index, TimestampTz ts);


/*
 * Deprecated feature names, one-to-one with DEPRECATED_* constants.
 */
static const char *const deprecated_feature_names[DEPRECATED_FEATURES_NUM_KINDS] = {
	"md5_password",				/* DEPRECATED_MD5_PASSWORD */
	"global_temp_table",		/* DEPRECATED_GLOBAL_TEMP_TABLE */
	"old_guc_names",			/* DEPRECATED_OLD_GUC_NAMES */
};

/*
 * Human-readable replacement descriptions, one-to-one with DEPRECATED_*
 * constants.
 */
static const char *const deprecated_feature_replacements[DEPRECATED_FEATURES_NUM_KINDS] = {
	"scram-sha-256",			/* DEPRECATED_MD5_PASSWORD */
	"TEMPORARY or TEMP",		/* DEPRECATED_GLOBAL_TEMP_TABLE */
	"work_mem, maintenance_work_mem, ssl_groups",	/* DEPRECATED_OLD_GUC_NAMES */
};


/*
 * Deprecated feature statistics counts waiting to be flushed out.  We assume
 * this variable inits to zeroes.  Entries are one-to-one with
 * deprecated_feature_names[].
 */
static PgStat_DeprecatedFeaturesStats pending_DeprecatedStats[DEPRECATED_FEATURES_NUM_KINDS];
static bool have_deprecatedstats = false;


/*
 * Reset counters for a single deprecated feature.
 *
 * Permission checking for this function is managed through the normal
 * GRANT system.
 */
void
pgstat_reset_deprecated_features(const char *name)
{
	TimestampTz ts = GetCurrentTimestamp();

	Assert(name != NULL);

	pgstat_reset_deprecated_counter_internal(pgstat_get_deprecated_feature_index(name), ts);
}

/*
 * Count one usage of a deprecated feature.
 */
void
pgstat_count_deprecated_feature(int feature_idx)
{
	if (!track_deprecated_features)
		return;

	get_deprecated_entry(feature_idx)->usage_count += 1;
}

/*
 * Support function for the SQL-callable pgstat* functions.  Returns
 * a pointer to the deprecated features statistics struct.
 */
PgStat_DeprecatedFeaturesStats *
pgstat_fetch_deprecated_features(void)
{
	pgstat_snapshot_fixed(PGSTAT_KIND_DEPRECATED);

	return pgStatLocal.snapshot.deprecated_features;
}

/*
 * Returns deprecated feature name for an index.  The index may be above
 * DEPRECATED_FEATURES_NUM_KINDS, in which case this returns NULL.  This
 * allows writing code that does not know the number of entries in advance.
 */
const char *
pgstat_get_deprecated_feature_name(int idx)
{
	if (idx < 0 || idx >= DEPRECATED_FEATURES_NUM_KINDS)
		return NULL;

	return deprecated_feature_names[idx];
}

/*
 * Returns the replacement description for a deprecated feature index.
 */
const char *
pgstat_get_deprecated_feature_replacement(int idx)
{
	if (idx < 0 || idx >= DEPRECATED_FEATURES_NUM_KINDS)
		return NULL;

	return deprecated_feature_replacements[idx];
}

/*
 * Determine index of entry for a deprecated feature with a given name.
 * If there's no exact match, returns -1.
 */
int
pgstat_get_deprecated_feature_index(const char *name)
{
	for (int i = 0; i < DEPRECATED_FEATURES_NUM_KINDS; i++)
	{
		if (strcmp(deprecated_feature_names[i], name) == 0)
			return i;
	}

	return -1;
}

/*
 * Flush out locally pending deprecated feature stats entries
 *
 * If nowait is true, this function returns true if the lock could not be
 * acquired.  Otherwise return false.
 */
bool
pgstat_deprecated_flush_cb(bool nowait)
{
	PgStatShared_DeprecatedFeatures *stats_shmem = &pgStatLocal.shmem->deprecated_features;
	int			i;

	if (!have_deprecatedstats)
		return false;

	if (!nowait)
		LWLockAcquire(&stats_shmem->lock, LW_EXCLUSIVE);
	else if (!LWLockConditionalAcquire(&stats_shmem->lock, LW_EXCLUSIVE))
		return true;

	for (i = 0; i < DEPRECATED_FEATURES_NUM_KINDS; i++)
	{
		PgStat_DeprecatedFeaturesStats *sharedent = &stats_shmem->stats[i];
		PgStat_DeprecatedFeaturesStats *pendingent = &pending_DeprecatedStats[i];

		sharedent->usage_count += pendingent->usage_count;
	}

	/* done, clear the pending entry */
	MemSet(pending_DeprecatedStats, 0, sizeof(pending_DeprecatedStats));

	LWLockRelease(&stats_shmem->lock);

	have_deprecatedstats = false;

	return false;
}

void
pgstat_deprecated_init_shmem_cb(void *stats)
{
	PgStatShared_DeprecatedFeatures *stats_shmem = (PgStatShared_DeprecatedFeatures *) stats;

	LWLockInitialize(&stats_shmem->lock, LWTRANCHE_PGSTATS_DATA);
}

void
pgstat_deprecated_reset_all_cb(TimestampTz ts)
{
	for (int i = 0; i < DEPRECATED_FEATURES_NUM_KINDS; i++)
		pgstat_reset_deprecated_counter_internal(i, ts);
}

void
pgstat_deprecated_snapshot_cb(void)
{
	PgStatShared_DeprecatedFeatures *stats_shmem = &pgStatLocal.shmem->deprecated_features;

	LWLockAcquire(&stats_shmem->lock, LW_SHARED);

	memcpy(pgStatLocal.snapshot.deprecated_features, &stats_shmem->stats,
		   sizeof(stats_shmem->stats));

	LWLockRelease(&stats_shmem->lock);
}

/*
 * Returns pointer to entry with counters for given deprecated feature.
 */
static inline PgStat_DeprecatedFeaturesStats *
get_deprecated_entry(int feature_idx)
{
	pgstat_assert_is_up();

	/*
	 * The postmaster should never register any deprecated feature statistics
	 * counts; if it did, the counts would be duplicated into child processes
	 * via fork().
	 */
	Assert(IsUnderPostmaster || !IsPostmasterEnvironment);

	Assert((feature_idx >= 0) && (feature_idx < DEPRECATED_FEATURES_NUM_KINDS));

	have_deprecatedstats = true;
	pgstat_report_fixed = true;

	return &pending_DeprecatedStats[feature_idx];
}

static void
pgstat_reset_deprecated_counter_internal(int index, TimestampTz ts)
{
	PgStatShared_DeprecatedFeatures *stats_shmem = &pgStatLocal.shmem->deprecated_features;

	LWLockAcquire(&stats_shmem->lock, LW_EXCLUSIVE);

	memset(&stats_shmem->stats[index], 0, sizeof(PgStat_DeprecatedFeaturesStats));
	stats_shmem->stats[index].stat_reset_timestamp = ts;

	LWLockRelease(&stats_shmem->lock);
}
