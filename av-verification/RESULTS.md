# Autovacuum 発火条件 実機検証レポート

- 対象: PostgreSQL master (`20devel`)
- ビルド元 HEAD: `6d4ca6de97770cdaee18517dd2f8fe8f4ecee187` ("psql: Fix \df tab completion for procedures")
- ビルド: `./configure --enable-debug --enable-cassert CFLAGS="-O0 -g3"` / cassert 有効
- 実行日: 2026-07-04
- 設定: `autovacuum_naptime=1s`, `log_autovacuum_min_duration=0`, `autovacuum_vacuum_cost_delay=0`
- GUC デフォルト実測: vacuum_threshold=50, vacuum_scale_factor=0.2, vacuum_insert_threshold=1000,
  vacuum_insert_scale_factor=0.2, analyze_threshold=50, analyze_scale_factor=0.1,
  **vacuum_max_threshold=100000000（1億, PG18+）**

すべての発火判定は psql 観測値（`pg_stat_user_tables`）とサーバログを証拠とした。

## 結果表

| ケース | 内容 | 期待 | 実測 | 所要 | 観測値（証拠） | ログ行 |
|---|---|---|---|---|---|---|
| T1 | dead 300 > 閾値 250(=50+0.2·1000) | FIRED | **FIRED** | ~36s | n_dead 300→0, autovacuum_count=1 | `automatic vacuum of table "...t1"` 13:31:03 |
| T2 | dead 200 < 閾値 250 | NOT-FIRED | **NOT-FIRED** | 91s 監視 | n_dead=200 維持, av_fired=f（autoanalyze は正常発火） | (vacuum 行なし) |
| T3 | insert 2000 > insert闾値 1000 | FIRED | **FIRED** | ~即時 | n_ins_since_vacuum 2000→0, autovacuum_count=1 | `automatic vacuum of table "...t3"` 13:30:26 |
| T4 | insert 1000（=闾値, 非超過）→ analyze のみ | FIRED(analyze) | **FIRED(analyze), vacuum は NOT** | ~即時 | autoanalyze_count=1, av_fired=f | (下記 log 仕様参照) |
| T5 | `autovacuum_enabled=off`, dead 9000 | NOT-FIRED | **NOT-FIRED** | 91s 監視 | n_dead=9000 維持, av/aa 共に未発火 | (行なし) |
| T6 | per-table threshold=10/scale=0, dead 20 | FIRED | **FIRED** | ~即時 | reloptions 反映, autovacuum_count=1 | `automatic vacuum of table "...t6"` 13:30:26 |
| T7 | TOAST 本体+TOAST | 本体 FIRED | **本体 FIRED / TOAST 空のため独立発火なし（正常）** | ~即時 | 本体 autovacuum_count=1; TOAST は `pg_relation_size=0`, n_tup_ins=0 | 本体のみ 13:30:27 |
| T8 | 一時テーブル dead 9000 | NOT-FIRED | **NOT-FIRED** | 60s | last_autovacuum/last_autoanalyze 共に NULL | (行なし) |

**全 8 ケースが仕様どおりに動作。発火ロジックの異常は 0 件。**

## 境界の決定的確認
- T1/T2 で dead tuple 闾値 250 を跨いで、直上(300)=発火 / 直下(200)=非発火を確認。
- T4 で insert 闾値の**厳密不等号**を確認: 挿入 1000 は `1000 + 0.2·0 = 1000` に対し**非超過**のため insert-vacuum は発火せず（`>` であって `>=` ではない）。

## T7 TOAST の深掘り（推測せず物理状態で確定）
- 初期 t7 の payload `repeat(md5(x),1000)` は反復文字列で圧縮率が極めて高く、TOAST 闾値未満に圧縮され**inline 格納**。TOAST テーブルは `pg_relation_size=0` / `n_tup_ins=0` / `reltuples=-1`＝**空**。よって dead tuple が発生せず TOAST の独立 autovacuum が不要 → `last_autovacuum=NULL` は**正常**。
- 反証実験 t7c（`STORAGE EXTERNAL`＋非圧縮ランダム 3KB × 2000 行, TOAST=8MB）で 1500 行削除 → **TOAST が独立に autovacuum された**ことを別個のログ行と autovacuum_count で実証:
  ```
  automatic vacuum of table "postgres.public.t7c"
  automatic vacuum of table "postgres.pg_toast.pg_toast_16424"   ← TOAST 独立発火
  ```
  → TOAST は独立に閾値判定・発火するパスが正しく機能。

## master の新挙動に関する重要な発見（バグではない）
`log_autovacuum_min_duration=0` を設定しても、小さいテーブルの **autoanalyze がログに出ない**現象を観測・再現。切り分けの結果、master では autovacuum/autoanalyze の**ログ闾値が分離**されていた:

- `src/backend/postmaster/autovacuum.c:2880-2888`
  - `log_vacuum_min_duration` ← `Log_autovacuum_min_duration`（GUC `log_autovacuum_min_duration`）
  - `log_analyze_min_duration` ← **新 GUC `log_autoanalyze_min_duration`**（`autovacuum.c:146` で **デフォルト 600000ms = 10min**）
- `src/backend/commands/analyze.c:750` が `params->log_analyze_min_duration` で分岐。

実証: `SET log_autoanalyze_min_duration=0` → reload 直後に
`automatic analyze of table "postgres.public.t10"` が即出力。
→ autoanalyze の**発火判定自体は全ケースで正しい**（`autoanalyze_count`/`last_autoanalyze` で確認）。ログに出ないのは新 GUC のデフォルト(10分)による**観測性の仕様変更**であり発火バグではない。運用上、autoanalyze をログしたい場合は `log_autoanalyze_min_duration` を別途設定する必要がある。

## クラッシュ/エラー
- サーバログの TRAP/PANIC/FATAL: **0 件**、core ファイル: なし。
- 唯一の ERROR: `unrecognized parameter "autovacuum_analyze_enabled"`。
  これは検証手順 T1 が使用した reloption 名が現行 PostgreSQL に**存在しない**ことによる（有効なのは `autovacuum_enabled`）。本レポートでは analyze 抑止を `autovacuum_analyze_threshold`(大)+`autovacuum_analyze_scale_factor=0` で代替し、T1 を正しく実施した。

## 最終統計スナップショット
```
 relname | n_dead_tup | n_ins_since_vacuum | autovacuum_count | autoanalyze_count | av_fired | aa_fired
 t1      |          0 |                  0 |                1 |                 0 | t        | f
 t2      |        200 |               1000 |                0 |                 1 | f        | t
 t3      |          0 |                  0 |                1 |                 1 | t        | t
 t4      |          0 |               1000 |                0 |                 1 | f        | t
 t5      |       9000 |              10000 |                0 |                 0 | f        | f
 t6      |          0 |                  0 |                1 |                 1 | t        | t
 t7      |          0 |                  0 |                1 |                 1 | t        | t
```
