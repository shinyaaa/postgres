# EXPLAIN COPY 詳細設計(パッチ 0001〜0004)

対象: PostgreSQL 20devel (master)
目的: EXPLAIN の対象コマンドに COPY を追加し、COPY FROM の時間内訳を表示する。

## パッチ構成

リファクタリング(挙動変更なし)と機能追加を分離した 4 パッチ構成とする。

| パッチ | 内容 | 挙動変更 |
|---|---|---|
| 0001 | copy.c / copyto.c のリファクタリング(共通関数の抽出) | なし |
| 0002 | `EXPLAIN COPY ...`(全バリアント、ANALYZE なし) | 新機能 |
| 0003 | `EXPLAIN ANALYZE COPY (query) TO ...` | 新機能 |
| 0004 | `EXPLAIN ANALYZE COPY ... FROM ...` + 時間内訳 | 新機能 |

分割の方針:
- **純粋なコード移動は独立パッチにする**(0001)。レビュアーが
  「挙動変更なし」を diff だけで確認でき、機能部分の議論と切り離して
  先行コミットできる。
- **利用者のいない API 変更は機能パッチ側に残す**。ExplainOnePlan の
  パラメータ追加(0002)や CopyFromInstrumentation のセッター(0004)を
  先行パッチに切り出すと、in-tree の呼び出し元が存在しない dead code に
  なるため、それを使う機能と同じパッチに含める。

## 設計根拠: なぜ COPY (VERBOSE) オプションではなく EXPLAIN 拡張か

対抗案は「COPY にオプション(例: `COPY ... WITH (VERBOSE)`)を追加し、
完了時に NOTICE で内訳を出す」である。UI 層以外(計測コード = 0004 の
本体)は両案で共通であり、これは計測結果をどの機構に載せるかの選択で
ある。以下の理由で EXPLAIN を採る。

### 積極的根拠

1. **実行統計の取得は EXPLAIN ANALYZE の責務、という既存の役割分担**。
   INSERT / UPDATE / DELETE / MERGE / CTAS の実行統計はすべて
   EXPLAIN ANALYZE で取る。COPY FROM は意味的にはバルク INSERT であり
   (WHERE 句・トリガ・パーティションルーティングを持つ DML 的性格)、
   これだけ別の入口になるのはユーザーのメンタルモデル
   (「遅い文を調べる → EXPLAIN ANALYZE」)に反する。

2. **構造化出力(FORMAT JSON/XML/YAML)が無償で手に入る**。
   NOTICE は自由書式テキストで、監視ツールや解析ツールが機械可読に
   取れず、文言変更が事実上の互換性破壊になる。EXPLAIN の JSON なら
   フィールド追加が後方互換で行える。

3. **既存 EXPLAIN オプション体系との直交な合成**。TIMING ON/OFF・
   BUFFERS・WAL・SUMMARY・FORMAT がそのまま効き、計測オーバーヘッドの
   制御語彙(TIMING OFF)も再発明不要。VERBOSE 案ではこれらを COPY
   オプションとして重複定義していくことになる。

4. **出力チャネルの問題**。COPY の結果はコマンドタグのみで行を返す場所が
   なく、VERBOSE 案は必然的に NOTICE/ログになる。NOTICE はドライバに
   よって扱いが異なり、捨てられることもある。EXPLAIN は結果セットとして
   返すため全クライアントで一様に扱える。リグレッションテストも
   explain_filter 等の既存基盤に乗る。

5. **COPY (query) TO のプラン表示は EXPLAIN でしか成立しない**。内包
   クエリの実行計画を NOTICE に吐くのは auto_explain のログ形式問題の
   再来である。TO/FROM を一貫した UI で扱うなら EXPLAIN 側しかない。

6. **「実行しないで確認」(非 ANALYZE)が自然に手に入る**。COPY
   オプション案には「実行しない COPY」という概念がなく、dry-run 相当を
   別途発明する必要がある。

7. **副作用と計測の意味論が確立済み**。「EXPLAIN ANALYZE は実際に実行
   する」は INSERT/CTAS で周知・文書化済みで、COPY FROM にもそのまま
   適用できる。

### 対抗案の利点と反論

- **STDIN が計測できない(EXPLAIN 案の弱点)**: VERBOSE 案なら
  COPY FROM STDIN でも動くのは事実。ただし (a) チューニング目的の計測は
  サーバサイドファイル / PROGRAM での再現実験として行うのが通常で、
  実運用ストリームの常時計測は progress ビューやログの領分、
  (b) CopyFromInstrumentation はコマンド非依存に設計してあるため、
  STDIN 込みの軽量サマリが将来必要になれば、同じ計測基盤の上に
  log_verbosity 拡張等を後付けできる。**EXPLAIN 案は VERBOSE 案を排除
  しないが、逆(NOTICE テキストから構造化出力・プラン表示へ)は
  成り立たない**。
- **VACUUM (VERBOSE) 等の前例がある**: VACUUM / CLUSTER は プランを
  持たず、複数リレーションを対象にし得る純ユーティリティで、EXPLAIN の
  対象になりようがない。COPY は半分(query TO)が文字どおりプランを持ち、
  FROM も DML 的性格を持つ点で異なる。また VACUUM (VERBOSE) の出力が
  機械可読でないことは長年の不満で、pg_stat_progress_vacuum や
  log_autovacuum 系が別途必要になった経緯は、むしろ「VERBOSE テキストは
  行き止まり」であることの証左。
- **「EXPLAIN はプランの説明であり、プランのない COPY FROM は対象外」**:
  EXPLAIN は既に NOTIFY / EXECUTE / DECLARE CURSOR / CTAS という
  ユーティリティ文を扱っており(ExplainOneUtility)、実態は「文の実行
  内容と実行統計の説明」である。プランノードを持たない文への内訳表示は
  その自然な延長にある。

### その他想定される反論

#### (A) 代替手段系

- **「pg_stat_progress_copy を拡張すべき」**: progress ビューは実行中の
  外部観測用で、int64 スロット固定の軽量カウンタが設計思想。位相別時間の
  ような「終了時に確定する統計」を载せる場所ではなく、事後に結果が
  消える点でチューニング用途に合わない。両者は補完関係(実行中 =
  progress、事後の内訳 = EXPLAIN)と整理する。
- **「file_fdw + EXPLAIN ANALYZE INSERT ... SELECT で既に可能」**:
  計測されるのは file_fdw と ModifyTable の経路であり、COPY 本体
  (マルチ挿入バッファ、FREEZE、ON_ERROR、binary フォーマット)とは
  別コードパス。COPY の性能問題を調べたいのに COPY を通らない計測では
  答えにならない。file_fdw は contrib であり binary 非対応。
- **「perf / eBPF でプロファイルすれば取れる」**: 開発者向けの手段で
  あり、本番 DBA が権限なしで・文単位で・全プラットフォームで取れる
  手段にならない。EXPLAIN ANALYZE が存在するのと同じ理由がそのまま
  当てはまる。
- **「pg_stat_io 等の累積統計に載せるべき」**: 累積統計はインスタンス
  全体の傾向把握用で、特定の 1 文の内訳という問いに答えられない。

#### (B) 意味論・UX 系

- **「実際のロードは psql の \copy やドライバ経由(= FROM STDIN)が
  大半で、ANALYZE 不可では実用にならない」**(STDIN 反論の実務版):
  最も痛い反論として想定する。回答: (a) チューニングはサーバサイド
  ファイル / PROGRAM への再現で行うのが現実的で、同一データなら計測
  結果は転用できる(STDIN 固有コストはフロントエンド読込のみで、それは
  Input Time に現れる性質のもの)。(b) プロトコル上は EXPLAIN 応答中の
  CopyInResponse も可能で、psql は処理できる見込みがあるため、将来
  緩和の余地を残した「初期実装の制限」と位置づける。
- **「フェーズ合計 ≠ Execution Time で、差分は何かと必ず聞かれる」**:
  WHERE 評価・パーティションルーティング・BEFORE トリガ・制約検査・
  タプル具現化などは 3 フェーズのどれにも入らない。回答: 内訳は網羅
  ではなく支配項の特定が目的であり、差分は「その他(ルーティング・
  制約等)」としてドキュメントに明記する。enum + 配列の設計により
  フェーズの追加は後方互換で行える。合計行を出さないことで「完全な
  分解」に見せない。
- **「計測が計測対象を歪める(観測者効果)」**: TIMING ON の行単位
  タイマーで Input Time 自体が膨らむ。回答: EXPLAIN ANALYZE のプラン
  計測と同じ既知の性質で、既にドキュメント化された注意事項の適用範囲を
  広げるだけ。相対比較(どのフェーズが支配的か)には有効で、絶対値が
  必要なら TIMING OFF + 全体時間で確認できる。
- **「EXPLAIN ANALYZE でデータが入るのは危険 / 驚き」**: INSERT / CTAS
  で確立済みの意味論であり、ドキュメントに BEGIN/ROLLBACK 例を載せる。
  「挿入せずパースだけ計測する dry-run」は実挿入と数値が乖離するため
  採らない(要望が強ければ将来の別オプション)。
- **「サポートマトリクスが歯抜け(STDIN は非 ANALYZE のみ、relation TO
  は ANALYZE 不可)で分かりにくい」**: 各制限に HINT 付きの明確な
  エラーを出し、ドキュメントに対応表を載せる。歯抜けを理由に全部入りを
  待つより、段階的に埋める方が本体の流儀(MERGE の段階的拡張等)。

#### (C) 実装・保守系

- **「auto_explain で拾えないため、本番で遅かった夜間ロードの事後調査
  には使えない」**: auto_explain は Executor フック依存でユーティリティ
  文を扱えない。回答: 本パッチの計測基盤(CopyFromInstrumentation)は
  EXPLAIN 非依存なので、将来 auto_explain のユーティリティ対応や
  log_verbosity 拡張を同じ基盤で実装できる。本提案はその第一歩。
- **「pg_stat_statements との整合」**: EXPLAIN ANALYZE COPY は内側の
  CopyStmt が ProcessUtility を通らないため pgss に COPY として計上
  されない。これは EXPLAIN ANALYZE INSERT 等の既存挙動と同等であり、
  新たな非一貫性ではないことを説明する。
- **「ホットループに計測点を撒くと将来の COPY 改修で腐る」**: 挿入経路の
  追加時に計測漏れが起き得る。回答: 計測点は CopyFromRoutine 境界と
  tableam / index / trigger 呼び出しという安定した抽象境界に限定して
  おり、無秩序に散らしていない。リグレッションテストで各フェーズが
  非ゼロになるケースを持つことで漏れを検出する。
- **「将来のパラレル COPY と衝突しないか」**: フェーズ別 instr_time
  配列はワーカー毎に持って合算可能な構造(Instrumentation の集約と
  同型)であり、設計上の障害にならない。

実行意味論(シリーズとして最初に固定し、以後変更しない):

| コマンド | ANALYZE なし | ANALYZE あり |
|---|---|---|
| COPY ... FROM | 実行しない | 実際にロードする(0004) |
| COPY (query) TO | 実行しない(プランのみ表示) | クエリを実行、COPY 出力は生成しない(0003) |
| COPY relation TO | 実行しない | ERROR(将来課題) |

---

## 0001: copy.c / copyto.c のリファクタリング

挙動変更を一切含まない、共通関数の抽出のみのパッチ。コミットメッセージに
"No functional changes." と、0002 以降で EXPLAIN から再利用する予定である
ことを明記する。新規テストは追加しない(既存リグレッションテストが
そのまま通ることが検証条件)。

### 0001-1. copy.c: ProcessCopyTarget の抽出

DoCopy(copy.c:63-386)の前半(74〜355 行: 権限チェック〜RLS 変換)を
共通関数に抽出する。

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

### 0001-2. copyto.c: CopyToTransformQuery の抽出

BeginCopyTo のクエリ解析・検証部(copyto.c:909-986)を抽出する。

```c
/* copyto.c / copy.h */
Query *CopyToTransformQuery(ParseState *pstate, RawStmt *raw_query);
```

内容: pg_analyze_and_rewrite_fixedparams、DO INSTEAD ルール拒否、
SELECT INTO 拒否、ユーティリティ文拒否、RETURNING 必須チェック。
プランニングと relationOids 再確認(copyto.c:989-1015)は BeginCopyTo に
残す(0003 の EXPLAIN 経路は自前でプランニングするため)。

### 0001-3. 変更ファイル一覧

```
src/backend/commands/copy.c                | ProcessCopyTarget 抽出
src/backend/commands/copyto.c              | CopyToTransformQuery 抽出
src/include/commands/copy.h                | 両関数の宣言
```

備考: 2 関数を 1 パッチにまとめるのは、いずれも「COPY 文のセットアップを
EXPLAIN から再利用可能にする」という同一目的の抽出であるため。レビューで
分割を求められた場合はファイル単位(copy.c / copyto.c)で容易に分割できる。

---

## 0002: 文法・ディスパッチ・非 ANALYZE の EXPLAIN

### 0002-1. 文法 (src/backend/parser/gram.y)

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

### 0002-2. パース解析

変更不要。`transformExplainStmt`(analyze.c:3461)は内包文を
`transformOptionalSelectInto` → `transformStmt` に渡し、CopyStmt は
transformStmt の default 分岐(analyze.c:435-444)で CMD_UTILITY の Query に
包まれる。実行時は ExplainQuery → ExplainOneQuery → ExplainOneUtility に
到達する(NotifyStmt と同じ経路)。

### 0002-3. ディスパッチ (src/backend/commands/explain.c)

`ExplainOneUtility()`(explain.c:396)の NotifyStmt 分岐の前に追加:

```c
else if (IsA(utilityStmt, CopyStmt))
    ExplainCopyStmt(castNode(CopyStmt, utilityStmt), es, pstate, params);
```

CopyStmt は変更しない(const 扱い)ため、EXPLAIN EXECUTE 経路のような
copyObject は不要。

### 0002-4. explain_copy.c(新規ファイル)

explain.c は近年 explain_dr.c / explain_format.c / explain_state.c に分割
されており、この流れに沿って `src/backend/commands/explain_copy.c` を新設。

```c
/* explain.h に宣言 */
void ExplainCopyStmt(CopyStmt *stmt, ExplainState *es,
                     ParseState *pstate, ParamListInfo params);
```

0002 時点の処理フロー:

```
ProcessCopyTarget(pstate, stmt, ..., &rel, &relid, &query, &whereClause);

if (stmt->is_from)
{
    if (es->analyze)
        ereport(ERROR, "EXPLAIN ANALYZE is not yet supported for COPY FROM");
        /* 0004 で解除 */
    ExplainCopyFromInfo(stmt, rel, es);      /* 静的情報のみ */
}
else if (query != NULL)          /* COPY (query) TO / RLS 変換された relation TO */
{
    if (es->analyze)
        ereport(ERROR, "...");   /* 0003 で解除 */
    ExplainCopyToQuery(stmt, query, relid, es, pstate, params);
}
else                             /* COPY relation TO */
{
    if (es->analyze)
        ereport(ERROR, "...");   /* relation TO の ANALYZE は将来課題 */
    ExplainCopyToInfo(stmt, rel, es);
}

if (rel)
    table_close(rel, NoLock);
```

STDIN/STDOUT は 0002 では**許可**する(実行しないためプロトコル問題は
発生しない)。ANALYZE 時の制限は 0003/0004 で導入する。

非 ANALYZE の EXPLAIN でも ProcessCopyTarget を通すことで、存在しない
テーブル・権限不足は通常の COPY と同様に検出される(EXPLAIN INSERT が
ExecutorStart で ACL チェックされるのと整合)。ファイルは open しないため、
ファイル不存在は検出されない(EXPLAIN の一般的な性質として許容し、
ドキュメントに記載)。

#### ExplainCopyToQuery の実装(0002 の中核)

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

このパラメータ追加は 0002 で初めて使うため、0001 には含めず本パッチに
含める(dead code を作らない)。

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

#### TEXT フォーマット出力例(0002)

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

### 0002-5. その他の変更

- **psql タブ補完** (src/bin/psql/tab-complete.in.c): EXPLAIN の後続候補に
  COPY を追加。
- **ドキュメント**: explain.sgml の対象文リスト(SELECT, INSERT, ...)に
  COPY を追加。copy.sgml から explain.sgml への相互参照を追加。
- **リグレッションテスト**: 新規 `src/test/regress/sql/explain_copy.sql`
  (+ expected、parallel_schedule への追加)。0002 分:
  - EXPLAIN COPY tbl FROM '/nonexistent'(実行しないため成功する)
  - EXPLAIN COPY tbl TO stdout / FROM stdin
  - EXPLAIN (FORMAT JSON) を explain.sql の explain_filter /
    explain_filter_to_json と同様のフィルタ関数で安定化
  - 権限エラー(非特権ロールで FROM 'file')、存在しないテーブル
  - EXPLAIN ANALYZE COPY ... が ERROR になること(0003/0004 で期待値更新)

### 0002-6. 変更ファイル一覧

```
src/backend/parser/gram.y                  | ExplainableStmt に CopyStmt
src/backend/commands/explain.c             | ディスパッチ + ExplainOnePlan 拡張
src/backend/commands/explain_copy.c        | 新規
src/backend/commands/Makefile, meson.build | explain_copy.o 追加
src/include/commands/explain.h             | ExplainCopyStmt / ExplainOnePlan
src/bin/psql/tab-complete.in.c
doc/src/sgml/ref/explain.sgml, copy.sgml
src/test/regress/{sql,expected}/explain_copy.*, parallel_schedule
```

---

## 0003: EXPLAIN ANALYZE COPY (query) TO

### 0003-1. 意味論(シリーズとして固定)

**ANALYZE 時、内包クエリは実行するが、COPY の整形出力は一切生成しない。**
ファイルは書かれず、STDOUT にもデータは送られない。

根拠: EXPLAIN ANALYZE SELECT が結果行をクライアントに送らないのと同じ
扱い。COPY TO の「書き込み」は外部への出力であり、CTAS / INSERT のような
データベース内の副作用(WAL・トリガ等、計測対象そのもの)とは性質が
異なる。この整理により:

- `TO STDOUT` でも CopyOutResponse が送られないためプロトコル問題が
  発生せず、**ANALYZE 時も STDIN/STDOUT 制限が不要**(TO 側)。
- 将来整形時間を計測する場合も、EXPLAIN (SERIALIZE) と同様に
  「整形するが捨てる」DestReceiver を追加するだけで意味論が変わらない。

### 0003-2. 実装

0002 の ExplainCopyToQuery から `if (es->analyze) ereport(ERROR ...)` を
削除するだけで、実行は ExplainOnePlan が担う:

- es->analyze 時、ExplainOnePlan は into == NULL かつ SERIALIZE なしなら
  None_Receiver で ExecutorRun する(explain.c:550-594)。行は破棄される。
- ノード別実測時間・BUFFERS・WAL・Planning/Execution Time は既存機構が
  そのまま出力する。追加の計測コードはゼロ。

スナップショット処理は ExplainOnePlan の PushCopiedSnapshot +
UpdateActiveSnapshotCommandId(explain.c:539-540)が BeginCopyTo
(copyto.c:1021-1022)と同等のため追加対応不要。

`COPY relation TO`(query なし)の ANALYZE はプランを持たないため 0003 の
対象外とし、引き続き ERROR(メッセージ: "EXPLAIN ANALYZE is not supported
for COPY relation TO", HINT: "Use the COPY (SELECT ...) TO variant.")。
RLS 有効時は relation TO でも query に変換されるため ANALYZE 可能になる
点をテストで確認する。

### 0003-3. 出力例

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

### 0003-4. テスト・ドキュメント

- explain_filter 経由で (ANALYZE, TIMING OFF, SUMMARY OFF, COSTS OFF,
  BUFFERS OFF) の TEXT / JSON 出力を検証。
- `TO STDOUT` + ANALYZE でデータが送られないこと(psql 出力がプランのみ)。
- ファイルが作成されないことの確認(pg_stat_file がエラーになる等)。
- RLS 付き relation TO の ANALYZE が動くこと。
- explain.sgml: 「EXPLAIN ANALYZE COPY ... TO はクエリを実行するが出力先
  には何も書かれない」を明記。

### 0003-5. 変更ファイル一覧

```
src/backend/commands/explain_copy.c        | ANALYZE 許可(エラー分岐の整理)
doc/src/sgml/ref/explain.sgml
src/test/regress/{sql,expected}/explain_copy.*
```

---

## 0004: EXPLAIN ANALYZE COPY FROM + 時間内訳

### 0004-1. 意味論

- **実際にデータをロードする**(EXPLAIN ANALYZE INSERT と同じ)。
  ドキュメントに BEGIN; EXPLAIN ANALYZE COPY ...; ROLLBACK; の例を記載。
- `FROM STDIN` は ANALYZE 時 ERROR:
  "EXPLAIN ANALYZE cannot be used with COPY FROM STDIN"
  HINT "Use COPY FROM a file or PROGRAM."
  (EXPLAIN 応答中に CopyInResponse を送るとプロトコル上クライアントの
  想定を壊すため。非 ANALYZE は 0002 どおり許可。)
- 読み取り専用トランザクションでは既存 COPY FROM と同じく
  PreventCommandIfReadOnly(copy.c:364-365 と同一条件)。
- FREEZE / ON_ERROR / WHERE / トリガ / パーティションはすべて通常どおり
  動作する。

### 0004-2. 計測構造体と受け渡し

計測フェーズを enum で定義し、位相別時間は enum で添字付けする配列で
保持する(EXPLAIN 出力側・将来のフェーズ追加の双方で扱いやすい)。

```c
/* src/include/commands/copy.h */

/* COPY FROM の計測フェーズ */
typedef enum CopyFromPhase
{
    COPY_FROM_PHASE_INPUT,      /* NextCopyFrom: 読込+パース+型変換
                                 * (DEFAULT 式の評価を含む) */
    COPY_FROM_PHASE_INSERT,     /* table_(multi_)insert / FDW insert */
    COPY_FROM_PHASE_INDEX,      /* ExecInsertIndexTuples */
} CopyFromPhase;

#define COPY_FROM_NUM_PHASES  (COPY_FROM_PHASE_INDEX + 1)

typedef struct CopyFromInstrumentation
{
    bool        collect_timing; /* es->timing: 位相別時間を計測するか */

    /* collect_timing 時のみ更新 */
    instr_time  phase_start;    /* 実行中フェーズの開始時刻 */
    instr_time  phase_time[COPY_FROM_NUM_PHASES];   /* フェーズ別累積時間 */

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
- セッターとフィールドは本パッチで初めて使われるため、リファクタリング
  パッチ(0001)には含めない(dead code を作らない)。

### 0004-3. 計測 API(スタート/ストップ)

呼び出し箇所(メインループとマルチ挿入フラッシュ)はいずれも copyfrom.c
内だが、将来 copyfromparse.c での read 時間細分化にも使えるよう、
copyfrom_internal.h に static inline で定義する。

```c
/* src/include/commands/copyfrom_internal.h */

/*
 * フェーズ計測の開始。計測が無効(instr == NULL または timing off)なら
 * 何もしない。フェーズはネスト不可(単一の phase_start を共有するため)。
 */
static inline void
CopyFromInstrStartPhase(CopyFromState cstate)
{
    CopyFromInstrumentation *ci = cstate->instr;

    if (ci == NULL || !ci->collect_timing)
        return;
    Assert(INSTR_TIME_IS_ZERO(ci->phase_start));    /* ネスト検出 */
    INSTR_TIME_SET_CURRENT(ci->phase_start);
}

/*
 * フェーズ計測の終了。経過時間を phase_time[phase] に加算する。
 */
static inline void
CopyFromInstrStopPhase(CopyFromState cstate, CopyFromPhase phase)
{
    CopyFromInstrumentation *ci = cstate->instr;
    instr_time  now;

    if (ci == NULL || !ci->collect_timing)
        return;
    INSTR_TIME_SET_CURRENT(now);
    INSTR_TIME_ACCUM_DIFF(ci->phase_time[phase], now, ci->phase_start);
    INSTR_TIME_SET_ZERO(ci->phase_start);           /* ネスト検出用 */
}
```

設計上のポイント:

- **ガードは関数内**に置き、呼び出し箇所は常に 1 行にする(ホットループの
  可読性維持)。通常 COPY(instr == NULL)の追加コストは分岐 1 回のみ。
- **start はフェーズ引数を取らない**。フェーズの区別が必要なのは累積先を
  決める stop 側だけであり、start を軽くする。
- **フェーズはネストしない**という不変条件を置く。3 フェーズの計測区間は
  すべて逐次(NextCopyFrom → [flush: multi_insert → index] → 次行)で
  重ならないため、単一の phase_start で足りる。誤用は
  Assert(INSTR_TIME_IS_ZERO) がアサートビルドで検出する
  (INSTR_TIME_SET_ZERO は数命令なので非アサートビルドでも許容)。
- **エラー時の後始末は不要**。計測途中で ereport(ERROR) が起きた場合
  (ON_ERROR stop のパースエラー等)は文全体が中断され EXPLAIN 出力自体が
  行われないため、走りかけのフェーズ時間は捨てられるだけでよい。
  ON_ERROR ignore のソフトエラーは NextCopyFrom が正常返却するので、
  直後の stop が通常どおり実行される。

### 0004-4. 計測ポイント(copyfrom.c への挿入箇所)

| フェーズ | start | stop | 箇所 |
|---|---|---|---|
| INPUT | NextCopyFrom 呼び出し直前 | 直後 | copyfrom.c:1151(メインループ) |
| INSERT | table_tuple_insert 直前 | 直後 | copyfrom.c:1429(単一挿入) |
| INSERT | ExecForeignInsert 直前 | 直後 | copyfrom.c:1411(FDW 単一挿入) |
| INSERT | table_multi_insert 直前 | 直後 | copyfrom.c:556(フラッシュ) |
| INDEX | ExecInsertIndexTuples 直前 | 直後 | copyfrom.c:1433(単一挿入) |
| INDEX | ExecInsertIndexTuples 直前 | 直後 | copyfrom.c:576(フラッシュ内の行ループ) |

挿入例(メインループ、copyfrom.c:1151):

```c
    CopyFromInstrStartPhase(cstate);
    if (!NextCopyFrom(cstate, econtext, myslot->tts_values, myslot->tts_isnull))
    {
        CopyFromInstrStopPhase(cstate, COPY_FROM_PHASE_INPUT);
        break;
    }
    CopyFromInstrStopPhase(cstate, COPY_FROM_PHASE_INPUT);
```

挿入例(フラッシュ内、copyfrom.c:556 / 576。cstate は
miinfo->cstate から取得):

```c
    CopyFromInstrStartPhase(cstate);
    table_multi_insert(resultRelInfo->ri_RelationDesc,
                       slots, nused, mycid, ti_options, buffer->bistate);
    CopyFromInstrStopPhase(cstate, COPY_FROM_PHASE_INSERT);

    for (i = 0; i < nused; i++)
    {
        ...
        CopyFromInstrStartPhase(cstate);
        recheckIndexes = ExecInsertIndexTuples(...);
        CopyFromInstrStopPhase(cstate, COPY_FROM_PHASE_INDEX);
        ExecARInsertTriggers(...);      /* タイマー外(トリガ計測に委ねる) */
        ...
    }
```

計測意味論の注記:

- INPUT は CopyFromRoutine->CopyFromOneRow のコールバック境界に一致する
  ため、text/csv/binary だけでなくカスタムフォーマットも計測される。
- INPUT には ON_ERROR でスキップされる行のパースコスト、および DEFAULT 式
  の評価コストが含まれる。
- INDEX のフラッシュ内計測は行単位の start/stop になるが、発生するのは
  インデックスが存在する場合のみで、コストは INPUT タイマー(全行で発生)
  と同オーダー以下。
- 検討した代替案: 既存の instrument.c(InstrStartNode / InstrStopNode +
  NodeInstrumentation)をフェーズごとに割り当てる案。フェーズ別
  BufferUsage が将来ほぼ無償で得られる利点はあるが、firsttuple /
  tuplecount 等プランノード前提の管理が不要に付いてくること、構造体が
  EXPLAIN 出力側に対して過剰であることから、軽量な専用 API を採用した。
  提案メールには代替案として記載する。

### 0004-5. トリガ・カウンタの計測

1. **トリガ**: EXPLAIN ANALYZE の既存トリガ計測機構を再利用する。
   - CopyFrom の初期化部で、instr 設定時に対象 ResultRelInfo の
     ri_TrigInstrument に InstrAlloc(numTriggers, INSTRUMENT_TIMER, false)
     を設定。パーティションルーティング時は resultRelInfo 切替ブロック
     (copyfrom.c:1220-1262)で未設定なら設定する。
   - trigger.c は ri_TrigInstrument が非 NULL なら自動的に計測する
     (trigger.c:2468 ほか)。
   - CopyFrom の終了処理(FreeExecutorState 前)で、estate の
     result-relation 群から {トリガ名, リレーション名, calls, total time}
     を instr->triggers に集約する(EState は CopyFrom のローカルで
     あり解放されるため、ここで転記が必要)。
2. **カウンタ**: excluded(copyfrom.c:1202 のローカル変数)と
   cstate->num_errors を終了時に instr へ転記。処理行数は CopyFrom の
   戻り値を使用。

### 0004-6. explain_copy.c の ANALYZE FROM 経路

```c
/* 0002 の ereport(ERROR) を置き換え */
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

### 0004-7. 出力設計

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
  ドキュメントに明記(細分化は将来課題)。名称は bikeshed 対象として
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

### 0004-8. オーバーヘッドの見積りと緩和

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

### 0004-9. テスト

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
  BEFORE・AFTER トリガ付き(Trigger 行)/ パーティション先ロード / FREEZE。
- エラー系: ANALYZE + STDIN、read-only トランザクション、REJECT_LIMIT 超過
  (途中エラーでも壊れないこと)。
- トランザクション内 ROLLBACK でデータが残らないこと。

### 0004-10. 変更ファイル一覧

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
