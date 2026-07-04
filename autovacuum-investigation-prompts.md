# PostgreSQL autovacuum 動的調査プロンプト集（master / Linux）

- 対象: PostgreSQL master ブランチ（20devel、調査設計時点 HEAD: `6d4ca6d`）の autovacuum
- 前提: 既知の症状なし。「何が問題かの発見」自体が調査目的
- 方針: **静的コードリーディングのみでの結論は禁止**。必ずビルド→実行→観測を軸とし、ソース参照は実行で得た異常の裏付けにのみ使う
- 実行者: Opus（各プロンプトは単体で完結し、そのままコピペで実行可能）

---

## ステップ1: 調査戦略の設計（Fable による整理)

### 1.1 autovacuum の構造と、実行で観測可能な故障面

autovacuum は「postmaster → autovacuum launcher（常駐、DB選択とworker起動要求）→ autovacuum worker（DBごとに起動、テーブル選択と実vacuum/analyze）」の3層構造で、以下のサブシステムに依存する:

| 依存領域 | 実行時に観測できる故障モード |
|---|---|
| 累積統計系(pgstat) | dead tuple 数が反映されず発火しない / 発火が過剰 |
| 発火判定式（vacuum/analyze/insert threshold, scale_factor, PG18の `autovacuum_vacuum_max_threshold`） | 閾値超過なのに永久に vacuum されない、逆に無限ループ的発火 |
| worker スケジューリング（`autovacuum_max_workers`, PG18の `autovacuum_worker_slots`, naptime, 複数DB間の分配） | worker 枯渇・特定DBの飢餓・launcher のハング |
| コストベース制御と worker 間バランシング | 遅延計算異常による停止同然の速度、または制御無効化 |
| 凍結・XID/MultiXact 周回対策（anti-wraparound, failsafe） | datfrozenxid が進まない、wraparound 警告が消えない、failsafe 不発火 |
| dead TID 格納（PG17+ の TidStore）とメモリ管理 | `autovacuum_work_mem` 境界での複数インデックスパス異常、メモリリーク |
| シグナル/再読込/キャンセル処理（SIGHUP、ロック競合での自己キャンセル） | reload 後の設定不反映、キャンセルすべきでない anti-wraparound の中断 |
| クラッシュ耐性 | worker の SEGV/assert 失敗（`--enable-cassert` で TRAP として顕在化） |

### 1.2 探索フロー

症状未知なので、以下の順で「広く浅く→異常が出た所を深く」進める:

1. **ビルドと環境確立**（P1）: assert 有効デバッグビルド。ここで壊れていれば以降全ての観測が無意味になるため、ビルド警告・regression test・launcher の生存確認まで含めて基盤を固める。
2. **基本動作 = 発火条件の網羅検証**（P2): 最も利用頻度が高く、かつ「静かに壊れる」（vacuum されないだけでエラーが出ない）領域。判定式ごとに決定的なテストを行う。
3. **スケジューリングとリソース制御**（P3): 複数DB・多テーブル・worker数変更（PG18 の online 変更は新しく回帰リスクが高い）・コストバランシング・SIGHUP。
4. **凍結と周回対策**（P4): master 同梱の `xid_wraparound` テストモジュールで XID を実際に消費し、anti-wraparound / failsafe を実発火させる。最悪の障害（クラスタ停止）に直結する領域。
5. **ストレス・境界条件**（P5): 長時間 churn、極小メモリでの複数インデックスパス、ロック競合キャンセル、クラッシュリカバリ横断、メモリリーク監視。
6. **異常の深掘りと最小再現化**（P6): P1〜P5 のどれかで異常が出た時に適用する共通テンプレート（gdb/strace/perf/コアダンプ/バイセクト）。

各プロンプトには「異常判定基準」を数値・文字列パターンで明示し、推測でなく実行ログ・終了コード・カタログ観測を証拠とすることを義務付ける。

### 1.3 全プロンプト共通の観測手段

- ログ: `log_autovacuum_min_duration = 0`, `log_min_messages = info`、`TRAP:`/`PANIC`/`segfault`/`ERROR` の grep
- カタログ/ビュー: `pg_stat_user_tables`（`n_dead_tup`, `last_autovacuum`, `autovacuum_count`）、`pg_stat_progress_vacuum`、`pg_stat_activity`（`backend_type` が `autovacuum launcher` / `autovacuum worker`）、`pg_database.datfrozenxid`
- プロセス: `/proc/<pid>/status`（VmRSS）、`ulimit -c unlimited` + コアダンプ
- デバッガ等: gdb（`-O0 -g3` ビルド）、strace、perf

---

## ステップ2: Opus 実行用プロンプト

---

## プロンプト P1: デバッグビルドと autovacuum 動作基盤の確立

**検証・発見する対象**: master が Linux でクリーンにビルド・起動できるか。autovacuum launcher/worker が基本サイクルで正常動作するか。以降の調査に使える「assert有効・デバッグシンボル付き」環境の確立。

### Opus への指示本文

```
あなたは PostgreSQL master ブランチの autovacuum の潜在バグを、実際にビルド・実行して発見する調査を行う。
静的なコードリーディングだけで結論を出すことは禁止。必ず実行し、ログ・終了コード・カタログの観測結果を証拠として報告すること。

# 背景
PostgreSQL の autovacuum は launcher（常駐）と worker（都度起動）で構成される。master は開発版（20devel）であり、
未知の回帰が含まれうる。このタスクではまず assert 有効のデバッグビルドを作り、基本動作を検証する。

# 手順

## 1. 取得とビルド
sudo apt-get update && sudo apt-get install -y build-essential bison flex libreadline-dev zlib1g-dev libicu-dev pkg-config gdb strace perl
git clone https://git.postgresql.org/git/postgresql.git ~/pgsrc   # 失敗時は https://github.com/postgres/postgres.git
cd ~/pgsrc && git checkout master && git log --oneline -1 | tee ~/build-head.txt
./configure --prefix=$HOME/pgav --enable-debug --enable-cassert --enable-tap-tests CFLAGS="-O0 -g3" 2>&1 | tee ~/configure.log
# libicu-dev が入らない環境なら --without-icu を追加して再実行
make -j"$(nproc)" 2>&1 | tee ~/make.log
make install
make -C contrib/pg_visibility install
make -C src/test/modules/xid_wraparound install
export PATH=$HOME/pgav/bin:$PATH

判定: configure/make の終了コードが非0なら異常。make.log 内の warning を grep -i warning で数え、
autovacuum.c / vacuumlazy.c / vacuum.c 由来の warning があれば内容を記録（それ自体が発見事項）。

## 2. 回帰テストによるベースライン確認
cd ~/pgsrc && make check 2>&1 | tail -30 | tee ~/regress-result.txt
判定: "All tests passed" 以外なら異常。失敗した diff は src/test/regress/regression.diffs を全文保存。
vacuum 関連テストの失敗は本調査の中心的発見となるので優先的に記録。

## 3. クラスタ作成と autovacuum 観測用設定
ulimit -c unlimited
initdb -D ~/pgav-data --no-locale -E UTF8
cat >> ~/pgav-data/postgresql.conf <<'EOF'
autovacuum_naptime = 1s
log_autovacuum_min_duration = 0
log_min_messages = info
logging_collector = on
log_directory = 'log'
log_line_prefix = '%m [%p] %b '
autovacuum_vacuum_cost_delay = 0
EOF
pg_ctl -D ~/pgav-data -l ~/pgav-start.log start
判定: pg_ctl の終了コード非0、または pgav-start.log に FATAL/PANIC があれば異常。

## 4. launcher/worker の生存と基本サイクル確認
psql -d postgres -Atc "SELECT pid, backend_type FROM pg_stat_activity WHERE backend_type LIKE 'autovacuum%';"
判定: 'autovacuum launcher' が1行返らなければ異常（autovacuum が起動していない）。

基本発火のスモークテスト:
psql -d postgres <<'EOF'
CREATE TABLE smoke(a int);
INSERT INTO smoke SELECT generate_series(1,10000);
DELETE FROM smoke WHERE a <= 6000;
EOF
その後、次のループで最大 180 秒監視:
for i in $(seq 1 180); do
  r=$(psql -d postgres -Atc "SELECT last_autovacuum IS NOT NULL FROM pg_stat_user_tables WHERE relname='smoke'")
  [ "$r" = "t" ] && echo "vacuumed after ${i}s" && break
  sleep 1
done
psql -d postgres -c "SELECT relname, n_dead_tup, last_autovacuum, autovacuum_count FROM pg_stat_user_tables WHERE relname='smoke';"
grep -E "automatic (vacuum|analyze)" ~/pgav-data/log/*.log | head

判定基準:
- 180秒以内に last_autovacuum が入り、ログに "automatic vacuum of table" が出れば正常。
- 入らない場合は異常。深掘り: (a) n_dead_tup が 0 のままなら統計系(pgstat)の問題 →
  psql -c "SELECT * FROM pg_stat_user_tables WHERE relname='smoke'" の全列を記録し、
  gdb -p <launcherのpid> で bt を取得。(b) n_dead_tup は増えているのに vacuum されないなら
  発火判定の問題 → log_min_messages = debug2 にして pg_ctl reload し、launcher のループログを観測。
- ログに TRAP: / PANIC / segfault が1件でもあれば重大異常。コアダンプ
  （~/pgav-data/ 直下または /proc/sys/kernel/core_pattern の場所）を探し、
  gdb ~/pgav/bin/postgres <core> -batch -ex 'bt full' を実行して全文保存。

## 5. 全過程を通しての常時監視
調査終了時に必ず実行:
grep -cE "TRAP:|PANIC|was terminated by signal" ~/pgav-data/log/*.log ~/pgav-start.log
0 以外なら該当行と前後 20 行を報告に含める。

# 成果物
- ~/build-head.txt(コミットID)、configure/make/regress の要約、warning 一覧
- スモークテストの観測値（発火までの秒数、pg_stat_user_tables の値、ログ行）
- 異常があった場合: 再現用の最小コマンド列を repro.sh として保存し、内容を報告に貼る
- 環境は ~/pgav (バイナリ), ~/pgav-data (クラスタ), ~/pgsrc (ソース) として保持したまま終了する
```

### 期待される出力・異常判定基準・引き継ぎ事項

- 期待: ビルド成功、`make check` 全パス、launcher 存在、スモークが 180 秒以内に発火。
- 異常判定: 上記本文中に明記（終了コード、`TRAP:`/`PANIC`、180 秒未発火、regression diff）。
- 引き継ぎ: HEAD コミットID、`~/pgav`・`~/pgav-data`・`~/pgsrc` のパス、warning 一覧、（異常時）repro.sh と gdb バックトレース。以降のプロンプトはこの環境構築手順を各自内包しているため、環境が消えていても再現可能。

---

## プロンプト P2: 発火条件マトリクスの実測検証（vacuum / analyze / insert / reloptions / TOAST）

**検証・発見する対象**: autovacuum の各発火判定式が実際に仕様どおり動くか。「エラーを出さずに vacuum されない」型のサイレント障害の検出。

### Opus への指示本文

```
あなたは PostgreSQL master ブランチの autovacuum 発火条件を、実際にビルド・実行して検証する。
静的コードリーディングのみでの結論は禁止。全ての判定は psql での観測値とサーバログを証拠とすること。

# 背景
autovacuum の発火式（設計仕様）:
- vacuum: n_dead_tup > autovacuum_vacuum_threshold(50) + autovacuum_vacuum_scale_factor(0.2) * reltuples
  （PG18 以降は上限 autovacuum_vacuum_max_threshold あり、デフォルト1億）
- analyze: 変更行数 > autovacuum_analyze_threshold(50) + autovacuum_analyze_scale_factor(0.1) * reltuples
- insert vacuum: 挿入行数 > autovacuum_vacuum_insert_threshold(1000) + autovacuum_vacuum_insert_scale_factor(0.2) * reltuples
これらが実機で成立するか、境界の直下/直上で決定的にテストする。

# 環境構築（自己完結。既に ~/pgav が存在するならビルドは省略してよいが、必ず git log で HEAD を記録すること）
sudo apt-get update && sudo apt-get install -y build-essential bison flex libreadline-dev zlib1g-dev libicu-dev pkg-config gdb
git clone https://git.postgresql.org/git/postgresql.git ~/pgsrc && cd ~/pgsrc && git checkout master
./configure --prefix=$HOME/pgav --enable-debug --enable-cassert CFLAGS="-O0 -g3" && make -j"$(nproc)" && make install
export PATH=$HOME/pgav/bin:$PATH
ulimit -c unlimited
initdb -D ~/pgav-data2 --no-locale -E UTF8
cat >> ~/pgav-data2/postgresql.conf <<'EOF'
autovacuum_naptime = 1s
log_autovacuum_min_duration = 0
logging_collector = on
log_directory = 'log'
autovacuum_vacuum_cost_delay = 0
EOF
pg_ctl -D ~/pgav-data2 -l ~/p2-start.log start

共通の待機関数（シェルに定義して使う）:
wait_av () {  # $1=relname $2=カラム(last_autovacuum|last_autoanalyze) $3=最大秒
  for i in $(seq 1 "$3"); do
    r=$(psql -d postgres -Atc "SELECT $2 IS NOT NULL FROM pg_stat_user_tables WHERE relname='$1'")
    [ "$r" = "t" ] && echo "FIRED after ${i}s" && return 0
    sleep 1
  done
  echo "NOT-FIRED after $3 s"; return 1
}

# テストケース（各ケースの前に統計をリセット: psql -c "SELECT pg_stat_reset();" は使わず、テーブルを都度 DROP/CREATE する）

## T1: dead tuple 閾値の直上（発火すべき）
psql -d postgres -c "CREATE TABLE t1(a int); ALTER TABLE t1 SET (autovacuum_analyze_enabled=off);
INSERT INTO t1 SELECT generate_series(1,1000); ANALYZE t1; DELETE FROM t1 WHERE a <= 300;"
# 閾値 = 50 + 0.2*1000 = 250 < 300 dead → 発火すべき
wait_av t1 last_autovacuum 120   # 判定: NOT-FIRED なら異常

## T2: 閾値の直下（発火してはならない）
psql -d postgres -c "CREATE TABLE t2(a int); INSERT INTO t2 SELECT generate_series(1,1000); ANALYZE t2;
DELETE FROM t2 WHERE a <= 200;"   # 200 < 250 → 発火しないはず
wait_av t2 last_autovacuum 60    # 判定: FIRED なら異常（過剰発火）。NOT-FIRED が正常

## T3: insert-only テーブル（insert threshold で発火すべき）
psql -d postgres -c "CREATE TABLE t3(a int); INSERT INTO t3 SELECT generate_series(1,2000);"
# 挿入 2000 > 1000 + 0.2*0 → 発火すべき（ログには "automatic vacuum" が出る）
wait_av t3 last_autovacuum 120   # 判定: NOT-FIRED なら異常

## T4: autoanalyze（発火すべき）
psql -d postgres -c "CREATE TABLE t4(a int); INSERT INTO t4 SELECT generate_series(1,1000);"
wait_av t4 last_autoanalyze 120  # 判定: NOT-FIRED なら異常

## T5: per-table 無効化（発火してはならない）
psql -d postgres -c "CREATE TABLE t5(a int) WITH (autovacuum_enabled=off);
INSERT INTO t5 SELECT generate_series(1,10000); DELETE FROM t5 WHERE a <= 9000;"
wait_av t5 last_autovacuum 90    # 判定: FIRED なら異常（reloptions 無視のバグ）

## T6: per-table 閾値上書き
psql -d postgres -c "CREATE TABLE t6(a int) WITH (autovacuum_vacuum_threshold=10, autovacuum_vacuum_scale_factor=0);
INSERT INTO t6 SELECT generate_series(1,100); DELETE FROM t6 WHERE a <= 20;"
wait_av t6 last_autovacuum 120   # 判定: NOT-FIRED なら異常

## T7: TOAST テーブル
psql -d postgres -c "CREATE TABLE t7(a int, b text);
INSERT INTO t7 SELECT g, repeat(md5(g::text), 1000) FROM generate_series(1,2000) g;
DELETE FROM t7 WHERE a <= 1500;"
sleep 90
psql -d postgres -c "SELECT c.relname, s.last_autovacuum FROM pg_class c
JOIN pg_stat_all_tables s ON s.relid=c.oid WHERE c.relname LIKE 'pg_toast%' AND
c.oid = (SELECT reltoastrelid FROM pg_class WHERE relname='t7');"
# 判定: 本体 t7 が vacuum されたのに TOAST 側の last_autovacuum が NULL のままなら要調査
#（TOAST は独立に閾値判定されるため即異常とは限らない。dead tuple 数を併記して判断）

## T8: 一時テーブル（発火してはならない）
psql -d postgres -c "CREATE TEMP TABLE t8(a int); INSERT INTO t8 SELECT generate_series(1,10000);
DELETE FROM t8 WHERE a <= 9000; SELECT pg_sleep(60);
SELECT last_autovacuum FROM pg_stat_all_tables WHERE relname='t8';"
# 判定: NULL 以外なら異常（temp テーブルは autovacuum 対象外が仕様）

# 異常時の深掘り手順（推測で終わらせないこと）
1. まず統計が正しいか切り分ける:
   psql -c "SELECT relname, n_live_tup, n_dead_tup, n_ins_since_vacuum, n_mod_since_analyze FROM pg_stat_user_tables WHERE relname='<対象>';"
   統計値自体が仕様とずれている → pgstat 側の問題。値の推移を 5 秒間隔で 60 秒記録する。
2. 統計は正しいのに発火しない → launcher/worker 判定の問題。
   ~/pgav-data2/postgresql.conf に log_min_messages = debug3 を追記して pg_ctl reload し、
   ログの autovacuum 関連 DEBUG 行（テーブル選択の判定過程）を採取。
   さらに gdb -p <launcher pid> -batch -ex bt で位置を確認。
3. ここまでの実行証拠が揃ってから、初めて該当ソース
   (src/backend/postmaster/autovacuum.c の relation_needs_vacanalyze 付近) を参照して整合を確認する。
4. ログに TRAP:/PANIC があれば即座にコアダンプを gdb で bt full し、最優先で報告。

# 成果物
- T1〜T8 の結果表（FIRED/NOT-FIRED、所要秒、n_dead_tup 等の観測値、対応するログ行）
- 異常があったケースの最小再現 repro.sh（initdb から異常観測までのコマンド列のみ）
- サーバログ全体の TRAP/PANIC/ERROR grep 結果
```

### 期待される出力・異常判定基準・引き継ぎ事項

- 期待: T1/T3/T4/T6 が FIRED、T2/T5/T8 が NOT-FIRED、T7 は dead tuple 数と整合。
- 異常判定: 各ケースに明記。特に「統計は増えているのに発火しない」と「発火してはならないのに発火」を区別して報告させる。
- 引き継ぎ: 結果表と repro.sh。発火系に異常があれば P6（深掘り）へ。正常なら P3 へ進む。

---

## プロンプト P3: worker スケジューリング・複数DB・オンライン設定変更の実測

**検証・発見する対象**: launcher の DB 選択と worker 分配、`autovacuum_max_workers` / PG18 新機能 `autovacuum_worker_slots`（reload での worker 数オンライン変更）、コストバランシング、SIGHUP 反映。新しめのコードパスであり回帰リスクが相対的に高い。

### Opus への指示本文

```
あなたは PostgreSQL master ブランチの autovacuum の worker スケジューリングを、実際にビルド・実行して検証する。
静的コードリーディングのみでの結論は禁止。pg_stat_activity・サーバログ・時系列観測を証拠とすること。

# 背景
- launcher は autovacuum_naptime ごとに対象 DB を選び worker を起動する。同時 worker 数の上限は
  autovacuum_max_workers（デフォルト3）。master(PG18以降)では autovacuum_worker_slots(デフォルト16) の
  範囲内で autovacuum_max_workers を再起動なし（reload）で増減できる。これは比較的新しい機能で回帰リスクがある。
- 複数 worker が同時稼働するとコスト制御(autovacuum_vacuum_cost_delay/limit)は worker 間で再バランスされる。

# 環境構築（自己完結）
sudo apt-get update && sudo apt-get install -y build-essential bison flex libreadline-dev zlib1g-dev libicu-dev pkg-config gdb
git clone https://git.postgresql.org/git/postgresql.git ~/pgsrc && cd ~/pgsrc && git checkout master
./configure --prefix=$HOME/pgav --enable-debug --enable-cassert CFLAGS="-O0 -g3" && make -j"$(nproc)" && make install
export PATH=$HOME/pgav/bin:$PATH
ulimit -c unlimited
initdb -D ~/pgav-data3 --no-locale -E UTF8
cat >> ~/pgav-data3/postgresql.conf <<'EOF'
autovacuum_naptime = 1s
log_autovacuum_min_duration = 0
logging_collector = on
log_directory = 'log'
autovacuum_max_workers = 3
autovacuum_worker_slots = 8
autovacuum_vacuum_cost_delay = 2ms
autovacuum_vacuum_cost_limit = 200
EOF
pg_ctl -D ~/pgav-data3 -l ~/p3-start.log start

# 監視ヘルパ（別シェルでバックグラウンド実行し、全テスト中の worker 数を1秒ごと記録）
( while true; do
    psql -d postgres -Atc "SELECT now()::time(0), count(*) FROM pg_stat_activity WHERE backend_type='autovacuum worker'" 2>/dev/null
    sleep 1
  done ) > ~/worker-count.log &
MON=$!

## S1: 複数 DB への分配
for d in db1 db2 db3 db4 db5; do createdb $d; done
for d in db1 db2 db3 db4 db5; do
  psql -d $d -c "CREATE TABLE big(a int, b text);
  INSERT INTO big SELECT g, md5(g::text) FROM generate_series(1,2000000) g;
  DELETE FROM big WHERE a % 2 = 0;" &
done
wait
sleep 5
# 300秒以内に 5 DB 全ての big が vacuum されるか監視:
for i in $(seq 1 300); do
  n=$(for d in db1 db2 db3 db4 db5; do psql -d $d -Atc "SELECT last_autovacuum IS NOT NULL FROM pg_stat_user_tables WHERE relname='big'"; done | grep -c t)
  echo "$i sec: $n/5 done"; [ "$n" = 5 ] && break; sleep 1
done
判定:
- 300秒経っても 5/5 に達しない DB があれば飢餓の疑い → その DB について pg_stat_progress_vacuum を確認し、
  進行中なら正常遅延、リストに現れないまま放置なら異常。
- ~/worker-count.log の最大値が autovacuum_max_workers(3) を超えていれば重大異常（上限突破）。

## S2: autovacuum_max_workers のオンライン増加（PG18 新機能）
S1 と同様の負荷を再投入した直後に:
psql -d postgres -c "ALTER SYSTEM SET autovacuum_max_workers = 8; SELECT pg_reload_conf();"
sleep 30
判定: ~/worker-count.log で reload 後に worker 数が 3 を超えて増えることを確認。増えなければ異常。
次に slots を超える値を設定:
psql -d postgres -c "ALTER SYSTEM SET autovacuum_max_workers = 20; SELECT pg_reload_conf();"
grep -i "worker_slots\|autovacuum_max_workers" ~/pgav-data3/log/*.log | tail -5
判定: 「slots(8) までに制限される」旨の WARNING/LOG が出て、worker 数が 8 を超えないこと。
8 を超えた、またはサーバがクラッシュ/PANIC したら重大異常。

## S3: reload での縮小
psql -d postgres -c "ALTER SYSTEM SET autovacuum_max_workers = 1; SELECT pg_reload_conf();"
sleep 60
判定: 既存 worker は完走してよいが、新規起動は 1 に抑えられること。worker-count.log で
reload の 60 秒後以降も 2 以上が継続していれば異常。

## S4: autovacuum のオンライン無効化/再有効化
psql -d postgres -c "ALTER SYSTEM SET autovacuum = off; SELECT pg_reload_conf();"
sleep 10
psql -d postgres -Atc "SELECT count(*) FROM pg_stat_activity WHERE backend_type='autovacuum launcher';"
判定: launcher が消えること（0）。残っていれば reload 不反映の異常。
psql -d postgres -c "ALTER SYSTEM RESET ALL; SELECT pg_reload_conf();"
sleep 10
判定: launcher が復活すること（1）。復活しなければ異常。

## S5: コストバランシングの体感測定
autovacuum_vacuum_cost_delay=10ms, cost_limit=200 に reload した上で、
2 つの DB に 500 万行・50% delete のテーブルを同時に作り、両方の vacuum が
pg_stat_progress_vacuum に載っている間の heap_blks_vacuumed の増分/秒を 10 秒間隔で記録。
判定: 片方の worker の進捗が完全に 0 のまま 120 秒続く（バランシングでなく停止）なら異常 →
その worker の pid に strace -p <pid> -e trace=select,epoll_wait,nanosleep -f を 10 秒あて、
延々と sleep しているのか、何かをビジーループしているのかを確認。gdb -p <pid> -batch -ex bt も取得。

# 終了処理
kill $MON
grep -cE "TRAP:|PANIC|was terminated by signal" ~/pgav-data3/log/*.log
0 以外なら該当行前後 20 行とコアダンプの bt full を報告。

# 深掘りの一般則
- worker 数の上限突破・launcher 消失などが出たら、まず同じ手順をもう一度実行して再現性を確認する。
- 再現したら、その時点の pg_stat_activity 全行、ログの直近 200 行、gdb での launcher の bt を採取。
- ソース参照（src/backend/postmaster/autovacuum.c の launcher ループ、
  autovacuum_worker_slots 関連コード）は、これらの実行証拠と突き合わせる形でのみ行う。

# 成果物
- worker-count.log（時系列）と各シナリオの判定結果
- S2/S3（オンライン変更）の前後の worker 数推移グラフ的要約
- 異常時: initdb からの最小再現 repro.sh、strace/gdb 出力
```

### 期待される出力・異常判定基準・引き継ぎ事項

- 期待: worker 数が常に設定上限以下、5 DB とも 300 秒以内に処理、reload で増減・無効化・再有効化が反映。
- 異常判定: 上限突破 / launcher 消失・不復活 / 特定 DB の永続飢餓 / 進捗ゼロ worker。
- 引き継ぎ: worker-count.log と repro.sh。オンライン変更（S2/S3）で異常が出た場合は「PG18 の worker_slots 機構の回帰」の可能性が高いことを P6 に申し送る。

---

## プロンプト P4: XID 周回対策（anti-wraparound・failsafe・凍結）の実発火検証

**検証・発見する対象**: XID を実際に大量消費して anti-wraparound vacuum と failsafe を発火させ、datfrozenxid が前進するか、`autovacuum_enabled=off` でも wraparound vacuum が走るか。クラスタ停止に直結する最重要領域。

### Opus への指示本文

```
あなたは PostgreSQL master ブランチの autovacuum の XID 周回対策を、実際に XID を消費して検証する。
静的コードリーディングのみでの結論は禁止。master 同梱のテストモジュール xid_wraparound を使い、
実発火とカタログの前進を証拠として確認すること。

# 背景
- age(datfrozenxid) が autovacuum_freeze_max_age を超えると、autovacuum=off や
  reloptions autovacuum_enabled=off でも anti-wraparound vacuum が強制起動される（仕様）。
- vacuum_failsafe_age を超えると failsafe が発動し、インデックス vacuum 等を省略して凍結を最優先する（仕様）。
- master には src/test/modules/xid_wraparound があり、SQL 関数 consume_xids(bigint) で XID を高速消費できる。

# 環境構築（自己完結）
sudo apt-get update && sudo apt-get install -y build-essential bison flex libreadline-dev zlib1g-dev libicu-dev pkg-config gdb
git clone https://git.postgresql.org/git/postgresql.git ~/pgsrc && cd ~/pgsrc && git checkout master
./configure --prefix=$HOME/pgav --enable-debug --enable-cassert CFLAGS="-O0 -g3" && make -j"$(nproc)" && make install
make -C src/test/modules/xid_wraparound install
make -C contrib/pg_visibility install
export PATH=$HOME/pgav/bin:$PATH
ulimit -c unlimited
initdb -D ~/pgav-data4 --no-locale -E UTF8
cat >> ~/pgav-data4/postgresql.conf <<'EOF'
autovacuum_naptime = 1s
log_autovacuum_min_duration = 0
logging_collector = on
log_directory = 'log'
autovacuum_freeze_max_age = 200000      # 最小近くまで下げて発火を早める（min 100000）
vacuum_freeze_min_age = 0
vacuum_freeze_table_age = 0
autovacuum_vacuum_cost_delay = 0
EOF
pg_ctl -D ~/pgav-data4 -l ~/p4-start.log start
psql -d postgres -c "CREATE EXTENSION xid_wraparound;"

## W1: anti-wraparound vacuum の強制発火（autovacuum_enabled=off のテーブルでも走ること）
psql -d postgres <<'EOF'
CREATE TABLE frozen_target(a int) WITH (autovacuum_enabled = off);
INSERT INTO frozen_target SELECT generate_series(1,100000);
SELECT datname, age(datfrozenxid) FROM pg_database ORDER BY 2 DESC;
EOF
# XID を 30万消費して freeze_max_age(20万) を確実に超えさせる:
psql -d postgres -c "SELECT consume_xids(300000);"
psql -d postgres -c "SELECT datname, age(datfrozenxid) FROM pg_database ORDER BY 2 DESC;"
# 300 秒監視: age が下がる（datfrozenxid が前進する）こと
for i in $(seq 1 300); do
  a=$(psql -d postgres -Atc "SELECT max(age(datfrozenxid)) FROM pg_database")
  echo "$i sec: max age=$a"; [ "$a" -lt 200000 ] && echo ADVANCED && break; sleep 1
done
grep -E "wraparound|aggressive" ~/pgav-data4/log/*.log | head -20

判定:
- ログに "to prevent wraparound" を含む automatic vacuum 行が出て、かつ 300 秒以内に
  max(age) が autovacuum_freeze_max_age 未満へ低下すれば正常。
- vacuum ログは出るのに age が下がらない → datfrozenxid 前進の異常（重大）。深掘り:
  psql -c "SELECT relname, age(relfrozenxid) FROM pg_class WHERE relkind in ('r','t','m') ORDER BY 2 DESC LIMIT 10;"
  で、どのリレーションが足を引っ張っているか特定し、そのテーブルに対する vacuum ログの有無を突き合わせる。
- そもそも wraparound vacuum が起動しない → 最重大。gdb -p <launcher pid> -batch -ex bt を取得し、
  log_min_messages=debug2 で reload して launcher の DB 選択ログを観測する。
- frozen_target（autovacuum_enabled=off）に対しても "to prevent wraparound" vacuum が
  走ることを個別に確認。走らなければ異常。

## W2: failsafe の発火
psql -d postgres -c "ALTER SYSTEM SET vacuum_failsafe_age = 300000; SELECT pg_reload_conf();"
psql -d postgres <<'EOF'
CREATE TABLE fs(a int, b text);
INSERT INTO fs SELECT g, md5(g::text) FROM generate_series(1,2000000) g;
CREATE INDEX ON fs(b);
DELETE FROM fs WHERE a % 2 = 0;
EOF
psql -d postgres -c "SELECT consume_xids(400000);"
sleep 120
grep -i "failsafe\|bypassing" ~/pgav-data4/log/*.log
判定: "bypassing nonessential maintenance of table" 等の failsafe ログが出れば正常発火。
consume 後 300 秒待っても failsafe ログが無く、かつ age が vacuum_failsafe_age を超えたままなら異常。
（age の低下が先に完了して failsafe 条件を外れた場合はその旨を記録し、
 vacuum_failsafe_age をさらに下げて再試行する）

## W3: anti-wraparound vacuum はロック競合でも自己キャンセルしないこと
通常の autovacuum は競合ロック要求で自己キャンセルするが、wraparound 用は キャンセルされないのが仕様。
1. 大きめのテーブル aw(500万行) を作り、consume_xids で age を超過させ、
   "to prevent wraparound" vacuum が pg_stat_progress_vacuum に載ったことを確認。
2. 別セッションで psql -c "LOCK TABLE aw IN ACCESS EXCLUSIVE MODE;" を timeout 30 付きで実行。
判定: ログに "canceling autovacuum task"（aw に対するもの）が出たら異常（wraparound vacuum が
キャンセルされた）。LOCK 側が待たされ、vacuum が完走するのが正常。

## W4: 周回警告の健全性
consume_xids をさらに続けて age(datfrozenxid) を 10M 程度まで一時的に上げた場合でも、
autovacuum が追いついて最終的に age が下がりきることを確認（最大 15 分監視）。
判定: age が単調増加のまま/固着したら重大異常。その場合は
pg_stat_progress_vacuum、gdb bt、pg_visibility の pg_visibility_map_summary('対象') を採取。

# 全体の常時監視
grep -cE "TRAP:|PANIC|was terminated by signal" ~/pgav-data4/log/*.log
0 以外なら該当行と bt full を最優先で報告。cassert ビルドなので凍結まわりの assert
（visibility map / freeze の整合性チェック）は TRAP として顕在化する。これが本調査の主要な狙いの一つ。

# 成果物
- W1〜W4 の判定結果、age(datfrozenxid) の時系列、該当ログ行
- 異常時: consume_xids を含む最小再現 repro.sh、gdb/pg_visibility の出力
```

### 期待される出力・異常判定基準・引き継ぎ事項

- 期待: anti-wraparound vacuum が `autovacuum_enabled=off` でも走り age が低下、failsafe ログが出る、wraparound vacuum はロック競合でキャンセルされない。
- 異常判定: age 固着・wraparound vacuum 不起動・failsafe 不発火・wraparound vacuum のキャンセル・TRAP。
- 引き継ぎ: age 時系列と repro.sh。TRAP が出た場合は「凍結/VM 整合性 assert」の可能性が高い旨と bt full を P6 へ。

---

## プロンプト P5: ストレス・境界条件（極小メモリ・複数インデックスパス・キャンセル・クラッシュ横断・リーク監視）

**検証・発見する対象**: TidStore（PG17+ の dead TID 格納）のメモリ境界動作、複数インデックス vacuum パス、ロック競合による自己キャンセル、クラッシュリカバリ後の再開、長時間 churn での worker メモリリーク。

### Opus への指示本文

```
あなたは PostgreSQL master ブランチの autovacuum を境界条件・ストレス下で実行し、異常を発見する。
静的コードリーディングのみでの結論は禁止。ログ・pg_stat_progress_vacuum・/proc の観測を証拠とすること。

# 背景
- vacuum の dead TID 格納は TidStore 実装で、autovacuum_work_mem（または maintenance_work_mem）を
  超えると index vacuum を複数パスに分けて実行する。pg_stat_progress_vacuum.index_vacuum_count で観測できる。
- 通常の autovacuum は、他セッションが競合ロックを要求すると自らキャンセルする
  （ログ: "canceling autovacuum task"）。
- worker はテーブルごとに使い捨てだが launcher は常駐であり、リークがあれば VmRSS の単調増加として現れる。

# 環境構築（自己完結）
sudo apt-get update && sudo apt-get install -y build-essential bison flex libreadline-dev zlib1g-dev libicu-dev pkg-config gdb strace
git clone https://git.postgresql.org/git/postgresql.git ~/pgsrc && cd ~/pgsrc && git checkout master
./configure --prefix=$HOME/pgav --enable-debug --enable-cassert CFLAGS="-O0 -g3" && make -j"$(nproc)" && make install
export PATH=$HOME/pgav/bin:$PATH
ulimit -c unlimited
initdb -D ~/pgav-data5 --no-locale -E UTF8
cat >> ~/pgav-data5/postgresql.conf <<'EOF'
autovacuum_naptime = 1s
log_autovacuum_min_duration = 0
logging_collector = on
log_directory = 'log'
autovacuum_vacuum_cost_delay = 0
autovacuum_work_mem = 1MB
EOF
pg_ctl -D ~/pgav-data5 -l ~/p5-start.log start

## X1: 極小メモリでの複数インデックスパス
psql -d postgres <<'EOF'
CREATE TABLE mp(a int, b text);
INSERT INTO mp SELECT g, md5(g::text) FROM generate_series(1,5000000) g;
CREATE INDEX mp_a ON mp(a);
CREATE INDEX mp_b ON mp(b);
DELETE FROM mp WHERE a % 2 = 0;   -- 250万 dead tuples ≫ 1MB の TidStore
EOF
# vacuum 進行中に 5 秒間隔で監視（最大 30 分）:
for i in $(seq 1 360); do
  psql -d postgres -Atc "SELECT phase, heap_blks_scanned, heap_blks_vacuumed, index_vacuum_count, dead_tuple_bytes, max_dead_tuple_bytes FROM pg_stat_progress_vacuum" | sed "s/^/${i}: /"
  sleep 5
done > ~/x1-progress.log &
# 完了待ち:
for i in $(seq 1 1800); do
  r=$(psql -d postgres -Atc "SELECT last_autovacuum IS NOT NULL FROM pg_stat_user_tables WHERE relname='mp'"); [ "$r" = t ] && break; sleep 1
done
grep "automatic vacuum of table.*mp" ~/pgav-data5/log/*.log
判定:
- index_vacuum_count が 2 以上になること（1MB で 250 万 TID は保持不能のため）。1 のまま完了したら
  メモリ制限が効いていない異常 → dead_tuple_bytes の最大値と autovacuum_work_mem を突き合わせて報告。
- vacuum が 30 分経っても完了しない場合はハング疑い → gdb -p <worker pid> -batch -ex 'bt full'、
  strace -p <pid> を 10 秒、pg_stat_progress_vacuum の停滞位置を報告。
- ログの "index scans: N" と index_vacuum_count の整合も確認。

## X2: ロック競合による自己キャンセル（通常 vacuum はキャンセルされるのが仕様）
psql -d postgres -c "CREATE TABLE cx(a int, b text); INSERT INTO cx SELECT g, md5(g::text) FROM generate_series(1,3000000) g; DELETE FROM cx WHERE a % 2 = 0;"
# cx の vacuum が pg_stat_progress_vacuum に現れるのを待ってから:
timeout 60 psql -d postgres -c "LOCK TABLE cx IN ACCESS EXCLUSIVE MODE; SELECT 1;"
grep "canceling autovacuum task" ~/pgav-data5/log/*.log
判定: LOCK が速やかに（数秒で）取得でき、ログに canceling が出れば正常。
LOCK 側が 60 秒 timeout したら「キャンセルすべき vacuum がキャンセルされない」異常。
その場合 worker の gdb bt を取得（どこでシグナルを無視しているか）。

## X3: クラッシュリカバリ横断
cx の vacuum 再開中（pg_stat_progress_vacuum に載っている間）に worker を SIGKILL:
kill -9 <worker pid>
判定: サーバ全体がクラッシュリカバリに入る（仕様）。pg_ctl status とログで
(1) リカバリが正常完了すること、(2) 再起動後に cx の vacuum が再度スケジュールされ完走すること、
(3) リカバリ後のログに TRAP/PANIC が無いこと。いずれかを満たさなければ異常。
さらに immediate shutdown 横断も実施:
pg_ctl -D ~/pgav-data5 -m immediate stop && pg_ctl -D ~/pgav-data5 -l ~/p5-start2.log start
判定基準は同上。

## X4: 30 分 churn とリーク監視
pgbench -i -s 50 postgres
LPID=$(psql -d postgres -Atc "SELECT pid FROM pg_stat_activity WHERE backend_type='autovacuum launcher'")
( while true; do
    echo "$(date +%s) launcher $(grep VmRSS /proc/$LPID/status 2>/dev/null)"
    for w in $(psql -d postgres -Atc "SELECT pid FROM pg_stat_activity WHERE backend_type='autovacuum worker'"); do
      echo "$(date +%s) worker$w $(grep VmRSS /proc/$w/status 2>/dev/null)"
    done
    sleep 10
  done ) > ~/rss.log &
RSSMON=$!
pgbench -T 1800 -c 8 -j 4 postgres
kill $RSSMON
判定:
- pgbench の終了コード非0、または期間中のサーバログに ERROR/TRAP/PANIC があれば異常。
- ~/rss.log で launcher の VmRSS が単調増加（開始比 +50% 以上かつ増加が止まらない）ならリーク疑い →
  さらに 30 分延長して傾向を確定し、gdb で MemoryContextStats を取る:
  gdb -p $LPID -batch -ex 'call MemoryContextStats(TopMemoryContext)' し、サーバログ(stderr)に出た
  コンテキスト統計を報告に貼る。
- 期間中に一度も autovacuum が走らないのも異常（pg_stat_user_tables の autovacuum_count 合計で確認）。

# 成果物
- X1 の progress ログと index_vacuum_count、X2 のキャンセル所要時間、X3 のリカバリ結果、
  X4 の RSS 時系列と autovacuum_count 集計
- 異常時: initdb からの最小再現 repro.sh、gdb/strace/MemoryContextStats の出力
```

### 期待される出力・異常判定基準・引き継ぎ事項

- 期待: 複数インデックスパス発生（`index_vacuum_count >= 2`）、ロック競合で数秒キャンセル、クラッシュ横断後に再スケジュール、RSS 安定。
- 異常判定: メモリ上限無視・ハング・キャンセル不能・リカバリ後の不再開・RSS 単調増加・TRAP。
- 引き継ぎ: progress/RSS ログと repro.sh。ハング/リークは P6 で `MemoryContextStats`・perf による深掘りに接続。

---

## プロンプト P6: 異常の深掘りと最小再現の確立（共通テンプレート）

**検証・発見する対象**: P1〜P5（または任意の実行）で観測された異常 1 件を、根本原因まで特定し、第三者が数分で再現できる最小手順に落とす。

### Opus への指示本文

```
あなたは PostgreSQL master ブランチの autovacuum で観測された異常 1 件の根本原因を、実行ベースで特定する。
推測で結論せず、全ての主張をデバッガ出力・ログ・再実行結果のいずれかで裏付けること。
コードリーディングは「実行証拠と突き合わせる」用途に限る。

# 入力（このプロンプトを使う際に以下を埋めて渡すこと。無い場合は自分の直前の調査結果から転記する）
- 異常の内容: <例: T3 insert-only テーブルが 120 秒で vacuum されない / ログに TRAP: FailedAssertion ...>
- 観測時のコマンド列・ログ抜粋・環境（HEAD コミットID、configure オプション）

# 環境（自己完結。異常観測時と同一条件で再構築する）
sudo apt-get update && sudo apt-get install -y build-essential bison flex libreadline-dev zlib1g-dev libicu-dev pkg-config gdb strace linux-tools-common linux-tools-generic
git clone https://git.postgresql.org/git/postgresql.git ~/pgsrc && cd ~/pgsrc && git checkout <観測時のコミットID>
./configure --prefix=$HOME/pgav --enable-debug --enable-cassert CFLAGS="-O0 -g3" && make -j"$(nproc)" && make install
export PATH=$HOME/pgav/bin:$PATH
ulimit -c unlimited

# 手順

## 1. 再現性の確定（最低 3 回)
観測時のコマンド列をそのまま 3 回実行し、再現率を記録する（3/3, 1/3 など）。
毎回 initdb からやり直すこと。再現しない場合はタイミング依存を疑い、
autovacuum_naptime・負荷並列度・sleep 位置を変えて 10 回まで試行し、条件を記録する。

## 2. 異常タイプ別の証拠採取
(a) クラッシュ/TRAP の場合:
    - コアダンプ位置を確認: cat /proc/sys/kernel/core_pattern（apport 等なら
      echo core > /proc/sys/kernel/core_pattern に変更するか coredumpctl を使う）
    - gdb ~/pgav/bin/postgres <core> -batch -ex 'bt full' -ex 'info registers' -ex 'p $_siginfo' を全文保存
    - TRAP の場合は assert の条件式・ファイル・行番号がログに出るので、その行の前後のソースを読み、
      assert が成立しなかった変数を gdb の frame で実際に印字する
(b) ハング/無応答の場合:
    - gdb -p <pid> -batch -ex 'bt full' を 30 秒間隔で 3 回取り、スタックが動いているか固着かを判定
    - strace -p <pid> -f -T を 30 秒: システムコールで待っているのか CPU ループか
    - CPU ループなら perf record -p <pid> -g -- sleep 30 && perf report --stdio | head -40
    - ロック待ちなら psql で pg_locks と pg_stat_activity.wait_event を突き合わせる
(c) 「発火しない/しすぎる」型（サイレント異常）の場合:
    - pg_stat_user_tables の関連列（n_dead_tup, n_ins_since_vacuum, n_mod_since_analyze,
      last_autovacuum）を 5 秒間隔で記録し、期待式とのずれが「統計側」か「判定側」かを切り分ける
    - log_min_messages=debug3 で launcher/worker の判定ログを採取
    - 必要なら gdb で relation_needs_vacanalyze にブレークポイントを張り、
      判定に使われた実値（reltuples, dead tuples, 閾値）を印字して式のどちら側が壊れているか確定する
(d) リソース異常（リーク・過大メモリ）の場合:
    - gdb -p <pid> -batch -ex 'call MemoryContextStats(TopMemoryContext)' をサーバログと突き合わせ、
      どのメモリコンテキストが成長しているか特定する

## 3. 原因コミットの特定（再現が決定的な場合のみ）
再現スクリプトを exit 0/1 を返す形に整えた上で:
cd ~/pgsrc
git bisect start master <直近の安定リリースタグ 例: REL_18_0>
git bisect run bash -c 'make -j$(nproc) >/dev/null 2>&1 && make install >/dev/null 2>&1 && ~/repro.sh'
（ビルド失敗コミットは git bisect skip）。特定できたら該当コミットのログとdiff要約を報告。
1 回の再現に 10 分以上かかる場合は bisect は行わず、その旨を報告して git log -- src/backend/postmaster/autovacuum.c
の直近変更から容疑コミットを列挙するに留める（これは推測であることを明記する）。

## 4. 成果物（必須）
- repro.sh: initdb から異常観測までの最小コマンド列。実行時間を可能な限り短縮し、
  異常検出時 exit 1 / 正常時 exit 0 とする。冒頭コメントに HEAD コミットID・configure オプション・
  再現率を記す。
- 証拠一式: bt full / strace / perf / debug ログ / カタログ観測の時系列
- 結論: 「観測事実 → 切り分け結果 → 原因（コード位置と機序）」の順で、各段が証拠に紐づく形で記述。
  原因を特定しきれない場合は、確定した事実と除外できた仮説、残る仮説を明確に分けて報告する。
  pgsql-hackers へ報告できる品質（環境・再現手順・観測結果・分析）でまとめること。
```

### 期待される出力・異常判定基準・引き継ぎ事項

- 期待: 再現率つき repro.sh、証拠に裏付けられた原因分析（可能なら bisect による原因コミット）。
- 異常判定: このプロンプト自体は深掘り用のため対象異常は入力で与える。「証拠なしの結論」を出したら差し戻す。
- 引き継ぎ: repro.sh と分析レポートが最終成果物。pgsql-hackers への報告草案に直結する形式。

---

## 運用メモ

- 実行順序は P1 → P2 → P3 → P4 → P5 を推奨。ただし各プロンプトは自己完結なので並列実行も可（マシンを分けること。同一マシンではデータディレクトリ名とポートが衝突しないよう `PGPORT` を変える）。
- どのプロンプトでも `TRAP:` / `PANIC` / コアダンプが出たら、そのプロンプトの残りより P6 での深掘りを優先する。cassert ビルドの TRAP は master の実バグである可能性が高い。
- 「異常なし」も成果である。その場合は各判定基準に対する観測値（発火までの秒数、worker 数の最大値、age の低下時間など）を定量で残すこと。次回 master が進んだ時の比較基準になる。
