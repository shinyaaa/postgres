# RLS バグ調査プロンプト設計書（Opus 実行用）

- 対象: PostgreSQL fork `shinyaaa/postgres` の `master` ブランチ（基準コミット: `dbaa4dc3c8dd77a0e1c977024d4ae150e00456b3`）
- 環境: Linux
- 前提: 既知の症状なし。「何が壊れているかの発見」自体が調査の目的。
- 方針: 静的コードリーディングのみでの結論は禁止。必ずビルド→実行→観測を軸にし、ソース参照は実行で得た異常の裏付けにのみ使う。

---

## ステップ1: 調査戦略の設計（問題領域の洗い出し）

### このツリーの特徴（設計の根拠）

事前の軽い偵察で判明した事実:

1. upstream PostgreSQL master 相当のコードベースに、**upstream に存在しない GRAPH_TABLE（プロパティグラフ）機能**が追加されている（`src/backend/rewrite/rewriteGraphTable.c`、回帰テスト `graph_table_rls`）。
2. GRAPH_TABLE は「security_invoker ビューと同様に扱う」設計コメントがあり（`rewriteGraphTable.c:508` 付近）、RLS ポリシー適用の経路が upstream と異なる。
3. RLS の中核は upstream 同様 `src/backend/rewrite/rowsecurity.c`（ポリシー式の取得と Query への注入）、`src/backend/commands/policy.c`（CREATE/ALTER POLICY）、`src/backend/executor/execMain.c`（WITH CHECK 検査）、plancache（ロール変更・`row_security` GUC 変更時の再プラン）に分散する。

fork 固有コード（GRAPH_TABLE×RLS）が最も疑わしいが、症状未知である以上、RLS 全域を「実行して観測する」網羅が必要。

### 起こりうる問題領域マップ

| 層 | 起こりうる問題 | 観測手段 |
|---|---|---|
| ビルド | コンパイルエラー、RLS 関連ファイルの警告、cassert ビルドでのみ発現する問題 | build ログ、`make check` |
| 起動/基本動作 | initdb 失敗、rowsecurity/graph_table_rls 回帰テストの diff、assert 失敗、コアダンプ | regression.diffs、サーバログ、core |
| 機能実行(RLS 単体) | 可視行の過不足（見えるべき行が見えない/隠すべき行が見える）、permissive/restrictive 合成の誤り、WITH CHECK 素通り | psql で期待行集合と実測を突合 |
| 機能実行(相互作用) | ビュー・パーティション・COPY・MERGE・ON CONFLICT・準備文+SET ROLE（プランキャッシュ無効化漏れ）での RLS 迂回 | 各構文をロール切替しつつ実行 |
| fork 固有(GRAPH_TABLE) | GRAPH_TABLE 経由だと RLS が掛からない/掛かりすぎる、直接 SELECT との可視集合不一致 | 同一データを直接 SELECT と GRAPH_TABLE の両方で読む差分試験 |
| 情報漏えい | leaky 関数がポリシー述語より先に評価され隠し行の内容を観測できる、エラーメッセージ経由の存在漏えい | `f_leak` 型 NOTICE プローブ、EXPLAIN、エラー文言 |
| ストレス/境界 | 多数ポリシー・深い式・再帰ポリシー・並行 ALTER POLICY でのクラッシュ/メモリ異常 | pgbench、isolation tester、メモリ監視 |
| 深掘り | 上記で出た異常の根本原因特定 | gdb、strace、デバッグビルド、コアダンプ解析 |

### 探索フロー

```
P1: ビルド+回帰テスト（ベースライン確立、最初の異常検出網）
 → P2: RLS 基本動作の系統的実行検証（可視行集合の突合）
 → P3: RLS×他機能の相互作用（迂回経路の探索）
 → P4: GRAPH_TABLE×RLS（fork 固有・最重点）
 → P5: 情報漏えい観点の動的検査
 → P6: ストレス/並行性 + 発見した異常の根本原因特定
```

P1 で環境を確立し、P2〜P5 は互いに独立に実行可能（各プロンプトが自前でビルド手順を持つ）。P6 は総仕上げ。

---

## ステップ2: Opus 実行用プロンプト（全6本）

---

## プロンプト1: ビルド・環境確立と回帰テストによるベースライン異常検出

**検証・発見する対象**: ソースが正しくビルドできるか、RLS 関連回帰テスト（rowsecurity / graph_table_rls）が通るか。最も検出コストの低い異常（コンパイル警告・regression diff・assert 失敗・クラッシュ）の刈り取り。

### Opus への指示本文

```
あなたは PostgreSQL の RLS（Row-Level Security）のバグを実際にビルド・実行して調査するエンジニアです。
対象は fork リポジトリ shinyaaa/postgres の master ブランチ（upstream master 相当 + fork 固有の GRAPH_TABLE 機能を含む）。
症状は未知です。静的なコード読みだけで結論を出すことは禁止。必ず実行して観測した証拠に基づいてください。

## 手順

### 1. 取得
リポジトリが /home/user/postgres に既にあればそれを使う。なければ:
  git clone https://github.com/shinyaaa/postgres.git ~/postgres && cd ~/postgres
  git checkout master
git log -1 --format='%H %s' で基準コミットを記録すること。

### 2. デバッグビルド（assert 有効）
  cd ~/postgres  # または /home/user/postgres
  ./configure --prefix="$HOME/pg-rls/install" \
      --enable-debug --enable-cassert --enable-tap-tests \
      CFLAGS="-O0 -g3 -fno-omit-frame-pointer" 2>&1 | tee ~/pg-rls/configure.log
  make -j"$(nproc)" 2>&1 | tee ~/pg-rls/build.log
  echo "exit=$?"
ビルド後、警告を抽出:
  grep -nE "warning:" ~/pg-rls/build.log | grep -Ei "rowsecurity|policy|rewriteGraphTable|rewriteHandler|execMain|plancache" 

### 3. 回帰テスト（全体 → RLS 関連に注目）
  ulimit -c unlimited
  make check 2>&1 | tee ~/pg-rls/check.log
  echo "exit=$?"
失敗があれば:
  cat src/test/regress/regression.diffs
  grep -E "TRAP|PANIC|FATAL|Assert|Segmentation" src/test/regress/log/postmaster.log
特に rowsecurity と graph_table_rls の結果行（ok / FAILED）を確認・記録する。

### 4. インストールと実クラスタ起動
  make install
  ~/pg-rls/install/bin/initdb -D ~/pg-rls/data
  ~/pg-rls/install/bin/pg_ctl -D ~/pg-rls/data -l ~/pg-rls/server.log start
  ~/pg-rls/install/bin/psql -d postgres -c "SELECT version();"
起動後 server.log に WARNING/ERROR/TRAP が出ていないか確認する。

### 5. RLS 関連テストの単独再実行（並行実行由来のノイズ除去）
  make check EXTRA_REGRESS_OPTS="" TESTS="test_setup rowsecurity" -C src/test/regress || true
  # graph_table_rls は依存 setup があるため、失敗時は parallel_schedule 上の同グループを含めて再実行して切り分ける

## 異常判定基準
- configure/make の非ゼロ終了、または RLS 関連ファイル（rowsecurity.c, policy.c, rewriteGraphTable.c, rewriteHandler.c）への新規警告 → 異常
- make check で rowsecurity / graph_table_rls が FAILED、または regression.diffs に差分 → 異常（差分内容が「可視行の増減」なら重大）
- postmaster.log に TRAP:（assert 失敗）、PANIC、Segmentation fault、core ファイル生成 → 重大異常
- すべて green でも「異常なし」と断定しない。P2 以降の動的検査に進む前提のベースラインである。

## 異常が出た場合の深掘り
- regression.diffs の差分を読み、期待出力と実出力のどちらが「RLS の仕様として正しいか」を、実クラスタ上で最小 SQL を組んで再実行して確認する（expected ファイルが改ざんされている可能性も疑う）。
- assert 失敗/クラッシュ時: core を gdb で解析
    gdb ~/pg-rls/install/bin/postgres <corefile> -batch -ex "bt full" -ex "info registers"
  TRAP 行のファイル名:行番号を控え、該当コードを読むのは「バックトレースの裏付け」としてのみ行う。
- ビルド警告は該当行を確認し、未初期化・符号・shadow 等が実挙動に影響するか、最小 SQL で実証を試みる。

## 成果物（必ず残す）
- ~/pg-rls/REPORT-P1.md に: 基準コミットハッシュ、configure オプション、ビルド結果、make check の合否一覧（rowsecurity / graph_table_rls を明記）、発見した異常の一覧、各異常の最小再現コマンド列（clone から異常再現までコピペで通るもの）
```

### 期待される出力・異常判定基準・引き継ぎ事項
- **期待**: ビルド成功、`make check` 全 pass、クラスタ起動成功。
- **異常判定**: 上記本文の基準どおり。特に `rowsecurity` / `graph_table_rls` の regression diff は「可視行の増減」かどうかで重大度を分ける。
- **引き継ぎ**: 基準コミットハッシュ、ビルド済みツリーの場所（`~/pg-rls/`）、configure オプション、検出済み異常リスト。以降のプロンプトは同一手順で環境を再現できる（各プロンプトに手順を再掲済み）。

---

## プロンプト2: RLS 基本動作の系統的実行検証（可視行集合の突合）

**検証・発見する対象**: ポリシーの USING / WITH CHECK、コマンド種別（SELECT/INSERT/UPDATE/DELETE/ALL）、PERMISSIVE/RESTRICTIVE 合成、ロール指定、`row_security` GUC、BYPASSRLS、FORCE ROW LEVEL SECURITY が仕様どおりに動くか。回帰テストが通っていても網羅されていない組合せで可視行の過不足がないか。

### Opus への指示本文

```
あなたは PostgreSQL fork（shinyaaa/postgres, master）の RLS 基本動作を、実行ベースで系統的に検証するエンジニアです。
症状は未知。静的読解での結論は禁止。すべて実クラスタで SQL を実行し、期待行集合と実測を突合してください。

## 環境準備（未構築の場合のみ。構築済みの ~/pg-rls があれば流用可）
  cd /home/user/postgres 2>/dev/null || { git clone https://github.com/shinyaaa/postgres.git ~/postgres; cd ~/postgres; }
  git checkout master
  ./configure --prefix="$HOME/pg-rls/install" --enable-debug --enable-cassert CFLAGS="-O0 -g3"
  make -j"$(nproc)" && make install
  ~/pg-rls/install/bin/initdb -D ~/pg-rls/data 2>/dev/null || true
  ~/pg-rls/install/bin/pg_ctl -D ~/pg-rls/data -l ~/pg-rls/server.log start
  export PATH="$HOME/pg-rls/install/bin:$PATH"

## 検証の型
各テストケースは必ず「期待される可視行を先に宣言 → 実行 → 突合」の順で行い、結果を表に記録する。
テスト用 SQL は ~/pg-rls/p2/ 以下にファイルとして保存し、psql -f で再実行可能にしておく。

## テストマトリクス（すべて実行する）
createdb rlstest として、以下を psql -d rlstest で実施:

1. 基本形:
   CREATE ROLE r_alice LOGIN; CREATE ROLE r_bob LOGIN; CREATE ROLE r_admin LOGIN BYPASSRLS;
   CREATE TABLE t(id int, owner text, val text);
   INSERT INTO t VALUES (1,'r_alice','a1'),(2,'r_bob','b1'),(3,'r_alice','a2');
   GRANT ALL ON t TO PUBLIC;
   ALTER TABLE t ENABLE ROW LEVEL SECURITY;
   CREATE POLICY p_own ON t USING (owner = current_user);
   SET ROLE r_alice; SELECT * FROM t;   -- 期待: id 1,3 のみ
   SET ROLE r_bob;   SELECT * FROM t;   -- 期待: id 2 のみ
   SET ROLE r_admin; SELECT * FROM t;   -- 期待: 全行（BYPASSRLS）
   RESET ROLE;       SELECT * FROM t;   -- 期待: 全行（所有者は RLS 非適用）
   ALTER TABLE t FORCE ROW LEVEL SECURITY;
   SELECT * FROM t;                     -- 期待: 所有者でもポリシー適用（current_user に一致する行のみ）

2. コマンド別ポリシー: FOR SELECT / INSERT / UPDATE / DELETE をそれぞれ単独で付けたテーブルを用意し、
   全 4 コマンドを各ロールで実行。UPDATE/DELETE が「USING で見えない行に触れない」こと、
   INSERT/UPDATE の WITH CHECK 違反が "new row violates row-level security policy" エラーになることを確認。
   UPDATE ... RETURNING が S