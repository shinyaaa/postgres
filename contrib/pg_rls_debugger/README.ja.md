# pg_rls_debugger — 行レベルセキュリティ（RLS）のX線透視

**「なぜこのユーザーにはこの行が見えないのか？」**

行レベルセキュリティ（RLS）はPostgreSQLの強力な機能ですが、デバッグは最悪です。
ポリシーが期待どおりに動かなくても、エラーは一切出ません。行がただ静かに消えるだけ。
ポリシー式が悪いのか？ ロール指定か？ RESTRICTIVEポリシーか？
そもそもそのロールにRLSが適用されているのか（テーブル所有者だからバイパスされていないか）？
結局 `SET ROLE` を繰り返してポリシーを手作業で二分探索する羽目になります。

`pg_rls_debugger` はこの質問に一発で答えます:

```sql
SELECT pg_rls_why('docs', '(0,3)', 'alice', 'select');
```

```
 RLS debug report for table public.docs
   row (0,3), role alice, command SELECT
   status: RLS is applied to role alice on public.docs: 4 of 5 policies match the role

   PERMISSIVE policy p_admin_all (FOR ALL): skipped, role does not match
   PERMISSIVE policy p_insert_self (FOR INSERT): skipped, command does not match
   PERMISSIVE policy p_owner (FOR ALL):
     USING ((owner = CURRENT_USER)) => pass
   PERMISSIVE policy p_public_read (FOR SELECT):
     USING (is_public) => fail
   RESTRICTIVE policy r_tenant (FOR ALL):
     USING ((tenant = 1)) => fail

 VERDICT: role alice CANNOT SELECT this row.
 Reason: restrictive policy failed: r_tenant
```

すべてのポリシー・すべての句を、実際の行に対して、**対象ロールとして**評価し、
ポリシーごとの pass/fail と、エグゼキュータと同じ規則で合成した最終判定を返します。

## 関数一覧

| 関数 | 答えてくれること |
|---|---|
| `pg_rls_status(rel, role)` | そもそもこのロールにRLSが適用されるのか？（スーパーユーザー / BYPASSRLS / 所有者 / RLS未有効でバイパスされていないか） |
| `pg_rls_policies(rel, role)` | どんなポリシーがあり、どれがこのロールに掛かるのか？ |
| `pg_rls_check_row(rel, ctid, role, cmd)` | 既存の1行に対する各ポリシーの USING / WITH CHECK の評価結果 |
| `pg_rls_check_values(rel, jsonb, role, cmd)` | 仮想の行に対する同上 — INSERTの WITH CHECK を**実行前に**テスト |
| `pg_rls_why(rel, ctid, role, cmd)` | 上記の人間可読レポート |
| `pg_rls_hidden_rows(rel, role, cmd, max_rows, scan_limit)` | テーブルをスキャンし、そのロールに**見えない**行を理由付きで列挙 |

`role` のデフォルトは `current_user`、`cmd` のデフォルトは `SELECT`
（`pg_rls_check_values` のみ `INSERT`）です。

## クイックツアー

```sql
CREATE EXTENSION pg_rls_debugger;

-- 1. まず現状確認: このロールにRLSは効いているか？
SELECT rls_applied, summary FROM pg_rls_status('docs', 'alice');
--  f | RLS is enabled on public.docs but role alice owns the table
--      and FORCE ROW LEVEL SECURITY is not set

-- 2. alice に見えない行はどれで、なぜか？
SELECT row_data->>'id' AS id, reason
  FROM pg_rls_hidden_rows('docs', 'alice');
--  3 | no permissive policy passed: p_owner => fail, p_public_read => fail

-- 3. このINSERTは弾かれる？ 実行せずに確認:
SELECT policy_name, check_result
  FROM pg_rls_check_values('docs',
       '{"id": 99, "owner": "alice", "tenant": 2}', 'alice')
 WHERE applies_to_role AND applies_to_cmd;
--  p_insert_self | pass
--  r_tenant      | fail
```

「ユーザーXにデータが見えない」というバグ報告への定番の流れ:

1. `pg_rls_status` — そもそもRLSが適用されているか？（RLSバグの半分はここで
   終わります: BYPASSRLS持ち、テーブル所有者、RLS未有効。summary は
   「ポリシーはあるのに ENABLE ROW LEVEL SECURITY を忘れている」ケースや
   デフォルト拒否も明示します）
2. `pg_rls_policies` — そのロール・そのコマンドに掛かるポリシーはあるか？
3. 見えるはずの行に `pg_rls_why` — VERDICT を読む。

## インストール

PostgreSQLソースツリーの一部として（このリポジトリ）:

```sh
cd contrib/pg_rls_debugger
make && make install
make check               # リグレッションテスト
```

既存のPostgreSQLに対してスタンドアロンで（PGXS経由）:

```sh
cd contrib/pg_rls_debugger
make USE_PGXS=1 install
```

その後、データベースで:

```sql
CREATE EXTENSION pg_rls_debugger;
```

この拡張はSQL（plpgsql）のみで、Cコードのコンパイルは不要です。
*trusted* 指定なので、スーパーユーザーでなくてもデータベース所有者なら
インストールできます。

## 仕組み

各ポリシーについて、`pg_get_expr()` で逆パースしたポリシー式
（`search_path` を `pg_catalog` に固定しているため、参照はすべて
スキーマ修飾されて出てきます）を取り、対象行を
`jsonb_populate_record()` でテーブル行型の複合値として再構成し、

```sql
SELECT (<ポリシー式>) FROM (SELECT (<行>).*) AS <テーブル名>;
```

を `SET ROLE <対象ロール>` の下で実行します。本物のロールで本物のクエリが
走るので:

- `current_user` や `current_setting()` は対象ロールにとっての値を返す
- ポリシー内のサブSELECTは、対象ロール自身の権限とRLSで他テーブルに触る
  （実際のスキャン時と同じ挙動）
- 評価時にエラーになる式（未定義のカスタムGUCなど）はポリシー単位で
  `error: ...` として報告され、レポート全体は中断しない

適用可否の判定はバックエンドの実装を忠実になぞっています:
RLSが適用されるか自体は `check_enable_rls()`（スーパーユーザーは暗黙に
BYPASSRLS、所有者は `FORCE ROW LEVEL SECURITY` がない限り免除）、
ロールのマッチは `check_role_for_policy()`（`pg_has_role(..., 'USAGE')`、
つまり継承メンバーシップ）、最終判定はエグゼキュータの合成規則
（**PERMISSIVEが最低1つpass、かつRESTRICTIVEが全部pass**。`NULL` は失敗扱い）。
`WITH CHECK` のない `ALL`/`UPDATE` ポリシーが `USING` にフォールバックする
挙動も本物と同じです。

## セキュリティモデル

`SECURITY DEFINER` も権限昇格も一切ありません:

- **行の取得は呼び出し側自身の権限・RLSで行われます。** この拡張を通じて、
  自分が `SELECT` できない行を覗くことは絶対にできません（だからこそ通常は
  テーブル所有者か `BYPASSRLS` ロールで実行します。そうでないと
  `pg_rls_hidden_rows` に見せられる「隠れた行」がありません）。
- **別ロールとしてのデバッグには、そのロールへの `SET ROLE` 権限が必要**で、
  これはPostgreSQL自身が強制します。元のロールは、ポリシー式が例外を投げた
  場合でも必ず復元されます。
- ポリシー定義の読み取り元は `pg_policy` で、これはもともと誰でも読めます。

## 注意事項

- 評価対象は指名したテーブルのポリシーです。既存列値を読む
  `UPDATE`/`DELETE` にプランナが追加する `SELECT` ポリシー由来の条件や、
  `ON CONFLICT` の特殊ケースまではモデル化していません。
- 行は `to_jsonb()` / `jsonb_populate_record()` を経由します。jsonの
  ラウンドトリップが非可逆な特殊型では、実スキャンと結果が変わり得ます。
  volatileなポリシー式は呼び出しごとに再評価されます。
- `pg_rls_hidden_rows` はスキャンした全行に全該当ポリシーを評価します。
  デバッグ用であり常時監視用ではありません。大きなテーブルでは
  `scan_limit`（デフォルト10000）で抑えてください。
- パーティションテーブルでは、ポリシーはクエリで実際に指名したテーブルの
  ものが適用されます。デバッガーも実クエリと同じテーブルに対して実行して
  ください。

## テスト

`make check` で、PERMISSIVE/RESTRICTIVEの合成、ロールマッチ、
FORCE/所有者/BYPASSRLSのステータス判定、デフォルト拒否、WITH CHECK
フォールバック、エラー捕捉、非特権ユーザーでの利用までカバーする
リグレッションテストが走ります。

## ライセンス

PostgreSQL License（PostgreSQL本体と同じ）。
