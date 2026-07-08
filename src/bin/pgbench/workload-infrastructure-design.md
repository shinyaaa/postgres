# pgbench ワークロード拡張インフラ設計書

## 1. 背景と目的

pgbench が実行できるのは TPC-B 風ワークロード（`tpcb-like` / `simple-update` /
`select-only`）のみである。TPC-C、TPC-H、TPC-E、TPC-AI といった他のベンチマークを
PostgreSQL 本体に取り込むことは、仕様の複雑さ・監査要件・メンテナンスコストの観点から
コミュニティ的に困難である。

一方で、「任意のワークロードを *記述できる* ようにするための汎用インフラ」であれば、
特定ベンチマークに依存しない機能として本体に入れる余地がある。本設計書は、
ワークロード定義そのものは外部（contrib 外のリポジトリやサードパーティ配布）に置き、
pgbench 本体にはワークロード非依存の実行基盤だけを追加する、という方針での設計を示す。

## 2. 現状分析

### 2.1 既にあるインフラ

| 機能 | 実装 | 備考 |
|---|---|---|
| カスタムスクリプト | `-f FILE[@weight]`, `-b NAME[@weight]` | 重み付きランダム選択（`chooseScript()`） |
| メタコマンド | `\set` `\setshell` `\shell` `\sleep` `\if/\elif/\else/\endif` `\gset` `\aset` `\startpipeline` `\syncpipeline` `\endpipeline` | `process_backslash_command()`（pgbench.c:2876 付近） |
| 式言語 | 整数/浮動小数/真偽/NULL、算術・ビット・比較演算、`random` `random_gaussian` `random_exponential` `random_zipfian` `hash_*` `permute` など | `exprparse.y` の `PGBENCH_FUNCTIONS[]`、値型は `PgBenchValue`（pgbench.h:44） |
| 初期化ステップ | `-I dtgGvpf`（drop/table/generate/vacuum/pkey/fkey） | `runInitSteps()`（pgbench.c:5326）。**pgbench_* テーブル固定** |
| エラーリトライ | `--max-tries`（直列化失敗・デッドロックの再試行） | TPC-C の要件に合致 |
| スロットリング | `-R`（グローバルなポアソン到着）、`--latency-limit` | スクリプト別レートは不可 |
| 統計 | スクリプト別集計（`ParsedScript.stats`）、`-r` コマンド別レイテンシ、`--log` / `--aggregate-interval` | 「特定スクリプトのみのスループット」算出は後処理が必要 |
| 事前定義変数 | `:client_id` `:scale` `:default_seed` `:random_seed` など | 端末→ウェアハウス割当等に利用可能 |

### 2.2 各ワークロードが要求するもの（ギャップ分析）

**TPC-C**
- 任意スキーマ（9 テーブル）の作成と、スケールファクタ（W）に比例した相関データ生成
  → 初期化が pgbench_* 固定（`initCreateTables()` ほか）なので不可能。
- NURand 非一様乱数 → `(random(0,A) | random(x,y)) ...` と既存のビット演算で合成可能だが冗長。
- New-Order の可変行数（5〜15 明細）→ **ループ構文がなく記述不能**（最大の欠落）。
- C_LAST 等のランダム文字列 → **式言語に文字列型がなく生成不能**（SQL 側での生成は可能だが
  パラメータとしてクライアント側で選ぶ用途に使えない）。
- 最低トランザクションミックス保証（デッキ方式）→ 現在は独立ランダム選択のみ。
- tpmC（New-Order のみ計数）→ スクリプト別カウントは出るが第一級のメトリクスではない。
- 1% ロールバック、キーイング/シンクタイム → `\if` + `ROLLBACK`、`\sleep :var` で既に可能。

**TPC-H**
- dbgen 相当の大規模ロード → 初期化の汎用化が必要（生成自体は `generate_series` 等の
  サーバサイド SQL でも表現できるが、それを走らせる枠組みがない）。
- 日付・文字列の置換パラメータ → 文字列型（および日付演算の代替）が必要。
- パワーテスト（22 クエリを規定順に 1 回ずつ）、スループットテスト（ストリームごとに
  規定の順列）→ 「重み付きランダム」以外の**スクリプト選択ポリシー**が必要。
- クエリ別実行時間 → スクリプト別統計で既にほぼ足りる。

**TPC-E / TPC-AI**
- さらに複雑な入力生成・アプリケーションロジックを要するため完全準拠は非現実的だが、
  上記と同じ基盤（汎用初期化＋文字列＋ループ＋選択ポリシー）で「〜風」ワークロードは
  記述可能になる。TPC-AI 系はベクトル・大規模バッチが主で、初期化の汎用化と
  サーバサイド生成ステップの任意化が効く。

## 3. 設計方針

1. **pgbench 本体にはワークロード非依存の機構のみを追加する。**
   ベンチマーク固有のスキーマ・スクリプト・生成規則は外部ファイルとして配布する。
2. **後方互換を完全に維持する。** 既存の `-i` / `-b` / `-f` の挙動は変えない。
3. **小さな独立パッチに分割できる構成にする**（コミュニティのレビュープロセスに合わせる）。
   各機能は単独でも有用であること。
4. 既存の拡張ポイント（`PgBenchValueType` の「add other types here」コメント、
   `PGBENCH_FUNCTIONS[]` テーブル、`runInitSteps()` の switch 等）に沿って実装する。

## 4. 提案するコンポーネント

### 4.1 式言語の拡張：文字列型と補助関数

`PgBenchValueType` に `PGBT_STRING` を追加し、`PgBenchValue` の union に `char *sval`
（クライアント側 malloc、変数代入時に所有権移動）を追加する。

追加する関数・機能：

- 文字列リテラル `\set name 'BAKING'`、`||`（連結）、`=` / `<>` の文字列比較
- `random_string(len_min, len_max [, alphabet])` — TPC-C の a-string / n-string
- `pick(expr, 'a', 'b', ...)` — 候補からの選択（C_LAST のシラブル合成等に使用）
- `random_nurand(A, x, y [, C])` — TPC-C NURand の組み込み版
  （既存演算子でも合成可能だが、ワークロード記述の可読性と C 定数の扱いのため）
- `lpad(v, n, 'c')`, `format_date(days)` 等、最小限の整形関数
  （日付は「エポックからの日数の整数」+ 整形関数で表し、日付型の追加は行わない）

既存の `\gset` は現在も任意のクエリ結果を文字列として変数に取り込めるため、
文字列型の導入で SQL 側生成との連携が完結する。

### 4.2 制御構造：`\while` ループ

```
\while <expr>
  ...
\endwhile
```

- 実装は既存の `\if` と同じ `ConditionalStack`（psqlscan 系）を拡張し、
  `\endwhile` 到達時に対応する `\while` のコマンド位置（`Command **` の添字）へ巻き戻す。
- 暴走対策として `--max-loop-iterations`（既定 100 万など）を設け、超過時は
  クライアントをエラー扱いにする。
- これにより TPC-C New-Order の「5〜15 明細を 1 明細ずつ INSERT」や、
  バッチ生成スクリプトが記述可能になる。パイプラインメタコマンドと組み合わせれば
  明細挿入を 1 往復にまとめられる。

### 4.3 初期化の汎用化：カスタム初期化ステップ

`runInitSteps()`（pgbench.c:5326）を拡張し、`-I` の文字列ステップに加えて
**ファイル参照ステップ**を許す：

```
pgbench -i -I 'd,file=schema.sql,file=load.pgbench,v,file=indexes.sql' -s 100
```

- `file=NAME` ステップは、通常のトランザクションスクリプトと同じパーサで解釈される
  「初期化スクリプト」を単一接続で実行する。`\set`・`\while`・`\gset`・
  パイプラインなどのメタコマンドと `:scale` 変数がそのまま使える。
- 既存の一文字ステップ（`d` `t` `g` `G` `v` `p` `f`）は従来通り pgbench_* を対象とし、
  互換性を保つ。カスタムワークロードは `d`/`t`/`g` 等を使わず file= のみで構成する。
- 高速ロードのため、初期化スクリプト専用メタコマンドを 1 つ追加する：

```
\copyinto <table> <nrows>
  :expr1, :expr2, ...
\endcopy
```

  行テンプレート（式のリスト）を `nrows` 回評価して `COPY ... FROM STDIN` で流し込む。
  既存の `initRowMethod` コールバック（pgbench.c:853）と
  `initPopulateTable()` の COPY 経路を一般化する形で実装できる。
  行番号は `:row`（1..nrows）として参照可能。`nrows` には `:scale` を含む式を許す。
- `--init-jobs=N`（または `-j` の流用）で `\copyinto` を行レンジ分割して並列ロードする
  （テーブル単位・レンジ単位のワーカ分配。相関のある親子テーブルはスクリプト側で
  順序を制御する）。

### 4.4 スケール検出の一般化

現在 `GetTableInfo()`（pgbench.c:5411）は `pgbench_branches` の行数から `:scale` を
推定しており、カスタムスキーマでは機能しない。以下の規約を追加する：

- 初期化時に `pgbench -i` が `pgbench_metadata(key text, value text)` 相当の
  1 行（scale, 初期化時刻, ワークロード名）を書き込む…のではなく、
  **より侵襲の少ない案**として、実行時オプション `--scale-query='SELECT ...'` を追加し、
  ベンチマーク実行時に `:scale` をそのクエリで決定できるようにする。
  マニフェスト（4.6）を使う場合はマニフェストに `scale_query` を書く。
- `--scale-query` も `-s` も無い場合の既存フォールバック（pgbench_branches）は不変。

### 4.5 スクリプト選択ポリシーとメトリクス

`--script-selection=POLICY` を追加する（既定は現行の `weighted`）：

- `weighted` — 現行の重み付き独立ランダム（既定、互換）。
- `deck` — 重みを比率とみなし、比率通りのカードデッキを作ってクライアントごとに
  シャッフルして消化する。TPC-C の最低ミックス保証に対応。
- `sequence` — 定義順に 1 スクリプトずつ実行し、末尾まで行ったら終了（`-t`/`-T` と併用）。
  TPC-H パワーテスト（Q1..Q22 を順に 1 回）に対応。
- `permute` — クライアントごとに `permute(script_index, nscripts, seed + client_id)` で
  決まる順列で 1 巡ずつ実行する。TPC-H スループットテストのストリーム順列に対応。

メトリクス側の追加：

- `--counted-scripts=name[,name...]` — TPS 計算（および `--progress` 表示）の分子を
  指定スクリプトの完了数に限定した値を **併記** する。tpmC（New-Order/分）や
  「クエリセット完了数」を後処理なしで得られるようにする。全体 TPS の表示は従来通り。
- スクリプト別統計に分位点（`--latency-percentiles=90,95,99` 等）を追加する。
  実装は固定バケットの HDR 風ヒストグラムを `StatsData` に足す。

### 4.6 ワークロード定義パッケージ（マニフェスト）

上記の機構を束ねる薄い層として、ディレクトリ 1 つでワークロードを配布可能にする：

```
pgbench --workload=/path/to/tpcc -i -s 100
pgbench --workload=/path/to/tpcc -c 64 -j 8 -T 600
```

`/path/to/tpcc/workload.conf`（キー=値形式、psql の service ファイル同様の簡易文法）：

```ini
name = tpcc-like
min_version = 19            # 要求する pgbench 機能レベル

# -i のときに使われる初期化ステップ列（-I で上書き可能）
init = file=schema.sql, file=load.pgbench, v, file=indexes.sql, file=fkeys.sql

# 実行スクリプトと重み（TPC-C 5.2.3 の最低ミックス）
script = new_order.pgbench @ 45
script = payment.pgbench @ 43
script = order_status.pgbench @ 4
script = delivery.pgbench @ 4
script = stock_level.pgbench @ 4

script_selection = deck
counted_scripts = new_order.pgbench
scale_query = SELECT count(*) FROM warehouse
default_max_tries = 0        # 直列化失敗を無制限リトライ
```

- マニフェストは **CLI オプションの既定値を与えるだけ** であり、コマンドラインが常に勝つ。
  実装的には「workload.conf を読み、相当する内部オプションを未指定の場合のみ埋める」
  薄いローダで済み、実行エンジンには手を入れない。
- これにより「TPC-C 風」「TPC-H 風」等のワークロードは GitHub 上の
  スクリプト集として配布・改良でき、本体は仕様準拠の責任を負わない。

### 4.7 スコープ外としたもの（検討済みの代替案）

- **日付/timestamp 型の変数**：整数日数＋整形関数で足りるため見送り。
- **per-script レート制御**：TPC 系では think time（`\sleep`）で表現でき、
  グローバル `-R` と併用可能なため見送り。将来 `-R` の per-script 化は独立提案とする。
- **C レベルのプラグイン（dlopen）機構**：セキュリティ・保守の懸念が大きく、
  スクリプト言語の強化で大半のニーズを満たせるため不採用。
- **ワークロード本体の contrib 入り**：TPC の商標・監査問題があるため対象外。

## 5. 各ワークロードでの成立性確認

### TPC-C（〜風）

```
-- new_order.pgbench（抜粋）
\set w_id random(1, :scale)
\set d_id random(1, 10)
\set c_id random_nurand(1023, 1, 3000)
\set ol_cnt random(5, 15)
\set rollback_flag random(1, 100)
BEGIN;
SELECT c_discount, c_last, c_credit, w_tax FROM customer ... \gset
...
\set i 0
\while :i < :ol_cnt
  \set ol_i_id random_nurand(8191, 1, 100000)
  \set ol_supply_w_id CASE WHEN random(1,100) = 1 THEN random(1,:scale) ELSE :w_id END
  INSERT INTO order_line ... VALUES (..., :ol_i_id, :ol_supply_w_id, ...);
  \set i :i + 1
\endwhile
\if :rollback_flag = 1
  ROLLBACK;
\else
  COMMIT;
\endif
```

キーイング/シンクタイムは `\sleep`、直列化リトライは既存 `--max-tries`、
ミックス保証は `--script-selection=deck`、tpmC は `--counted-scripts` で成立する。

### TPC-H（〜風）

ロードは `file=` 初期化スクリプト内のサーバサイド SQL（`generate_series`）または
`\copyinto` で記述。Q1〜Q22 を各 1 ファイルにし、置換パラメータは文字列型＋
`random`/`pick`/`format_date` で生成。パワーテストは `--script-selection=sequence -t 1`、
スループットテストは `--script-selection=permute -c <streams>` で実行し、
スクリプト別統計から幾何平均を後処理で算出する。

### TPC-E / TPC-AI（〜風）

完全準拠は対象外だが、文字列型・ループ・`\gset` による結果依存分岐・汎用初期化により
主要トランザクションの近似が記述可能。ベクトル系ワークロードは `\copyinto` の式で
乱数ベクトル文字列を合成するか、サーバサイド生成ステップで対応する。

## 6. パッチ分割と導入計画

コミットフェスト単位で独立にレビュー可能なよう、以下の順で分割する。
各パッチは docs（pgbench.sgml）と TAP テスト（`t/001_pgbench_*.pl`）を含む。

| # | パッチ | 依存 | 主な変更点 |
|---|---|---|---|
| 1 | 文字列型 `PGBT_STRING` と文字列関数 | なし | pgbench.h の値型、exprparse.y/exprscan.l、evaluateExpr |
| 2 | `random_nurand` ほか補助関数 | 1 | PGBENCH_FUNCTIONS[] への追加のみ |
| 3 | `\while` / `\endwhile` | なし | ConditionalStack 拡張、CSTATE ループ巻き戻し |
| 4 | `-I file=...` カスタム初期化 + `\copyinto` | 3（生成ループに使用） | runInitSteps、initPopulateTable の一般化 |
| 5 | `--scale-query` | なし | GetTableInfo の分岐追加 |
| 6 | `--script-selection` / `--counted-scripts` / 分位点 | なし | chooseScript、StatsData、レポート出力 |
| 7 | `--workload` マニフェストローダ | 4,5,6 | オプション既定値の注入層 |

1〜3 は単独でも既存ユーザに価値がある（例：`\while` はバッチ投入の記述、
文字列は現状 `\setshell` で回避されている用途の置き換え）ため、
「特定ベンチマークのための機能」ではなく汎用機能として提案できる。

## 7. リスクと論点

- **式言語の肥大化**：文字列演算をどこまで持つかは論争になりうる。最小集合
  （リテラル・連結・比較・random_string・pick）から始め、必要に応じて追加する。
- **`\while` の暴走**：反復上限と `--exit-on-abort` の組み合わせで緩和。
- **マニフェストの文法**：新文法の発明を嫌う意見が予想される。実体は
  「オプション既定値ファイル」であり、psql service ファイルと同系の key=value に留める。
  最悪この層が rejected でも 1〜6 だけでワークロードはシェルスクリプトから組める。
- **性能**：文字列変数の malloc/free がホットパスに乗る。変数スロットの再利用
  （既存 Variable 配列の in-place 更新）で従来ワークロードへの影響をゼロに保つ。
