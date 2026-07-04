# pgstats 高並行負荷テスト報告

- 対象: PostgreSQL 20devel (`shinyaaa/postgres`, master @ `6d4ca6d`)
- ブランチ: `claude/postgres-pgstats-race-test-ifqsql`
- 日付: 2026-07-04
- 手法: **cassert 有効ビルドで実負荷を実行**（静的読解のみの結論は不採用）

---

## 0. 結論

**cassert ビルドで合計約 10 分の高並行負荷（pgbench 50 接続 + 統計撹乱ループ a〜f）を
かけたが、レースコンディション・assertion 失敗(TRAP)・PANIC・コアダンプ・backend 異常終了・
統計値の破損(負値/巨大値)・エントリリーク・ハングはいずれも検出されなかった。**

- クラッシュマーカ（TRAP/PANIC/terminated by signal/segfault）: 全ログ通算 **0**
- コアダンプ: **0**（`ulimit -c unlimited`、出力先確認済）
- `pg_stat_lock` / `pg_stat_get_backend_lock` の負値・巨大値: 全監視サンプルで **0 件**
- fast shutdown → restart: **正常**（テスト前後で複数回確認）
- 独自機能（共有ロック統計・バックエンド単位ロック統計）は**正しい値を集計することを実測で確認**

異常が出なかったこと自体が成果だが、下記 **§4 の「テストが実際にコードを駆動していることの
検証」** が本報告の要点。初期のループ構成では対象コードが一切実行されておらず、それを是正した
うえでの陰性結果である。

---

## 1. ビルド・環境

```
./configure --prefix=/home/user/pgi --enable-debug --enable-cassert \
            --without-icu CFLAGS="-O0 -g3"
make -j4 && make install
```
- `--without-icu`: ICU 未導入のため（統計機能に無関係）。`flex` は `apt` で導入。
- cassert 確認: `src/include/pg_config.h` に `#define USE_ASSERT_CHECKING 1`。
- コアダンプ: `core_pattern=core`（backend の cwd=`$PGDATA` に出力）。postmaster の
  `/proc/<pid>/limits` で `Max core file size = unlimited` を実測確認。
- cluster: `max_connections=200`, `track_functions=all`, `log_min_messages=warning`。
- postgres は root 実行不可のため、非特権ユーザ `user` で全 postgres/pgbench プロセスを起動。

## 2. テスト対象（このforkの独自機能＝主眼）

stock の PostgreSQL master には無く、本 fork が追加した pgstats 機能：

| 機能 | 実体 | 追加コミット |
|---|---|---|
| 集約ロック統計 | `pg_stat_lock` ビュー / `pg_stat_get_lock()` / `PGSTAT_KIND_LOCK`(kind 11, fixed) | c776550 ほか |
| バックエンド単位ロック統計 | `pg_stat_get_backend_lock(pid)` | **8c579bd（最新の独自追加）** |
| 統計種別メタ情報 | `pg_stat_kind_info` / `pg_stat_get_kind_info()` / `entry_count` | — |

主なコード経路：
- 計数: `pgstat_count_lock_waits()` / `pgstat_count_lock_fastpath_exceeded()`
  （`src/backend/utils/activity/pgstat_lock.c`、backend 版は `pgstat_backend.c`）
- 呼出元: `src/backend/storage/lmgr/proc.c:1613`（wait）、`lock.c:1024`（fastpath 超過）
- flush: pending → 共有メモリを LWLock 排他で加算（`LOCKSTAT_ACC` マクロ）
- reset/snapshot: `pgstat_lock_reset_all_cb`(EXCLUSIVE) / `pgstat_lock_snapshot_cb`(SHARED)

## 3. 負荷ハーネス（`/home/user/stress/`）

| ループ | スクリプト | 内容 |
|---|---|---|
| a | `loop_a_reset.sh` | `pg_stat_reset()`, `pg_stat_reset_shared(NULL/'io'/'lock')`, `pg_stat_reset_backend_stats()` を 0.2s 間隔 |
| b | `loop_b_views.sh` | 全 `pg_stat_*` ビュー（`pg_stat_lock`,`pg_stat_kind_info` 含む）を連続 SELECT |
| c | `loop_c_backendlock.sh` | `pg_stat_activity` の全 PID に `pg_stat_get_backend_lock(pid)`（終了直後 PID のレース狙い）+ lateral join 版 |
| d | `loop_d_ddl.sh` | table/function の CREATE/CALL/DROP 反復（統計エントリ生成/破棄レース） |
| e | `loop_e_advisory.sh` | advisory lock の holder/waiter 競合（ロック待ち生成） |
| f | `loop_f_fastpath.sh` | 1 トランザクションで 40 テーブルに弱ロック → fast-path 超過を連続生成 |

監視 `monitor.sh`（10s 間隔）: クラッシュマーカ数 / コア数 / kind entry_count /
postmaster RSS / ツリー RSS / backend 数 / テーブル統計エントリ数 / ロック統計の負値・巨大値。

## 4. 【要点】テストが実際に対象コードを駆動していることの検証

負荷を回すだけでは対象コードが動かない罠が 2 つあり、実測で発見・是正した。

### F1. `pg_stat_kind_info.entry_count` は組込み種別では常に NULL
`entry_count` はカインド定義の `track_entry_count` が真の場合のみ計上される
（`pgstat_kind.c:62`）。組込み 13 種別はいずれも `track_entry_count` を設定していないため、
`SELECT ... entry_count FROM pg_stat_kind_info` は**全種別 NULL**（実測: 13/13 NULL）。
`track_entry_count` を使うのはカスタム統計モジュール（`test_custom_stats`）のみ。
→ 手順書の「entry_count が単調増加ならリーク疑い」という判定は**組込み統計には適用不可**。
  代替として (i) `pg_stat_all_tables` の行数、(ii) postmaster RSS 推移でリークを監視した。

### F2. ロック待ち計数は `deadlock_timeout` 経過後のみ発火
`pgstat_count_lock_waits()` は `proc.c:1601` の `if (deadlock_state != DS_NOT_YET_CHECKED)`
ブロック内でのみ呼ばれる。**`deadlock_timeout`（既定 1s）未満の待ちは一切計数されない。**
初期の loop_e は holder 保持を 0.3〜0.4s にしていたため、**wait 計数経路が一度も実行されて
いなかった**（実測: 計数 0）。`deadlock_timeout='100ms'` に下げ、holder 保持を 0.3〜0.5s に
することで、待ちが閾値を越え計数されることを確認（advisory waits=6, wait_time=2685ms）。

### F3. fast-path 超過はグループ単位（弱ロックのみ）
`fastpath_exceeded` は fast-path グループ（16 スロット）が溢れた時のみ計上。`AccessExclusiveLock`
等の強ロックは fast-path を使わず対象外。グループ数は `max_locks_per_transaction` に比例
（`InitializeFastPathLocks`, 既定 128→8 グループ）。`max_locks_per_transaction=16`（1 グループ）
にし、1 トランザクションで 40 テーブルに `AccessShareLock` を取得することで
`relation fastpath_exceeded=377` を確認。

### 是正後の「計数が実際に走っている」証拠（count_noreset ラウンド, reset 無し 90s）
```
   locktype    | waits | wait_time  | fastpath_exceeded
---------------+-------+------------+-------------------
 advisory      |   120 |  28355.382 |                 0
 relation      |     0 |          0 |            895391
 transactionid |  1712 | 286012.025 |                 0   ← pgbench の行競合による実待ち
 tuple         |   353 |  58731.112 |                 0
```
→ 共有ロック統計が**負値・巨大値なく**大きな正の値に正しく積算されることを確認。

### バックエンド単位ロック統計の正当性（正の実測値）
`pg_stat_get_backend_lock()` は共有側 backend 統計を読むため、自身の pending が flush される前に
読むと 0 になる（PQexec 単位の flush タイミング差、バグではない）。文を分割し flush を挟むと：
```
   locktype    | waits | wait_time | fastpath_exceeded
---------------+-------+-----------+-------------------
 transactionid |     1 |  1704.427 |                 0   ← 実際に ~1.7s 待った backend の自 PID 統計
```
→ `PGSTAT_BACKEND_FLUSH_ALL` は `PGSTAT_BACKEND_FLUSH_LOCK` を含む（`pgstat_internal.h:709`）ことを
  コードでも確認済。機能は正しく動作。

## 5. 実施ラウンドと結果一覧

| ラウンド | 時間 | ループ | tps | クラッシュ | コア | ロック負値/巨大 |
|---|---|---|---|---|---|---|
| smoke | 20s | a-e | 1049 | 0 | 0 | 0 |
| full | 120s | a-e | 1005 | 0 | 0 | 0 |
| rep1 | 60s | a-e | 1015 | 0 | 0 | 0 |
| rep2 | 60s | a-e | 1022 | 0 | 0 | 0 |
| rep3 | 60s | a-e | 1031 | 0 | 0 | 0 |
| **count_noreset** | 90s | b-f（計数有効, reset 無） | 876 | 0 | 0 | 0 |
| **count_full** | 90s | a-f（計数+reset+read 同時） | 890 | 0 | 0 | 0 |

**再現性**: 60s 短縮版 3 回はいずれも異常 0（「陰性」が 3/3 再現）。計数有効ラウンドも 0。

## 6. 整合性・リソース確認

- **xact_commit 整合**: reset ループ無しで pgbench を固定 5000 tx 実行 →
  `pg_stat_database.xact_commit` の増分 **+5022**（+22 は psql/vacuum 由来）。整合。
  ※ reset ループ稼働中は 0.2s 毎に統計がゼロ化されるため、この検証は reset 無しで実施する必要がある。
- **ロック統計の負値**: 共有・backend 単位とも全ラウンドで負値・巨大値なし。
- **エントリリーク（代替指標）**: `pg_stat_all_tables` 行数は DDL churn 中も ~166 で安定
  （create/drop がベースラインへ回復）。無限成長なし。
- **メモリ**: **postmaster の VmRSS は全ラウンドで平坦**（例: 33296KB 固定 / 再起動後 23792KB 固定）
  → 長寿命プロセスに蓄積なし。ツリー合計 RSS は増加するが**逓減（漸近）**しており、
  50 個の pgbench backend が共有バッファ(shared_buffers)ページに触れて RSS 計上されるため
  （共有ページの各プロセス重複計上）。線形リークではない。
- **fast shutdown → restart**: 全期間で正常。再起動後に統計ビュー参照可。

## 7. ログ中の全 FATAL/ERROR の内訳（サーバ欠陥ではない）

`connection to client lost`（teardown でループ backend を kill した結果）を除くと、ログ中の
FATAL/ERROR は**すべてテスト実行側の操作ミス**：
- `role "user" does not exist` … pgbench に `-U postgres` を付け忘れた回（是正済）。
- `column "create table..." does not exist` / `relation "fp_1"` … SQL クオート誤り（是正済）。
- `ALTER SYSTEM cannot run inside a transaction block` … ALTER SYSTEM を 1 文にまとめた誤り。

いずれもサーバ側の異常ではない。

## 8. 原因箇所の特定

- クラッシュ・コア・assertion は**発生せず**、特定すべき原因箇所は無し。
- ASAN ビルドは手順書上「レースが疑われる場合のみ」。cassert で約 10 分の駆動でも陽性兆候
  （コア/ハング/assertion）が皆無のため**未実施**（＝現時点でレースは positively には疑われない）。
  必要なら `CFLAGS="-O0 -g3 -fsanitize=address" --enable-cassert` で同手順の再走可能。

### 未確定事項（推測を明示）
- 「レースが**無い**」ことの証明はしていない。本テストは cassert 下でも**顕在化しなかった**という
  観測にとどまる（10 分規模、4 コア）。より長時間・多コア・ASAN では別結論の可能性を排除できない
  → **未確定**。
- pending→shared の flush 競合や reset との競合は LWLock で保護されており、コード上も
  waits/wait_time/fastpath_exceeded を同一マクロで一括更新するため整合的だが、これは静的観察
  であり、動的に「破損を再現できなかった」ことが根拠。

## 9. 成果物の所在
- ハーネス: `/home/user/stress/loop_[a-f]_*.sh`, `monitor.sh`, `run_stress.sh`, `consistency.sh`
- 監視時系列: `/home/user/stress/logs/monitor_<label>.log`
- 異常イベント: `/home/user/stress/logs/anomalies_<label>.log`（全ラウンド空）
- pgbench ログ: `/home/user/stress/logs/pgbench_<label>.log`
- 本報告: `/home/user/stress/REPORT.md`

## 10. 最小再現スクリプト
再現すべきクラッシュ／破損が発生しなかったため **該当なし（N/A）**。
（もし将来 count_full で異常が出た場合の二分探索起点として、`run_stress.sh <label> <sec> <loops>`
 の第3引数でループ部分集合を指定できる。例: `run_stress.sh min 60 a,c` で a と c のみ。）
