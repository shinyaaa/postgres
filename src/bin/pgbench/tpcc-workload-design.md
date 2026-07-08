# pgbench で TPC-C（風）ワークロードを実現するためのインフラ設計書

## 1. 目的とスコープ

pgbench で TPC-C 風ワークロード（以下 "tpcc-like"）をカスタムスクリプトとして
記述・実行できるようにするために、pgbench 本体へ追加が必要な機能を設計する。

方針は次の 2 点に集約される。

1. **TPC-C のスキーマ・スクリプト自体は本体に入れない。**
   商標・監査要件・メンテナンスコストの観点から、ワークロード定義は外部配布
   （サードパーティのスクリプト集）とし、本体には**ワークロード非依存の汎用機構**
   だけを追加する。各機能は TPC-C 以外にも使い道がある形で提案する。
2. **完全準拠は目標にしない。** 監査、端末エミュレーションの厳密な再現、
   Delivery の非同期キュー実行などはスコープ外とし、
   「構成が明記された、比較可能な tpcc-like」を到達点とする（§6 に割り切りを列挙）。

## 2. TPC-C 要件の整理

設計の前提として、TPC-C（v5.11 系）の要素を pgbench 視点で整理する。

### 2.1 スキーマとスケール

スケールファクタは倉庫数 W。初期データ量は W にほぼ比例する。

| テーブル | 行数 | 備考 |
|---|---|---|
| warehouse | W | |
| district | 10 × W | |
| customer | 30,000 × W | C_LAST はシラブル合成文字列 |
| history | 30,000 × W | |
| orders | 30,000 × W | |
| new_order | 9,000 × W | 各 district の直近 900 オーダ |
| order_line | 約 300,000 × W | オーダごとに 5〜15 行（乱数） |
| item | 100,000 | W に依存しない固定 |
| stock | 100,000 × W | |

親子で行数・値が相関する（orders.o_ol_cnt と order_line の行数一致等）。

### 2.2 トランザクションと実行モデル

| トランザクション | ミックス | 特徴 |
|---|---|---|
| New-Order | 約 45%（残余） | 5〜15 明細のループ、1% は意図的ロールバック、NURand |
| Payment | 43% 以上 | 60% は C_LAST（文字列）で顧客検索、15% はリモート倉庫 |
| Order-Status | 4% 以上 | 60% は C_LAST 検索、読み取りのみ |
| Delivery | 4% 以上 | 10 district を順に処理（仕様上は非同期キュー実行） |
| Stock-Level | 4% 以上 | district 固定、閾値 10〜20、読み取りのみ |

- 乱数: `NURand(A, x, y) = (((random(0,A) | random(x,y)) + C) % (y - x + 1)) + x`。
  A は用途別（品目 8191、顧客 ID 1023、C_LAST 255）。定数 C はロード時と実行時で
  異なる値を使い、その差（C_delta）に仕様上の制約がある。
- 端末モデル: 端末数は 10 × W。各トランザクションにキーイング時間
  （固定: 18/3/2/2/2 秒）とシンク時間（平均 12/12/10/5/5 秒の指数分布）が付く。
- メトリクス: **tpmC = New-Order の完了数/分**。他の 4 種は分母にも分子にも入らない。
- 直列化異常（SQLSTATE 40001 等）はリトライして完遂することが求められる。

### 2.3 既存機能とのギャップ

| TPC-C 要件 | pgbench の現状 | 判定 |
|---|---|---|
| 任意スキーマの作成と相関データロード | `-I dtgGvpf` は pgbench_\* テーブル固定（`runInitSteps()` pgbench.c:5326、`initCreateTables()` 同 4895） | **欠落（P0）** |
| New-Order の 5〜15 明細ループ | ループ構文なし（`\if` のみ） | **欠落（P0）** |
| C_LAST 等の文字列生成・比較 | 式言語の値型は int/double/bool/null のみ（`PgBenchValue` pgbench.h:44） | **欠落（P0）** |
| `:scale` の検出 | `GetTableInfo()`（pgbench.c:5411）が pgbench_branches の行数固定 | **欠落（P0）** |
| NURand | 既存の `random()` とビット OR（`PGBENCH_BITOR`）で合成可能 | 補助関数で改善（P1） |
| 最低ミックス保証 | 重み付き独立ランダム選択のみ（`chooseScript()`） | デッキ方式で改善（P1） |
| tpmC の算出 | スクリプト別完了数は出力されるが、TPS は全スクリプト合算のみ | 改善（P1） |
| 1% ロールバック | `\if` + `ROLLBACK;` で可能 | 既存で可 |
| キーイング/シンク時間 | `\sleep :var ms` で可能（指数分布は `random_exponential`） | 既存で可 |
| 端末→倉庫の割当 | `:client_id` + `permute()` で可能 | 既存で可 |
| 直列化リトライ | `--max-tries`（0 = 無制限） | 既存で可 |
| リモート倉庫等の確率分岐 | `\if` + `random(1,100)` | 既存で可 |

以下、欠落 4 点（P0）と改善 3 点（P1）を個別に設計する。

## 3. P0: tpcc-like の記述に必須の機能

### 3.1 `\while` / `\endwhile` メタコマンド

New-Order の可変明細数（5〜15）を記述するために必須。現状は最大数まで `\if` を
展開する以外に方法がなく、実用的でない。

```
\set i 0
\while :i < :ol_cnt
  ...
  \set i :i + 1
\endwhile
```

設計:

- 文法は `\if` と対称にする。`\while <expr>` は式が真の間ブロックを実行し、
  `\endwhile` で先頭に戻る。`\if` と同様にネスト可能で、`\if`/`\while` の
  交差ネスト（不整合な閉じ方）はパース時にエラーにする。
- 実装は 2 層に分かれる:
  1. **パース時**: `ParsedScript.commands[]` 上で `\while` と対応する `\endwhile` の
     添字を解決し、`Command` に相互のジャンプ先を保持する（`\if` が使う
     ConditionalStack と同様のスタックで対応付け）。
  2. **実行時**: `\endwhile` に到達したら `st->command` を対応する `\while` に戻す。
     式が偽なら `\endwhile` の次へジャンプする。実行時スタックは不要
     （ジャンプ先が静的に決まるため）。
- `\sleep` や SQL コマンドをループ体に含む場合も、既存のステートマシン
  （`CSTATE_*`）はコマンド添字ベースで動くため大きな変更は不要。
- **暴走対策**: 1 トランザクション内の総ループ反復数に上限
  （`--max-loop-iterations`、既定 100 万）を設け、超過時はそのクライアントを
  エラー扱い（`--exit-on-abort` に従う）とする。
- パイプライン（`\startpipeline`）内のループも許す。New-Order の明細 INSERT を
  1 往復にまとめる用途に有効。

### 3.2 式言語への文字列型の追加

Payment / Order-Status の「60% は C_LAST で検索」、およびロード時の
文字列データ生成に必須。`PgBenchValueType` には既に
`/* add other types here */` の拡張ポイントがある（pgbench.h:41）。

設計:

- `PGBT_STRING` を追加し、union に `char *sval` を持たせる。
- 対応する演算・関数は最小集合に絞る:
  - 文字列リテラル: `\set name 'BAR'`（exprscan.l に引用符付きリテラルを追加）
  - 連結: `||`
  - 比較: `=` / `<>`（`\if` での分岐用）
  - `random_string(min_len, max_len [, alphabet])` — TPC-C の a-string / n-string
  - `pick(idx, 'v0', 'v1', ...)` — idx 番目の候補を返す。C_LAST の
    シラブル合成（10 候補 × 3 桁）に使う:

    ```
    \set n random_nurand(255, 0, 999)
    \set c_last pick(:n / 100, 'BAR','OUGHT','ABLE','PRI','PRES','ESE','ANTI','CALLY','ATION','EING') || pick((:n / 10) % 10, ...) || pick(:n % 10, ...)
    ```
- SQL への変数展開（`:var`）は既存経路がそのまま使えるが、文字列値は
  **リテラルとしてクォート**して展開する（現状の数値と同じ素朴な文字列置換だと
  SQL インジェクション的な事故になるため、`PQescapeLiteral` 相当で展開する。
  拡張プロトコル（`-M extended/prepared`）ではパラメータとして渡るので自然に安全）。
- `\gset` で取り込んだ値は現状すべて文字列として保持され必要時に数値へ
  parse される（`makeVariableValue()`）。文字列型導入後は「数値に parse
  できなければ文字列値」と自然に拡張でき、既存動作は変わらない。
- **性能への配慮**: 変数への文字列代入は既存 `Variable` スロットの buffer を
  再利用（必要時のみ realloc）し、数値のみのワークロード（既存 tpcb-like）の
  ホットパスにはコードパスの追加を一切入れない。

### 3.3 カスタム初期化: `-I file=...` と `\copyinto`

9 テーブルのスキーマ作成と W に比例した相関データロードを可能にする。

#### 3.3.1 初期化ステップのファイル参照

`-I` のステップ文字列を拡張し、ファイル参照ステップを許す
（区切りにカンマを許容。既存の一文字ステップとの混在も可）:

```
pgbench -i -s 100 -I 'file=schema.sql,file=load.pgbench,file=indexes.sql,v,file=fkeys.sql'
```

- `file=NAME` は、トランザクションスクリプトと同じパーサで解釈した
  「初期化スクリプト」を単一接続で実行する。`\set` `\while` `\gset`
  `\startpipeline` と `:scale` 変数がそのまま使える。
- `checkInitSteps()`（pgbench.c:5306）と `runInitSteps()` の switch に
  分岐を追加するだけで、既存の一文字ステップの意味は変えない。
  tpcc-like は `d`/`t`/`g` を使わず file= のみで構成する。
- 各ステップの所要時間は既存同様 "done in ... (schema.sql 1.23 s, ...)" 形式で
  報告する。

#### 3.3.2 行生成メタコマンド `\copyinto`

item（10 万行）、stock（10 万 × W 行）、customer（3 万 × W 行）などの大量ロードを
`INSERT` のループで行うのは遅すぎるため、COPY ベースの行生成コマンドを
初期化スクリプト専用に追加する:

```
\copyinto stock :scale * 100000
  ((:row - 1) / 100000) + 1,          -- s_w_id
  ((:row - 1) % 100000) + 1,          -- s_i_id
  random(10, 100),                    -- s_quantity
  random_string(24, 24),              -- s_dist_01
  ...
\endcopy
```

- 行テンプレート（式のカンマ区切りリスト、複数行可）を行数分評価し、
  `COPY <table> FROM STDIN` で送る。`:row`（1..N）が行番号として使える。
- 実装は既存の COPY ロード経路の一般化である。現在 `initPopulateTable()` が
  `initRowMethod` コールバック（pgbench.c:853）で pgbench_accounts 等の行を
  組み立てているのを、「式リストの評価」をコールバックにした形で共通化する。
  進捗表示（x of y tuples）・`--partitions` 世代の FREEZE オプション適用条件
  （`get_table_relkind()`）も同じ経路に乗る。
- **並列ロード**: `pgbench -i -j N` のとき、`\copyinto` は行レンジを N 分割して
  ワーカ接続で並列実行する（`:row` の範囲だけが異なる同一テンプレート）。
  テーブル間の順序はスクリプト記述順を保証する（FK は最後に張る前提）。
- 行数一致の相関（orders.o_ol_cnt = order_line の行数）は `\copyinto` では
  表現しにくいため、順序依存のロードは次のどちらかで記述する:
  1. サーバサイド SQL（`generate_series` + ウィンドウ関数）— orders を先に
     生成し、order_line を orders から導出する方法。schema.sql / load 内の
     プレーン SQL で書ける。
  2. `\while` + `\startpipeline` + INSERT — 小規模テーブル向け。

  つまり `\copyinto` は独立行の大量生成用、相関はサーバサイド SQL 用と
  役割を分ける。TPC-C の初期ロードはこの 2 つで全テーブルを表現できる
  （o_ol_cnt を先に乱数決定して orders に持たせ、order_line を
  `generate_series(1, o_ol_cnt)` で展開するのが素直）。

### 3.4 `--scale-query` によるスケール検出の一般化

実行時に `-s` が与えられない場合、`GetTableInfo()` は
`select count(*) from pgbench_branches` で `:scale` を推定するため、
カスタムスキーマでは警告の上 scale=1 になってしまう。

- 新オプション `--scale-query='SELECT count(*) FROM warehouse'` を追加する。
  結果（1 行 1 列の整数）を `:scale` にセットする。
- 指定が無い場合の挙動（pgbench_branches へのフォールバック）は不変。
- ベンチマーク実行コマンドが自己完結する（実行側スクリプトに
  `\gset` でのスケール取得を書かせない）ことが目的。パーティション情報の
  自動検出（`--partitions` 相当）はカスタムスキーマでは行わない。

## 4. P1: 品質・忠実度を上げる機能

### 4.1 `random_nurand(A, x, y [, C])` 関数

NURand は既存演算子で

```
\set c_id (((random(0, 1023) | random(1, 3000)) + :C) % 3000) + 1
```

と書けるが、頻出のわりに読みにくく、C 定数の扱いを各スクリプトに任せると
ロード時/実行時の C_delta 制約（仕様 2.1.6.1）を満たす配慮が漏れやすい。
`PGBENCH_FUNCTIONS[]`（exprparse.y:254）への追加のみで実装できる組み込み関数として:

- `random_nurand(A, x, y)` — C は乱数シードから導出（run ごとに一定）。
- `random_nurand(A, x, y, C)` — C を明示（ロードと実行で整合を取りたい場合、
  `-D c_load=123` のように外から渡す）。
- C_delta 制約の検証自体は pgbench の責務にしない（ワークロード配布側の
  ドキュメントで案内する）。

### 4.2 デッキ方式のスクリプト選択 `--script-selection=deck`

TPC-C 5.2.4 のミックスは「最低比率の保証」であり、独立ランダム選択（現行）では
短時間の実行で比率が揺れる。カードデッキ方式を追加する:

- `--script-selection={weighted|deck}`（既定 weighted、現行互換）。
- deck では `-b`/`-f` の `@weight` をカード枚数と解釈し、クライアントごとに
  重み合計枚数のデッキを作って Fisher–Yates でシャッフルし、1 枚ずつ消化、
  使い切ったら再シャッフルする。TPC-C なら `@45 @43 @4 @4 @4` で
  100 トランザクションごとに正確なミックスになる。
- `chooseScript()` の分岐追加と、`CState` へのデッキ（`int *` + カーソル）追加のみ。
  統計・ログ形式への影響はない。

### 4.3 tpmC のための `--counted-scripts`

tpmC は New-Order の完了数だけを数える。現在もスクリプト別の実行数は
最終レポートに出るが、`--progress` の途中経過や集約ログは全体 TPS のみで、
「規定シンク時間込みで New-Order だけを数えた値」を得るには後処理が要る。

- `--counted-scripts=NAME[,NAME...]` — 指定スクリプト（`-f` のファイル名 or
  `-b` の組み込み名）の完了数に基づく "counted tps" を、最終レポートと
  `--progress` 行に**併記**する（既存の全体 TPS 表示は変えない）。
- スクリプト別 `StatsData` は既にあるため（`ParsedScript.stats`）、集計は
  表示層の変更のみで済む。
- 併せて、スクリプト別レイテンシの分位点表示
  （`--latency-percentiles=90,95,99`）を追加する。TPC-C の応答時間制約
  （90 パーセンタイル ≤ 5 秒等）の近似確認に使う。実装は `StatsData` への
  固定境界ヒストグラム（対数バケット）の追加。

## 5. tpcc-like ワークロードの全体像（外部配布物のイメージ）

本体機能が揃ったとき、外部リポジトリで配布される tpcc-like は
次のような構成になる（本体には入れない）:

```
tpcc/
  schema.sql          -- 9 テーブルの CREATE TABLE
  load.pgbench        -- \copyinto + サーバサイド SQL によるロード
  indexes.sql         -- PK・インデックス
  fkeys.sql           -- FK（任意）
  new_order.pgbench
  payment.pgbench
  order_status.pgbench
  delivery.pgbench
  stock_level.pgbench
```

初期化（W=100）:

```
pgbench -i -s 100 -j 8 \
  -I 'file=schema.sql,file=load.pgbench,file=indexes.sql,v,file=fkeys.sql'
```

実行（キーイング/シンク時間なしのスループット測定の例）:

```
pgbench -c 64 -j 8 -T 600 -M prepared --max-tries=0 \
  --scale-query='SELECT count(*) FROM warehouse' \
  --script-selection=deck \
  --counted-scripts=new_order.pgbench \
  -f new_order.pgbench@45 -f payment.pgbench@43 \
  -f order_status.pgbench@4 -f delivery.pgbench@4 -f stock_level.pgbench@4
```

New-Order スクリプトの骨子（本設計の機能がどう使われるか）:

```
\set w_id random(1, :scale)
\set d_id random(1, 10)
\set c_id random_nurand(1023, 1, 3000)
\set ol_cnt random(5, 15)
\set rbk random(1, 100)
BEGIN;
SELECT c_discount, c_last, c_credit FROM customer
  WHERE c_w_id = :w_id AND c_d_id = :d_id AND c_id = :c_id \gset
UPDATE district SET d_next_o_id = d_next_o_id + 1
  WHERE d_w_id = :w_id AND d_id = :d_id RETURNING d_next_o_id - 1 AS o_id, d_tax \gset
INSERT INTO orders ... ;
INSERT INTO new_order ... ;
\set i 1
\while :i <= :ol_cnt
  \if :rbk = 1 AND :i = :ol_cnt
    \set ol_i_id 999999              -- 存在しない品目 → 1% ロールバック
  \else
    \set ol_i_id random_nurand(8191, 1, 100000)
  \endif
  \set ol_supply_w_id CASE WHEN random(1, 100) = 1 AND :scale > 1 THEN random(1, :scale) ELSE :w_id END
  SELECT i_price, i_name FROM item WHERE i_id = :ol_i_id \gset
  UPDATE stock SET s_quantity = ... WHERE s_i_id = :ol_i_id AND s_w_id = :ol_supply_w_id ... ;
  INSERT INTO order_line ... ;
  \set i :i + 1
\endwhile
COMMIT;
```

（1% ロールバックは存在しない品目 ID によるエラーで発生させるのが仕様の意図。
`--continue-on-error` あるいは `\if` + 明示 `ROLLBACK` のどちらでも表現できる。）

Payment の顧客検索（文字列型の使いどころ）:

```
\set by_last random(1, 100)
\if :by_last <= 60
  \set n random_nurand(255, 0, 999)
  \set c_last pick(:n / 100, 'BAR','OUGHT',...) || pick((:n / 10) % 10, ...) || pick(:n % 10, ...)
  SELECT c_id FROM customer
    WHERE c_w_id = :c_w_id AND c_d_id = :c_d_id AND c_last = :c_last
    ORDER BY c_first OFFSET (SELECT count(*)/2 FROM customer WHERE ...) LIMIT 1 \gset
\endif
```

端末モデルを模す場合はスクリプト冒頭・末尾に
`\sleep :keying s` / `\set think random_exponential(...)` + `\sleep :think s` を
置き、`-c` を 10 × W に近づける（完全な端末エミュレーションは §6 の通り対象外）。

## 6. 準拠レベルの割り切り（明示的な非目標）

1. **端末エミュレーション**: 10 × W 端末の厳密な再現はしない。`-c` と
   `\sleep` による近似、またはシンク時間なしの飽和スループット測定を想定する。
2. **Delivery の非同期実行**: 仕様ではキュー投入と遅延実行（80 秒以内）だが、
   同期実行で代替する。
3. **応答時間制約の検証・レポート監査**: 分位点表示（§4.3）で目視確認できる
   水準に留める。
4. **C_delta 制約の強制**: 関数側では強制しない（§4.1）。
5. したがって結果は「tpmC」ではなく tpcc-like の参考値であり、
   外部配布側ドキュメントでその旨を明記する。

## 7. パッチ分割と導入計画

コミットフェスト単位で独立にレビュー可能な粒度に分割する。各パッチは
pgbench.sgml の文書化と TAP テスト（`t/001_pgbench_with_server.pl` ほか）を含む。

| # | パッチ | 依存 | 優先度 | 主な変更箇所 |
|---|---|---|---|---|
| 1 | `\while` / `\endwhile` | なし | P0 | pgbench.c（パース・ステートマシン） |
| 2 | 文字列型 + `random_string` / `pick` / `\|\|` | なし | P0 | pgbench.h, exprscan.l, exprparse.y, pgbench.c |
| 3 | `-I file=...` + `\copyinto`（並列ロード含む） | 1 | P0 | pgbench.c（runInitSteps, initPopulateTable 一般化） |
| 4 | `--scale-query` | なし | P0 | pgbench.c（GetTableInfo） |
| 5 | `random_nurand` | なし | P1 | exprparse.y, pgbench.c |
| 6 | `--script-selection=deck` | なし | P1 | pgbench.c（chooseScript, CState） |
| 7 | `--counted-scripts` + 分位点 | なし | P1 | pgbench.c（StatsData, レポート） |

- 1・2 は TPC-C 文脈を出さずとも汎用機能として単独で提案価値がある
  （バッチ投入の記述、`\setshell` 回避など）。ここから着手する。
- 3 が最も大きく、レビュー負荷を下げるため「file= ステップ」と
  「`\copyinto`」「並列化」の 3 段に細分することも検討する。
- P0 の 4 本が入った時点で tpcc-like は（合成 NURand・weighted 選択で）
  動作可能になる。P1 は忠実度と使い勝手の改善。

## 8. テスト計画

- `\while`: 反復回数の境界（0 回・1 回・ネスト）、`\if` との交差ネストの
  パースエラー、`--max-loop-iterations` 超過時の失敗系。
- 文字列型: リテラル・連結・比較・`\gset` 経由の文字列、SQL 展開時の
  クォート（引用符・バックスラッシュを含む値）、extended/prepared での
  パラメータ渡し。
- `-I file=` / `\copyinto`: 生成行数と `:row` の範囲、`-j` 並列時の行数一致、
  失敗時のエラーメッセージ（ファイル名・行番号）。
- `--scale-query`: 正常系、0 行/複数列などの不正な結果のエラー。
- deck: 100 トランザクション消化後のミックス比率の厳密一致を
  ログ（`--log`）から検証。
- 統合: 最小 tpcc-like（W=1、数トランザクション）を TAP テスト内で組み立てて
  スモークとする（スキーマは数カラムに簡略化したもの。仕様準拠検証はしない）。

## 9. リスクと論点

- **`\while` の暴走と CHECK_FOR_INTERRUPTS 相当**: クライアント側ループは
  Ctrl-C（`CancelRequested`）とアラーム（`-T`）に反応する必要がある。
  反復ごとのフラグ確認を入れる。
- **文字列の SQL 展開**: simple プロトコルでの安全なクォートが必須
  （§3.2）。レビューで最も指摘されやすい箇所と想定。
- **式言語の肥大化**: 文字列演算は最小集合（リテラル・`\|\|`・比較・
  `random_string`・`pick`）から始め、`substr` 等はニーズが出てから追加する。
- **`\copyinto` の文法**: メタコマンドが複数行にまたがる初の例になる
  （現行パーサはメタコマンド 1 行前提）。`\endcopy` までを本体として読む
  字句処理の変更が必要で、ここが実装上の最大の新規性。
  代替案として「1 行に式リストを書き切る」制約から始める選択肢もある。
- **並列ロードの一貫性**: `\copyinto` の分割は独立行生成のみ対象で、
  乱数列の再現性（`--random-seed`）とワーカ分割の関係を文書化する必要がある
  （ワーカごとに seed を派生させる。分割数が変われば同一 seed でも
  データは変わる旨を明記）。
