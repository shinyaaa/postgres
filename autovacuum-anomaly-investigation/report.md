# PostgreSQL master autovacuum — execution-based anomaly investigation

**Author date:** 2026-07-04
**Build under test:** PostgreSQL `20devel`, commit `6d4ca6de97770cdaee18517dd2f8fe8f4ecee187`
("psql: Fix \df tab completion for procedures")
**configure:** `--prefix=$HOME/pgav --enable-debug --enable-cassert CFLAGS="-O0 -g3"`
**Host:** Linux 6.18, gcc 13.3, x86_64. Server run as unprivileged user, `autovacuum_naptime=1s`.
**Comparison baseline:** stock PostgreSQL 16.13 (Ubuntu).

> Note on scope: the task template expected a *specific* observed anomaly as
> input. None was supplied and there was no prior investigation to transcribe,
> so — per the chosen option — this is an **exploration**: drive master's
> autovacuum across its decision paths and report any deviation, backed by
> execution evidence. Code was read only to design experiments and to explain
> observed behaviour.

---

## TL;DR

Across an eight-way sweep of master's autovacuum decision / scoring /
prioritization / anti-wraparound machinery, **no new (master-introduced)
anomaly was reproduced.** All core behaviour is correct and the new PG19+
scoring system (`pg_stat_autovacuum_scores`, `autovacuum_*_score_weight`,
`autovacuum_vacuum_max_threshold`, `relallfrozen`-based insert scaling) matches
hand-computed expectations.

One reproducible behavioural deviation was found and characterized: **VACUUM /
ANALYZE do not reliably reset `n_ins_since_vacuum` / `n_mod_since_analyze` when
run in the same backend immediately after the DML, before that backend's
pending cumulative-statistics delta has flushed.** This is **pre-existing**
(reproduces identically on 16.13) and is a known consequence of the deferred
pgstat flush design — *not* a master regression. `repro.sh` reproduces it 3/3.

---

## 1. Method

A single instrumented cluster (`autovacuum_naptime=1s`, `log_autovacuum_min_duration=0`,
`log_min_messages=debug2`, scale factors 0 and low base thresholds so triggers
are fast and arithmetic is exact). Each path was exercised with a controlled
workload; the state was read from `pg_stat_user_tables`, `pg_class`, and the new
`pg_stat_autovacuum_scores` view (which exposes exactly the values
`relation_needs_vacanalyze()` computes), then compared against a hand-derived
expected value. Evidence files are in `evidence/`.

The shallow checkout (depth 50, no release tags) rules out `git bisect`; the
vacuum-touching commits within that window are cosmetic only (error-message
placeholders `7905416`, MultiXact hint text `084734f`, a comment `cfa573c`), so
any behavioural anomaly would live in already-present code, which is what the
execution sweep targets.

## 2. What was verified correct (evidence → result)

| # | Path exercised | Expected | Observed | Evidence |
|---|----------------|----------|----------|----------|
| 1 | Dead-tuple (UPDATE) trigger | autovacuum fires | fired, `avc=1` | `02_scenario_sweep.txt` |
| 2 | Insert-only (`ins_since_vacuum`) trigger | fires | fired | `02_scenario_sweep.txt` |
| 3 | Analyze (`mod_since_analyze`) trigger | fires | fired, `aac=1` | `02_scenario_sweep.txt` |
| 4 | DELETE dead-tuple trigger | fires | fired | `02_scenario_sweep.txt` |
| 5 | `vacuum_score` math + `vacuum_max_threshold` clamp | `3000/min(1050,500)=6.00` | `6.000` | `03_score_validation.txt` |
| 6 | Anti-wraparound force-vacuum | aged table vacuumed, `relfrozenxid` advances | age 130001 → 0 after force | `04_wraparound.txt` |
| 7 | Score-based prioritization order (1 worker) | process highest score first | pa→pb→pc→pd→pe→pf, exact | `05_prioritization_ordering.txt` |
| 8 | `*_score_weight` scaling incl. 0.0 escape hatch | 100 / 300 / 0 | 100 / 300 / 0 | `07_weight_scaling.txt` |
| 9 | `relallfrozen`/`pcnt_unfrozen` insert scale | fully-frozen ⇒ thresh=base | confirmed (§ below) | transcript |

The scoring math was validated component-by-component against catalog inputs;
`relation_needs_vacanalyze()` (`src/backend/postmaster/autovacuum.c:3284-3320`)
and the descending-order comparator (`autovacuum.c:1908-1917`) behave exactly
as written. See `08_code_refs.txt`.

## 3. The one reproducible deviation (pre-existing, not a regression)

### Observation
`INSERT` of 10 000 rows followed by `VACUUM` **in the same session with no
delay** leaves `n_ins_since_vacuum = 10000` instead of `0`
(`06_pg16_comparison.txt`, `09_repro_run.txt`). With a ≥2 s gap before the
VACUUM the counter resets to `0` correctly (control case, same file). The same
holds for `n_mod_since_analyze` vs `ANALYZE`.

### Isolation
- Not CTAS-specific: plain `INSERT … generate_series` reproduces it (Test C).
- Timing-gated: the discriminator is whether the inserting backend flushed its
  pending pgstat delta before the VACUUM.
- **Version control:** stock **PostgreSQL 16.13 produces the identical result**
  (`ins=10000`), so this is *not* introduced by master.

### Mechanism (execution ↔ code)
1. A backend's tuple counts accumulate in local pending stats and are flushed to
   shared memory only by `pgstat_report_stat()`, which **defers** if called
   less than `PGSTAT_MIN_INTERVAL` (1 s) since the last flush. So right after a
   fast INSERT the `+10000` is still pending.
2. `VACUUM` calls `pgstat_report_vacuum()`, which sets the *shared*
   `ins_since_vacuum = 0` (`pgstat_relation.c:248`).
3. Later, the backend flushes its pending delta; the table flush callback does
   `tabentry->ins_since_vacuum += lstats->counts.tuples_inserted`
   (`pgstat_relation.c:880`) — **adding on top of the reset**, so the counter
   lands back at `10000`. A nearby comment (`:873-878`) already acknowledges
   related imprecision in this counter.

### Impact
Low and self-correcting. For real autovacuum the DML and the vacuum are in
different backends and separated by ≥`naptime`, so the triggering delta is
already flushed; at worst an insert-heavy table under sustained sub-second load
may keep a slightly inflated `ins_since_vacuum` and be re-vacuumed marginally
sooner. It does **not** cause missed vacuums.

## 4. Conclusion

**Confirmed facts**
- Every core autovacuum trigger (dead-tuple, insert, analyze, anti-wraparound)
  fires correctly on `6d4ca6d`.
- The new scoring/prioritization system computes and orders correctly across
  weights, the max-threshold clamp, and the unfrozen-percentage insert scale.
- The `n_ins_since_vacuum`/`n_mod_since_analyze` same-backend reset race exists
  and is deterministic, but is **pre-existing (≥ v16)**, not a master anomaly.

**Excluded hypotheses**
- Broken threshold/decision arithmetic — refuted (§2 #5, #8).
- Reversed/incorrect prioritization comparator — refuted (§2 #7).
- Broken anti-wraparound forcing — refuted (§2 #6).
- A *new* insert-counter accounting bug on master — refuted by the PG16
  equivalence (§3).

**Remaining (untested) hypotheses** — would need more time/targeted setups:
- MultiXact-freeze scoring (`scores->mxid`) under real multixact pressure.
- Multi-worker balancing/contention and cross-database launcher fairness.
- TOAST-table and complex per-table reloption combinations.
- The eager-scan freezing behaviour inside `vacuumlazy.c` itself (only the
  autovacuum-side trigger was exercised here).

No crash, TRAP/assertion (built with `--enable-cassert`), hang, or memory
anomaly was observed in any run.

## 5. Reproduce

```bash
# build (as used here)
./configure --prefix=$HOME/pgav --enable-debug --enable-cassert CFLAGS="-O0 -g3"
make -j"$(nproc)" && make install
export PATH=$HOME/pgav/bin:$PATH

# the one reproducible deviation (exit 1 when observed, 3/3):
PGBIN=$HOME/pgav/bin ./repro.sh
```

Files: `repro.sh`, `evidence/01_env.txt` … `evidence/09_repro_run.txt`.
