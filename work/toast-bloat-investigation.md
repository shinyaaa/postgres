# TOAST 膨張の可視化 — 調査レポート

- 調査日: 2026-07-31
- 対象ツリー: postgres master (PG19 devel), HEAD = `8f191a79617d906e34d041382e6ecfbf78166a65` (2026-07-29)
- 実機検証: 上記 HEAD をビルドし、autovacuum off のインスタンスで実施(手順とログは付録 A)
- 本文中のファイル:行番号はすべて上記 HEAD 時点のもの

## TL;DR

- 引き継ぎプロンプトの前提は**ほぼすべて正しかった**。ただし「監視クエリの書き方次第で落ちる」
  という認識は控えめすぎる。`pg_stat_user_tables` は**ビュー定義自体が** `pg_toast` スキーマを
  除外しており、ユーザテーブルの TOAST 統計は `pg_stat_sys_tables` 側に分類される。
  監視側の過失ではなく、本体側の分類がそもそも直感に反する。
- 穴は実在する。ただし「データがない」穴ではなく「紐付けがない」穴。したがって
  **新規統計カウンタは一切不要**で、SQL レベルのビュー変更(`reltoastrelid` join +既存の
  `pg_stat_get_*` 関数)だけで塞げる。`pg_statio_all_tables` が既に完全に同じパターン
  (`toast_blks_read/hit` を親の行に併記)を実装している。
- 先行の pg_stat_toast(Gunnar Bluth, 2021-22, withdrawn)は「新規カウンタ追加による
  統計オーバーヘッド」で止められた。本提案はカウンタを増やさないため、同じ理由では
  止まらない。この差分を提案メールの冒頭で明示すべき。
- 推奨する最小形: `pg_stat_all_tables` に `toast_relid` 1 列 + ドキュメントに推奨 join
  クエリを追記。次点で `toast_n_dead_tup` / `toast_last_autovacuum` /
  `toast_autovacuum_count` の併記(これも SQL のみで実装可能)。

---

## 1. 前提の検証結果

### 1-1. 「データは既に存在する」 → **正**

| 主張 | 判定 | 根拠 |
|---|---|---|
| `pg_stat_all_tables` は relkind `'t'` を含み、`pg_toast_<oid>` が行として現れる | **正** | ビュー定義の relkind フィルタ `('r', 't', 'm', 'p')`: `src/backend/catalog/system_views.sql:754`。実機でも確認(付録 A の [A]) |
| `pg_table_size()` は TOAST を含む | **正** | `calculate_table_size()` が `reltoastrelid` の有効時に `calculate_toast_table_size()` を加算: `src/backend/utils/adt/dbsize.c:442-461`(`pg_table_size` 本体は同 504-520)。実機: heap 56kB に対し `pg_table_size` = 108MB(付録 A の [E]) |

TOAST テーブルの `n_dead_tup` 等が DML でリアルタイムに維持される点も確認した。
chunk の削除は `simple_heap_delete()` 経由
(`src/backend/access/common/toast_internals.c:428`)なので、通常テーブルと同じ
pgstat 経路(`pgstat_count_heap_delete` 等)でカウントされる。VACUUM を待たずに
`n_dead_tup` が増えることは実機の [C] で確認済み(update 直後に 52,000)。

### 1-2. 「欠けているのは紐付けと意味論」 → **正(1 点はより深刻)**

**(1) 親から辿るには手動 join が必要 → 正。**
親テーブルの行から TOAST の統計に到達する手段はビューに存在しない。
`pg_class.reltoastrelid` を自分で join する必要がある(動作するクエリは付録 A の [F])。
象徴的なのは、**公式ドキュメント自身がこの手動 join を読者に書かせている**こと:

- ディスク使用量の節: `doc/src/sgml/monitoring.sgml:9177-9190`(reltoastrelid のサブクエリ join)
- 周回(wraparound)監視の節: `doc/src/sgml/maintenance.sgml:617-621`
  (`LEFT JOIN pg_class t ON c.reltoastrelid = t.oid` で親子の `relfrozenxid` の greatest を取る例)

つまり「join すれば書ける」は本体ドキュメントの公式見解でもあり、逆に言えば
join を書かない限り見えないことを本体側も認めている。

**(2) 監視クエリの書き方で落ちる → 正だが、実態はより深刻。**
`schemaname = 'public'` などのフィルタ以前の問題として、
`pg_stat_user_tables` は**ビュー定義自体が** `schemaname !~ '^pg_toast'` で除外している
(`src/backend/catalog/system_views.sql:788-791`)。逆に `pg_stat_sys_tables` は
`schemaname ~ '^pg_toast'` を**含む**(同 778-781)。すなわち:

> ユーザテーブルの TOAST 部分の統計は「システムテーブル」に分類される。

ユーザデータの膨張を監視する目的で `pg_stat_user_tables` を見るのは自然な行動だが、
そのユーザデータの一部(TOAST)は定義上そこに決して現れない(実機 [B]: 0 行)。
ドキュメントは「filtered to only show user and system tables respectively」と述べるのみ
(`doc/src/sgml/monitoring.sgml:4474-4482`)で、TOAST が sys 側に落ちることへの注意書きはない。

**(3) 親の統計は TOAST の状況を反映せず、autovacuum は独立判断 → 正。**
`src/backend/postmaster/autovacuum.c` で確認した事実:

- autovacuum のテーブル収集は 2 パス構成。第 1 パスで通常テーブル+matview、
  第 2 パスで relkind `'t'` を独立にスキャンする(`autovacuum.c:2017-2030, 2133-2190`)。
  コメントも明言: "we don't automatically vacuum toast tables along the parent table"
  (`autovacuum.c:2099-2102`)
- 実際のバキューム実行時も `VACOPT_PROCESS_TOAST` を**付けずに** `vacuum()` を呼ぶ
  ("Note we don't say VACOPT_PROCESS_TOAST, so that vacuum() skips toast relations",
  `autovacuum.c:2915-2916`)。親が autovacuum されても TOAST は連動しない
- 閾値の決まり方(`relation_needs_vacanalyze`, `autovacuum.c:3134-3177`):
  1. TOAST テーブル自身の reloptions(親への `ALTER TABLE ... SET (toast.autovacuum_*)`
     は TOAST rel 側の reloptions として格納される。実機 [H] で確認)
  2. それが無ければ**親テーブルの reloptions** をフォールバックとして使う
     (`autovacuum.c:2160-2174`。第 2 パスが必要な理由そのもの)
  3. それも無ければ GUC のグローバル値
  つまり「別閾値で独立に判断」は正しいが、正確には
  「**判断は常に独立、閾値は toast reloptions → 親 reloptions → GUC の 3 段フォールバック**」
- analyze は TOAST に対して行われない(`autovacuum.c:2182-2183`, `3312-3315`)

対照的に、**手動 VACUUM はデフォルトで TOAST も処理する**
(`PROCESS_TOAST` デフォルト true: `src/backend/commands/vacuum.c:174`, 実行は同 2336-2347)。
このため「手動 VACUUM では親子一緒 / autovacuum では別々」という非対称があり、
親の `last_autovacuum` から TOAST の手入れ状況を推測することは原理的にできない。

**事故シナリオの再現(実機、付録 A の [C][D]):**
50 行・payload 約 100kB の親テーブルを 20 回全行 UPDATE 後、
`VACUUM (PROCESS_TOAST FALSE)`(autovacuum が親だけ処理した状況の模擬)を実行すると:

| relname | n_live_tup | n_dead_tup | vacuum 済み表示 |
|---|---|---|---|
| t_wide(親) | 50 | **0** | true |
| pg_toast_16384 | 2,600 | **52,000** | false |

親は「dead 0・vacuum 済み」で完全に健全に見えるが、TOAST には 52,000 dead chunk・
ディスク 108MB(heap は 56kB)が残る。`pg_stat_user_tables` にこの 52,000 は一切現れない。

### 1-3. おまけ: PG19 devel の新ビューも同じパターンを踏襲している

本調査中に見つけた追加の材料。PG19 devel で入った autovacuum 優先度づけ
(commit `d7965d65fc5b`, 2026-03-27, Nathan Bossart)に伴う新ビュー
`pg_stat_autovacuum_scores`(commit `87f61f0c8280`, 2026-04-06, author: Sami Imseih)は
TOAST テーブルを**独立した行として**含む(relkind フィルタに `RELKIND_TOASTVALUE`:
`src/backend/postmaster/autovacuum.c:3680-3682`、ビュー定義は
`src/backend/catalog/system_views.sql:798-814`)。実機 [G] では TOAST 行の score が 1040 と
親(19)より 2 桁大きく出ており、「TOAST が独立に監視対象である」ことを本体が
再確認した直近の実例になっている。ここでも親への紐付け列はない。

なお細部の指摘: このビューは TOAST rel の reloptions フォールバック
(親 reloptions の継承, `autovacuum.c:2160-2174`)を行わず、TOAST rel 自身の
reloptions → GUC で計算する(`autovacuum.c:3687` は `extract_autovac_opts` を
単独で呼ぶだけ)。親にだけ `autovacuum_vacuum_scale_factor` 等を設定している場合、
ビューの score/do_vacuum が実際の autovacuum の判断とズレる。これは本提案とは独立の
小さな不整合であり、報告あるいは小パッチの種として使える(hackers での
「ついでに見つけた」報告は心証が良い)。

---

## 2. 先行提案の状況

### 2-1. PG18 の列追加前例: total_vacuum_time 等 → **認識どおり存在**

- Commit: `30a6ed0ce4bb18212ec38cdb537ea4b43bc99b83`
  "Track per-relation cumulative time spent in [auto]vacuum and [auto]analyze"
  (2025-01-28, committer: Michael Paquier, **author: Sami Imseih**)
- スレッド: https://postgr.es/m/CAA5RZ0uVOGBYmPEeGF2d1B_67tgNjKx_bKDuL+oUftuoz+=Y1g@mail.gmail.com
- `pg_stat_all_tables` に `total_vacuum_time` / `total_autovacuum_time` /
  `total_analyze_time` / `total_autoanalyze_time` の 4 列を追加。catversion と
  PGSTAT_FILE_FORMAT_ID を bump

**変更ファイル一覧(今回のテンプレート、計 +141/-19 行):**

| ファイル | 変更量 | 今回の最小形で必要か |
|---|---|---|
| doc/src/sgml/monitoring.sgml | +38 | 必要 |
| src/backend/catalog/system_views.sql | +5/-1 | 必要 |
| src/test/regress/expected/rules.out | +15/-3 | 必要(ビュー定義が丸ごと出る) |
| src/include/catalog/catversion.h | +1/-1 | 必要 |
| src/backend/access/heap/vacuumlazy.c | +5/-2 | **不要**(新カウンタ用) |
| src/backend/commands/analyze.c | +7/-5 | **不要**(同上) |
| src/backend/utils/activity/pgstat_relation.c | +17/-4 | **不要**(同上) |
| src/backend/utils/adt/pgstatfuncs.c | +28 | **不要**(新 C 関数用) |
| src/include/catalog/pg_proc.dat | +16 | **不要**(同上) |
| src/include/pgstat.h | +9/-3 | **不要**(同上) |

今回の提案は既存統計の紐付けだけなので、下 6 ファイルが丸ごと不要になる。
「PG18 の前例より小さい」ことを示す具体的な材料。

**スレッドでの議論(タイトル: "POC: track vacuum/analyze cumulative time per relation")**
— 特筆すべきは**列追加そのものへの反対が出なかった**こと。低摩擦で commit に至った:

- Bertrand Drouvot: データ型の一貫性(double precision として文書化、ms 単位の明記)、
  スタイル指摘のみ(例: https://www.postgresql.org/message-id/Z4ez/l7kbFd6Ppmq%40ip-10-97-1-34.eu-west-3.compute.internal)
- Michael Paquier: vacuum/analyze の報告経路の対称性、関数名(`total` を含める)。
  最終的に自身で簡素化して commit
- オーバーヘッド論はスレッドで表面化せず。**固定幅カウンタ 4 個だけ**という規模が
  効いたとみられる(対照的に、~30 カウンタを足す Rybakina の "Vacuum statistics"
  パッチはメモリオーバーヘッドで押し返され続けている。2-3 (4) 参照)
- commit 後の指摘: Alena Rybakina が自身の大型パッチとの重複を指摘
  (https://www.postgresql.org/message-id/b2be6254-c977-4329-b62f-c35ba8772641%40postgrespro.ru)
  が、最小限の in-core 列は残った。意味論の混乱 2 件(コストベース遅延の包含、
  VACUUM FULL の除外)は**ドキュメント追記のみで解決**
  (`92ee8a4df5b5`, `7c3b591af3d8`)

教訓: このビューへの列追加は「少数・固定幅・既存インフラ再利用」なら通る。
新規カウンタすらない本提案はさらに条件が良い。

なお PG18 の 4 列も TOAST テーブルについては **TOAST 自身の行**(= pg_stat_sys_tables 側)
に付くため、本レポートが指摘する親からの導線欠損は PG18 新列にもそのまま当てはまる。

### 2-2. pg_stat_toast(Gunnar "Nick" Bluth, 2021-22)→ **Withdrawn。スコープも却下理由も本提案とは別物**

- スレッド: https://www.postgresql.org/message-id/flat/a08b54fa-7b13-9531-6233-33a3d23773a8@pro-open.de
  (初回投稿 2021-12-12)
- Commitfest: https://commitfest.postgresql.org/37/3457/ — 2022-07-01 に **Withdrawn**
- 内容: 新 GUC `track_toast`(デフォルト off)配下で、**カラム単位**の TOAST 活動統計
  (外部化回数、圧縮試行/成功回数、圧縮前後サイズ累計、圧縮時間)を新規カウンタとして
  追加する提案。**膨張・dead tuple は対象外**(認識どおり)
- 停滞理由(重要):
  1. **統計トラフィック/サイズのオーバーヘッド** — Andres Freund が初日に指摘
     ("For some workload it'll substantially increase the amount of stats traffic",
     https://www.postgresql.org/message-id/20211212215248.zzssvm7mpneh4zqx%40alap3.anarazel.de)。
     当時は PG15 以前の UDP 統計コレクタ+統計ファイル時代で、カラム単位の新規エントリ
     (約 50-60 bytes/attribute)は重いと判断された
  2. **Robert Haas の判定(2022-04)** — "this patch has no chance of being accepted,
     due to overhead"(Bluth の返信:
     https://www.postgresql.org/message-id/399d9104-d53e-4c91-d714-f897c2e43fa6@pro-open.de)。
     共有メモリ pgstat 化(PG15)後なら軽くなるかも、と示唆されたが、直後に
     pgstat rework との衝突で bitrot し、作者が取り下げた
  3. その後 2026 年現在まで再提案なし(`git log --all --grep`/`git grep -il pg_stat_toast`
     ともに 0 件)
- **本提案への含意**: pg_stat_toast を止めたのは「新規カウンタの追加コスト」であり、
  「TOAST の可視性に価値がない」ではない。本提案は
  (a) 新規カウンタゼロ、(b) 行単位の既存統計の紐付けのみ、(c) GUC 追加なし、なので
  同じ轍を踏まない。ただし「TOAST 関連の統計ビュー提案は一度死んでいる」という
  空気は残っている可能性があり、提案メールで pg_stat_toast との差分
  (activity stats vs 既存 stats の紐付け)を先回りして明示すべき

### 2-3. その他の類似提案・歴史的経緯

**過去に `pg_stat_all_tables` へ TOAST 関連列(toast_relid / toast dead tuple 等)を
追加する提案は見つからなかった。** 却下された前例がない=未開拓であり、
「過去に却下済み」という最悪の反論は存在しない。関連する歴史は以下のとおり。

**(1) 2005: TOAST 行が統計ビューに現れるようになった起点(PG 8.1)**
- Commit `87808aef05c91bdd26cb4447489db8a35c0d6fb2`(Tom Lane, 2005-08-15):
  "Allow the pgstat views to show toast tables as well as regular tables (the stats
  system has always collected this info, but the views were filtering it out)"
- 当時の設計は「TOAST の活動量が閾値を超えたら**親を** VACUUM する」だった。
  契機は "short, wide tables" 議論
  (https://www.postgresql.org/message-id/24101.1120841848%40sss.pgh.pa.us)

**(2) 2008: autovacuum の TOAST 独立処理化と、幻の `pg_stat_toast_tables`(PG 8.4)**
- スレッド "handling TOAST tables in autovacuum"(Alvaro Herrera, 2008-06-08,
  https://www.postgresql.org/message-id/20080608230348.GD11028@alvh.no-ip.org)で、
  TOAST を `pg_stat_*_tables` で別扱いする専用ビュー **`pg_stat_toast_tables`** の案が
  出たが実装されず、TOAST 行は `pg_stat_sys_tables` に落ちる現状のまま確定した。
  閾値は「親の設定を継承し、実需要があれば後で拡張」で決着
- Commit `3ccde312ec8ee47f5f797b070d34a675799448ae`(Alvaro Herrera, 2008-08-13):
  autovacuum が TOAST を親と独立に処理するようになった。1-2 (3) の 2 パス構造の起源
- つまり **2008 年に処理は独立化されたのに、可視化の導線は 2005 年の
  「TOAST 行が別に出るだけ」のまま 18 年間据え置かれている**。これが本提案の
  歴史的な位置づけになる
- 補足: `toast.autovacuum_*` reloptions は `3a5b77371522`(2009-02-02)で導入。
  `b5faba1284c4`(2010-06-07, Itagaki Takahiro)が `toast.autovacuum_analyze_*` を
  禁止(TOAST は analyze されないため)

**(3) 2017: Kyotaro Horiguchi "More stats about skipped vacuums" → 停滞**
- `pg_stat_*_tables` に `vacuum_required`, `last_autovacuum_status`,
  `incomplete_autovacuum_count` 等を足す提案
  (https://www.postgresql.org/message-id/20171010.192616.108347483.horiguchi.kyotaro%40lab.ntt.co.jp)
- 当時のファイルベース統計コレクタでの per-table エントリ肥大が争点になり未 commit。
  pg_stat_toast と同じ「旧統計基盤時代のオーバーヘッド」パターン

**(4) 2024-継続中: Alena Rybakina "Vacuum statistics"(CF: https://commitfest.postgresql.org/51/5012/)**
- `pg_stat_vacuum_tables` 等、per-relation に約 30 カウンタを足す大型パッチ。
  **メモリオーバーヘッド**で押し返され、拡張化・GUC ゲート化の提案を受けつつ
  PG18 時点で未 commit(スレッド:
  https://www.mail-archive.com/pgsql-hackers@lists.postgresql.org/msg171076.html)
- PG18 の 4 列(30a6ed0ce4bb)がすんなり通ったのと対照的で、
  「**カウンタの大量追加は落ちる/少数・再利用は通る**」という現在の相場観を示す。
  本提案(新規カウンタ 0)はこの相場観の最も通りやすい側にいる

**(5) ユーザ側の被害報告(問題の実在の証拠)**
- "Bloat and Slow Vacuum Time on Toast"(pgsql-admin, 2011): 約 200GB の説明不能な
  TOAST 膨張
  (https://www.postgresql.org/message-id/CAMg8r_o%3DsHXqOzPgNw9%2Bndp%2B-0bAK6DBcjCu0poZn2se5qC-vQ%40mail.gmail.com)
- "Why pg_toast table not get auto vacuumed?"(pgsql-general, 2014:
  https://www.postgresql.org/message-id/53C7D943.4000004@aklaver.com)、
  "vacuum TOAST tables"(pgsql-general, 2023)など、autovacuum の独立処理に起因する
  混乱の質問が定期的に発生
- サードパーティでも同型のバグ: keithf4/pg_bloat_check issue #15
  "Toast table is not being checked, hence bloat amount is vastly wrong"
  (https://github.com/keithf4/pg_bloat_check/issues/15)

**(6) pg_statio 側の先例が保守され続けている証拠**
- `ef11051bbe96`(2020-04-28, Alexander Korotkov)と `ce95c543763b`(2022-03-24,
  Tom Lane)はいずれも `pg_statio_all_tables` の TOAST join の不具合修正。
  「親の行に TOAST 統計を併記する」パターンはコミュニティが現役で保守している設計

> 検証度の注記: 本節と 2-2 のスレッド内容は、サンドボックスのプロキシが
> postgresql.org への直接アクセスを拒否したため、検索スニペット+ミラー
> (mail-archive.com, postgrespro.com 等)経由の要約に基づく。コミットハッシュと
> ローカルソースで裏取りできる事実(ビュー定義、autovacuum の挙動、コミットの存在)は
> すべて一次情報で確認済みだが、**引用文の正確な文言とスレッド内の細かい応酬は
> 提案メール執筆前にアーカイブ原文で再確認すること**(特に 2-2 の Haas 発言と
> 本節 (2) の pg_stat_toast_tables 案の経緯)。

---

## 3. 監視ツール・流通クエリの TOAST 取り扱い

「SQL で書けるが、実際には書かれていない」の実証調査。主要ツールのソースを直接確認した。

| ツール / クエリ | TOAST の dead tuple | TOAST の膨張推定 | TOAST サイズ | 判定 |
|---|---|---|---|---|
| check_postgres `bloat` | 見えない | 常に 0 と報告 | 見えない | **取りこぼし** |
| PostgreSQL wiki "Show database bloat" | 見えない | 見えない(pg_stats 駆動) | 見えない | **取りこぼし** |
| pgwatch `table_stats` | 見えない(pg_stat_user_tables 駆動) | — | 親に併記あり | 部分的 |
| pgwatch `table_bloat_approx_*`(pgstattuple 系) | 見えない | relkind ('r','m') 限定で除外 | 見えない | **取りこぼし** |
| postgres_exporter(prometheus) | 見えない(pg_stat_user_tables 駆動) | 見えない | pg_table_size に混入 | 部分的 |
| pg_monz(Zabbix) | テーブル単位では見えない | 見えない | 見えない | 部分的 |
| ioguix table_bloat.sql | 間接的 | **親に折り込んで推定**(`ceil(toasttuples/4)`) | 含む | 含む(近似) |
| Datadog(integrations-core) | **親に紐付けて見える**(`toast.dead_rows`) | 見えない(bloat は wiki クエリ) | 別立てで見える | 部分的(dead は最良) |
| pganalyze collector | 見えない | 素材のみ収集 | 親に併記あり | 部分的 |

要点(各項目の評価根拠となるソース URL・SQL 断片は付録 C):

1. **膨張推定クエリの主流系譜(check_postgres → wiki → Datadog bloat)は TOAST に対し
   構造的に盲目**。`pg_stats` 駆動だが、TOAST テーブルは ANALYZE されない
   (1-2 (3) 参照)ため `pg_stats` に決して現れず、推定対象に入り得ない
2. **`pg_stat_user_tables` 駆動のツール(pgwatch table_stats, postgres_exporter,
   pg_monz)は dead tuple が構造的に見えない**。原因はツール側の書き方ではなく
   ビュー定義の `schemaname !~ '^pg_toast'`(1-2 (2))
3. **postgres_exporter は事故シナリオの構造をそのまま持つ**: サイズ系メトリクスは
   `pg_table_size()`(TOAST 込み)、dead tuple 系は `pg_stat_user_tables`(TOAST 抜き)。
   「サイズだけ増え、dead が増えない」という監視上の説明不能状態が既定で発生する
4. **Datadog だけが本レポート案 2 と同じ `reltoastrelid` 手動 join を実装済み**
   (`pg_stat_get_dead_tuples(C.reltoastrelid)` を直接呼ぶ)。
   商用ベンダ 1 社だけが正しくやれている事実は、
   (a) この join が実務上必要とされている証拠、かつ
   (b) 本体がビューで提供していないために各自が再発明している証拠、として提案に使える
5. ioguix クエリは TOAST を親の膨張推定に折り込む唯一の広く流通した例だが、
   「1 ページ = full-width chunk 4 個」という粗い仮定に依存

**結論: 「SQL で書ける」は反論として成立していない。** 広く使われるツール 9 系統中、
TOAST の dead tuple を親テーブルに紐付けて見せられるのは Datadog(opt-in 設定時)のみ。

---

## 4. 穴の有無の判定

**穴は実在する。ただし種類は「データ欠損」ではなく「導線欠損」。** 内訳:

1. **データは全部ある**(1-1)。`pg_stat_all_tables` の TOAST 行、`pg_table_size`、
   DML 追随の `n_dead_tup`。ここに追加すべき新規カウンタはない
2. **導線が 3 重に切れている**(1-2):
   - 親の行から TOAST の行に辿る列がビューにない(手動 join が公式作法)
   - 「ユーザテーブルの監視」の正面玄関である `pg_stat_user_tables` が TOAST を
     定義レベルで除外し、`pg_stat_sys_tables` 側に分類している
   - 親の `n_dead_tup` / `last_autovacuum` は TOAST と非連動(autovacuum は独立判断)
     なので、親だけ見て健全と判断する運用は原理的に破綻している
3. **「SQL で書けるで終わる話」か?** — 書けるのは事実(付録 A の [F] は 4 行の join)。
   しかし:
   - 公式ドキュメント自身が 2 箇所で手動 join を教えている(1-2 (1))=
     本体が導線の欠如を自認している状態
   - `pg_statio_all_tables` は `toast_blks_read/hit` を親の行に併記している
     (`system_views.sql:816-843`, 特に 826-833 の
     `pg_class T ON C.reltoastrelid = T.oid`)。この join はコミュニティが現役で
     保守している(修正コミット `ef11051bbe96` 2020 年, `ce95c543763b` 2022 年)。
     つまり「I/O 統計では親から TOAST が見えるのに、行統計・vacuum 統計では
     見えない」という**ビュー間の非一貫性**があり、これは「SQL で書ける」では
     説明のつかない設計の穴
   - 監視ツールの実態(3 節)が「書けるが書かれていない」の実証になる

結論: 本体を変える価値はある。ただし攻め口は「新機能」ではなく
「`pg_statio_all_tables` には既にある導線を `pg_stat_all_tables` にも通し、
ビュー間の一貫性を取る」という**整合性の回復**として提示するのが最も通りやすい。

---

## 5. 推奨する最小形

段階的に 3 案。下に行くほど大きい。**推奨は案 1+案 2 の同時提案**(実装は同一パッチで
成立し、レビューで案 2 が削られても案 1 が残る構造にする)。

### 案 1(最小): `toast_relid` 1 列 + ドキュメント

- `pg_stat_all_tables` に `C.reltoastrelid AS toast_relid`(NULL if none)を追加
- `doc/src/sgml/monitoring.sgml` の pg_stat_all_tables 節に、TOAST 統計が
  `pg_stat_sys_tables` 側に分類される旨の注意書きと推奨 join クエリを追記
- 変更: system_views.sql(1 行)、rules.out、monitoring.sgml、catversion bump のみ。
  **新規 C 関数ゼロ、pg_proc.dat 変更ゼロ、統計フォーマット変更ゼロ**
- 弱点: 結局 join は自分で書く。「それなら今と大差ない」と言われうる

### 案 2(本命): `toast_` プレフィックス列の併記

`pg_statio_all_tables` と同じ `LEFT JOIN pg_class T ON C.reltoastrelid = T.oid` を足し、
既存関数を T.oid に対して呼ぶだけ:

```sql
pg_stat_get_live_tuples(T.oid)          AS toast_n_live_tup,
pg_stat_get_dead_tuples(T.oid)          AS toast_n_dead_tup,
pg_stat_get_last_autovacuum_time(T.oid) AS toast_last_autovacuum,
pg_stat_get_autovacuum_count(T.oid)     AS toast_autovacuum_count
```

- TOAST を持たないテーブルでは LEFT JOIN が miss して `T.oid` が NULL になり、
  これらの関数はすべて strict(`pg_proc.dat` のデフォルト)なので toast_* 列は
  **自然に NULL に落ちる**。「TOAST なし(NULL)」と「TOAST あり dead 0(0)」が
  区別でき、意味論が汚れない。`C.reltoastrelid` に直接関数を当てる実装
  (Datadog がやっている形)だと 0 が返って区別が付かないので、join 形を採ること
- `toast_n_live_tup` を含めたのは、dead の絶対数だけでは膨張率が判断できないため
  (実機 [C] 参照: dead 52,000 は live 2,600 の 20 倍で初めて意味を持つ)。
  それでも「列を増やしすぎない」原則から、まず 4 列 + toast_relid に絞る
- 派生ビューへの波及: `pg_stat_user_tables` / `pg_stat_sys_tables` は
  `SELECT * FROM pg_stat_all_tables` なので**定義変更不要**(自動で列が増える)。
  `pg_stat_xact_all_tables` は別定義だが、xact 系に TOAST 列は不要(トランザクション内
  DML 統計に TOAST の意味論がない)ので触らない
- 意味論上の利点: **`pg_stat_user_tables` から TOAST の膨張が初めて見えるようになる**
  (親の行に併記されるため、`^pg_toast` 除外の影響を受けない)。1-2 (2) の
  分類問題を、分類を変えずに解決できる

### 案 3(不採用を明記): 合算列

引き継ぎどおり不採用。理由の再確認: 親の `n_dead_tup`(ユーザ行)と TOAST の
`n_dead_tup`(約 2kB chunk)は単位が異なり、合算は無意味どころか有害
(実機 [C]: 親 1,000 vs TOAST 52,000 — 同じ 20 回の UPDATE 由来)。
提案メールでは「なぜ合算しないか」を先に書く。

### パフォーマンス論点(先回り)

- 案 2 の追加コストは行あたり `pg_class` への LEFT JOIN 1 つ+関数呼び出し 4-5 個。
  `pg_statio_all_tables` が同一の join +関数 4 個構成であり、かつ
  これらのビューは監視用途で低頻度アクセスが前提。PG18 で 4 列追加した
  `30a6ed0ce4bb` でもオーバーヘッド議論は表面化していない(2-1 参照)
- pgstat スナップショット(`stats_fetch_consistency = snapshot`)のサイズには影響しない
  (エントリ自体は既存。参照が増えるだけ)

---

## 6. 想定される反論と応答案

| 反論 | 応答 |
|---|---|
| 「reltoastrelid を join すれば SQL で書ける」 | 公式ドキュメント自身が 2 箇所で手動 join を教えている(monitoring.sgml:9177-9190, maintenance.sgml:617-621)。書ける導線を用意していないのは本体側で、pg_statio_all_tables では 20 年前から用意済み。ビュー間の一貫性の問題(4 節) |
| 「pg_stat_toast は overhead で死んだ。TOAST 統計はまた死ぬ」 | あれは**新規カウンタをカラム単位で追加**する提案で、指摘された overhead は統計エントリの増加コスト。本提案は既存エントリの紐付けのみで新規カウンタゼロ、GUC ゼロ。却下理由が構造的に当たらない(2-2) |
| 「ビューが太る/列が多すぎる」 | 最小形は toast_relid 1 列(案 1)。併記案でも 5 列で、PG18 の 4 列追加(30a6ed0ce4bb)と同規模。xact 系ビューには波及させない |
| 「行ごとの関数呼び出しが増える」 | pg_statio_all_tables が同一パターンを既に実施。監視ビューは低頻度アクセス前提で、PG18 の列追加時もこの点は問題にならなかった |
| 「TOAST の n_dead_tup は chunk 数で、ユーザ行と単位が違う。混乱しないか」 | だからこそ合算せず `toast_` プレフィックスで併記し、単位の違いをドキュメントに明記する。判断は比率(toast_n_dead_tup / toast_n_live_tup)で行える設計 |
| 「autovacuum が別々に処理すること自体が実装詳細。見せるべきでない」 | PG19 の pg_stat_autovacuum_scores(87f61f0c8280)が TOAST を独立行として既に露出しており、この抽象化はすでに破れている(むしろ公式化された)。1-3 参照 |
| 「pg_stat_sys_tables で見えるからいい」 | ユーザデータの膨張が「システムテーブル」に分類されている現状こそが監視事故の原因(1-2 (2))。少なくともドキュメントの注意書きは必要で、それだけなら docs パッチで済む |
| 「Rybakina の Vacuum statistics(CF 51/5012)と重複する」 | あちらは新規カウンタ約 30 個の追加でオーバーヘッドが争点。本提案は既存統計の紐付けのみで直交する。PG18 でも大型パッチと重複する最小限の 4 列が先に入った前例がある(2-1) |
| 「2008 年に pg_stat_toast_tables 案が流れた」 | あれは TOAST を別ビューに分離する案で、親の行への紐付けではない。しかも「実需要があれば拡張」で終わっており(2-3 (2))、3 節の実需要の証拠はまさにその宿題への回答になっている |

---

## 7. 未解決の論点

1. **引用文言の原文確認**: プロキシ制約により、スレッド引用の一部は検索スニペット
   経由(2-3 末尾の注記参照)。提案メール執筆前に、少なくとも
   pg_stat_toast スレッドの Haas 発言と 2008 年スレッドの `pg_stat_toast_tables` 案の
   文脈をアーカイブ原文で確認すること
2. **toast_relid の NULL 表現**: reltoastrelid = 0 を 0 のまま出すか NULL に変換するか。
   `pg_statio_all_tables` は join miss で NULL になる。`NULLIF(C.reltoastrelid, 0)` が
   素直だが、既存ビューの oid 列の流儀確認が必要
3. **パーティションテーブル(relkind 'p')の行**: 親行に toast 列を併記する際、
   partitioned table 行では常に NULL になる。許容範囲と考えるが、レビューで
   聞かれる可能性はある
4. **matview の TOAST**: matview も reltoastrelid を持つ。案 2 はそのまま機能するはず
   だが、実機確認はしていない
5. **pg_stat_autovacuum_scores の reloptions フォールバック不整合**(1-3)を
   先に単独報告するか、本提案に同梱するか。単独報告のほうが筋が良い
6. **`n_ins_since_vacuum` / `n_mod_since_analyze` 系を toast 側にも出すか**: insert-driven
   autovacuum(PG13+)の観点では `toast_n_ins_since_vacuum` にも意味があるが、
   列を絞る原則とのトレードオフ。初回提案では見送りを推奨

---

## 付録 A: 実機検証ログ(要点)

検証スクリプト: `work/verify.sql`(このリポジトリの作業ブランチに同梱)。
手順: HEAD をビルド → `initdb` → `autovacuum = off` で起動 →
50 行 × payload 約 100kB(STORAGE EXTERNAL)を 20 回全行 UPDATE。

```
=== [A] toast rows ARE visible in pg_stat_all_tables ===
 schemaname |    relname     | n_live_tup | n_dead_tup
------------+----------------+------------+------------
 pg_toast   | pg_toast_16384 |       2600 |      52000

=== [B] ...but NOT in pg_stat_user_tables ===
 toast_rows_in_user_tables
---------------------------
                         0

=== [C] parent vs toast dead tuples BEFORE vacuum ===
    relname     | n_live_tup | n_dead_tup
----------------+------------+------------
 t_wide         |         50 |       1000
 pg_toast_16384 |       2600 |      52000

=== [D] AFTER parent-only vacuum (PROCESS_TOAST FALSE) ===
    relname     | n_live_tup | n_dead_tup | vacuumed
----------------+------------+------------+----------
 t_wide         |         50 |          0 | t
 pg_toast_16384 |       2600 |      52000 | f

=== [E] pg_table_size includes toast; heap alone is small ===
 heap_only | with_toast
-----------+------------
 56 kB     | 108 MB

=== [F] the join users must write today ===
 relname | toast_n_dead_tup | toast_last_autovacuum | toast_autovacuum_count
---------+------------------+-----------------------+------------------------
 t_wide  |            52000 |                       |                      0

=== [G] pg_stat_autovacuum_scores includes the toast table (PG19 dev) ===
    relname     | schemaname |  score   | do_vacuum
----------------+------------+----------+-----------
 t_wide         | public     |   19.091 | f
 pg_toast_16384 | pg_toast   | 1040.000 | f

=== [H] toast.autovacuum_* reloptions land on the toast rel itself ===
    relname     |        reloptions
----------------+--------------------------
 t_wide         | {autovacuum_enabled=off}
 pg_toast_16384 | {autovacuum_enabled=off}
```

## 付録 B: 根拠ポインタ一覧(ソース)

| 事実 | 場所 |
|---|---|
| pg_stat_all_tables が relkind 't' を含む | src/backend/catalog/system_views.sql:717-755(フィルタは 754) |
| pg_stat_user_tables が ^pg_toast を除外 | src/backend/catalog/system_views.sql:788-791 |
| pg_stat_sys_tables が ^pg_toast を包含 | src/backend/catalog/system_views.sql:778-781 |
| pg_statio_all_tables の toast_blks_* 併記(先例) | src/backend/catalog/system_views.sql:816-843(join は 832-833) |
| pg_stat_autovacuum_scores 定義 | src/backend/catalog/system_views.sql:798-814 |
| autovacuum 2 パス構成・独立判断 | src/backend/postmaster/autovacuum.c:2017-2030, 2133-2190 |
| 親 vacuum 時に TOAST 非連動(autovacuum) | src/backend/postmaster/autovacuum.c:2099-2102, 2915-2916 |
| TOAST reloptions の親フォールバック | src/backend/postmaster/autovacuum.c:2160-2174 |
| 閾値パラメータの決定(reloptions → GUC) | src/backend/postmaster/autovacuum.c:3134-3177 |
| TOAST は analyze 対象外 | src/backend/postmaster/autovacuum.c:2182-2183, 3312-3315 |
| scores SRF が RELKIND_TOASTVALUE を含む | src/backend/postmaster/autovacuum.c:3680-3682 |
| scores SRF の reloptions フォールバック欠如 | src/backend/postmaster/autovacuum.c:3687 |
| 手動 VACUUM は PROCESS_TOAST デフォルト true | src/backend/commands/vacuum.c:174, 2265-2270, 2336-2347 |
| pg_table_size が TOAST を含む | src/backend/utils/adt/dbsize.c:442-461, 504-520 |
| chunk 削除が通常 pgstat 経路 | src/backend/access/common/toast_internals.c:428 |
| docs が手動 join を教示(disk usage) | doc/src/sgml/monitoring.sgml:9177-9190 |
| docs が手動 join を教示(wraparound) | doc/src/sgml/maintenance.sgml:617-621 |
| pg_stat_all_tables のドキュメント記述 | doc/src/sgml/monitoring.sgml:4474-4482 |

| 事実 | コミット / URL |
|---|---|
| PG18 total_*_time 4 列追加 | `30a6ed0ce4bb18212ec38cdb537ea4b43bc99b83`(2025-01-28, author: Sami Imseih)/ https://postgr.es/m/CAA5RZ0uVOGBYmPEeGF2d1B_67tgNjKx_bKDuL+oUftuoz+=Y1g@mail.gmail.com |
| autovacuum 優先度スコア導入 | `d7965d65fc5bb2139bc51c051c11428414c65160`(2026-03-27, Nathan Bossart) |
| pg_stat_autovacuum_scores ビュー追加 | `87f61f0c82806b7e4201f15bd77920e9e7108b11`(2026-04-06, author: Sami Imseih)/ https://postgr.es/m/CAA5RZ0s4xjMrB-VAnLccC7kY8d0-4806-Lsac-czJsdA1LXtAw%40mail.gmail.com |
| 統計ビューに TOAST 行を表示(PG8.1) | `87808aef05c91bdd26cb4447489db8a35c0d6fb2`(2005-08-15, Tom Lane) |
| autovacuum の TOAST 独立処理化(PG8.4) | `3ccde312ec8ee47f5f797b070d34a675799448ae`(2008-08-13, Alvaro Herrera)/ 設計スレッド https://www.postgresql.org/message-id/20080608230348.GD11028@alvh.no-ip.org |
| toast.* reloptions 導入 | `3a5b77371522b64feda006a7aed2a0e57bfb2b22`(2009-02-02, Alvaro Herrera) |
| toast.autovacuum_analyze_* の禁止 | `b5faba1284c4e5108c6fbe577daa33f933e7a4e0`(2010-06-07, Itagaki Takahiro) |
| pg_statio の TOAST join 修正(保守の証拠) | `ef11051bbe96ea2d06583e4b3b9daaa02657dd42`(2020-04-28)、`ce95c543763b6fade641a67fa0c70649d8527243`(2022-03-24) |
| Horiguchi 2017 提案スレッド | https://www.postgresql.org/message-id/20171010.192616.108347483.horiguchi.kyotaro%40lab.ntt.co.jp |
| Rybakina Vacuum statistics CF | https://commitfest.postgresql.org/51/5012/ |
| pg_stat_toast 提案スレッド | https://www.postgresql.org/message-id/flat/a08b54fa-7b13-9531-6233-33a3d23773a8@pro-open.de |
| pg_stat_toast Commitfest(Withdrawn 2022-07-01) | https://commitfest.postgresql.org/37/3457/ |
| Andres Freund の overhead 指摘 | https://www.postgresql.org/message-id/20211212215248.zzssvm7mpneh4zqx%40alap3.anarazel.de |
| Robert Haas 判定への Bluth 返信 | https://www.postgresql.org/message-id/399d9104-d53e-4c91-d714-f897c2e43fa6@pro-open.de |

## 付録 C: 監視ツール調査の根拠

- **check_postgres**: https://github.com/bucardo/check_postgres/blob/master/check_postgres.pl
  の `sub check_bloat`(~4379-4498 行)。サイズ推定サブクエリが `tbl.relkind='r'` かつ
  `pg_stats` 駆動。TOAST 行は期待サイズ(otta)が計算されず wastedbytes が常に 0
- **PostgreSQL wiki**: https://wiki.postgresql.org/wiki/Show_database_bloat 。
  check_postgres 由来で `FROM pg_stats s, ...` 駆動。TOAST は pg_stats に現れないため対象外
- **pgwatch**: https://github.com/cybertec-postgresql/pgwatch/blob/master/internal/metrics/metrics.yaml
  - `table_stats`(~3341 行): `from pg_stat_user_tables ut join pg_class c ...`、
    ただし `pg_total_relation_size(reltoastrelid) as toast_size_b` でサイズのみ親に併記
  - `table_bloat_approx_stattuple`(~2942 行): `pgstattuple_approx(c.oid)` を
    `relkind in ('r','m')` かつ `not n.nspname like any (array[E'pg\_%', ...])` に限定
- **ioguix**: https://github.com/ioguix/pgsql-bloat-estimation/blob/master/table/table_bloat.sql
  `LEFT JOIN pg_class AS toast ON tbl.reltoastrelid = toast.oid` で
  `(heappages + toastpages)` を実サイズ、`ceil(toasttuples/4)` を期待サイズに算入
- **pg_monz**: https://github.com/pg-monz/pg_monz の `pgsql_tbl_funcs.sh`
  (`pg_stat_user_tables` 駆動)、`pgsql_userdb_funcs.sh`(DB 集計のみ
  `pg_stat_all_tables` 駆動で TOAST 込み。内訳なし)
- **postgres_exporter**:
  https://github.com/prometheus-community/postgres_exporter/blob/master/collector/pg_stat_user_tables.go
  (166-192 行)。`FROM pg_stat_user_tables` に `pg_table_size(relid)` を併置
- **Datadog**:
  https://github.com/DataDog/integrations-core/blob/master/postgres/datadog_checks/postgres/relationsmanager.py
  の `QUERY_PG_CLASS`(~194-284 行)。`pg_stat_get_live_tuples(C.reltoastrelid)`,
  `pg_stat_get_dead_tuples(C.reltoastrelid)` 等を直接呼び、`toast.dead_rows` 等を
  親テーブルのメトリクスとして送出。bloat メトリクス(`TABLE_BLOAT_QUERY`, ~312-352 行)は
  wiki クエリのままで TOAST 対象外
- **pganalyze**:
  https://github.com/pganalyze/collector/blob/master/input/postgres/relation_stats.go
  (~20-110 行)。`toast_bytes`・TOAST の I/O ブロック統計は収集するが、
  dead/live tuple は親の oid に対してのみ取得
