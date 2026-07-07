# pg_undo — Ctrl+Z for PostgreSQL 設計書

**「間違えて DELETE / UPDATE / DROP してしまった」を、SQL 一発で元に戻せる PostgreSQL 拡張**

- ステータス: 設計ドラフト v0.1(2026-07-07)
- 想定リポジトリ名: `pg_undo`
- タグライン案: *"Ctrl+Z for your PostgreSQL database"*

---

## 1. 背景:人気拡張の調査結果

### 1.1 現在人気のある拡張(カテゴリ別)

| カテゴリ | 代表的な拡張 | 傾向 |
|---|---|---|
| AI / ベクトル検索 | pgvector, pgvectorscale, pgai | 現在最も星が集まる領域。ただし超激戦区 |
| 分析 / OLAP | pg_duckdb, pg_mooncake, pg_analytics(archived), hydra | DuckDB 統合が流行。大手が参入済み |
| 全文検索 | pg_search (ParadeDB), pgroonga | BM25 系は ParadeDB が強い |
| 時系列 | timescaledb | 成熟・独占状態 |
| ジョブ / キュー | pg_cron, pgmq | pgmq は「シンプルさ」で急成長した好例 |
| 運用 / 監視 | pg_stat_statements, pg_partman, pg_repack, pg_auto_failover | 定番化しており新規参入余地は小さい |
| 開発体験 (DX) | pg_graphql, pg_jsonschema, hypopg | Supabase 系が量産 |

### 1.2 スターを集める拡張に共通するパターン

1. **痛みが普遍的**:ほぼ全ての Postgres ユーザーが遭遇する問題を解く(pgvector = AI ブーム、pg_cron = cron を DB 外に持ちたくない)。
2. **README の 30 秒で価値が伝わる**:`SELECT cron.schedule(...)` のような「1 行デモ」がある。
3. **セットアップが一撃**:`CREATE EXTENSION` + Docker ワンライナーで試せる。
4. **商用 DB には有る機能の OSS 化**:Oracle / SQL Server にあって Postgres に無いものは鉄板ネタ(例: 温度差のある温式レプリケーション、フラッシュバック)。
5. **名前で機能が分かる**:pgmq、pg_cron、pgvector。

### 1.3 ギャップ分析:存在しない(または貧弱な)領域

「**誤操作からのデータ復旧**」は、あらゆる開発者・DBA が経験する普遍的な恐怖でありながら、OSS Postgres には統合的な解決策が存在しない:

| 既存手段 | 問題点 |
|---|---|
| `temporal_tables` / `periods` | トリガーベースで**テーブルごとに事前設定が必要**。履歴テーブルの手動管理。メンテナンスが停滞気味 |
| `pg_dirtyread` | VACUUM 前の dead tuple を読むだけ。**autovacuum との競争**(実質 60 秒以内)。undo SQL は生成しない |
| `pg_surgery` | 破損修復用。誤操作復旧の UX は皆無 |
| `pgtrashcan` | 2013 年の小規模実験。DROP のみ、メンテ停止 |
| WAL からの手動復旧 / walminer | 専門知識が必要。緊急時に平常心でやれる作業ではない |
| PITR(バックアップからのリストア) | **クラスタ全体**の巻き戻し。1 テーブルの誤 DELETE のために全 DB を戻せない。復旧に数時間 |
| Oracle Flashback / SQL Server temporal / PolarDB・Redrock の flashback | **商用・クラウド専用**。OSS Postgres には存在しない ← ここが狙い目 |

**結論:Oracle の Flashback Query + Flashback Drop(ごみ箱)に相当する体験を、OSS Postgres にゼロコンフィグで提供する拡張は存在しない。** 商用フォークが軒並み実装していることが、需要の強さの証明になっている。

### 1.4 検討したが見送った他の候補

- **セマンティックキャッシュ / AI 系**:pgvector・pgai エコシステムが飽和。大手 (Supabase, Timescale, Neon) と正面衝突する。
- **RLS ポリシーデバッガ**:便利だが対象ユーザーが狭く、バイラル性に欠ける。
- **マイグレーション安全性リンタ**:squawk・pgroll など外部ツールが既に定番。DB 内拡張にする必然性が弱い。
- **DB ブランチング**:ストレージ層の協力が必要で拡張単体では筋が悪い。Neon が事実上の解。

---

## 2. プロダクト概要

### 2.1 エレベーターピッチ

> `WHERE` を忘れた `UPDATE`。本番と間違えて流した `DELETE`。手が滑った `DROP TABLE`。
> **pg_undo** を入れておけば、直近 24 時間(設定可)のあらゆる変更を SQL 一発で巻き戻せる。
> バックアップからのリストアも、WAL の手動解析も、もう要らない。

### 2.2 README に載せる「30 秒デモ」

```sql
-- セットアップ(一度だけ)
CREATE EXTENSION pg_undo;
SELECT undo.track('public.users');

-- ...やらかす...
DELETE FROM users;  -- WHERE を忘れた!

-- 何が起きたか確認
SELECT * FROM undo.recent_changes('users', '10 minutes');

-- 巻き戻す(まずプレビュー)
SELECT undo.preview(last => '10 minutes', "table" => 'users');
--> "INSERT INTO users ... (48,213 rows will be restored)"

-- 実行
SELECT undo.apply(last => '10 minutes', "table" => 'users');
--> UNDO applied: 48,213 rows restored in 1.2s

-- DROP TABLE すらも
DROP TABLE users;
SELECT undo.restore_dropped('users');  -- ごみ箱から復元
```

### 2.3 主要機能

1. **DML の undo(Flashback DML 相当)**
   - トランザクション単位:`undo.apply(xid => 12345)`
   - 時間範囲 + テーブル/ユーザー絞り込み:`undo.apply(last => '5 minutes', "table" => 'users', by_role => 'app_rw')`
   - 必ず `undo.preview()` で逆 DML と件数を事前確認できる(信頼性の要)
2. **タイムトラベルクエリ(Flashback Query 相当)**
   - `SELECT * FROM undo.as_of('users', now() - interval '1 hour') AS t(LIKE users)`
   - `SELECT undo.create_snapshot_view('users', <ts>)` → `users_asof` ビューで通常の SELECT が可能
3. **ごみ箱(Flashback Drop 相当)**
   - `DROP TABLE` を横取りして `undo_trash` スキーマへ退避。`undo.restore_dropped('users')` で復元
   - 保持期間経過後に本当に削除。`DROP TABLE ... WITH (undo off)` 相当のバイパス GUC も用意
4. **変更の監査ビュー**
   - `undo.recent_changes(table, interval)`:誰が・いつ・どの行をどう変えたかを行画像つきで表示(副産物として軽量監査ログにもなる)

---

## 3. アーキテクチャ

```
┌─────────────────────────────── PostgreSQL ───────────────────────────────┐
│                                                                          │
│  アプリの DML ──▶ WAL ──▶ logical decoding (専用 replication slot)        │
│                              │                                           │
│                              ▼                                           │
│                    [bgworker: undo capturer]                             │
│                              │ 旧/新 行イメージ + xid + role + timestamp  │
│                              ▼                                           │
│              undo.history(時間パーティション化された履歴テーブル)          │
│                              ▲                                           │
│        undo.preview / undo.apply / undo.as_of が参照                      │
│                                                                          │
│  DROP TABLE ──▶ [ProcessUtility hook] ──▶ undo_trash スキーマへ退避        │
│                                                                          │
│  [bgworker: janitor] ── retention 超過パーティションの DROP、slot 前進、    │
│                          ごみ箱の掃除、サイズ上限の強制                     │
└──────────────────────────────────────────────────────────────────────────┘
```

### 3.1 変更キャプチャ:logical decoding + 常駐 background worker

- 拡張が専用の **logical replication slot** を作成し、background worker がインプロセスでデコードして `undo.history` に書き込む。
- トリガー方式(temporal_tables)と比べた利点:
  - 書き込みトランザクションの**クリティカルパスに入らない**(コミットレイテンシに影響しない)
  - テーブルごとのトリガー設置が不要。`undo.track()` はメタデータ登録のみ
- 要件:`wal_level = logical`(主要マネージドサービスはすべて設定可能)。
- UPDATE / DELETE の**旧行イメージ**を得るため、`undo.track()` が対象テーブルに `REPLICA IDENTITY FULL` を設定する(トレードオフは §5)。

### 3.2 履歴ストレージ:`undo.history`

```sql
CREATE TABLE undo.history (
    relid       oid          NOT NULL,
    change_lsn  pg_lsn       NOT NULL,
    xid         xid8         NOT NULL,
    changed_at  timestamptz  NOT NULL,
    changed_by  name         NOT NULL,   -- session_authorization
    op          "char"       NOT NULL,   -- I / U / D / T(truncate)
    old_row     jsonb,                   -- U, D で使用
    new_row     jsonb                    -- I, U で使用
) PARTITION BY RANGE (changed_at);       -- 1 時間単位。GC はパーティション DROP
```

- 行イメージは jsonb(+ TOAST の lz4/zstd 圧縮)で保存。型忠実性が必要な復元時は `jsonb_populate_record` でテーブルの行型に戻す。
- インデックス:`(relid, changed_at)`、`(xid)`。
- MVP は「履歴も同じ DB に持つ」割り切り。ディスク破損まで守るのはバックアップの仕事であり、pg_undo は**論理的な誤操作**専用と明言する(スコープの明確化)。

### 3.3 undo の生成と適用

- `undo.preview(...)`:履歴から**逆操作**(D→INSERT、U→旧値への UPDATE、I→DELETE)を新しい順に生成し、件数と SQL サンプルを返す。
- `undo.apply(...)`:単一トランザクションで逆操作を実行。
  - **競合検出**:undo 対象行が「対象時点より後にさらに変更されている」場合を検出し、`on_conflict => 'abort' | 'skip' | 'force'` で挙動を選択(デフォルト abort)。
  - 実行そのものも WAL に載る通常の DML なので、**undo の undo** も可能。
- 主キー(または replica identity)必須。無いテーブルは track 時に警告して full-row 一致モードにフォールバック。

### 3.4 タイムトラベル

時点 T の状態 = 「現在の行のうち T 以降に変更されていないもの」∪「T 以降に変更/削除された行の T 時点の旧イメージ」。`undo.history` の (relid, changed_at) インデックスで差分だけを読むため、変更が少なければ大テーブルでも高速。

### 3.5 ごみ箱(DROP の横取り)

- **ProcessUtility hook** で `DropStmt`(TABLE)を検知し、実削除の代わりに `ALTER TABLE ... SET SCHEMA undo_trash` + リネーム(`users__dropped_20260707_103000`)。依存オブジェクト(インデックス、シーケンス)は道連れで移動。
- イベントトリガーでは DROP を「置き換え」できないため、フックが必須(この設計判断が C/pgrx で書く理由の一つ)。
- `undo.trash` ビューでごみ箱を一覧、`undo.restore_dropped(name)` で復元、`undo.purge()` で即時完全削除。

### 3.6 GC / 自己保護(janitor bgworker)

- GUC:`pg_undo.retention = '24h'`、`pg_undo.max_history_size = '10GB'`、`pg_undo.trash_retention = '7d'`。
- retention 超過パーティションの DROP、replication slot の定期的な前進(WAL 肥大防止)。
- **フェイルセーフ**:slot 遅延やサイズが閾値を超えたら、本体を守るために自動で履歴収集を停止し WARNING を出す(「入れたら本番が死んだ」を絶対に起こさない設計を README で強調)。

### 3.7 セキュリティ

- `undo.history` は全データのコピーを含むため、参照は superuser と `pg_undo_admin` ロールのみ。
- `undo.apply` / `restore_dropped` は対象テーブルの所有者権限が必要。
- RLS 有効テーブルは track 時に警告(履歴閲覧はポリシーを迂回しうるため admin 限定であることを明記)。

---

## 4. 実装技術

| 項目 | 選択 | 理由 |
|---|---|---|
| 言語 / フレームワーク | **Rust + pgrx** | bgworker・フック・SQL 関数を一つのクレートで安全に実装できる。pgrx 自体の注目度によるスター流入も期待できる |
| 対応バージョン | PostgreSQL 14–18 | pgrx のサポート範囲に準拠 |
| 配布 | pgxn / apt・rpm(pgdg 互換)/ Docker イメージ / Pigsty・Trunk 登録 | 「試すまで 1 分」を担保 |
| テスト | pgrx test + pgTAP、CI で全対応バージョン × amd64/arm64 | |
| ライセンス | PostgreSQL License または Apache-2.0 | 商用フォークにも採用されやすく、エコシステム標準 |

---

## 5. 制約と正直な告知(README に明記)

1. `wal_level = logical` と `shared_preload_libraries = 'pg_undo'` が必要(再起動 1 回)。
2. `REPLICA IDENTITY FULL` により、track 対象テーブルの UPDATE/DELETE の WAL 量が増える(旧行全体が載る)。幅広テーブルでは顕著。→ ベンチマーク結果を README に掲載(隠さないことが信頼につながる)。
3. 履歴分のディスクを消費する(書き込み量 × retention に比例)。
4. DDL の undo は DROP TABLE(ごみ箱)のみ。ALTER の巻き戻しはスコープ外(v1 では)。
5. バックアップの代替ではない。**「論理誤操作の高速復旧」専用**。

---

## 6. ロードマップ

| バージョン | 内容 |
|---|---|
| v0.1 (MVP) | track/untrack、履歴収集 bgworker、`recent_changes`、`preview` / `apply`(xid・時間範囲)、janitor | 
| v0.2 | タイムトラベル(`as_of`、スナップショットビュー)、`by_role` フィルタ |
| v0.3 | ごみ箱(DROP 横取り + restore)、TRUNCATE 対応 |
| v0.4 | 圧縮強化(列指向な差分格納)、履歴の外部オフロード(S3)検討 |
| v1.0 | 安定化、マネージドサービス(Supabase/Neon/RDS 相当環境)での動作マトリクス公開 |

---

## 7. スター獲得戦略

1. **README 冒頭に「やらかし→復旧」の 15 秒 GIF**。`DELETE FROM users;` → 顔面蒼白 → `undo.apply()` → 復活、のストーリー。
2. **ワンライナー体験**:`docker run -e POSTGRES_PASSWORD=x ghcr.io/<org>/pg_undo` で即試せるイメージ。
3. **ローンチ**:Show HN(タイトル案: *"Show HN: pg_undo – Ctrl+Z for PostgreSQL"*)、/r/PostgreSQL、Postgres Weekly、ブログ「How we built an undo button for Postgres with logical decoding」。
4. **比較表で立ち位置を明確化**:PITR / temporal_tables / pg_dirtyread / Oracle Flashback との対比(§1.3 の表を英語化して掲載)。
5. **オーバーヘッドの実測値を公開**:pgbench での TPS 影響・WAL 増加率。誠実さは DBA コミュニティで最も効く。
6. **エコシステム登録**:PGXN、Pigsty、Trunk、Supabase/Neon の extension request。
7. 名前の由来がそのまま検索性になる:`pg_undo` は「postgres undo」の検索を総取りできる。

---

## 8. リスクと対応

| リスク | 対応 |
|---|---|
| 本家 Postgres が将来 temporal / flashback を実装 | 数年単位の先の話(SQL:2011 AS OF は v18 時点でも未実装)。それまでに獲得したユーザーと運用ノウハウが資産になる |
| REPLICA IDENTITY FULL のオーバーヘッドが嫌われる | PG16+ の replica identity index 活用、track 時に「キー列のみモード」(undo 精度とのトレードオフ)を提供 |
| マネージドサービスで shared_preload_libraries を設定できない | トリガーベースのフォールバックモード(機能限定)を v0.4 で検討 |
| 履歴テーブル自体の肥大 | max_history_size の強制 + フェイルセーフ停止(§3.6) |
