# EXPLAIN COPY 詳細設計(パッチ 0001〜0003)

対象: PostgreSQL 20devel (master)
目的: EXPLAIN の対象コマンドに COPY を追加し、COPY FROM の時間内訳を表示する。

パッチシリーズの意味論(最初に固定し、以後変更しない):

| パッチ | できるようになること | 実行の有無 |
|---|---|---|
| 0001 | `EXPLAIN COPY ...`(全バリアント、ANALYZE なし) | 一切実行しない |
| 0002 | `EXPLAIN ANALYZE COPY (query) TO ...` | クエリを実行、COPY 出力(ファイル/STDOUT)は生成しない |
| 0003 | `EXPLAIN ANALYZE COPY ... FROM ...` + 時間内訳 | 実際にデータをロードする |

---

## 0001: 文法・ディスパッチ・非 ANALYZE の EXPLAIN

### 0001-1. 文法 (src/backend/parser/gram.y)

`ExplainableStmt`(gram.y:12846)に `| CopyStmt` を追加する。

```
ExplainableStmt:
            SelectStmt
            | ...
            | ExecuteStmt
            | CopyStmt                  /* by default all are $$=$1 */
```

bison 3.8.2 で shift/reduce 競合が発生しないことは検証済み(gram.y は
`%expect 0` のため、競合があればビルドが失敗する)。

`PreparableStmt` には追加しない(PREPARE 対象外のため EXPLAIN EXECUTE 経由で
CopyStmt が来ることはない)。

### 0001-2. パース解析

変更不要。`transformExplainStmt`(analyze.c:3461)は内包文を
`transformOptionalSelectInto` → `transformStmt` に渡し、CopyStmt は
transformStmt の default 分岐(analyze.c:435-444)で CMD_UTILITY の Query に
包まれる。実行時は ExplainQuery → ExplainOneQuery → ExplainOneUtility に
到達する(NotifyStmt と同じ経路)。

### 0001-3. ディスパッチ (src/backend/commands/explain.c)

`ExplainOneUtility()`(explain.c:396)の NotifyStmt 分岐の前に追加:

```c
else if (IsA(utilityStmt, CopyStmt))
    ExplainCopyStmt(castNode(CopyStmt, utilityStmt), es, pstate, params);
```

CopyStmt は変更しない(const 扱い)ため、EXPLAIN EXECUTE 経路のような
copyObject は不要。

### 0001-4. copy.c のリファクタリング

DoCopy(copy.c:63-386)の前半(74〜355 行: 権限チェック〜RLS 変換)を
共通関数に抽出する。**挙動変更なし**。

```c
/* copy.c / copy.h */
void ProcessCopyTarget(ParseState *pstate, const CopyStmt *stmt,
                       int stmt_location, int stmt_len,
                       Relation *rel_p,          /* out: 対象リレーション(query TO は NULL) */
                       Oid *relid_p,             /* out: RLS 再確認用 relid */
                       RawStmt **query_p,        /* out: query TO / RLS 変換後クエリ */
                       Node **whereClause_p);    /* out: FROM の WHERE(変換済み) */
```

抽出内容:
- file/PROGRAM のロール権限チェック(pg_read_server_files 等)
- リレーションの open + lock(FROM: RowExclusiveLock, TO: AccessShareLock)
- WHERE 句の transform と検証
- 列単位 ACL チェック(ExecCheckPermissions)
- RLS 有効時の relation TO → query TO 変換(copy.c:242-342)

DoCopy は `ProcessCopyTarget` + 実行部(357-382 行)+ table_close となる。

EXPLAIN(非 ANALYZE)でもこの関数を通すことで、存在しないテーブル・権限
不足は通常の COPY と同様に検出される(EXPLAIN INSERT が ExecutorStart で
ACL チェックされるのと整合)。ファイルは open しないため、ファイル不存在は
検出されない(EXPLAIN の一般的な性質として許容し、ドキュメントに記載)。

### 0001-5. copyto.c のリファクタリング

BeginCopyTo のクエリ解析・検証部(copyto.c:909-986)を抽出する。
**挙動変更なし**。

```c
/* copyto.c / copy.h */
Query *CopyToTransformQuery(ParseState *pstate, RawStmt *raw_query);
```

内容: pg_analyze_and_rewrite_fixedparams、DO INSTEAD ルール拒否、
SELECT INTO 拒否、ユーティリティ文拒否、RETURNING 必須チェック。
プランニングと relationOids 再確認(copyto.c:989-1015)は呼び出し元に残す。

### 0001-6. explain_copy.c(新規ファイル)

explain.c は近年 explain_dr.c / explain_format.c / explain_state.c に分割
されており、この流れに沿って `src/backend/commands/explain_copy.c` を新設。

```c
/* explain.h に宣言 */
void ExplainCopyStmt(CopyStmt *stmt, ExplainState *es,
                     ParseState *pstate, ParamListInfo params);
```

0001 時点の処理フロー:

```
ProcessCopyTarget(pstate, stmt, ..., &rel, &relid, &query, &whereClause);

if (stmt->is_from)
{
    if (es->analyze)
        ereport(ERROR, "EXPLAIN ANALYZE is not yet supported for COPY FROM");
        /* 0003 で解除 */
    ExplainCopyFromInfo(stmt, rel, es);      /* 静的情報のみ */
}
else if (query != NULL)          /* COPY (query) TO / RLS 変換された relation TO */
{
    if (es->analyze)
        ereport(ERROR, "...");   /* 0002 で解除 */
    ExplainCopyToQuery(stmt, query, relid, es, pstate, params);
}
else                             /* COPY relation TO */
{
    if (es->analyze)
        ereport(ERROR, "...");   /* relation TO の ANALYZE は将来課題(Phase 4) */
    ExplainCopyToInfo(stmt, rel, es);
}

if (rel)
    table_close(rel, NoLock);
```

STDIN/STDOUT は 0001 では**許可**する(実行しないためプロトコル問題は
発生しない)。ANALYZE 時の制限は 0002/0003 で導入する。

#### ExplainCopyToQuery の実装(0001 の中核)

standard_ExplainOneQuery(explain.c:324-381)を模倣し、COPY 用の追加情報を
ExplainOnePlan に渡す:

```c
static void
ExplainCopyToQuery(CopyStmt *stmt, RawStmt *raw_query, Oid queryRelId,
                   ExplainState *es, ParseState *pstate, ParamListInfo params)
{
    Query      *query;
    PlannedStmt *plan;
    instr_time  planstart, planduration;
    BufferUsage bufusage_start, bufusage;   /* es->buffers 時 */
    MemoryContextCounters mem_counters;     /* es->memory 時 */
    JumbleState *jstate = NULL;

    query = CopyToTransformQuery(pstate, raw_query);

    /* CTAS 分岐(explain.c:429-434)と同様に jumble + フック */
    if (IsQueryIdEnabled())
        jstate = JumbleQuery(query);
    if (post_parse_analyze_hook)
        (*post_parse_analyze_hook) (pstate, query, jstate);

    /* standard_ExplainOneQuery と同じ計測付きでプランニング */
    ... INSTR_TIME_SET_CURRENT(planstart) ...
    plan = pg_plan_query(query, pstate->p_sourcetext,
                         CURSOR_OPT_PARALLEL_OK, params, es);
    ... planduration 算出 ...

    /* BeginCopyTo(copyto.c:1003-1015)と同じ RLS 再確認 */
    if (OidIsValid(queryRelId) &&
        !list_member_oid(plan->relationOids, queryRelId))
        ereport(ERROR, "relation referenced by COPY statement has changed");

    ExplainOnePlan(plan, NULL, es, pstate->p_sourcetext, params,
                   pstate->p_queryEnv, &planduration,
                   (es->buffers ? &bufusage : NULL),
                   (es->memory ? &mem_counters : NULL),
                   stmt);                    /* ← 新パラメータ */
}
```

#### ExplainOnePlan のシグネチャ拡張

COPY の静的情報を「Query」グループの**内側**に出力するため、
`ExplainOnePlan()`(explain.c:500)に `const CopyStmt *copystmt` パラメータを
追加する(NULL 可)。既存呼び出し元(explain.c、prepare.c)は NULL を渡す。

理由: JSON 等の構造化フォーマットで、ExplainOnePlan が開く無ラベルの
"Query" グループ(explain.c:603)の外側にラベル付きグループを重ねると
不正な JSON になる。CTAS が `into` パラメータで同じ問題を解決している
前例に従う。ABI 変化はメジャーリリースの通例として許容(planduration /
bufusage / mem_counters 追加時と同じ)。

ExplainOnePlan 内では ExplainPrintPlan 直後に、copystmt が非 NULL なら
ExplainPrintCopyInfo(explain_copy.c で定義、後述の共通出力関数)を呼ぶ。

#### 静的情報の出力関数(FROM / TO 共通)

```c
static void ExplainPrintCopyInfo(const CopyStmt *stmt, Relation rel,
                                 ExplainState *es);
```

出力プロパティ(値が既定値のものは省略):

| プロパティ | 出力条件 | 値 |
|---|---|---|
| Relation Name / Schema | rel != NULL(Schema は VERBOSE 時) | 対象テーブル |
| Format | 常時 | text / csv / binary(拡張フォーマット名も可) |
| Source(FROM)/ Target(TO) | 常時 | file / program / stdin / stdout |
| File | file/program 時 | ファイル名 or コマンド(文中に既出のため常時表示) |
| Freeze | FREEZE 時 | true |
| On Error | on_error != stop 時 | ignore / set_null |

オプションの単純な復唱(DELIMITER 等)は行わない(文面に書いてある情報で
あり、レビューで削られるのが常のため最小限とする)。

#### TEXT フォーマット出力例(0001)

```
=# EXPLAIN COPY tab FROM '/tmp/tab.csv' WITH (FORMAT csv);
                QUERY PLAN
------------------------------------------
 Copy From on tab
   Format: csv
   Source: file
   File: /tmp/tab.csv

=# EXPLAIN COPY (SELECT * FROM t WHERE a > 0) TO stdout;
                QUERY PLAN
------------------------------------------
 Seq Scan on t  (cost=0.00..41.88 rows=850 width=8)
   Filter: (a > 0)
 Copy To
   Format: text
   Target: stdout
```

JSON 出力例:

```json
[{ "Copy From": { "Relation Name": "tab", "Format": "csv",
                  "Source": "file", "File": "/tmp/tab.csv" } }]

[{ "Plan": { ... },
   "Copy": { "Format": "text", "Target": "stdout" } }]
```

FROM / relation TO は ExplainOpenGroup("Query", NULL, true, es) →
ExplainOpenGroup("Copy From", "Copy From", true, es) → プロパティ、の
入れ子で出力する(TEXT の見出し行 "Copy From on tab" は
format == EXPLAIN_FORMAT_TEXT のとき手動出力)。

### 0001-7. その他の変更

- **psql タブ補完** (src/bin/psql/tab-complete.in.c): EXPLAIN の後続候補に
  COPY を追加。
- **ドキュメント**: explain.sgml の対象文リスト(SELECT, INSERT, ...)に
  COPY を追加。「ANALYZE は 0001 時点では COPY に未対応」の footnote は
  シリーズ全体コミット時には不要になるため、0002/0003 と同時期の
  コミットを想定して段階ごとに記述を更新。copy.sgml から explain.sgml への
  相互参照を追加。
- **リグレッションテスト**: 新規 `src/test/regress/sql/explain_copy.sql`
  (+ expected、parallel_schedule への追加)。0001 分:
  - EXPLAIN COPY tbl FROM '/nonexistent'(実行しないため成功する)
  - EXPLAIN COPY tbl TO stdout / FROM stdin
  - EXPLAIN (FORMAT JSON) を explain.sql の explain_filter /
    explain_filter_to_json と同様のフィルタ関数で安定化
  - 権限エラー(非特権ロールで FROM 'file')、存在しないテーブル
  - EXPLAIN ANALYZE COPY ... が ERROR になること(0002/0003 で期待値更新)

### 0001-8. 変更ファイル一覧

```
src/backend/parser/gram.y                  | ExplainableStmt に CopyStmt
src/backend/commands/explain.c             | ディスパッチ + ExplainOnePlan 拡張
src/backend/commands/explain_copy.c        | 新規
src/backend/commands/copy.c                | ProcessCopyTarget 抽出
src/backend/commands/copyto.c              | CopyToTransformQuery 抽出
src/backend/commands/Makefile, meson.build | explain_copy.o 追加
src/include/commands/explain.h             | ExplainCopyStmt / ExplainOnePlan
src/include/commands/copy.h                | ProcessCopyTarget / CopyToTransformQuery
src/bin/psql/tab-complete.in.c
doc/src/sgml/ref/explain.sgml, copy.sgml
src/test/regress/{sql,expected}/explain_copy.*, parallel_schedule
```

---

## 0002: EXPLAIN ANALYZE COPY (query) TO

### 0002-1. 意味論(シリーズとして固定)

**ANALYZE 時、内包クエリは実行するが、COPY の整形出力は一切生成しない。**
ファイルは書かれず、STDOUT にもデータは送られない。

根拠: EXPLAIN ANALYZE SELECT が結果行をクライアントに送らないのと同じ
扱い。COPY TO の「書き込み」は外部への出力であり、CTAS / INSERT のような
データベース内の副作用(WAL・トリガ等、計測対象そのもの)とは性質が
異なる。この整理により:

- `TO STDOUT` でも CopyOutResponse が送られないためプロトコル問題が
  発生せず、**ANALYZE 時も STDIN/STDOUT 制限が不要**(TO 側)。
- 将来整形時間を計測する場合(Phase 4)も、EXPLAIN (SERIALIZE) と同様に
  「整形するが捨てる」DestReceiver を追加するだけで意味論が変わらない。

### 0002-2. 実装

0001 の ExplainCopyToQuery から `if (es->analyze) ereport(ERROR ...)` を
削除するだけで、実行は ExplainOnePlan が担う:

- es->analyze 時、ExplainOnePlan は into == NULL かつ SERIALIZE なしなら
  None_Receiver で ExecutorRun する(explain.c:550-594)。行は破棄される。
- ノード別実測時間・BUFFERS・WAL・Planning/Execution Time は既存機構が
  そのまま出力する。追加の計測コードはゼロ。

スナップショット処理は ExplainOnePlan の PushCopiedSnapshot +
UpdateActiveSnapshotCommandId(explain.c:539-540)が BeginCopyTo
(copyto.c:1021-1022)と同等のため追加対応不要。

`COPY relation TO`(query なし)の ANALYZE はプランを持たないため 0002 の
対象外とし、引き続き ERROR(メッセージ: "EXPLAIN ANALYZE is not supported
for COPY relation TO", HINT: "Use the COPY (SELECT ...) TO variant.")。
RLS 有効時は relation TO でも query に変換されるため ANALYZE 可能になる
点をテストで確認する。

### 0002-3. 出力例

```
=# EXPLAIN (ANALYZE, COSTS OFF) COPY (SELECT * FROM t) TO '/tmp/t.out';
                QUERY PLAN
------------------------------------------
 Seq Scan on t (actual time=0.010..45.2 rows=100000 loops=1)
 Copy To
   Format: text
   Target: file
   File: /tmp/t.out
 Planning Time: 0.100 ms
 Execution Time: 60.123 ms
```

(注: /tmp/t.out は作成されない。ドキュメントに明記する。)

### 0002-4. テスト・ドキュメント

- explain_filter 経由で (ANALYZE, TIMING OFF, SUMMARY OFF, COSTS OFF,
  BUFFERS OFF) の TEXT / JSON 出力を検証。
- `TO STDOUT` + ANALYZE でデータが送られないこと(psql 出力がプランのみ)。
- ファイルが作成されないことの確認(pg_stat_file がエラーになる等)。
- RLS 付き relation TO の ANALYZE が動くこと。
- explain.sgml: 「EXPLAIN ANALYZE COPY ... TO はクエリを実行するが出力先
  には何も書かれない」を明記。

### 0002-5. 変更ファイル一覧

```
src/backend/commands/explain_copy.c        | ANALYZE 許可(エラー分岐の整理)
doc/src/sgml/ref/explain.sgml
src/test/regress/{sql,expected}/explain_copy.*
```

---

## 0003: EXPLAIN ANALYZE COPY FROM + 時間内訳

### 0003-1. 意味論

- **実際にデータをロードする**(EXPLAIN ANALYZE INSERT と同じ)。
  ドキュメントに BEGIN; EXPLAIN ANALYZE COPY ...; ROLLBACK; の例を記載。
- `FROM STDIN` は ANALYZE 時 ERROR:
  "EXPLAIN ANALYZE cannot be used with COPY FROM STDIN"
  HINT "Use COPY FROM a file or PROGRAM."
  (EXPLAIN 応答中に CopyInResponse を送るとプロトコル上クライアントの
  想定を壊すため。非 ANALYZE は 0001 どおり許可。)
- 読み取り専用トランザクションでは既存 COPY FROM と同じく
  PreventCommandIfReadOnly(copy.c:364-365 と同一条件)。
- FREEZE / ON_ERROR / WHERE / トリガ / パーティションはすべて通常どおり
  動作する。

### 0003-2. 計測構造体と受け渡し

```c
/* src/include/commands/copy.h */
typedef struct CopyFromInstrumentation
{
    bool        collect_timing; /* es->timing: 位相別時間を計測するか */

    /* collect_timing 時のみ更新 */
    instr_time  input_time;     /* NextCopyFrom 合計(読込+パース+型変換) */
    instr_time  insert_time;    /* table_(multi_)insert / FDW insert */
    instr_time  index_time;     /* ExecInsertIndexTuples */

    /* 常時更新(既存カウンタの転記) */
    uint64      excluded;       /* WHERE で除外された行数 */
    uint64      skipped;        /* ON_ERROR でスキップされた行数 */

    /* トリガ実測(ri_TrigInstrument から集約、下記参照) */
    List       *triggers;       /* ExplainCopyTrigger のリスト */
} CopyFromInstrumentation;

/* copyfrom.c がエクスポート */
void CopyFromSetInstrumentation(CopyFromState cstate,
                                CopyFromInstrumentation *instr);
```

- `CopyFromStateData`(copyfrom_internal.h)に
  `CopyFromInstrumentation *instr`(既定 NULL)を追加。
- **BeginCopyFrom のシグネチャは変更しない**。BeginCopyFrom は file_fdw
  等の拡張から呼ばれる公開 API のため、セッター方式で後付けする。

### 0003-3. 計測ポイント(copyfrom.c)

タイマーはすべて `if (cstate->instr && cstate->instr->collect_timing)` で
ガードし、EXPLAIN 経由でない通常 COPY(instr == NULL)には**分岐 1 回以外の
コストを一切追加しない**。

1. **input_time**: メインループの NextCopyFrom 呼び出し
   (copyfrom.c:1151)を INSTR_TIME_SET_CURRENT 対で挟む。
   - 計測点が CopyFromRoutine->CopyFromOneRow のコールバック境界に一致
     するため、text/csv/binary だけでなくカスタムフォーマットも計測される。
   - ON_ERROR でスキップされる行のパースコストも含まれる(入力時間の
     一部として妥当)。
2. **insert_time / index_time**(2 経路):
   - 単一挿入経路: table_tuple_insert(copyfrom.c:1429)と
     ExecForeignInsert(copyfrom.c:1411)を insert_time で、
     ExecInsertIndexTuples(copyfrom.c:1433)を index_time で挟む。
   - マルチ挿入経路: CopyMultiInsertBufferFlush 内の
     table_multi_insert(copyfrom.c:556)を insert_time で、
     ExecInsertIndexTuples(copyfrom.c:576)を index_time で挟む
     (miinfo->cstate から instr に到達可能)。
   - フラッシュ内の AFTER ROW トリガ処理はタイマーの外に置き、トリガ
     計測(下記)に委ねる。
3. **トリガ**: EXPLAIN ANALYZE の既存トリガ計測機構を再利用する。
   - CopyFrom の初期化部で、instr 設定時に対象 ResultRelInfo の
     ri_TrigInstrument に InstrAlloc(numTriggers, INSTRUMENT_TIMER, false)
     を設定。パーティションルーティング時は resultRelInfo 切替ブロック
     (copyfrom.c:1220-1262)で未設定なら設定する。
   - trigger.c は ri_TrigInstrument が非 NULL なら自動的に計測する
     (trigger.c:2468 ほか)。
   - CopyFrom の終了処理(FreeExecutorState 前)で、estate の
     result-relation 群から {トリガ名, リレーション名, calls, total time}
     を instr->triggers に集約する(EState は CopyFrom のローカルで
     ある解放されるため、ここで転記が必要)。
4. **カウンタ**: excluded(copyfrom.c:1202 のローカル変数)と
   cstate->num_errors を終了時に instr へ転記。処理行数は CopyFrom の
   戻り値を使用。

### 0003-4. explain_copy.c の ANALYZE FROM 経路

```c
/* 0001 の ereport(ERROR) を置き換え */
if (es->analyze)
{
    CopyFromInstrumentation ci = {0};
    BufferUsage bufusage_start;         /* es->buffers 時 */
    WalUsage    walusage_start;         /* es->wal 時 */
    instr_time  starttime;
    uint64      processed;
    CopyFromState cstate;

    if (stmt->filename == NULL)
        ereport(ERROR, ... STDIN 拒否 ...);
    if (XactReadOnly && !rel->rd_islocaltemp)
        PreventCommandIfReadOnly("COPY FROM");

    ci.collect_timing = es->timing;
    ... bufusage_start / walusage_start 記録、starttime 記録 ...

    cstate = BeginCopyFrom(pstate, rel, whereClause, stmt->filename,
                           stmt->is_program, NULL, stmt->attlist,
                           stmt->options);
    CopyFromSetInstrumentation(cstate, &ci);
    processed = CopyFrom(cstate);
    EndCopyFrom(cstate);

    ... 差分算出、出力(下記) ...
}
```

BUFFERS / WAL は pgBufferUsage / pgWalUsage の差分を取り、explain.c の
show_buffer_usage() / show_wal_usage()(現在 static、explain.c:150-151)を
extern 化して再利用する。トリガ出力は report_triggers(explain.c:74)と
同一書式を explain_copy.c 側で生成する(データ源が ci.triggers のため)。

全体時間は starttime からの経過を es->summary 時に "Execution Time" として
出力(ExplainOnePlan と同書式)。プランニングが存在しないため
"Planning Time" は出力しない。

### 0003-5. 出力設計

TEXT(TIMING ON):

```
=# BEGIN;
=# EXPLAIN (ANALYZE, BUFFERS) COPY lineitem FROM '/tmp/lineitem.csv' (FORMAT csv);
                            QUERY PLAN
------------------------------------------------------------------
 Copy From on lineitem  (actual rows=6001215)
   Format: csv
   Source: file
   File: /tmp/lineitem.csv
   Input Time: 3210.456 ms
   Insert Time: 2103.222 ms
   Index Update Time: 812.345 ms
   Rows Skipped: 5
   Buffers: shared hit=12345 read=678 dirtied=91011 written=1213
   WAL: records=6001220 fpi=123 bytes=987654321
 Trigger trg_audit: time=102.334 calls=6001215
 Execution Time: 6543.210 ms
=# ROLLBACK;
```

表示規則:
- TIMING OFF 時は Input/Insert/Index Update Time の 3 行を出力しない
  (actual rows と各カウンタのみ)。
- Rows Excluded by Filter は WHERE 句がある場合のみ、Rows Skipped は
  ON_ERROR が stop 以外の場合のみ出力。
- Input Time は「読み込み+パース+型変換」の合計であることを
  ドキュメントに明記(細分化は Phase 4)。名称は bikeshed 対象として
  提案メールで代替案(Read Time / Parse Time 分離等)とともに提示する。

JSON:

```json
[{ "Copy From": {
     "Relation Name": "lineitem",
     "Format": "csv", "Source": "file", "File": "/tmp/lineitem.csv",
     "Actual Rows": 6001215,
     "Input Time": 3210.456,
     "Insert Time": 2103.222,
     "Index Update Time": 812.345,
     "Rows Skipped": 5,
     "Shared Hit Blocks": 12345, ...,
     "WAL Records": 6001220, ... },
   "Triggers": [ { "Trigger Name": "trg_audit", "Relation": "lineitem",
                   "Time": 102.334, "Calls": 6001215 } ],
   "Execution Time": 6543.210 }]
```

### 0003-6. オーバーヘッドの見積りと緩和

- TIMING ON 時の追加コストは行あたり clock_gettime × 2(input)+
  単一挿入経路なら × 4。Linux vDSO で 1 回 20〜30ns として 10^7 行で
  0.5〜1 秒程度、細い行の高速ロードでは 5〜10% 級になり得る。
- マルチ挿入経路のフラッシュは約 1000 行単位のため insert/index タイマーの
  コストは無視できる。支配項は input タイマー。
- 緩和策: `EXPLAIN (ANALYZE, TIMING OFF)` では位相別タイマーを完全に
  無効化し、カウンタのみ収集する(追加 clock 呼び出しゼロ)。
- 提案メールには pgbench 相当のベンチ結果を添付する:
  unpatched / patched+非EXPLAIN / ANALYZE+TIMING OFF / ANALYZE+TIMING ON を
  narrow(2 列)・wide(30 列)× 1000 万行で比較。

### 0003-7. テスト

```
\set filename :abs_builddir '/results/explain_copy.data'
COPY src_tbl TO :'filename';
BEGIN;
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY OFF, COSTS OFF)
  COPY dst_tbl FROM :'filename';
ROLLBACK;
```

- 出力の時間値・ブロック数は不定のため、基本は TIMING OFF + SUMMARY OFF +
  BUFFERS OFF で安定化し、TIMING ON の形は explain_filter(数値→N 置換)で
  1 ケースのみ検証。
- ケース: 単純ロード / WHERE 付き / ON_ERROR ignore(Rows Skipped)/
  BEFORE・AFTER トリガ付き(Trigger 行)/ パーティション先ロード /
  FDW 先(postgres_fdw regress は不可のため file_fdw 圏外、コアでは
  対象外とし contrib テスト追加は保留)/ FREEZE。
- エラー系: ANALYZE + STDIN、read-only トランザクション、REJECT_LIMIT 超過
  (途中エラーでも壊れないこと)。
- トランザクション内 ROLLBACK でデータが残らないこと。

### 0003-8. 変更ファイル一覧

```
src/backend/commands/copyfrom.c            | タイマー挿入、セッター、トリガ集約
src/include/commands/copyfrom_internal.h   | cstate->instr フィールド
src/include/commands/copy.h                | CopyFromInstrumentation / セッター
src/backend/commands/explain_copy.c        | ANALYZE FROM 経路と出力
src/backend/commands/explain.c             | show_buffer_usage 等の extern 化
src/include/commands/explain.h
doc/src/sgml/ref/explain.sgml, copy.sgml
src/test/regress/{sql,expected}/explain_copy.*
```

---

## シリーズ全体の残論点(提案メールに明記するもの)

1. **位相名の命名**(Input Time / Insert Time / Index Update Time)。
2. **EXPLAIN ANALYZE COPY TO が出力を生成しない**という意味論の是非
   (CTAS はテーブルを作るという非対称の説明)。
3. ExplainOnePlan のシグネチャ変更(拡張への影響)の許容。
4. 非 ANALYZE EXPLAIN でファイルを open しない(不存在を検出しない)ことの
   是非。
5. 将来課題: input の細分化(read/parse/convert)、COPY relation TO の
   ANALYZE、整形時間計測(SERIALIZE 型 DestReceiver)、パーティション別
   内訳、pg_stat_progress_copy との関係整理。
