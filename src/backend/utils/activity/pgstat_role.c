/* -------------------------------------------------------------------------
 *
 * pgstat_role.c
 *	  Implementation of role statistics.
 *
 * This file contains the implementation of role statistics. It is kept
 * separate from pgstat.c to enforce the line between the statistics access /
 * storage implementation and the details about individual types of
 * statistics.
 *
 * Statistics are attributed to the login role of a session (the one
 * reported by pgstat_report_role_connect()), not to the current user, so
 * SET ROLE and SECURITY DEFINER functions do not redirect where activity
 * is counted.
 *
 * Copyright (c) 2001-2026, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *	  src/backend/utils/activity/pgstat_role.c
 * -------------------------------------------------------------------------
 */

#include "postgres.h"

#include "miscadmin.h"
#include "utils/pgstat_internal.h"


/*
 * The login role of this session, as reported by
 * pgstat_report_role_connect().  Remains InvalidOid in processes that don't
 * report role statistics (e.g. autovacuum workers, background workers).
 */
static Oid	pgStatSessionRoleId = InvalidOid;

/*
 * Transaction counts not yet transferred to the pending entry.  Like the
 * database transaction counters, these are accumulated at transaction end
 * and moved to the pending entry by pgstat_update_role_stats().
 */
static PgStat_Counter pgStatRoleXactCommit = 0;
static PgStat_Counter pgStatRoleXactRollback = 0;

static PgStat_StatRoleEntry *pgstat_prep_role_pending(Oid roleid);


/*
 * Report creating the role.
 */
void
pgstat_create_role(Oid roleid)
{
	/* Ensures that stats are dropped if transaction rolls back */
	pgstat_create_transactional(PGSTAT_KIND_ROLE,
								InvalidOid, roleid);

	/* Create and initialize the role stats entry */
	pgstat_get_entry_ref(PGSTAT_KIND_ROLE, InvalidOid, roleid,
						 true, NULL);
	pgstat_reset_entry(PGSTAT_KIND_ROLE, InvalidOid, roleid, 0);
}

/*
 * Report dropping the role.
 *
 * Ensures that stats are dropped if transaction commits.
 */
void
pgstat_drop_role(Oid roleid)
{
	pgstat_drop_transactional(PGSTAT_KIND_ROLE,
							  InvalidOid, roleid);
}

/*
 * Notify stats system of a new connection, attributed to the given login
 * role.
 *
 * Like pgstat_report_connect(), only count client sessions, not background
 * processes.
 */
void
pgstat_report_role_connect(Oid roleid)
{
	PgStat_StatRoleEntry *pending;

	if (MyBackendType != B_BACKEND)
		return;

	/* remember the login role for transaction accounting */
	pgStatSessionRoleId = roleid;

	pending = pgstat_prep_role_pending(roleid);
	pending->sessions++;
}

/*
 * Called from access/xact.c at transaction commit/abort.
 */
void
AtEOXact_PgStat_Role(bool isCommit, bool parallel)
{
	/* Don't count parallel worker transaction stats */
	if (parallel)
		return;

	/* Don't count transactions in sessions not tied to a login role */
	if (!OidIsValid(pgStatSessionRoleId))
		return;

	if (isCommit)
		pgStatRoleXactCommit++;
	else
		pgStatRoleXactRollback++;
}

/*
 * Subroutine for pgstat_report_stat(): Handle xact commit/rollback counts
 * for the session's login role.
 */
void
pgstat_update_role_stats(void)
{
	PgStat_StatRoleEntry *pending;

	if (!OidIsValid(pgStatSessionRoleId))
		return;

	if (pgStatRoleXactCommit == 0 && pgStatRoleXactRollback == 0)
		return;

	pending = pgstat_prep_role_pending(pgStatSessionRoleId);
	pending->xact_commit += pgStatRoleXactCommit;
	pending->xact_rollback += pgStatRoleXactRollback;

	pgStatRoleXactCommit = 0;
	pgStatRoleXactRollback = 0;
}

/*
 * Support function for the SQL-callable pgstat* functions. Returns
 * the collected statistics for one role or NULL. NULL doesn't mean
 * that the role doesn't exist, just that there are no statistics, so the
 * caller is better off to report ZERO instead.
 */
PgStat_StatRoleEntry *
pgstat_fetch_stat_role_entry(Oid roleid)
{
	return (PgStat_StatRoleEntry *)
		pgstat_fetch_entry(PGSTAT_KIND_ROLE, InvalidOid, roleid, NULL);
}

/*
 * Find or create a local PgStat_StatRoleEntry entry for roleid.
 */
static PgStat_StatRoleEntry *
pgstat_prep_role_pending(Oid roleid)
{
	PgStat_EntryRef *entry_ref;

	entry_ref = pgstat_prep_pending_entry(PGSTAT_KIND_ROLE, InvalidOid,
										  roleid, NULL);

	return entry_ref->pending;
}

/*
 * Flush out pending stats for the entry
 *
 * If nowait is true and the lock could not be immediately acquired, returns
 * false without flushing the entry.  Otherwise returns true.
 */
bool
pgstat_role_flush_cb(PgStat_EntryRef *entry_ref, bool nowait)
{
	PgStat_StatRoleEntry *localent;
	PgStatShared_Role *sharedent;

	localent = (PgStat_StatRoleEntry *) entry_ref->pending;
	sharedent = (PgStatShared_Role *) entry_ref->shared_stats;

	if (!pgstat_lock_entry(entry_ref, nowait))
		return false;

#define PGSTAT_ACCUM_ROLECOUNT(item)	\
	(sharedent)->stats.item += (localent)->item
	PGSTAT_ACCUM_ROLECOUNT(sessions);
	PGSTAT_ACCUM_ROLECOUNT(xact_commit);
	PGSTAT_ACCUM_ROLECOUNT(xact_rollback);
#undef PGSTAT_ACCUM_ROLECOUNT

	pgstat_unlock_entry(entry_ref);
	return true;
}

void
pgstat_role_reset_timestamp_cb(PgStatShared_Common *header, TimestampTz ts)
{
	((PgStatShared_Role *) header)->stats.stat_reset_timestamp = ts;
}
