# pgstats カスタム統計種別・統計ファイル永続化 実行ベース検証レポート

対象: PostgreSQL 20devel (`master`), test_custom_stats モジュール
直近コミット: `5045d9f` "test_custom_stats: Fail if loading module outside shared_preload_libraries"
検証日: 2026-07-04 / ビルド: `--enable-debug --enable-cassert --enable-tap-tests CFLAGS="-O0 -g3"`（**assert 有効**）

すべて実サーバの起動・停止・クラッシュ・破損注入で確認（静的読解のみの結論なし）。

---

## 0. 結論サマリ

| # | 検証項目 | 判定基準 | 観測結果 | 判定 |
|---|---------|---------|---------|------|
| 1 | 公式 TAP | 全 pass | `t/001_custom_stats.pl .. ok`, **Tests=16, Result: PASS** | ✅ 正常 |
| 2 | 正規ロード | 起動時登録・`builtin=false`・値更新/参照 | kind 25/26 登録, `builtin=f`, report 正 | ✅ 正常 |
| 3 | **エラーパス (5045d9f)** | 明確な ERROR で拒否・無クラッシュ | LOAD/直接呼出/CREATE EXTENSION すべて `ERROR`, トランザクション rollback, 他ビュー健全, core 無し | ✅ 正常 |
| 4 | 正常停止の永続化 | `write_to_file=true` は保存, 非永続は初期化 | var(3,5)+desc・fixed(7)・lock(1) 完全保存, 破損警告無し | ✅ 正常 |
| 5 | immediate 停止 | クラッシュ後 全破棄・リセット | var 消失, fixed=0(reset_ts 有), lock リセット | ✅ 正常 |
| 6a | 破損: 末尾 truncate | 警告+リセット+正常起動 | `WARNING: could not read data...` + `corrupted statistics file` → reset → 起動 | ✅ 正常 |
| 6c | 破損: 空ファイル | 同上 | `WARNING: could not read format ID` + `corrupted...` → reset → 起動 | ✅ 正常 |
| 6b-1 | 破損: **構造**バイト書換 (format ID) | 同上 | `WARNING: found incorrect format ID` + `corrupted...` → reset → 起動 | ✅ 正常 |
| 6b-2 | 破損: **値**バイト書換 (IO 統計領域) | 警告+リセット期待 | **警告なしで読込 → SIGABRT クラッシュ → 全クラスタ crash recovery** | ❌ **異常** |

**主要所見**: 統計ファイルの読込 `pgstat_read_statsfile()` は**構造**（format ID・kind・エントリ種別・chunk 長・EOF マーカ・重複）を検証するが、読み込んだ統計**値**は一切検証しない。固定種別 IO 統計 (kind 10) の値領域を 1 バイト破損させると、無検証で共有メモリにロードされ、`Assert(pgstat_bktype_io_stats_valid)` に反して **SIGABRT** で当該プロセスが落ち、postmaster がクラスタ全体を crash recovery（全統計消失）する。これはコミット 5045d9f の回帰ではなく、また test_custom_stats 固有でもない、pgstat ファイルロードの堅牢性ギャップである。

---

## 1. 公式 TAP テスト

```
make -C src/test/modules/test_custom_stats check
# t/001_custom_stats.pl .. ok
# Files=1, Tests=16 ... Result: PASS
```
（作成/更新/参照, 正常再起動での永続化, crash recovery での消失, fixed リセットまで全網羅）

## 2. 正規ロード経路

`shared_preload_libraries = 'test_custom_fixed_stats, test_custom_var_stats'` で起動:
```
LOG:  registered custom cumulative statistics "test_custom_fixed_stats" with ID 26
LOG:  registered custom cumulative statistics "test_custom_var_stats" with ID 25
```
`pg_stat_kind_info`:
```
25|test_custom_var_stats|f|f|t|t     (builtin=f, fixed=f, cross_db=t, write_to_file=t)
26|test_custom_fixed_stats|f|t|f|t   (builtin=f, fixed=t, cross_db=f, write_to_file=t)
```
提供関数（`*--1.0.sql` より）:
- var: `test_custom_stats_var_create/_update/_drop/_report`
- fixed: `test_custom_stats_fixed_update/_report/_reset`

値の更新→flush→参照が期待どおり（var は pending がバックエンドローカル、`pg_stat_force_next_flush()` またはセッション終了で共有へ flush されてから report に反映。設計どおりの挙動）。

## 3. エラーパス検証（コミット 5045d9f の変更点）

`shared_preload_libraries` を外して再起動（起動時登録ログ無し = 正）。4 経路すべてで:
```
ERROR:  failed to register custom cumulative statistics "test_custom_fixed_stats" with ID 26
DETAIL:  Custom cumulative statistics must be registered while initializing modules in "shared_preload_libraries".
```
- `LOAD 'test_custom_fixed_stats'` / `LOAD 'test_custom_var_stats'` → ERROR
- `SELECT test_custom_stats_fixed_update()` / `..._var_update('x')`（遅延ロードで `.so` 読込 → `_PG_init`）→ ERROR
- 別 DB で `CREATE EXTENSION` → `CREATE FUNCTION ... LANGUAGE C` のシンボル検証で `.so` を読込 → ERROR → **拡張作成がトランザクション rollback**（関数も残らない）

**改善の実証**: コミット前は `_PG_init` が `process_shared_preload_libraries_in_progress` を見て早期 return し、拡張は作られるが「呼べるが壊れた」関数が残った。コミット後は `pgstat_register_kind()`（`pgstat.c:1526` 付近の `!process_shared_preload_libraries_in_progress` チェック）で明示的に ERROR となり、CREATE EXTENSION 自体が失敗・rollback する。

エラー後の健全性:
- `SELECT 1` 応答, `pg_stat_database`(5 行)/`pg_stat_lock`/`pg_stat_wal`/`pg_stat_kind_info`(13=builtin のみ) すべて正常
- 起動ログに `PANIC|TRAP|FailedAssertion` 無し, **core 無し**

→ コミットの意図どおり、明確な ERROR で拒否・無クラッシュ・サーバ健全。✅

## 4. 永続化（正常シャットダウン）

`write_to_file` 一覧（`pg_stat_kind_info`）: kind 6 (`backend`) のみ `write_to_file=f`。他 builtin と custom 25/26 は `t`。

baseline（flush 後）→ `pg_ctl stop -m fast` → start:

| 統計 | kind | 停止前 | 再起動後 | |
|------|------|-------|---------|--|
| var `persist1` | 25 (write=t) | `3\|persistent entry 1` | `3\|persistent entry 1` | ✅ 保存（説明文字列=副次統計ファイル round-trip） |
| var `persist2` | 25 | `5\|persistent entry 2` | `5\|persistent entry 2` | ✅ 保存 |
| fixed numcalls | 26 (write=t) | `7` | `7` | ✅ 保存 |
| lock relation waits | 11 (write=t, builtin) | `1` | `1` | ✅ 保存 |
| backend | 6 (write=f) | — | 初期化 | ✅ 非永続（唯一の非永続 kind、本質的にバックエンド毎で揮発） |

- 正常停止時に `$PGDATA/pg_stat/pgstat.stat`（74881B）と副次ファイル `test_custom_var_stats_desc.stats`（86B）が書かれる。
- 起動ログに `corrupted statistics file` 警告 **無し**。✅

## 5. クラッシュ時の破棄（immediate 停止）

`pg_ctl stop -m immediate` → `pg_stat/` は空（`pgstat.stat` 未書込 = クラッシュは永続化しない）。副次 desc ファイルも読込時 unlink 済で不在。起動:
```
LOG:  database system was not properly shut down; automatic recovery in progress
```
- var `persist1/2` → 空（drop 済）
- fixed numcalls → `0`、`stats_reset IS NOT NULL` の numcalls → `0`（crash が reset timestamp を設定）
- lock relation waits → 空（リセット）
- `PANIC|TRAP|FailedAssertion` 無し

→ 意図的な全破棄。✅

## 6. 統計ファイル破損耐性

各試行の前に good ファイルをバックアップ（`/tmp/pgstat.*.bak`）。破損注入コマンドは下記「最小再現」に記載。

### 6a. 末尾 truncate — ✅ 正常
```
truncate -s -20 $PGDATA/pg_stat/pgstat.stat        # 67333 -> 67313
```
```
WARNING:  could not read data for entry 2/0/2677 of type S
LOG:  corrupted statistics file "pg_stat/pgstat.stat"
```
→ reset・正常起動・サーバ健全。EOF マーカ欠落を検出。

### 6c. 空ファイル — ✅ 正常
```
: > $PGDATA/pg_stat/pgstat.stat                    # 0 bytes
```
```
WARNING:  could not read format ID
LOG:  corrupted statistics file "pg_stat/pgstat.stat"
```
→ reset・正常起動。

### 6b-1. 中間バイト書換（構造バイト = 先頭 format ID を in-place）— ✅ 正常
```
printf '\xde\xad\xbe\xef' | dd of=$PGDATA/pg_stat/pgstat.stat bs=1 seek=0 count=4 conv=notrunc
# サイズ不変(65887) = 本体は無傷、ヘッダのみ破損
```
```
WARNING:  found incorrect format ID -272716322 (expected 27638972)
LOG:  corrupted statistics file "pg_stat/pgstat.stat"
```
→ reset・正常起動。**構造を成すバイト**（format ID/エントリ種別/kind/長さ/EOF）は検証され安全。

### 6b-2. 中間バイト書換（**値**バイト = IO 統計カウンタ領域）— ❌ **異常（クラッシュ）**

good ファイル中間の 1 バイトを `0x00 -> 0xFF`（IO 統計の固定エントリ内、ある untracked カウンタの最上位バイトに命中）:
```
printf '\xff' | dd of=$PGDATA/pg_stat/pgstat.stat bs=1 seek=$((SIZE/2)) count=1 conv=notrunc
```
- 起動時: **破損警告なし**（値は無検証でそのまま共有メモリへロード）
- その後 IO 統計に触れた最初のアクセスで **SIGABRT**:
```
LOG:  client backend (PID ...) was terminated by signal 6: Aborted
DETAIL:  Failed process was running: SELECT ... FROM pg_stat_io ...
LOG:  all server processes terminated; reinitializing
LOG:  database system was not properly shut down; automatic recovery in progress
```
→ クラスタ全体 crash recovery、**全統計消失**。

異常判定該当: 「破損読み込みでのクラッシュ」「部分的に読み込まれた不整合な統計」。

---

## 7. 異常の深掘り（原因特定）

### 7.1 コアの実行証拠（2 つのクラッシュ地点、同一根本原因）

**地点 A** — 停止時、checkpointer の IO flush（`/tmp/core.checkpointer.evidence`）:
```
#5 ExceptionalCondition("pgstat_bktype_io_stats_valid(bktype_shstats, MyBackendType)", "pgstat_io.c", 228)
#6 pgstat_io_flush_cb (nowait=false)            pgstat_io.c:228
#7 pgstat_flush_io (nowait=false)               pgstat_io.c:177
#8 pgstat_report_checkpointer ()                pgstat_checkpointer.c:71
#9 CheckpointerMain ()  [ShutdownXLOGPending 経路]  checkpointer.c:631
MyBackendType = B_CHECKPOINTER
```

**地点 B** — `pg_stat_io` 参照時、任意バックエンド（`/tmp/core.repro.evidence`, `core.repro_smear.evidence`）:
```
#5 ExceptionalCondition("pgstat_bktype_io_stats_valid(bktype_stats, bktype)", "pgstatfuncs.c", 1588)
#6 pg_stat_get_io (fcinfo=...)                  pgstatfuncs.c:1588
#7 ExecMakeTableFunctionResult ...
```

### 7.2 破損値の同定（コアから）

`pgstat_io_flush_cb` の `bktype_shstats->counts` をコアからダンプ:
```
counts[0][0][1] = -72057594037927936   (= 0xFF00000000000000)
```
添字は `[IOOBJECT_RELATION][IOCONTEXT_BULKREAD][IOOP_FSYNC]`。値 `0xFF00000000000000` は int64 の**最上位バイトのみ 0xFF** = 注入した `0x00→0xFF` の 1 バイトそのもの。checkpointer は BULKREAD コンテキストの IO を一切行わない（untracked）ため、この非ゼロ値が不変条件違反となる。

### 7.3 根本原因（コード位置）

- 読込ループ `pgstat_read_statsfile()`（`src/backend/utils/activity/pgstat.c:1810–2116`）。固定種別は
  `pgstat.c:1916` で `pgstat_read_chunk(ptr, info->shared_data_len)` により**生ブロックのまま**共有メモリへ復元。format ID/kind/エントリ種別/長さ/EOF/重複は検証するが、**カウンタ値の健全性検証は無い**。
- IO 統計の不変条件は `pgstat_bktype_io_stats_valid()`（`pgstat_io.c:37`）で、「tracked op は time≠0 なら count>0」「untracked op は count=0」を要求。強制は **`Assert` のみ**（`pgstat_io.c:228` の flush 時、`pgstatfuncs.c:1588` の参照時）。
- 破損した on-disk 値がこの不変条件を破ると、assert 有効ビルドで **SIGABRT**。

### 7.4 影響範囲・ビルド差

- **assert 有効（本ビルド）**: 破損 IO 値ロード → 次の IO 統計 flush/参照で `Assert` 発火 → プロセス abort → クラスタ crash recovery（全統計消失）。
- **本番（assert 無効）**: `Assert` はコンパイル除去されクラッシュしない。代わりに `pg_stat_io` が**巨大/負の異常値**を表示し、正常停止で**その異常値がファイルへ再永続化**され `pg_stat_reset()` まで残る（＝黙って壊れた統計）。
- test_custom_* のカスタムカウンタには同種の assert が無いため、値破損は「黙って誤った値」になるのみ（クラッシュしない）。
- 破損検出は**構造限定**という設計（統計は非クリティカル、チェックサム無し）で概ね意図どおりだが、固定 IO 統計に限っては値破損が assert クラッシュに直結する点が堅牢性ギャップ。

---

## 8. 最小再現（破損注入コマンド列を含む）

前提: assert 有効ビルド、非特権 OS ユーザで実行。`BIN`/`PGDATA` は環境に合わせる。
同梱スクリプト: `validation/repro_pgstat_iocorrupt.sh`（決定的再現。中間 32B スメアで untracked IO カウンタ命中を保証）。

構造破損 3 種（すべて **正常** = 警告+リセット）:
```bash
F=$PGDATA/pg_stat/pgstat.stat            # 事前に good を stop -m fast で生成 & バックアップ
# (a) 末尾 truncate
cp "$F" /tmp/good.a; truncate -s -20 "$F"
# (c) 空ファイル
cp "$F" /tmp/good.c; : > "$F"
# (b-1) 構造バイト = format ID を in-place
cp "$F" /tmp/good.b1; printf '\xde\xad\xbe\xef' | dd of="$F" bs=1 seek=0 count=4 conv=notrunc
# 各々の後: pg_ctl start → ログに WARNING/"corrupted statistics file" → reset → 正常起動
```

値破損（**異常** = クラッシュ、決定的）:
```bash
# good を生成
$PSQL -c 'SELECT pg_stat_reset()'; $PSQL -c 'CHECKPOINT'; $PSQL -c 'SELECT pg_stat_force_next_flush()'
pg_ctl -D $PGDATA -w stop -m fast
F=$PGDATA/pg_stat/pgstat.stat; SZ=$(stat -c %s "$F"); MID=$((SZ/2))
cp "$F" /tmp/good.b2
# IO 統計領域に 32B の 0xFF スメア（untracked カウンタを非ゼロ化）
dd if=/dev/zero bs=1 count=32 2>/dev/null | tr '\0' '\377' | dd of="$F" bs=1 seek=$MID count=32 conv=notrunc
pg_ctl -D $PGDATA -l $LOG -w start                 # 破損警告は出ない（無検証ロード）
$PSQL -c 'SELECT count(*) FROM pg_stat_io'          # → SIGABRT / crash recovery
gdb -batch -ex bt $BIN/postgres $PGDATA/core        # → Assert(pgstat_bktype_io_stats_valid)
```

保全済み証拠: `/tmp/core.checkpointer.evidence`, `/tmp/core.repro.evidence`, `/tmp/core.repro_smear.evidence`,
good バックアップ `/tmp/pgstat.*.bak`。

---

## 9. 総括

- test_custom_stats の正規ロード・カスタム種別可視化・値更新/参照・**正常停止での永続化**・**crash 時の全破棄**・**fixed リセット**は、実行ベースで全て設計どおり。公式 TAP も PASS。
- コミット **5045d9f** のエラーパス（`shared_preload_libraries` 外ロードの明示失敗）は、LOAD/直接呼出/CREATE EXTENSION いずれも**明確な ERROR + rollback + 無クラッシュ**で、意図どおり・回帰なし。
- 統計ファイル破損耐性は、**構造破損**（truncate/空/ヘッダ）に対しては警告+リセット+正常起動で堅牢。一方**値破損**は無検証でロードされ、固定 IO 統計 (kind 10) の場合 `pgstat_bktype_io_stats_valid` の assert を破って **assert 有効ビルドで SIGABRT → クラスタ crash recovery**（本番ビルドでは異常値の黙認・再永続化）を招く。これが唯一の異常所見で、原因は `pgstat_read_statsfile`（`pgstat.c:1916`）の値無検証と、IO 不変条件が `Assert` のみで守られている点。
