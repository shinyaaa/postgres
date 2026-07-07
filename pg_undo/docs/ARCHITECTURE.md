# pg_undo アーキテクチャ詳細設計(as-built, v0.4)

本書は実装済みの pg_undo の詳細設計を記述する。企画段階の設計書(リポジトリルートの
`PG_UNDO_DESIGN.md`)とは異なり、**実装の実態を正**とする。対象バージョンは
PostgreSQL 19(19devel/19beta1)のみで、`pg_undo.h` がコンパイル時に強制する。

- v0.1: 履歴キャプチャ + DML undo(preview/apply)
- v0.2: ごみ箱(DROP TABLE の横取りと復元)
- v0.3: タイムトラベル(`undo.as_of`)
- v0.4: 巨大トランザクションのディスクスピル

---

## 1. 全体構成

```
┌────────────────────────────── PostgreSQL クラスタ ─────────────────────────────┐
│                                                                                │
│  各バックエンド(全DB)                                                          │
│  ┌──────────────────────────────┐                                              │
│  │ ProcessUtility フック         │  DROP TABLE → undo_trash へ退避(§7)          │
│  │ (pg_undo_drop.c)             │  ※拡張が入っているDBのみ作動                  │
│  └──────────────────────────────┘                                              │
│                                                                                │
│  アプリの DML ──▶ WAL ──▶ logical replication slot "pg_undo"                    │
│                              │                                                 │
│                              ▼  インプロセス消費(walsender/ネットワーク不使用)  │
│  ┌─────────────── pg_undo capture worker (bgworker, 1個/クラスタ) ────────────┐ │
│  │  naptime ループ:                                                           │ │
│  │   1. refresh_tracked_rels()   追跡relidをHTABへロード(自前トランザクション) │ │
│  │   2. run_capture_cycle()      WALデコード → プラグインがメモリへバッファ    │ │
│  │        │   (閾値超過分はスピルファイルへ / §3.6)                            │ │
│  │        └─ flush_completed_txns()  自前トランザクションで undo.history へ    │ │
│  │           INSERT → COMMIT 後に slot confirm(§3.4 exactly-once)             │ │
│  │   3. maybe_run_janitor()      retention GC / failsafe / ごみ箱GC(§8)       │ │
│  └────────────────────────────────────────────────────────────────────────────┘ │
│                              ▲                                                 │
│  SQL API(すべてSQL/plpgsql): undo.track/untrack, recent_changes,               │
│    preview/apply, as_of/create_snapshot_view, trash/restore_dropped/purge      │
└────────────────────────────────────────────────────────────────────────────────┘
```

モジュールは1つの共有ライブラリ `pg_undo.so` で、以下の4役を兼ねる:

| ソース | 役割 |
|---|---|
| `pg_undo.c` | `_PG_init`: GUC定義、bgworker登録、ProcessUtilityフック設置 |
| `pg_undo_worker.c` | キャプチャワーカー本体(slot管理・デコードループ・flush・janitor・スピル読み戻し) |
| `pg_undo_plugin.c` | logical decoding 出力プラグイン(バッファリング・タプル→JSON・スピル書き出し) |
| `pg_undo_drop.c` | ごみ箱(DropStmt 横取り) |

ワーカーとプラグインは**同一プロセスで動く**(ワーカーがスロットをインプロセス消費する)
ため、両者は `pg_undo.h` のプレーンなグローバル変数
(`undo_buffer_cxt` / `undo_completed_txns` / `undo_buffered_rows` / `undo_tracked_rels`)
で通信する。共有メモリは不要。

`shared_preload_libraries = 'pg_undo'` と `wal_level = logical` が前提。
ワーカーは `pg_undo.database` で指定した1データベースにのみ接続する
(履歴キャプチャは1DB限定。ごみ箱フックは拡張が CREATE されている全DBで作動する)。

---

## 2. なぜこの構成か(設計判断の記録)

1. **トリガー方式ではなく logical decoding**
   トリガーは書き込みトランザクションのクリティカルパスに入りコミットレイテンシを
   悪化させる。logical decoding は WAL から非同期に読むため書き込み側への影響が
   小さく、テーブルごとのトリガー設置も不要になる。
2. **walsender ではなくインプロセス消費**
   外部プロセスやレプリケーション接続を要求しない。`pg_logical_slot_get_changes()`
   の実装(`logicalfuncs.c`)と同じ手順を bgworker 内で実行する。
3. **出力プラグインは「何も出力しない」**
   通常のプラグインは `OutputPluginWrite` で出力ストリームへ書くが、pg_undo は
   同一プロセスのグローバルバッファに直接積むため、writer コールバックは no-op
   スタブである。`pg_logical_slot_peek_changes('pg_undo', ...)` のような外部消費は
   startup コールバックで拒否する(ワーカーが読むべき変更が失われるため)。
4. **C関数のSQL APIはゼロ**
   preview/apply/as_of 等はすべて SQL/plpgsql。行イメージを jsonb で持ち、
   `jsonb_populate_record()`(=型の入力関数)で行型へ戻せるため、C を増やす
   必要がない。C の表面積はキャプチャ経路とフックに限定した。

---

## 3. キャプチャパイプライン

### 3.1 スロットのライフサイクル

- ワーカー起動時、`SearchNamedReplicationSlot("pg_undo")` で存在確認し、無ければ
  `create_logical_replication_slot()` と同じ手順で自作成する:
  `ReplicationSlotCreate(RS_EPHEMERAL)` → `CreateInitDecodingContext` →
  `DecodingContextFindStartpoint` → `ReplicationSlotPersist` → release。
  ワーカーは書き込み済みトランザクションの外にいるため
  「cannot create logical replication slot in transaction that has performed writes」
  の制約(logical.c)に抵触しない。
- **キャプチャはスロット作成時点から始まる**。`undo.ready()`(スロット存在確認)を
  提供し、README とテストは「ready を待ってから DML」を徹底する。

### 3.2 デコードループ(run_capture_cycle)

`pg_logical_slot_get_changes_guts()` を手本に、1サイクルで以下を行う:

```
end_of_wal = GetFlushRecPtr()
confirmed_flush >= end_of_wal なら即return(アイドル時の省力化)
ReplicationSlotAcquire("pg_undo")
ctx = CreateDecodingContext(InvalidXLogRecPtr, ...,
        XL_ROUTINE(.page_read = read_local_xlog_page_no_wait, ...),
        no-op writer × 2)
ctx->reader->private_data = &ReadLocalXLogPageNoWaitPrivate  ← 下記(a)
XLogBeginRead(reader, restart_lsn)                            ← 下記(b)
InvalidateSystemCaches()
while (reader->EndRecPtr < end_of_wal && !shutdown):
    record = XLogReadRecord()
    NULL なら end_of_wal 到達(a)または errm でエラー
    LogicalDecodingProcessRecord()
    バッファ行数 >= 1000 で flush_completed_txns()            ← 下記(c)
flush_completed_txns()
LogicalConfirmReceivedLocation(reader->EndRecPtr)             ← 下記(d)
FreeDecodingContext / InvalidateSystemCaches / release
バッファcontextをリセット、スピルsweep(§3.6)
```

- (a) **non-blocking リーダー**を使う。ブロッキング版 `read_local_xlog_page` は
  WAL末尾の部分レコード待ちでワーカーを無期限に停止させ得る(実際に janitor が
  止まる現象を v0.1 開発中に観測)。`read_local_xlog_page_no_wait` +
  `private_data->end_of_wal` 判定(pg_walinspect と同じイディオム)により、
  ポーリング型ワーカーがデコード中に眠り込むことはない。
  なお `ctx->reader->private_data` は本体側の decoding では参照されないため
  上書きして安全(調査済み)。
- (b) 読み開始は confirmed_flush ではなく **restart_lsn**。reorderbuffer が
  トランザクション全体を再構築するために必要で、出力されるのは
  confirmed_flush より後にコミットしたトランザクションだけ、という本体の
  規約に従う。
- (c) 中間 flush は**レコードとレコードの間**でのみ行う。デコードコールバックの
  内側では実行されない(§3.3)。
- (d) 最終 confirm はデコード済み末尾(EndRecPtr)まで進める。追跡対象外の
  テーブルだけが書かれている期間でもスロットが前進しないと WAL が
  溜まり続けるため。バッファ済みの内容はすべて直前の flush でコミット済み
  なので安全。

### 3.3 デコードコールバックの制約(このシステムの土台)

logical decoding のコールバックは、**historic snapshot** の下、**意図的に abort
されるトランザクション**の中で実行される(reorderbuffer.c。XID を取ると
`"output plugin used XID"` エラー)。ここから2つの絶対規則が導かれる:

1. **コールバック内からテーブルへ書けない** → 変更はメモリ(+スピルファイル)に
   バッファし、デコードの外でワーカー自身のトランザクションが適用する。
2. **コールバック内からユーザーテーブルを読めない**(読めるのはカタログのみ)→
   `undo.tracked_tables` をコールバックから引けないため、ワーカーが毎サイクル
   冒頭に自前トランザクションで relid を `undo_tracked_rels`(HTAB)へロードし、
   `change_cb` はハッシュだけを見る。track/untrack の反映は最大 naptime 遅れる
   (仕様として文書化)。

カタログアクセス(型の出力関数など)は historic snapshot が提供する正当な機能
であり、コールバック内で安全に使える(test_decoding / wal2json と同じ)。

### 3.4 exactly-once(重複ゼロ)の仕組み

再起動やクラッシュ後、デコードは restart_lsn から再開されるため、確認前の
トランザクションは**再送されうる**。重複防止は次の1点に集約される:

> `undo.progress.last_commit_end_lsn` を **履歴INSERTと同一トランザクションで**
> 更新し、`commit_end_lsn <= last_commit_end_lsn` のトランザクションは
> flush 時にスキップする。

スロットの confirm(`LogicalConfirmReceivedLocation`)は、この履歴トランザクション
の **COMMIT 後** にのみ行う。これにより:

- INSERT コミット後・confirm 前にクラッシュ → 再送されるが progress で弾く
- confirm 後にスロット状態のディスク書き込みが失われても → 再デコード+progress で弾く

つまり at-least-once な配送を progress LSN で exactly-once な適用に変換している。
ユニークインデックスによる重複排除は採らなかった(高頻度 INSERT への恒常的な
課税で、稀なクラッシュ窓を守ることになるため)。

### 3.5 行イメージの表現(タプル→JSON)

- `undo_tuple_to_json()` は全列を**型の出力関数 + `escape_json`** で JSON 文字列に
  する(`{"id": "1", "name": "alice"}` — 数値も文字列)。復元側は常に
  `jsonb_populate_record()`(=入力関数)を通すので、出力→入力のラウンドトリップ
  で損失がない。`datum_to_jsonb` を使わないのは、キャスト経由の任意関数実行を
  避け、挙動を決定的に保つため。
- **REPLICA IDENTITY FULL** を `undo.track()` が設定する。これにより UPDATE/DELETE
  の旧行全体が WAL に載る(トレードオフ: 追跡テーブルの WAL 増加)。
- **TOAST**: UPDATE で変更されなかった out-of-line 値は新タプル側に
  `VARATT_IS_EXTERNAL_ONDISK` マーカーとしてしか現れず、**デコード中に TOAST
  テーブルを追うことはできない**。旧タプル(RI FULL により flatten 済み・完全)を
  fallback として渡し、キャプチャ時にマージする。結果として `undo.history` の
  new_row は常に完全形である。
- dropped column(`attisdropped`)とシステム列は除外。

### 3.6 ディスクスピル(v0.4)

**問題**: 1トランザクションの全変更は `LogicalDecodingProcessRecord` 1回の中で
コールバックに流れ込む。中間 flush はレコード間でしか動けず、しかも未コミットの
トランザクションは書けないため、巨大トランザクションのイメージはメモリに積み
上がる。OOM でワーカーが死ぬと、再起動後も同じトランザクションで死ぬ
「毒薬クラッシュループ」になる。

**解決**: per-txn バッファが `pg_undo.spill_threshold`(既定256MB)を超えたら、
その時点の変更リストをファイルへ追記してメモリを解放する。

- **ファイルAPIの選定が核心**: コールバックは abort されるトランザクション内で
  走るため、リソースオーナー管理の一時ファイル(`OpenTemporaryFile`/`BufFile`)は
  その abort で消えてしまう。`OpenTransientFile` の fd は EOX(abort 含む)で
  close されるだけで**ファイル自体は unlink されない**(fd.c の `CleanupTempFiles`
  → `FreeDesc` は close のみ)。本体 reorderbuffer のスピルと同じく
  「名前付きファイル + 操作ごとに open→write→close 完結」で安全になる。
- **配置**: `base/pgsql_tmp/pgsql_tmp.pg_undo.xid-<xid>.spill`。
  `PG_TEMP_FILE_PREFIX`("pgsql_tmp")で始まる名前のため、**サーバ通常起動の
  たびに本体の `RemovePgTempFiles` が残骸を削除**する(クラッシュ後の最終防衛線)。
- **レコード形式**(packed, ホストバイトオーダー):
  `Oid relid, char op, XLogRecPtr change_lsn, int32 old_len(-1=NULL),
  int32 new_len(-1=NULL), old bytes, new bytes`。1MB 単位でバッファして write。
  短書き込みはエラー(errno==0 は ENOSPC 扱い、本体の定石)。
- **読み戻し**: flush の SPI トランザクション内で open→順次 read→1件ずつ
  INSERT→close(COMMIT 前に必ず close)。読み戻した件数が `nspilled` と一致
  しなければデータ破損としてエラー。
- **掃除の3層**: ①flush 後に unlink(dedupe スキップ・paused でも必ず)、
  ②ワーカー起動時とサイクル末に `pgsql_tmp.pg_undo.` プレフィックスを sweep
  (in-flight 分は次サイクルの再デコードで再生成されるため消して正しい)、
  ③サーバ起動時の本体掃除。
- durability は不要(クラッシュ = WAL から再デコードで再生成)なので fsync しない。

### 3.7 メモリ管理

| コンテキスト | 親 | 寿命・用途 |
|---|---|---|
| `undo_buffer_cxt` | TopMemoryContext | キャプチャバッファ。**サイクル末にのみ** reset(mid-flush では in-flight txn が参照中のため reset せず、flush 済み txn を個別 pfree) |
| `undo_hash_cxt` | TopMemoryContext | tracked HTAB。refresh のたびに reset + 再構築 |
| decoding cycle ctx | TopMemoryContext | `CreateDecodingContext` の生存域。flush のトランザクション COMMIT を跨いで生きる必要があるため、トランザクションコンテキストに置かない。サイクル末に delete |

---

## 4. スキーマ(undo / undo_trash)

| オブジェクト | 役割 |
|---|---|
| `undo.tracked_tables (relid PK, tracked_at, prev_replident)` | 追跡対象。prev_replident は untrack 時の復元用。`pg_extension_config_dump` 登録済み(pg_dump に含まれる) |
| `undo.progress (singleton)` | `last_commit_end_lsn`(dedupe 基準)、`capture_paused`、`paused_reason` |
| `undo.history (relid, change_lsn, commit_lsn, xid int8, changed_at, changed_by, op "char", old_row jsonb, new_row jsonb)` | 履歴本体。非パーティション。インデックス: `(relid, changed_at)`, `(xid)`, `(changed_at)`。changed_by は **常にNULL**(WALにロール情報が無い) |
| `undo.trash_meta (trash_relid PK, original_name, original_schema, dropped_at, dropped_by)` | ごみ箱メタ。dropped_by はフック実行時に取得できるため記録される |
| `undo_trash` スキーマ | 捨てられたテーブルの置き場 |
| 関数群 | すべて SQL/plpgsql。`REVOKE EXECUTE ... FROM PUBLIC`(§9) |

`op` は I/U/D/T(TRUNCATE)。T は行イメージを持たず**不可逆**である。

---

## 5. 逆DML生成と競合検出(preview/apply)

- セレクタ: `xid` または時間範囲(`last`/`since`/`until`)+ 任意の `"table"`。
  両方の指定はエラー。対象履歴は **`change_lsn` 降順(新しい順)** に処理する
  (同一行への複数変更を正しく巻き戻すための必須条件)。
- 逆操作:
  - `D` → `INSERT INTO t (書込可能列) [OVERRIDING SYSTEM VALUE] SELECT ... FROM jsonb_populate_record(NULL::t, old_row)`
    (generated column は列リストから除外、GENERATED ALWAYS identity があれば OVERRIDING)
  - `U` → `UPDATE t SET (書込可能列) = (SELECT ... FROM jsonb_populate_record(NULL::t, old_row)) WHERE <identity一致(new_row)>`
  - `I` → `DELETE FROM t WHERE <identity一致(new_row)>`
  - `T` → 生成不能。abort モードではエラー、skip では skipped 計上
- identity 一致は PK 列(無ければ全列)を `ROW(...) IS NOT DISTINCT FROM ROW(...)`
  で比較する。イメージ側は `jsonb_populate_record` で**行型を経由**させるため、
  「全値を文字列で保存」というキャプチャ表現と現在行の型付き値が正しく比較できる。
- **競合検出**(`undo._has_conflict`): 変更を巻き戻す前提条件が崩れていないかを
  行単位で確認する。
  - U/I の undo: 「post-change イメージ(new_row)と完全一致する行が現存する」
    ことが前提。無ければ競合(後から誰かが変更/削除した)。
  - D の undo: 同じ identity の行が既に存在すれば競合。
  - `on_conflict => 'abort'`(既定)は例外で全体ロールバック、`'skip'` は該当行を
    飛ばし、`'force'` は強行する。
- apply は**呼び出し元の単一トランザクション**で実行される。undo 自体も WAL に
  載る通常の DML なので、**undo の undo** が可能(検証済み)。

---

## 6. タイムトラベル(undo.as_of)の再構成アルゴリズム

時刻 T の状態は、行(identity = PK 値の text 配列)ごとに:

1. 履歴のうち `changed_at > T` の変更を**イベントへ分解**する:
   - I → その identity の `born`
   - D → `gone`(old_row 付き)
   - U(PK不変)→ `mod`(old_row 付き)
   - U(PK変更)→ 旧 identity の `gone` + 新 identity の `born`
2. identity ごとに **T後の最初のイベント**(`DISTINCT ON ... ORDER BY change_lsn`)を取る:
   - `mod`/`gone` → その old_row が「T時点の姿」→ `jsonb_populate_record` で行化して出力
   - `born` → T時点には存在しなかった → 出力しない
3. T後のイベントを一つも持たない現在行は、そのまま出力する。

- PK 値の比較は「イメージ側 `->> 'col'`(text)」対「現在行 `col::text`」で行う。
  キャプチャが全値を出力関数の text 表現で保存しているため、`::text` 経由で
  正確に一致する。
- 呼び出しはポリモーフィック(`undo.as_of(NULL::mytable, ts)` が
  `SETOF anyelement` を返す)ので、列定義リストが不要。
  `undo.create_snapshot_view()` は同じクエリを TEMP VIEW に包む。
- **ガード**: 未追跡・PK無し・`tracked_at` より前の時刻はエラー。
  **T より後に TRUNCATE がある場合もエラー**(T は行イメージを残さないため
  再構成不能。正直に拒否する)。
- 既知の意味論: スキーマは再構成しない(T以降に追加された列は再構成行で NULL)。
  直近 naptime 内の時刻は、まだ flush されていない変更を「イベント無し」と
  みなすため、わずかに新しい状態が混ざりうる。

---

## 7. ごみ箱(ProcessUtility フック)

イベントトリガーは DROP を「観測または全体abort」しかできず、**別のコマンドへの
置換**ができないため、ProcessUtility フックを使う(設計時に本体ソースで確認)。

### 7.1 横取りの条件(all-or-nothing、意図的に保守的)

次を**すべて**満たすときだけ DropStmt を横取りし、1つでも外れると文全体を
通常の DROP に素通しする:

- `pg_undo.recycle_bin = on`(PGC_SUSET: スーパーユーザーだけがセッションで無効化可能)
- 対象 DB に拡張(>=0.2、`undo_trash` スキーマ)が存在
- `removeType == OBJECT_TABLE` かつ **CASCADE でない**(CASCADE は「本気で消す」
  明示的な脱出ハッチとして温存)
- 全対象が「通常の永続ユーザーテーブル」: 一時テーブルでない・パーティション子
  でない・拡張所有でない・システム/undo/undo_trash スキーマでない
- `IF EXISTS` で存在しない対象は本体と同じ NOTICE を出して同様にスキップ

### 7.2 実行手順(undo_move_to_trash)

1. `RangeVarGetRelidExtended(AccessExclusiveLock)` で解決・ロック(実DROPと同じ)
2. **権限チェックは DROP と同一**: テーブル所有者またはスキーマ所有者
   (`object_ownercheck`)。満たさなければ `aclcheck_error`
3. その後 `SetUserIdAndSecContext(BOOTSTRAP_SUPERUSERID, ... | SECURITY_LOCAL_USERID_CHANGE)`
   で**内部的に昇格**(一般所有者は undo_trash への CREATE 権限を持たないため)。
   `PG_FINALLY` で必ず復元
4. SPI で以下を実行(SPI 経由の ALTER は再びフックを通るが DropStmt でないので素通り):
   - **所有シーケンスを oid サフィックス名へリネーム**(`pg_depend` の deptype
     'a'/'i' で列挙)
   - **全インデックスを oid サフィックス名へリネーム**(`pg_index` で列挙。
     制約名はテーブル毎の名前空間なので衝突せず、インデックスの pg_class 名だけが
     衝突源。これを潰さないと「drop→再作成→drop」や restore が
     `dt_pkey already exists` で失敗する — 実測で発見したバグ)
   - `ALTER TABLE ... RENAME TO <name>__<oid>` → `SET SCHEMA undo_trash`
     (SET SCHEMA は所有シーケンス・インデックスを道連れに移動する)
   - `undo.trash_meta` へ INSERT(dropped_by は昇格**前**のユーザー名)
5. `SetQueryCompletion(qc, CMDTAG_DROP_TABLE, 0)` を設定し、本体の DROP は
   呼ばずに return

### 7.3 意味論の差異(文書化済みの割り切り)

- RESTRICT の依存エラーは出ない(依存ビュー等はテーブルに従ってごみ箱でも
  機能し続ける)。drop イベントトリガーも発火しない。
- ごみ箱内テーブルは pg_dump に含まれる。
- restore(`undo.restore_dropped`)は `SET SCHEMA` + `RENAME` を戻し meta を消す
  だけ(同名の trash エントリは新しい順)。インデックス/シーケンス名の oid
  サフィックスは戻さない(cosmetic)。
- janitor が `pg_undo.trash_retention`(既定7日)超過を `DROP ... CASCADE` で完全削除。

---

## 8. janitor(自己保護)

`pg_undo.janitor_interval`(既定60秒)ごとに1トランザクションで実行:

1. **retention GC**: `DELETE FROM undo.history WHERE changed_at < now() - retention`
2. **ごみ箱GC**: `trash_retention` 超過エントリを DROP CASCADE + meta 削除、
   孤児 meta(テーブルが別経路で消えたもの)の掃除
3. **サイズ・フェイルセーフ**: `pg_total_relation_size('undo.history')` が
   `pg_undo.max_history_size` を超えたら `capture_paused = true` にして WARNING。
   **重要**: paused 中も flush は「INSERT だけをスキップ」し、progress 更新と
   slot confirm は続ける。キャプチャを完全に止めるとスロットが WAL を保持し
   続け、守るべき本体を危険に晒すため。解消すれば自動再開(状態遷移時のみログ)。

ワーカーのシャットダウンは `SignalHandlerForShutdownRequest` +
`while (!ShutdownRequestPending)`(autoprewarm 方式)。デコードループ内でも
shutdown をチェックする。エラー時はワーカーごと死んで `bgw_restart_time=10` で
再起動し、§3.4 の仕組みが整合性を回復する。

---

## 9. セキュリティモデル(v0.4 時点)

- `undo` スキーマと全関数は **superuser 専用**(スキーマに PUBLIC 権限なし、
  関数は EXECUTE を REVOKE)。履歴は全追跡データのコピーなので閲覧は特権。
- 例外は**ごみ箱への投入**: 一般ユーザーの DROP TABLE もフックが横取りする。
  権限モデルは「DROP できる者は bin に入れられる」(所有チェック後に内部昇格)。
  restore/purge/バイパス GUC は特権側に残る。
- ワーカーは bootstrap superuser として接続(`BackgroundWorkerInitializeConnection`
  の user=NULL)。
- RLS: 履歴は RLS を迂回して全行を保存する(閲覧が superuser 限定であることが
  前提。README に明記)。

---

## 10. 障害モデルまとめ

| 事象 | 挙動 |
|---|---|
| ワーカー kill -9 / クラッシュ | 10秒後に再起動 → restart_lsn から再デコード → progress LSN dedupe で重複ゼロ(検証済み) |
| 巨大トランザクション | 閾値超過分はスピル。メモリは有界。kill -9 を挟んでも exactly-once(検証済み) |
| historyの肥大 | フェイルセーフが記録を pause(WAL 消費は継続)、GC 後に自動再開 |
| デコード中のエラー | ワーカー再起動で回復。`PG_CATCH` で `InvalidateSystemCaches` してから re-throw |
| 拡張が未作成/DROPされた | ワーカーは待機/サイクルをスキップ(クラッシュループしない) |
| スピルファイルの残骸 | flush後unlink / ワーカーsweep(起動時・サイクル末)/ サーバ起動時の本体掃除の3層 |
| サーバ再起動 | スロットは永続。TAP で再起動後の無重複・継続キャプチャを検証 |

---

## 11. 既知の制約(意図的なトレードオフ)

- `changed_by` は NULL(WAL にロール情報が載らない。設計書の当初案は撤回)
- TRUNCATE は記録されるが不可逆。DDL undo は DROP TABLE のみ
- REPLICA IDENTITY FULL による追跡テーブルの WAL 増加
- 履歴は同一 DB 内(= バックアップの代替ではない。論理誤操作専用)
- キャプチャは track()/ready() から。それ以前の変更は遡れない
- as_of はデータのみ再構成(スキーマ変更は対象外)
- 対象は PostgreSQL 19 のみ(コンパイル時強制)

---

## 12. テスト戦略

| スイート | 対象 |
|---|---|
| regress `pg_undo` | track検証、I/U/D キャプチャ、TOAST完全性、recent_changes、preview非破壊、apply(xid/時間、競合3モード)、TRUNCATE、untrack。非同期性は `wait_for_history()`/`wait_ready()` ポーリングで吸収 |
| regress `recycle_bin` | drop→restore、serial継続、同名共存(oidサフィックス)、CASCADE/temp/GUCバイパス、依存ビューの挙動、非特権ユーザーの昇格経路と権限拒否、purge |
| regress `time_travel` | t0再構成(U巻き戻し/D復活/I不在)、PK更新の分解、snapshot view、全ガード、TRUNCATE前後 |
| TAP `001_undo_basic` | スロット存在、**サーバ再起動を跨いだ無重複+継続キャプチャ**、xid指定undoの復元一致 |
| TAP `002_spill` | 1MB閾値×4.5MBトランザクション → スピル発生(ログ確認)、全件キャプチャ、undo往復、残骸ゼロ |

エラーメッセージは regress の決定性のため、タイムスタンプ・xid 等の可変値を
含めない(実装時に修正済み)。

---

## 13. GUC 一覧

| GUC | 既定 | 文脈 | 用途 |
|---|---|---|---|
| `pg_undo.database` | postgres | POSTMASTER | ワーカーの接続先 |
| `pg_undo.enabled` | on | SIGHUP | キャプチャの主スイッチ |
| `pg_undo.naptime` | 1s | SIGHUP | サイクル間隔 |
| `pg_undo.retention` | 24 hours | SIGHUP | 履歴保持期間 |
| `pg_undo.max_history_size` | 10240MB | SIGHUP | フェイルセーフ閾値 |
| `pg_undo.janitor_interval` | 60s | SIGHUP | GC/フェイルセーフ間隔 |
| `pg_undo.spill_threshold` | 256MB | SIGHUP | per-txn スピル閾値 |
| `pg_undo.recycle_bin` | on | SUSET | DROP 横取りの有効化 |
| `pg_undo.trash_retention` | 7 days | SIGHUP | ごみ箱保持期間 |

---

## 14. 将来課題

- ストリーミングコールバック(`stream_*`)対応による in-progress デコード
  (スピルと組み合わせればさらに早期にメモリを解放できる)
- flush の `SPI_prepare` 化 / COPY 化(現状は行ごとに parse)
- `pg_undo_admin` ロールと非特権向け権限モデル
- 履歴のパーティション化(GC を DROP PARTITION に)
- マネージド環境向けのトリガーベース・フォールバック
- 独立リポジトリへの切り出し(本ディレクトリは PGXS 単体ビルド可能な構成済み)
