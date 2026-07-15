# pg_stat_role ビュー設計書

ロール(ユーザー)ごとの累積統計情報を提供する新しいモニタリングビュー
`pg_stat_role` の設計書。

## 1. 背景と目的

現在のPostgreSQLには、ロール単位で活動量を追跡する累積統計の仕組みが存在しない。
`pg_stat_activity.usename` は「今この瞬間」の接続情報のみであり、
`pg_stat_database` はデータベース単位、`pg_stat_user_tables` はテーブル単位の
集計しか提供しない。そのため、次のような運用上の問いに答えられない。

- どのロールがどれだけトランザクションを実行しているか
- どのロールが接続時間・実行時間を多く消費しているか(マルチテナント環境での
  テナント別利用量の把握、課金・キャパシティプランニング)
- 特定ロールのロールバック率が異常に高くないか

`pg_stat_role` は、累積統計システム(Cumulative Statistics System, pgstat)に
新しい統計種別 `PGSTAT_KIND_ROLE` を追加し、ロールOIDをキーとする累積カウンタを
提供することでこれを解決する。

## 2. ビュー仕様

### 2.1 列定義

```sql
CREATE VIEW pg_stat_role AS
    SELECT
        r.oid AS roleid,
        r.rolname,
        s.xact_commit,
        s.xact_rollback,
        s.sessions,
        s.session_time,
        s.active_time,
        s.idle_in_transaction_time,
        s.stats_reset
    FROM pg_roles AS r,
         pg_stat_get_role_stats(r.oid) AS s;
```

| 列 | 型 | 説明 |
|---|---|---|
| `roleid` | `oid` | ロールのOID |
| `rolname` | `name` | ロール名 |
| `xact_commit` | `bigint` | このロールでコミットされたトランザクション数 |
| `xact_rollback` | `bigint` | このロールでロールバックされたトランザクション数 |
| `sessions` | `bigint` | このロールで確立されたセッション数 |
| `session_time` | `double precision` | このロールのセッションが費やした累計時間(ミリ秒) |
| `active_time` | `double precision` | SQL文の実行に費やした累計時間(ミリ秒) |
| `idle_in_transaction_time` | `double precision` | トランザクション内アイドルの累計時間(ミリ秒) |
| `stats_reset` | `timestamp with time zone` | 統計が最後にリセットされた時刻 |

ベースとなる catalog には、スーパーユーザー限定の `pg_authid` ではなく
全ユーザーが参照可能な `pg_roles` を用いる(`pg_stat_database` が
`pg_database` を用いるのと同様)。

統計エントリが存在しないロール(一度も活動していないロール)についても行は返し、
カウンタはすべて 0 / `stats_reset` は NULL とする
(`pg_stat_get_subscription_stats()` が未取得エントリに all-zero を返すのと同じ挙動)。

### 2.2 帰属モデル: current user と session user のどちらに計上するか

列によって帰属先を使い分ける。**トランザクション統計は current user
(`GetUserId()`)、セッション統計は session user(`GetSessionUserId()`)に帰属する。**

| 列グループ | 帰属先 | 捕捉タイミング |
|---|---|---|
| `xact_commit` / `xact_rollback` | **current user** (`GetUserId()`) | **トランザクション開始時**に捕捉 |
| `sessions` / `session_time` / `active_time` / `idle_in_transaction_time` | **session user** (`GetSessionUserId()`) | 接続確立時および統計フラッシュ時 |

設計理由:

- **トランザクション統計に current user を使う理由**: `SET ROLE` を用いた運用
  (共有ログインロール + 個別作業ロール、コネクションプーラ配下でのロール切替)
  では、「実際に作業したロール」は current user である。session user に統一すると
  この情報が失われる。
- **セッション統計に session user を使う理由**: セッションの確立・維持は認証された
  ロールの属性であり、セッション途中の `SET ROLE` とは無関係。また
  `pg_stat_activity.usename`(`backend_status.c` の
  `st_userid = GetSessionUserId()`)と整合する。

#### 捕捉タイミングに関する重要な制約

`xact_commit`/`xact_rollback` の計上フックである `AtEOXact_PgStat()` は
`CommitTransaction()` / `AbortTransaction()` から呼ばれるが、その**直前に**
`AtEOXact_GUC()` が実行される(`src/backend/access/transam/xact.c`:
commit 経路では line 2508 → 2518、abort 経路では line 3035 → 3045)。
`role` は GUC であるため、トランザクション終了処理の時点では:

- abort 経路: トランザクション内の `SET ROLE` はすでに巻き戻されている
- commit 経路: `SET LOCAL ROLE` はすでに巻き戻されている

つまり **`AtEOXact_PgStat()` の中で `GetUserId()` を呼ぶと、コミットとアボートで
帰属先が非対称になる**。これを避けるため、current user の捕捉は
`StartTransaction()` 時点で行い、バックエンドローカル変数
(`pgStatXactRoleId`)に保存しておく。トランザクション終了時はこの保存値に対して
計上する。

この方式の帰結として、**トランザクション途中の `SET ROLE` は、そのトランザクション
の計上先を変えない**(次のトランザクションから新ロールに計上される)。この挙動は
決定的で説明しやすく、ドキュメントに明記する。

また、`SECURITY DEFINER` 関数による一時的なユーザー切替はトランザクション境界では
必ず復元されているため、帰属に影響しない。

## 3. アーキテクチャ

### 3.1 統計種別 `PGSTAT_KIND_ROLE` の追加

ロールはクラスタ共通(データベース非依存)のオブジェクトであるため、既存の
`PGSTAT_KIND_SUBSCRIPTION`(`src/backend/utils/activity/pgstat_subscription.c`)
と同じ「可変数・クラスタ共通・永続化あり」の統計種別として実装する。

- Kind ID: `PGSTAT_KIND_ROLE = 14`
  (`src/include/utils/pgstat_kind.h`。現在の組み込み最大は
  `PGSTAT_KIND_WAL = 13`。`PGSTAT_KIND_BUILTIN_MAX` を `PGSTAT_KIND_ROLE` に
  更新する。カスタム種別領域は 24〜32 なので衝突しない)
- ハッシュキー: `PgStat_HashKey{ kind = PGSTAT_KIND_ROLE, dboid = InvalidOid,
  objid = ロールOID }`(`src/include/utils/pgstat_internal.h:58-64`)

`src/backend/utils/activity/pgstat.c` の `pgstat_kind_builtin_infos[]`
(line 283〜)への登録内容:

```c
[PGSTAT_KIND_ROLE] = {
    .name = "role",
    .fixed_amount = false,
    .write_to_file = true,               /* 再起動をまたいで永続化 */
    .accessed_across_databases = true,   /* クラスタ共通オブジェクト */

    .shared_size = sizeof(PgStatShared_Role),
    .shared_data_off = offsetof(PgStatShared_Role, stats),
    .shared_data_len = sizeof(((PgStatShared_Role *) 0)->stats),
    .pending_size = sizeof(PgStat_StatRoleEntry),

    .flush_pending_cb = pgstat_role_flush_cb,
    .reset_timestamp_cb = pgstat_role_reset_timestamp_cb,
},
```

### 3.2 データ構造

`src/include/pgstat.h` に追加(保存形式・pending 共用):

```c
typedef struct PgStat_StatRoleEntry
{
    PgStat_Counter xact_commit;
    PgStat_Counter xact_rollback;
    PgStat_Counter sessions;
    PgStat_Counter session_time;             /* マイクロ秒で蓄積 */
    PgStat_Counter active_time;
    PgStat_Counter idle_in_transaction_time;
    TimestampTz    stat_reset_timestamp;
} PgStat_StatRoleEntry;
```

`src/include/utils/pgstat_internal.h` に追加(共有メモリ側ラッパ。
`PgStatShared_Subscription`(line 517)と同形):

```c
typedef struct PgStatShared_Role
{
    PgStatShared_Common header;
    PgStat_StatRoleEntry stats;
} PgStatShared_Role;
```

### 3.3 データフロー

`pg_stat_database` の `xact_commit` が採用している
「バックエンドローカル蓄積 → pending エントリ → 共有メモリ」の2段階フラッシュを
ロールOIDキーで一般化する。

```
[トランザクション開始]
  StartTransaction()
    └─ pgStatXactRoleId = GetUserId() を捕捉               … 新規

[トランザクション終了(コミット/アボート)]
  CommitTransaction()/AbortTransaction() (xact.c:2518, 3045)
    └─ AtEOXact_PgStat(isCommit, parallel)
         └─ AtEOXact_PgStat_Role(isCommit, parallel)        … 新規
              └─ バックエンドローカルの per-role 蓄積域
                 (roleid → {commit, rollback} の小配列)に加算
                 ※ 共有メモリには触れない。parallel worker は計上しない
                   (pg_stat_database と同じ扱い)

[統計レポート(トランザクション外、pgstat.c:788 付近)]
  pgstat_report_stat()
    ├─ pgstat_update_dbstats()                              … 既存
    └─ pgstat_update_rolestats()                            … 新規
         ├─ 蓄積済みの各 roleid について
         │    pgstat_prep_pending_entry(PGSTAT_KIND_ROLE,
         │                              InvalidOid, roleid, NULL)
         │    で pending エントリを取得し、xact カウンタを折り込む
         ├─ セッション統計(session_time / active_time /
         │    idle_in_transaction_time)を GetSessionUserId() の
         │    pending エントリへ折り込む(pgstat_database.c:367-376 の
         │    pgStatActiveTime 等の折り込みと対をなす。既存のバックエンド
         │    ローカル統計は DB 用と共有できないため、ロール用に同種の
         │    ローカルカウンタを併設して同じ箇所で加算する)
         └─ ローカル蓄積域をクリア

  (pgstat 共通機構による pending → 共有メモリのフラッシュ)
    └─ pgstat_role_flush_cb(entry_ref, nowait)              … 新規
         pgstat_lock_entry() で共有エントリをロックし、
         PGSTAT_ACCUM_ROLECOUNT(field) マクロで全フィールドを加算後、
         pending を memset(0)
         (pgstat_database_flush_cb / pgstat_database.c:437-500 と同型)

[接続確立]
  pgstat_report_connect() 相当の経路
    └─ GetSessionUserId() の pending エントリの sessions++ … 新規
       (pgstat_database.c:247 の dbentry->sessions++ と対)

[参照]
  pg_stat_get_role_stats(oid)
    └─ pgstat_fetch_stat_roleentry(roleid)                  … 新規
         └─ pgstat_fetch_entry(PGSTAT_KIND_ROLE, InvalidOid, roleid)
```

`pgstat_report_stat()` には `Assert(!IsTransactionOrTransactionBlock())` があり
(`pgstat.c:732`)、この時点で `GetUserId()` は「実行中トランザクションのロール」を
意味しない。これが 2 段階方式(§2.2 の捕捉タイミング)を必須とする根拠である。

### 3.4 ロールのライフサイクル連携

`pgstat_xact.c` のトランザクショナルな create/drop 機構
(`pgstat_create_transactional` / `pgstat_drop_transactional`、
lines 360-387)を用いる。DROP がロールバックされた場合も統計は失われず、
ドロップはコミット/アボート WAL レコード経由でレプリカへも伝播する。

- `CreateRole()`(`src/backend/commands/user.c`)に `pgstat_create_role(roleid)`
  を追加(`pgstat_create_subscription` / `pgstat_subscription.c:77-88` と同型)。
- `DropRole()`(`user.c:1097`、`CatalogTupleDelete` は line 1314 付近)に
  `pgstat_drop_role(roleid)` → `pgstat_drop_transactional(PGSTAT_KIND_ROLE,
  InvalidOid, roleid)` を追加。`DeleteSharedComments` 等の既存クリーンアップと
  並べて呼ぶ。先例: `dropdb()` の `pgstat_drop_database()`
  (`src/backend/commands/dbcommands.c:1832`)。

ドロップ済みロールのOIDに対する遅延フラッシュで統計エントリが「復活」する競合は、
既存種別(サブスクリプション等)と同様に pgstat 共通機構が許容する範囲の挙動と
する(vacuum 相当のガベージコレクションは既存機構に従う)。

### 3.5 SQL関数

`src/backend/utils/adt/pgstatfuncs.c` に追加:

| 関数 | 内容 |
|---|---|
| `pg_stat_get_role_stats(oid) → record` | 1ロール分の統計レコードを返す。`pg_stat_get_subscription_stats`(pgstatfuncs.c:2306)と同型。エントリ未存在時は all-zero を返す |
| `pg_stat_reset_role_stats(oid)` | 引数NULLで全ロールの統計をリセット(`pgstat_reset_of_kind(PGSTAT_KIND_ROLE)`)、OID指定で単一ロールをリセット(`pgstat_reset(PGSTAT_KIND_ROLE, InvalidOid, roleid)`)。`pg_stat_reset_subscription_stats`(pgstatfuncs.c:2130-2152)と同型 |

`src/include/catalog/pg_proc.dat` エントリの要点:

- OID は `src/include/catalog/unused_oids` スクリプトで採番する
- `pg_stat_get_role_stats`: `provolatile => 's'`, `proparallel => 'r'`,
  `prorettype => 'record'`, `proargtypes => 'oid'`,
  `proallargtypes`/`proargmodes`/`proargnames` で出力列を宣言
  (`pg_stat_get_subscription_stats`(pg_proc.dat:5748)と同型)
- `pg_stat_reset_role_stats`: `provolatile => 'v'`, `proisstrict => 'f'`,
  `prorettype => 'void'`, `proacl => '{POSTGRES=X}'`(デフォルトは
  スーパーユーザーのみ実行可、GRANT可能)

### 3.6 可視性・権限

`pg_stat_database` と同様に、ビュー自体は全ユーザーが参照可能とする
(統計値は集計値でありSQL文の内容等の機微情報を含まないため)。
将来「自ロール分のみ可視」に絞る要件が出た場合は、ビュー定義への
`pg_read_all_stats` / `pg_has_role()` 条件の追加で対応可能である点を記載しておく。

リセットはデフォルトでスーパーユーザーのみ(§3.5 の `proacl`)。

### 3.7 永続化と互換性

- `.write_to_file = true` により、クリーンシャットダウン時に
  `pg_stat/pgstat.stat` へ書き出され、再起動後も維持される。
- 統計ファイル形式が変わるため `PGSTAT_FILE_FORMAT_ID`
  (`src/include/pgstat.h:221`)をバンプする。旧形式ファイルは起動時に
  破棄される(既存の互換性ポリシーどおり)。
- `pg_proc.dat` / `system_views.sql` の変更に伴い `CATALOG_VERSION_NO`
  (`src/include/catalog/catversion.h`)をバンプする。
- pg_upgrade: 累積統計は従来どおり引き継がれない(既存挙動に従う)。
- メモリ影響: ロール数 × (`PgStatShared_Role` ≒ 数十バイト + dshash
  オーバーヘッド)。エントリは dshash により動的確保されるため、
  ロール数が少ない一般的なクラスタへの影響は無視できる。

## 4. 変更ファイル一覧(実装チェックリスト)

| # | ファイル | 変更内容 |
|---|---|---|
| 1 | `src/include/utils/pgstat_kind.h` | `PGSTAT_KIND_ROLE 14` 追加、`PGSTAT_KIND_BUILTIN_MAX` 更新 |
| 2 | `src/include/pgstat.h` | `PgStat_StatRoleEntry`、関数宣言、`PGSTAT_FILE_FORMAT_ID` バンプ |
| 3 | `src/include/utils/pgstat_internal.h` | `PgStatShared_Role`、`pgstat_role_flush_cb` / `pgstat_role_reset_timestamp_cb` 宣言 |
| 4 | `src/backend/utils/activity/pgstat_role.c` **(新規)** | 蓄積・フラッシュ・fetch・create/drop・reset の実装 |
| 5 | `src/backend/utils/activity/Makefile`, `meson.build` | `pgstat_role.o` / `'pgstat_role.c'` を登録 |
| 6 | `src/backend/utils/activity/pgstat.c` | `pgstat_kind_builtin_infos[]` へ登録、`pgstat_report_stat()` から `pgstat_update_rolestats()` 呼び出し |
| 7 | `src/backend/access/transam/xact.c` ほか | `StartTransaction()` でのロールOID捕捉、`AtEOXact_PgStat()`(`pgstat_xact.c:39-60`)から `AtEOXact_PgStat_Role()` 呼び出し |
| 8 | `src/backend/commands/user.c` | `CreateRole` / `DropRole` に `pgstat_create_role` / `pgstat_drop_role` |
| 9 | `src/backend/utils/adt/pgstatfuncs.c` | `pg_stat_get_role_stats`、`pg_stat_reset_role_stats` |
| 10 | `src/include/catalog/pg_proc.dat` | 上記2関数のエントリ追加 |
| 11 | `src/backend/catalog/system_views.sql` | `CREATE VIEW pg_stat_role` |
| 12 | `src/include/catalog/catversion.h` | `CATALOG_VERSION_NO` バンプ |
| 13 | `doc/src/sgml/monitoring.sgml` | ビュー一覧表への行追加、詳細 `<sect2>`(`role="catalog_table_entry"` 形式)、リセット関数の記載 |
| 14 | `src/test/regress/sql/stats.sql`, `expected/stats.out` | 機能テスト追加 |
| 15 | `src/test/regress/expected/rules.out` | ビュー定義スナップショットの更新(必須。更新しないと `rules` テストが失敗する) |

## 5. テスト計画

`src/test/regress/sql/stats.sql` に追加する回帰テスト:

1. **基本参照**: `SELECT * FROM pg_stat_role WHERE rolname = current_user` が
   1行返ること。
2. **コミット/ロールバック計上**: テストロールを作成して `SET ROLE` し、
   コミットとロールバックを実行 → `pg_stat_force_next_flush()` +
   `pg_stat_clear_snapshot()` 後に `xact_commit` / `xact_rollback` の増分を確認
   (stats.sql 既存のカウンタ増分検証パターンに従う)。
3. **current user への帰属**: `SET ROLE` 後のトランザクションが session user では
   なく current user 側のロールに計上されることを確認。
4. **リセット**: `pg_stat_reset_role_stats(oid)` 単一リセット / NULL 全リセットで
   カウンタが0に戻り `stats_reset` が更新されることを確認。
5. **DROP ROLE 連携**: ロールのドロップ後に
   `pg_stat_have_stats('role', 0, <roleid>)` が false になること。
   ドロップをロールバックした場合に統計が残ること。
6. **未活動ロール**: 活動のないロールが all-zero / `stats_reset` NULL の行として
   現れること。
7. **永続化**(TAP テスト、`src/test/`): 再起動後に統計が維持されること
   (既存の stats 永続化 TAP テストへの追加)。

## 6. 制限事項と将来拡張

### 制限事項

- トランザクション途中の `SET ROLE` は当該トランザクションの帰属先を変えない
  (§2.2。トランザクション開始時点の current user に帰属)。
- prepared transaction(2PC)の `COMMIT PREPARED` は準備したバックエンドと別の
  セッション/ロールから実行され得る。第1版では 2PC のコミット/アボートは
  ロール統計に計上しない(`pg_stat_database` も 2PC では `xact_commit` の帰属が
  DB 単位なので問題にならないが、ロール単位では帰属が曖昧になるため)。
- コネクションプーラが単一ロールで接続を共有する構成では、ロール別の内訳は
  得られない(プーラ側で `SET ROLE` を使う構成であればトランザクション統計は
  分離される)。

### 将来拡張(第2段階)

- タプル操作数(`tuples_returned/fetched/inserted/updated/deleted`)、
  ブロックI/O(`blks_read/blks_hit`)、一時ファイル(`temp_files/temp_bytes`)、
  `deadlocks` のロール別集計。これらは executor / bufmgr / 一時ファイル管理の
  複数箇所にロール帰属の捕捉を追加する必要があり、`PgStat_StatRoleEntry` の
  フィールド追加(= `PGSTAT_FILE_FORMAT_ID` バンプ)で段階的に導入可能。
- `sessions_abandoned` / `sessions_fatal` / `sessions_killed` 相当の
  セッション終了内訳。
- `pg_stat_get_role_*` 形式のスカラアクセサ関数の追加(必要になった場合。
  `PG_STAT_GET_DBENTRY_INT64` マクロ(pgstatfuncs.c:1053)と同型)。
