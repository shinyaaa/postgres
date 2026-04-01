# PostgreSQL WAL書き込みフロー詳細解説

## 1. 全体アーキテクチャ

WAL書き込みは大きく **3つのフェーズ** に分かれます：

```
[レコード組み立て] → [WALバッファへの挿入] → [ディスクへの書き出し・fsync]
```

主要ファイル：

- `src/backend/access/transam/xloginsert.c` — レコード組み立て・挿入API
- `src/backend/access/transam/xlog.c` — バッファ管理・書き出し・同期制御
- `src/backend/postmaster/walwriter.c` — WALライターバックグラウンドプロセス

---

## 2. フェーズ1: WALレコードの組み立て

呼び出し側（各バックエンド）が以下の順序でWALレコードを構築します：

| 関数 | ファイル | 役割 |
|------|---------|------|
| `XLogBeginInsert()` | `xloginsert.c:153` | 挿入開始の宣言。内部フラグを初期化 |
| `XLogRegisterBuffer()` | `xloginsert.c:246` | 変更されたバッファ（ページ）を登録。FPW判定用 |
| `XLogRegisterData()` | `xloginsert.c:372` | メインのWALレコードデータを登録 |
| `XLogRegisterBufData()` | `xloginsert.c:413` | バッファ固有のデータを登録 |
| `XLogInsert()` | `xloginsert.c:482` | **最終エントリポイント**。組み立て＋挿入を実行 |

`XLogInsert()` の内部では：

1. `GetFullPageWriteInfo()` でFull Page Write（FPW）が必要か判定
2. `XLogRecordAssemble()` （`xloginsert.c:620`）で `XLogRecData` チェーン（リンクリスト）を構築
   - `XLogRecord` ヘッダ → ブロックヘッダ → バックアップブロックイメージ → メインデータ
   - FPWが必要なページは圧縮付きで丸ごとバックアップ
3. 組み立てたチェーンを `XLogInsertRecord()` に渡す

---

## 3. フェーズ2: WALバッファへの挿入（`XLogInsertRecord()`）

**ファイル**: `xlog.c:750`

これが核心部分で、**2段階の処理**になっています：

### 段階A: 空間予約（スピンロック）

```c
SpinLockAcquire(&Insert->insertpos_lck);
  startbytepos = Insert->CurrBytePos;
  endbytepos = startbytepos + size;
  Insert->CurrBytePos = endbytepos;       // 予約完了
  Insert->PrevBytePos = startbytepos;     // xl_prevリンク用
SpinLockRelease(&Insert->insertpos_lck);
```

`ReserveXLogInsertLocation()` (`xlog.c:1115`) が担当。スピンロックは極めて短時間（2つの64bit値の更新のみ）で解放されるため、高スループットを実現しています。

「使用可能バイト位置」（ページヘッダを除いた論理バイト数）を使う設計で、ヘッダサイズを気にせずに単純な加算で予約できます。

### 段階B: データコピー（ロック不要で並行実行）

`CopyXLogRecordToWAL()` (`xlog.c:1232`) が担当：

1. `GetXLogBuffer()` でWALバッファ内の書き込み先ポインタを取得
2. `XLogRecData` チェーンを順に走査し、データをバッファにコピー
3. **ページ境界をまたぐ場合**：
   - 次ページのヘッダに `xlp_rem_len`（残りバイト数）を設定
   - `XLP_FIRST_IS_CONTRECORD` フラグを立てる
4. 各バックエンドは予約済みの排他領域に書くため、**この段階ではロック不要**

### WAL挿入ロック（並行性制御）

```c
typedef struct {
    LWLock           lock;
    pg_atomic_uint64 insertingAt;   // この挿入者がどこまで進んだか
    XLogRecPtr       lastImportantAt;
} WALInsertLock;
```

- **`NUM_XLOGINSERT_LOCKS = 8`** 個のロックをラウンドロビンで分散
- 各バックエンドは1つのロックだけ取得（`WALInsertLockAcquire()`、`xlog.c:1378`）
- `XLOG_SWITCH` やチェックポイントなど特殊操作時は全ロック取得（`WALInsertLockAcquireExclusive()`）
- `insertingAt` フィールドにより、フラッシュ側が「全挿入者がどこまで完了したか」を非破壊的に確認可能

---

## 4. WALバッファの管理

WALバッファは **リングバッファ** 構造です（`XLogCtlData.pages`）：

```
LSN → バッファインデックス = XLogRecPtrToBufIdx(ptr)
（同じLSNは常に同じバッファスロットにマップ）
```

| 構造体フィールド | 役割 |
|----------------|------|
| `pages` | 実際のWALページバッファ（XLOG_BLCKSZ = 8KB単位） |
| `xlblocks[]` | 各バッファスロットが保持するページの終端LSN（atomic） |
| `XLogCacheBlck` | バッファスロット数 - 1 |
| `InitializedUpTo` | 初期化済みの最新ページ位置 |

### ページ初期化: `AdvanceXLInsertBuffer()` (`xlog.c:1992`)

新しいページが必要になると：

1. `WALBufMappingLock` を排他取得
2. 古いページがまだ書き出されていなければ、先にフラッシュ（`XLogWrite()` 呼び出し）
3. ページをゼロクリアし、ヘッダを初期化（`xlp_magic`, `xlp_tli`, `xlp_pageaddr`）
4. セグメント先頭ページの場合はロングヘッダ（`XLP_LONG_HEADER`）を設定
5. メモリバリア付きで `xlblocks[]` を更新

---

## 5. フェーズ3: ディスクへの書き出しとfsync

### 5.1 同期コミット時: `XLogFlush()` (`xlog.c:2767`)

トランザクションコミット時に呼ばれ、指定LSNまでの永続化を保証します：

```
XLogFlush(LSN)
  ├─ 既にフラッシュ済みか確認（RefreshXLogWriteResult）
  ├─ WaitXLogInsertionsToFinish() で挿入完了を待機
  ├─ WALWriteLock を LWLockAcquireOrWait() で取得
  │   └─ 取得できなければ、先行者の完了を待って再確認（グループコミット）
  ├─ [CommitDelay] スリープして他トランザクションの便乗を待つ
  ├─ XLogWrite() で実際の書き出し
  │   ├─ 連続ページをバッチして pg_pwrite()
  │   └─ issue_xlog_fsync() でfsync
  └─ logWriteResult, logFlushResult をアトミック更新
```

### 5.2 グループコミットの仕組み

複数バックエンドが同時にコミットする場合：

1. **ロックピギーバック**: `LWLockAcquireOrWait()` でロック待ちしている間に、先行者がフラッシュを完了すれば自分はスキップ可能
2. **CommitDelay**: ロック取得後、`CommitDelay` マイクロ秒だけ待機。この間に他のバックエンドのWAL挿入が蓄積され、1回のfsyncで複数トランザクションを永続化

### 5.3 WALライター: `walwriter.c`

バックグラウンドで約200ms間隔で動作し、非同期コミットのWALを書き出します：

```
WalWriterMain()
  └─ ループ:
      ├─ XLogBackgroundFlush()
      │   ├─ 書き出し対象を計算（時間ベース or ブロック数ベース）
      │   ├─ WaitXLogInsertionsToFinish()
      │   ├─ WALWriteLock取得
      │   └─ XLogWrite() 実行
      └─ WalWriterDelay (200ms) or ハイバネーション (5000ms) スリープ
```

- `WalWriterFlushAfter` ブロック以上溜まるか、`WalWriterDelay` 経過でフラッシュ
- 50回連続で仕事がないとハイバネーションモード（スリープ25倍）

### 5.4 fsyncメカニズム: `issue_xlog_fsync()` (`xlog.c:8886`)

| 方式 | 関数 | 特徴 |
|------|------|------|
| `fsync` (デフォルト) | `pg_fsync_no_writethrough()` | データ+メタデータを同期 |
| `fdatasync` | `pg_fdatasync()` | データのみ同期（より効率的） |
| `fsync_writethrough` | `pg_fsync_writethrough()` | ディスクキャッシュも含めて同期 |
| `open_datasync` / `open_sync` | — (no-op) | O_DSYNC/O_SYNCフラグでwrite時に同期 |

---

## 6. LSN追跡の3段階

```
logInsertResult  ≥  logWriteResult  ≥  logFlushResult
  (バッファ挿入済)    (write済)          (fsync済・永続化)
```

すべて `pg_atomic_uint64` で管理され、ロックなしで読み取り可能。フラッシュ位置は必ず書き出し位置以下になるよう、メモリバリアで順序を保証しています。

---

## 7. WALセグメントファイル管理

- ファイル名パターン: `%08X%08X%08X`（タイムラインID、ログID、セグメント番号）
- `XLogFileInitInternal()` (`xlog.c:3213`) で事前作成
  - `wal_init_zero=on`: 全体をゼロ埋め（確実にディスク領域確保）
  - `wal_init_zero=off`: 末尾に1バイトだけ書く（スパースファイル、高速）
- テンポラリファイル `xlogtemp.PID` として作成後、アトミックリネーム

---

## 8. 全体フロー図

```
バックエンド                      共有メモリ                    ディスク

XLogBeginInsert()
XLogRegisterBuffer()
XLogRegisterData()
XLogInsert()
  ├─ XLogRecordAssemble()
  └─ XLogInsertRecord()
      ├─ WALInsertLockAcquire()   ─→ WALInsertLocks[n]
      ├─ ReserveXLogInsertLocation()
      │   └─ SpinLock            ─→ CurrBytePos更新
      ├─ CopyXLogRecordToWAL()   ─→ WALバッファ(pages[])
      │   └─ GetXLogBuffer()     ─→ xlblocks[] 確認/初期化
      └─ WALInsertLockRelease()  ─→ insertingAt更新
                                     │
  XLogFlush() (同期コミット時)       │
      ├─ WaitXLogInsertionsToFinish()│
      ├─ [CommitDelay]               │
      └─ XLogWrite()             ────┼──→  pg_pwrite()  ──→ WALファイル
          └─ issue_xlog_fsync()  ────┼──→  fsync()      ──→ 永続化
                                     │
  WALWriter (バックグラウンド)        │
      └─ XLogBackgroundFlush()   ────┘
```

---

## 9. 設計のポイント

この設計の核心は以下の点にあります：

1. **スピンロックの保持時間を最小化**: 空間予約のみ（2つの64bit値更新）
2. **データコピーはロックなし**: 各バックエンドは予約済みの排他領域に書き込む
3. **8個の挿入ロックで分散**: バックエンド数に依存しない固定数のロックで並行性を確保
4. **アトミック変数による3段階LSN追跡**: ロックなしで進捗状況を確認可能
5. **グループコミット**: CommitDelayとロックピギーバックで fsync コストを償却
6. **リングバッファ**: LSNからバッファインデックスへの決定的マッピングで高速アクセス
