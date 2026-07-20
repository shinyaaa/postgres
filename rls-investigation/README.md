# RLS × 他機能 相互作用バグ調査 レポート

対象: PostgreSQL master (20devel, commit d4046a4, 2026-07-19)
ビルド: `./configure --enable-debug --enable-cassert`、ローカル起動 (port 5455)、
`FORCE ROW LEVEL SECURITY` + planning role ≠ execution role の軸で検証。
PoC: `work/poc/*.sql`（各ファイル冒頭に仮説を記載）。

## サマリ
- 調査した組み合わせ数: 14 PoC / 約25シナリオ ＋ コード監査2本（MERGE実行系・論理レプリケーション）
- **バグ候補数: 0（確証あり）**
- 既知仕様と判定: 3（FK/RI存在オラクル、論理レプリケーションのWAL復号、UPDATE USING(true)のブラインド更新）
- 付随所見: 1（論理レプリケーションのドキュメント欠落。コードバグではない）

歴史的3故障クラス（プラン再利用×ロール変更 / 統計×leaky operator / fail-open）は、
マトリクスで指定された **新機能・新経路**（MERGE の全アクション、NOT MATCHED BY SOURCE、
`BEGIN ATOMIC` 関数本体、security_invoker ビュー、拡張統計、クロスパーティション行移動、
writable CTE）でも **再発していない**。すべて正しく防御されているか、文書化された仕様。

---

## 検証したクラスと結果（すべて「正しく防御」）

### クラス1: プラン再利用 × ロール変更（CVE-2024-10976隣接）
`plan_cache_mode=force_generic_plan` で generic plan を強制し、alice で PREPARE →
`SET ROLE bob` で EXECUTE。RLS対象テーブルへの到達経路を変えて検証。

| 経路 | 結果 |
|------|------|
| 直接参照 | bob は bob 行のみ。正 |
| CTE 内 | bob は bob 行のみ。正 |
| FROM句のインラインSQL関数 | bob は bob 行のみ。正 |
| `BEGIN ATOMIC` SRF本体 | bob は bob 行のみ。正 |
| security_invoker ビュー | bob は bob 行のみ。正 |
| 非invokerビュー（checkAsUser）| ビュー所有者のポリシーを選択。正 |

機構: rewrite時の `dependsOnRLS`（`extract_query_dependencies` が全Queryツリーを走査、
plancache.c:731-734）がロール変更で **再rewrite** を強制。インラインされFROM関数は
rewrite時には見えないため、`inline_function_in_from` が plan時に `dependsOnRole` を立て
（clauses.c:6010）、plancache.c:1145 が両者をORして **再plan** を強制。
スカラ `inline_function` は本体に sublink/rtable があれば inline 拒否（clauses.c:5478,5480）
のため RLS テーブルを漏らさず、propagation不要。
PoC: `09_plancache_role.sql`, `10_beginatomic_checkasuser.sql`, `11_checkasuser_policy_selection.sql`

### クラス2: 統計情報 × leaky operator（CVE-2017-7484 / CVE-2019-10130隣接）
- `pg_stats` の most_common_vals: RLS有効時 alice には 0 行（隠し値を漏らさない）。正
- **拡張統計** `pg_stats_ext`（MCV）: 同上 0 行。正
- `pg_statistic_ext_data` 直接参照: permission denied。正
- 非leakproof関数を alice の WHERE に混ぜても、`Filter: ((tenant=CURRENT_USER) AND leak(secret))`
  の順で AND 短絡し、leak() は隠し行 (bob) を **一度も** 見ない。正
PoC: `07_stats_leak.sql`, `08_leaky_operator.sql`

### MERGE（マトリクス#9 ★）— コード監査＋実機
`ExecMergeMatched`/`ExecMergeNotMatched` を精読（nodeModifyTable.c）。
- WHEN NOT MATCHED BY SOURCE の UPDATE/DELETE は MATCHED と **同一ループ**で
  `WCO_RLS_MERGE_UPDATE_CHECK`/`WCO_RLS_MERGE_DELETE_CHECK` を評価（nodeModifyTable.c:3640-3647）。
- DO NOTHING は行を変更しないため WCO スキップ（正）。
- EvalPlanQual 並行更新 recheck は最新版を `ri_oldTupleSlot` に載せ直して再ループ→WCO再評価（正）。
- クロスパーティション行移動は宛先の `WCO_RLS_UPDATE_CHECK` を `mt_merge_action` 経由で選択（正）。
- 実機: SELECT=true/UPDATE・DELETE=own の分離ポリシーで NMBS DELETE を実行 →
  「target row violates row-level security policy (USING expression)」で正しくエラー。
PoC: `01_merge_actions.sql`, `06_nmbs_rls_clean.sql`

### パーティショニング（マトリクス#3 ★）
- クロスパーティション UPDATE 行移動（tenant alice→bob）→ 宛先の WITH CHECK が発火し
  「new row violates row-level security policy」でエラー、行不変。正
- partition pruning は境界メタデータのみで枝刈りし行内容を漏らさない。
PoC: `12_partition_returning_fk.sql`

### ビュー（マトリクス#5 ★）
- security_invoker ビュー: 実行者のポリシーで再評価（クラス1表参照）。
- 非invokerビュー: ロール固有ポリシーを **ビュー所有者** の user_id で選択（checkAsUser）。
  ただしポリシー式中の `current_user` は実行時関数のため常に呼び出し元を返す（仕様）。
PoC: `10`, `11`

### RETURNING / writable CTE（マトリクス#11,#13）
- UPDATE USING(true) でも SELECT ポリシーが security qual として付与され、
  隠し行は UPDATE/DELETE ... RETURNING で **触れも読めもしない**（0行）。
- writable CTE の INSERT は WITH CHECK 違反でエラー、UPDATE/DELETE RETURNING も隠し行0。
PoC: `12`, `13`

### COPY（マトリクス#10）
`COPY t TO` / `COPY (SELECT..) TO` とも alice 行のみ出力。正。 PoC: `14_copy.sql`

---

## 既知仕様として除外したもの
- **FK/RI 存在オラクル（マトリクス#7）**: RI チェックはテーブル所有者権限で走り RLS を素通り。
  alice が SELECT できない `ref` 行 (id=2) でも、FK 付き INSERT の成否で存在を判別できる
  （存在=成功 / 不在=FK違反エラー）。`doc/src/sgml/ddl.sgml` の RLS 節に明記された仕様。
  PoC: `12` (C)。
- **論理レプリケーション subscriber**: apply worker は RLS を適用せず、適用ロールが RLS の
  対象になる場合は **エラーで停止**（worker.c:2637、`logical-replication.sgml:2255-2266` に明記）。
- **UPDATE USING(true) のブラインド更新**: WHERE/RETURNING が列を参照しない UPDATE は
  SELECT 権限不要のため SELECT ポリシーが付かず、USING(true) の全行更新は仕様どおり。

## 付随所見（コードバグではない / hackers向け候補外）
- **論理レプリケーション publisher の定常WAL復号は RLS を適用しない**（pgoutput.c に RLS 参照なし）。
  publication row filter が代替手段。ただし docs は初期COPY時のRLSのみ記述し、
  「テーブルを publish すると RLS で隠すはずの行が subscriber に流れる」旨の注意書きが無い。
  → **ドキュメント改善候補**（セキュリティ境界の設計上の性質であり実装バグではない）。

## 未検証・要追加調査
- back-branch (17/16/15) での回帰確認（本調査は master のみ）。
- 生成列 / 式インデックス / CHECK制約式 に埋めたポリシー関数の評価タイミング（マトリクス#14）。
- パラレルワーカのロール文脈・GUC 引き継ぎ（マトリクス#12）— parallel-safe と leakproof の境界。
- 拡張のポリシーフック（permissive/restrictive）経由の異常系。
- rules (`CREATE RULE`) 書き換え後の tracking（マトリクス#15）。
