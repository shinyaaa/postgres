# RLS 列レベルマスキング(Column-Level Masking)実装方針

本ドキュメントは、PostgreSQL の行レベルセキュリティ(RLS)を拡張し、
列レベルの動的データマスキングをネイティブに実装するための設計方針をまとめたものである。

- 対象ブランチ: `claude/rls-column-masking-plan-h0frux`
- 調査対象コードベース: PostgreSQL master(catversion 2026 系)

---

## 1. 目的と背景

現状の PostgreSQL には列単位でデータを「隠す」手段として以下があるが、いずれも不十分である。

| 手段 | 問題点 |
|---|---|
| 列権限 (`REVOKE SELECT (col)`) | 参照した瞬間にエラーになる。`SELECT *` が壊れ、アプリ互換性がない |
| ビュー + `security_barrier` | テーブルごとに手書きが必要。ビュー経由に迂回を強制できない |
| `postgresql_anonymizer` 拡張 | 外部拡張。動的マスキングはビュー/イベントトリガベースで運用が重い |
| RLS (`CREATE POLICY`) | 行単位のフィルタのみ。「行は見せるが特定列だけ隠す」ができない |

目的は、**行は返しつつ、ポリシー条件を満たさない利用者・行に対して特定列の値を
マスク式の評価結果に置き換えて返す**機能を、RLS と同じポリシー枠組みで提供することである。

```sql
-- 目指す利用イメージ
CREATE POLICY mask_ssn ON employees
    AS MASKING
    FOR SELECT
    TO public
    USING (manager = current_user)                     -- 条件を満たす行は素の値
    MASK (ssn WITH '***-**-' || right(ssn, 4));        -- 満たさない行はマスク値

SELECT name, ssn FROM employees;
--  name  |     ssn
-- -------+-------------
--  alice | 123-45-6789   ← 自分の部下: 素の値
--  bob   | ***-**-4321   ← 他人: マスク値(行自体は見える)
```

---

## 2. 他 RDBMS の調査まとめ

方針決定の参考として主要 RDBMS の類似機能を調査した。

### 2.1 IBM Db2 — `CREATE MASK`(最も参考にすべきモデル)

```sql
CREATE MASK ssn_mask ON employees FOR COLUMN ssn
  RETURN CASE WHEN VERIFY_ROLE_FOR_USER(SESSION_USER,'HR') = 1
              THEN ssn
              ELSE 'XXX-XX-' || SUBSTR(ssn, 8, 4)
         END
  ENABLE;
ALTER TABLE employees ACTIVATE COLUMN ACCESS CONTROL;
```

- マスクの実体は**列値を返す CASE 式**。宣言的で、行の値・セッション情報の両方を条件に使える。
- **1 列につき有効なマスクは 1 つ**。組み合わせ意味論の問題を仕様として回避している。
- 行フィルタ(`CREATE PERMISSION`)と列マスク(`CREATE MASK`)が同じ枠組み
  (Row and Column Access Control, RCAC)に統合されている。
- マスクは**最終出力(外側 SELECT の選択リスト)にのみ適用**され、WHERE 句・JOIN 条件は
  素の値で評価される(= 述語経由の推測リークは仕様として許容)。
- 有効化はテーブル単位の明示的スイッチ(`ACTIVATE COLUMN ACCESS CONTROL`)。

### 2.2 Oracle — VPD 列マスキング / Data Redaction

- VPD (`DBMS_RLS.ADD_POLICY`) の `sec_relevant_cols` + `sec_relevant_cols_opt => ALL_ROWS`:
  ポリシー述語を満たさない行でも行自体は返し、**該当列を NULL にする**。
  「行ごとの条件でマスクの有無が変わる」という RLS 統合型のモデルはここが源流。
  ただしマスク値は NULL 固定で、SELECT 文にしか適用されない。
- Data Redaction (`DBMS_REDACT`): FULL / PARTIAL / REGEXP / RANDOM などの定型マスク関数を
  列に紐付ける。適用は問い合わせ結果の出力段のみで、WHERE 句は素の値で評価される。

### 2.3 SQL Server — Dynamic Data Masking (DDM)

```sql
ALTER TABLE employees ALTER COLUMN ssn
  ADD MASKED WITH (FUNCTION = 'partial(0,"XXX-XX-",4)');
GRANT UNMASK ON employees(ssn) TO hr_role;   -- 列単位の UNMASK 権限
```

- マスクは列のプロパティであり、ポリシーオブジェクトではない。行条件は書けない。
- `UNMASK` 権限(近年は列単位まで細分化)でロールごとに素の値を許可。
- 適用は結果セットの出力段のみ。`WHERE salary > 100000` のような**述語ベースの
  推測攻撃が可能**なことが公式ドキュメントでも明記されており、DDM は
  「アクセス制御ではなく偶発的漏えい防止」と位置付けられている。

### 2.4 Snowflake — Masking Policy(再利用可能ポリシーオブジェクト)

```sql
CREATE MASKING POLICY ssn_mask AS (val string) RETURNS string ->
  CASE WHEN current_role() IN ('HR') THEN val ELSE '***' END;
ALTER TABLE employees MODIFY COLUMN ssn SET MASKING POLICY ssn_mask;
```

- ポリシーが独立オブジェクトで複数テーブルに再利用できる点が特徴。
- 式は対象列の値のみを引数に取り、同一行の他列は参照できない(条件列を追加で
  渡す "conditional masking" は別構文)。

### 2.5 比較と示唆

| 観点 | Db2 | Oracle VPD | SQL Server | Snowflake |
|---|---|---|---|---|
| 定義単位 | テーブル×列 | ポリシー(行条件つき) | 列プロパティ | 再利用可能オブジェクト |
| 行条件によるマスク切替 | ○(CASE で表現) | ○ | × | △ |
| マスク値の自由度 | 任意式 | NULL 固定 | 定型関数 | 任意式 |
| 述語は素の値で評価 | ○(リーク許容) | ○ | ○(リーク許容) | ×(参照全体に適用) |
| 1列複数マスク | 禁止 | — | — | 禁止 |

示唆:
1. **「マスク = 列値を返す任意式 + 適用条件」**というモデル(Db2/Oracle)が最も表現力が高く、
   PostgreSQL の `CREATE POLICY`(USING 句 = 行条件)と自然に統合できる。
2. **1 列 1 マスク**の制約(Db2/Snowflake)は、複数ポリシー合成の意味論の泥沼を避ける
   実績あるショートカットであり、v1 ではこれを踏襲すべき。
3. 「述語を素の値で評価するか」は各社で割れており、セキュリティと利便性のトレードオフの
   核心。PostgreSQL は RLS で leakproof 関数の枠組みまで作り込んだ経緯があるため、
   **述語経由リークを仕様として許容する設計はコミュニティに受け入れられにくい**と判断する
   (→ §4.3)。

---

## 3. 設計の全体方針(推奨案)

**「マスキングポリシー」という新しい種別を `CREATE POLICY` に追加し、
リライタ(rewriter)でテーブル参照を security_barrier 副問い合わせに置換して適用する。**

- 構文・カタログ・権限モデル・バイパス規則は既存 RLS に相乗りする
  (`pg_policy` 拡張、`check_enable_rls()` 再利用、`BYPASSRLS` / `row_security` GUC 準拠)。
- 意味論は「マスク対象ユーザーにとって、その列の値は*クエリ全体を通じて*マスク値である」
  (Snowflake 型)。SELECT リストだけでなく WHERE / JOIN / GROUP BY / ウィンドウ関数も
  マスク後の値を見る。述語経由の推測リークを構造的に排除する。
- 実装位置は `fireRIRrules()`(リライタ)。RLS の行ポリシーが `securityQuals` を注入するのと
  同じタイミングで、マスク対象 RTE をビュー展開と同様の副問い合わせに置き換える。

### 却下した代替案

| 代替案 | 却下理由 |
|---|---|
| (a) 出力段のみ適用(Db2/SQL Server 型): 最終 targetlist の Var だけ差し替え | 実装は最小だが `WHERE salary > 100000` で実値が推測できる。RLS が leakproof 機構まで備えて行値リークを塞いできた思想と矛盾し、-hackers で通らない可能性が高い |
| (b) 列プロパティ方式(`ALTER TABLE ... ALTER COLUMN ... SET MASKED`) | 行条件つきマスクが表現できず、ロール指定も別権限 (`UNMASK`) が必要になる。RLS と統合するという要件に合わない |
| (c) 再利用可能ポリシーオブジェクト(Snowflake 型、新カタログ + 新コマンド体系) | 表現力は魅力だが新規オブジェクト種別・依存関係・pg_dump 対応など初期コストが大きい。将来拡張として残す |
| (d) executor での適用(スキャンノードの投影で差し替え) | プランナが述語をスキャンより下に押し込むため「述語もマスク値を見る」意味論を保証できない。リライタ適用が正解 |

---

## 4. 詳細設計

### 4.1 SQL 構文

```
CREATE POLICY name ON table_name
    AS MASKING
    [ FOR SELECT ]                 -- v1 は SELECT(=読取り)のみ。省略時 SELECT
    [ TO { role_name | PUBLIC | CURRENT_ROLE | CURRENT_USER | SESSION_USER } [, ...] ]
    [ USING ( unmask_condition ) ] -- 真の行は素の値。省略時は常にマスク
    MASK ( column_name WITH expression [, ...] );

ALTER POLICY name ON table_name
    [ TO ... ] [ USING ( ... ) ] [ MASK ( ... ) ];

ALTER TABLE table_name { ENABLE | DISABLE | FORCE | NO FORCE } COLUMN MASKING;
```

- `AS MASKING` は既存の `AS { PERMISSIVE | RESTRICTIVE }` と同じ位置に追加する
  第三のポリシー種別。`MASKING` は非予約キーワードで足りる(gram.y 上は
  `RowSecurityDefaultPermissive` 相当の generic-option 扱いにできる)。
- `MASK` 句の意味: 実効的に各列参照が
  `CASE WHEN unmask_condition THEN col ELSE (expression) END` に置換される。
- `expression` の制約:
  - 対象列の型に暗黙キャスト可能であること(`coerce_to_target_type`、ビューの
    列型チェックと同様)。
  - 同一行の他列・対象列自身・`current_user` 等の STABLE 関数・サブリンクを参照可
    (RLS の USING と同じ `EXPR_KIND_POLICY` 系の新 `EXPR_KIND_COLUMN_MASK` で変換)。
  - 集約・ウィンドウ関数・SRF は不可(既存ポリシー式と同じ制限)。
- **制約: 1 列につき有効なマスクポリシーは 1 つ**(Db2 踏襲)。同一列に 2 つ目の
  MASKING ポリシーを作ろうとしたらエラー。TO のロールが違っても不可
  (ロール重複判定は一般に不能なため)。将来、ポリシー名順の CASE 合成で緩和可能。
- `polcmd` は v1 では SELECT 固定。将来 `FOR ALL` で RETURNING 等へ拡張余地を残すため
  構文上は FOR 句を受け付け、SELECT 以外はエラーにする。

### 4.2 カタログ変更

`pg_policy` に追加(`src/include/catalog/pg_policy.h`):

```c
CATALOG(pg_policy,3256,PolicyRelationId)
{
    ...
    char        polcmd;
    bool        polpermissive;
+   bool        polmasking;       /* マスキングポリシーか */

#ifdef CATALOG_VARLEN
    Oid         polroles[1];
    pg_node_tree polqual;         /* MASKING では unmask 条件として使う */
    pg_node_tree polwithcheck;    /* MASKING では常に NULL */
+   int2vector  polmaskcols;      /* マスク対象列の attnum 列(varlena 部) */
+   pg_node_tree polmaskexprs;    /* マスク式の List (polmaskcols と対応) */
#endif
}
```

- 種別表現は `polpermissive` を char 型 `polkind`('p'/'r'/'m')に置き換える案もあるが、
  既存カラムの互換破壊(psql 旧版・監視 SQL)を避けるため **bool 追加**とする。
- 依存関係: マスク式は `recordDependencyOnExpr()` で列・関数への依存を記録。
  対象列自体への依存も明示登録し、`ALTER TABLE DROP COLUMN` は
  RLS 同様ポリシーごと落とすのではなく**エラー**にする(ポリシーが黙って消えて
  マスクが外れる事故を防ぐ。`RemovePolicyById` の既存挙動と要整合確認)。
- `pg_class` に `relcolmasking` / `relforcecolmasking`(bool)を追加。
  `relrowsecurity` に相乗りしない理由: RLS の有効化は「ポリシーなし = default-deny」の
  意味論を持つため、マスクだけ使いたいテーブルで行が全部消える事故になる。
  独立フラグにすれば **MASKING ポリシーは行の可視性計算(default-deny 含む)に
  一切関与しない**、と単純に規定できる。
- `system_views.sql` の `pg_policies` ビューに `masking` 種別とマスク定義列
  (`pg_get_expr(polmaskexprs, polrelid)`)を追加。
- catversion バンプ。

### 4.3 適用の意味論

1. **どの参照に適用するか**: リレーションを「読む」すべての箇所。
   SELECT、DML の非対象リレーション(`UPDATE t1 ... FROM t2` の t2)、
   サブクエリ・CTE・ビュー内部の参照。適用後のクエリでは、その RTE 由来の
   マスク対象列の Var はすべて `CASE WHEN qual THEN col ELSE maskexpr END` を見る。
2. **述語もマスク値で評価する**(重要な決定)。
   `WHERE ssn = '123-45-6789'` はマスクされたユーザーには(素の値では)決してマッチしない。
   - 利点: 推測リークが構造的に不可能。EXPLAIN・エラーメッセージ・演算子の
     エラー経由のリーク(RLS が leakproof で対処した問題群)も、そもそも実値が
     プラン内に現れないため発生しない。
   - 代償: マスクされたユーザーはその列でのインデックス絞り込み・結合ができない
     (security_barrier 副問い合わせ越しになるため)。unmask 条件を満たすロールには
     従来どおりのプランを維持する(§4.4 の適用スキップ)。
3. **行条件つきマスク**: `USING (cond)` がある場合、行ごとに CASE で切り替わる。
   cond が真の行は素の値、偽の行はマスク値。Oracle VPD の ALL_ROWS 相当。
4. **DML 対象リレーション**(v1 の割り切り):
   結果リレーションの RTE は副問い合わせに置換できない。v1 では、
   マスクが適用されるユーザーが UPDATE/DELETE/MERGE の WHERE・SET・RETURNING で
   マスク対象列を**参照**した場合はエラーにする
   (`ERROR: column "ssn" is masked and cannot be referenced in DML`)。
   参照しない DML(`UPDATE t SET note = ... WHERE id = ...`)は従来どおり動く。
   列権限 REVOKE 時の挙動(エラー)と整合し、「更新はできるが古い値は読めない」を保証する。
   INSERT は既存値を読まないため無制限(`INSERT ... SELECT` のソース側は 1. で処理済み)。
5. **集約**: `count(ssn)`・`GROUP BY ssn` などもマスク値に対して動作する。
   統計的リーク(`GROUP BY` で「同じマスク値になる行数」が分かる等)は、マスク式が
   定数ならそもそも情報がない。行値依存のマスク式を書いた場合の漏えいは
   ポリシー作成者の責任としてドキュメント化する。

### 4.4 有効化・バイパス規則(RLS と対称)

`check_enable_rls()`(`src/backend/utils/misc/rls.c`)と並行な
`check_enable_colmask(relid, checkAsUser, noError)` を追加し、判定規則を揃える:

- `relcolmasking = false` → 適用なし。
- テーブルオーナー → `relforcecolmasking` でない限り適用なし。
- `BYPASSRLS` 属性ロール + `row_security = off` → 適用なし(既存 GUC を共用。
  マスク専用 GUC は増やさない)。`row_security = off` で素通しにできない一般ユーザーは
  RLS と同様、off 設定時はエラーにする(黙って実値を返さない)。
- `RLS_NONE_ENV` 相当の場合は `hasRowSecurity` フラグを立てて plancache の
  再プラン条件(ロール・GUC 変化)に載せる。**プランキャッシュの無効化機構は
  既存の `hasRowSecurity` をそのまま共用できる**(rowsecurity.c:544 と同じ扱い)。
- `row_security_active()` 同様の `column_masking_active(regclass)` SQL 関数を追加し、
  `pg_stats` / `pg_stats_ext` 系ビュー(system_views.sql:276 ほか 3 箇所)の
  ガード条件に **`AND NOT column_masking_active(c.oid)`** を追加する。
  これを忘れるとヒストグラム経由で実値が漏れる(RLS が既に塞いでいる穴と同型)。

### 4.5 実行時実装(リライタ)

適用箇所は `fireRIRrules()`(`src/backend/rewrite/rewriteHandler.c:2250` 付近)の
RLS 適用ループと同じ場所。処理の流れ:

1. `RelationBuildRowSecurity()`(`src/backend/commands/policy.c:193`)を拡張し、
   MASKING ポリシーも `RowSecurityDesc` にロードする
   (`RowSecurityPolicy` に `List *maskcols` / `List *maskexprs` を追加、
   もしくは並行の `ColumnMaskDesc` を relcache に持たせる。前者を推奨 —
   キャッシュ無効化・メモリコンテキスト管理をそのまま流用できる)。
2. 各 RTE について `check_enable_colmask()` → 適用対象なら、現在ロールに
   合致する(`check_role_for_policy()` 再利用)マスクポリシー群から
   列ごとの置換式 `CASE WHEN qual THEN Var ELSE maskexpr END` を組み立てる。
3. **RTE をビュー展開と同形の副問い合わせに置換**する:

   ```
   変換前:  SELECT name, ssn FROM employees WHERE ssn = $1;
   変換後:  SELECT name, ssn
            FROM (SELECT id, name,
                         CASE WHEN manager = current_user
                              THEN ssn ELSE '***-**-'||right(ssn,4) END AS ssn,
                         ...全列...
                  FROM employees) employees   -- security_barrier 相当
            WHERE ssn = $1;
   ```

   - 生成した subquery RTE に `security_barrier = true` を立て、外側の Var は
     `ReplaceVarsFromTargetList()`(`rewriteManip.h:113`)で付け替える。
     ビュー展開(`ApplyRetrieveRule`)と同じ既存経路なので、プランナ側
     (`planner.c:953` の securityQuals → SubqueryScan 化、`initsplan.c` の
     leakproof 押し込み制御)は**変更不要**。
   - 内側の素の `employees` RTE に対して行 RLS(`securityQuals`)が従来どおり付く。
     適用順は「行フィルタが先、マスクはその結果に対して」で一貫する。
   - `whole-row Var`(`employees.*` や `row_to_json(t)`)は副問い合わせの
     出力行を組むため自動的にマスク後の値になる。ここが targetlist 差し替え方式では
     漏れやすいポイントで、副問い合わせ方式の大きな利点。
   - マスク式内の Var/サブリンクには RLS と同様 `acquireLocksOnSubLinks` →
     `fireRIRonSubLink` → `setRuleCheckAsUser` の処理(rewriteHandler.c:2285-2337 と
     同じ枠組み)を通す。無限再帰検出(`activeRIRs`)も共用。
4. ビュー経由アクセス: ビュー内部の参照はビュー owner を `checkAsUser` として
   判定される(既存 RLS と同じ)。`security_invoker` ビューなら呼出しユーザーで判定。
   追加実装なしで整合する。

### 4.6 パーティション・継承

- RLS と同じ規則に揃える: パーティション親に定義したポリシーは親経由アクセスに適用され、
  子を直接叩く場合は子自身のポリシーのみ。ドキュメントに明記。
- 継承 (`SELECT FROM parent`) は親 RTE 段階で副問い合わせ化されるため、
  子テーブル展開(`inherit.c`)より前に適用されて一貫する。

### 4.7 ユーティリティ・周辺機能

| 機能 | 方針 |
|---|---|
| `COPY table TO` | 内部で SELECT クエリに変換される RLS 経路(copyto)に相乗り。マスク適用される |
| `pg_dump` | RLS と同一: デフォルト `row_security = off` で実行し、バイパスできなければエラー。黙ってマスク値をダンプしない。`--enable-row-security` 指定時はマスク値がダンプされる旨をドキュメント化 |
| 論理レプリケーション / `pg_basebackup` | ヒープ直読みのため対象外(RLS と同じ)。ドキュメントに明記 |
| `postgres_fdw` | リモート側ポリシーはリモートで適用される。ローカルテーブルに対する FDW 越し参照は通常経路 |
| インデックス・制約 | 実データは不変なので UNIQUE/FK/CHECK に影響なし |
| `EXPLAIN` | 副問い合わせとして見える。マスク式自体は表示されるが実値は含まれない |
| psql `\d` | 既存の "Policies:" 表示に `(MASKING)` 種別と MASK 句を追加(describe.c) |
| タブ補完 | `AS MASKING`, `MASK (`, `ENABLE COLUMN MASKING`(tab-complete.in.c) |

---

## 5. セキュリティ考慮事項(レビューで必ず突かれる点)

1. **述語リーク**: 本設計では構造的に不可能(§4.3-2)。Db2/SQL Server 型の
   出力段適用を選ばない最大の理由。
2. **統計情報リーク**: `pg_stats` 系ビューのガード追加(§4.4)。planner が使う
   統計自体は実値ベースだが、ユーザーに見える形では出ない(選択率経由の
   サイドチャネルは RLS と同水準の残余リスクとしてドキュメント化)。
3. **エラーメッセージリーク**: マスク式評価前の実値が constraint violation 等で
   出る経路はない(読取りは常に副問い合わせ越し)。DML は参照自体をエラーに
   するため old 値は出ない。
4. **マスク式自体の権限**: ポリシー定義はテーブルオーナーのみ(既存 RLS と同じ)。
   マスク式はクエリ実行ユーザー権限で評価される点も RLS の USING と同じ
   (悪意あるマスク式からの防御はオーナー信頼モデルで既存 RLS と同等)。
5. **`SET ROW_SECURITY = off` の扱い**: バイパス資格がなければエラー(黙って
   実値も黙ってマスク値も返さない)。RLS の既存挙動に揃える。

---

## 6. 実装ステップ(パッチ分割案)

コミュニティ投稿を想定し、独立レビュー可能な単位に分割する。

1. **Patch 1: カタログ + DDL**
   - `pg_policy.h`(polmasking/polmaskcols/polmaskexprs)、`pg_class`(relcolmasking/relforcecolmasking)
   - `gram.y` / `parsenodes.h`(CreatePolicyStmt/AlterPolicyStmt に mask リスト追加)
   - `policy.c`(CreatePolicy/AlterPolicy: `EXPR_KIND_COLUMN_MASK` での式変換、
     型整合チェック、1列1マスク検査、依存関係登録)
   - `tablecmds.c`(ENABLE/DISABLE/FORCE COLUMN MASKING)
   - `pg_policies` ビュー、psql `\d`、pg_dump、タブ補完
   - この段階ではポリシーは保存されるだけで適用されない(RLS 初期パッチと同じ進め方)
2. **Patch 2: 実行時適用**
   - `rls.c`(check_enable_colmask, column_masking_active)
   - `policy.c`(RelationBuildRowSecurity 拡張)+ `rowsecurity.h`
   - `rowsecurity.c`(get_column_masks() — ロール判定・CASE 式組み立て)
   - `rewriteHandler.c`(副問い合わせ置換、DML 参照エラー)
   - plancache 連携(hasRowSecurity 共用)
3. **Patch 3: 情報リーク封じとユーティリティ**
   - `system_views.sql`(pg_stats 系ガード)、COPY TO、pg_dump の安全側動作確認
4. **Patch 4: ドキュメント**
   - `create_policy.sgml` / `alter_policy.sgml` / `alter_table.sgml` /
     `ddl-rowsecurity.sgml`(新節「Column Masking」)/ `catalogs.sgml`

### テスト計画

- `src/test/regress/sql/rowsecurity.sql` 拡張(または新規 `colmasking.sql`):
  基本動作、行条件つきマスク、ロール切替、ビュー経由(owner/security_invoker)、
  パーティション、CTE/サブクエリ/whole-row Var、集約、DML エラー、
  BYPASSRLS/row_security GUC、FORCE、default(マスクなし)テーブルへの影響なし確認
- plancache テスト(ロール切替で再プラン)、EXPLAIN 出力確認
- `pg_dump` TAP テスト(バイパス不可時エラー / --enable-row-security 時の出力)
- psql describe / タブ補完テスト

---

## 7. 未解決課題・将来拡張

| 項目 | 状況 |
|---|---|
| DML 述語での参照許可(old 値をマスク値で評価する等) | v1 はエラー。MERGE/RETURNING の意味論整理後に緩和検討 |
| 1 列複数マスクの合成(ポリシー名順 CASE ネスト) | v1 は禁止。需要を見て検討 |
| 再利用可能マスク関数ライブラリ(`partial()`, `email()` 等の組込み) | contrib または core 関数として別提案。構文上は任意式なので後付け可能 |
| Snowflake 型の独立ポリシーオブジェクト | 将来の上位互換拡張として設計余地を確保(polmaskexprs を式リストにしてあるため移行可能) |
| インデックス利用不可の緩和(マスク式の leakproof 宣言によるプッシュダウン) | security_barrier の既存 leakproof 機構がそのまま効くため、leakproof な演算子は自動で押し込まれる。追加作業なしだが性能検証は必要 |
| `FOR SELECT` 以外(`FOR ALL`)の意味論 | 構文だけ予約。v1 はエラー |

---

## 8. 参考(調査したコード位置)

- ポリシー適用の入口: `src/backend/rewrite/rewriteHandler.c:2250-2358`(fireRIRrules)
- ポリシー収集と qual 構築: `src/backend/rewrite/rowsecurity.c:97-545`
- ポリシー DDL / relcache ロード: `src/backend/commands/policy.c`(RelationBuildRowSecurity:193)
- 有効化判定: `src/backend/utils/misc/rls.c:52`(check_enable_rls)
- securityQuals のプランナ処理: `src/backend/optimizer/plan/planner.c:949-1170`
- Var 置換ユーティリティ: `src/include/rewrite/rewriteManip.h:107-113`
- pg_stats の RLS ガード: `src/backend/catalog/system_views.sql:276,314,408`
- カタログ: `src/include/catalog/pg_policy.h`
