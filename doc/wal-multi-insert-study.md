# heap_multi_insert の WAL 実装 学習ドキュメント

## 目的

`heap_multi_insert` の WAL を「複数ページ集約（複数ページ分のタプルを 1 つの WAL レコードにまとめる）」という方向で最適化することを想定し、まず WAL の読み書きに必要な基礎知識を習得する。

---

## 1. WAL とは何か

### 1.1 基本原則

**Write-Ahead Log (WAL)** の根本的な前提は「データページへの変更をディスクに書き出す前に、ログエントリを安定ストレージに書き出す」ことである（`src/backend/access/transam/README` より）。

```
A basic assumption of a write AHEAD log is that log entries must reach stable
storage before the data-page changes they describe.
```

クラッシュリカバリは「WAL の末尾まで再生すれば、トランザクションが中途半端に適用されていない一貫した状態に戻る」ことで実現される。

### 1.2 LSN (Log Sequence Number)

各データページ（ヒープ・インデックスどちらも）には、そのページに最後に影響を与えた WAL レコードの位置を示す **LSN** が書き込まれている。

- バッファマネージャがダーティページを書き出す前に、`page.LSN` まで WAL がフラッシュされていることを保証する
- リカバリ時に「このレコードはすでに適用済みか」を `page.LSN >= record.LSN` で判定する

### 1.3 Full Page Write (FPI)

チェックポイント後の **最初の変更** は、ページ全体のコピー（Full Page Image）を WAL に含める。これは電源断などで書き込み中のページが破損（torn page）した場合に備えるためである。

FPI を含む条件：
- `full_page_writes = on` または オンラインバックアップ実行中
- 前回チェックポイント以降、そのページへの最初の変更

---

## 2. WAL レコードのフォーマット

### 2.1 物理レイアウト

`src/include/access/xlogrecord.h` のコメントより：

```
XLogRecord          (固定長ヘッダ、28 バイト)
XLogRecordBlockHeader × N   (変更したバッファの数だけ)
XLogRecordDataHeader[Short|Long]
ブロックデータ × N
メインデータ
```

### 2.2 XLogRecord（固定ヘッダ）

```c
/* src/include/access/xlogrecord.h:41 */
typedef struct XLogRecord
{
    uint32      xl_tot_len;   /* レコード全体のバイト長 */
    TransactionId xl_xid;    /* このレコードを生成したトランザクション ID */
    XLogRecPtr  xl_prev;     /* 直前の WAL レコードの LSN（ログのリンクリスト） */
    uint8       xl_info;     /* フラグビット: 上位4bit = RmgrInfo, 下位4bit = 汎用フラグ */
    RmgrId      xl_rmid;     /* リソースマネージャ ID（どの機能のレコードか） */
    /* 2 バイトパディング */
    pg_crc32c   xl_crc;      /* CRC-32C（破損検出） */
} XLogRecord;
```

`xl_rmid` で「どのコンポーネントの WAL か」を識別する。ヒープ操作は `RM_HEAP_ID` / `RM_HEAP2_ID`、インデックスなら各インデックスの ID が使われる。

### 2.3 XLogRecordBlockHeader（バッファ参照）

```c
/* src/include/access/xlogrecord.h:103 */
typedef struct XLogRecordBlockHeader
{
    uint8   id;           /* block_id（0〜32、XLogRegisterBuffer() で指定した番号） */
    uint8   fork_flags;   /* フォーク番号 + フラグ */
    uint16  data_length;  /* バッファに紐付いたペイロードのバイト長（FPI は含まず） */
    /* BKPBLOCK_HAS_IMAGE の場合は XLogRecordBlockImageHeader が続く */
    /* BKPBLOCK_SAME_REL でない場合は RelFileLocator が続く */
    /* BlockNumber が続く */
} XLogRecordBlockHeader;
```

1 つの WAL レコードは最大 **XLR_MAX_BLOCK_ID+1 個**（デフォルト 5 個、`XLogEnsureRecordSpace()` で拡張可能）のバッファ参照を持てる。

---

## 3. WAL レコード構築 API

WAL レコードの作成は以下の 5 関数で行う（`src/backend/access/transam/xloginsert.c`）。

### 3.1 XLogBeginInsert()（line 153）

WAL レコード構築を開始する。以降の `XLogRegister*` 呼び出しの前に必ず 1 回呼ぶ。

```c
void XLogBeginInsert(void);
```

内部ステートをリセットし `begininsert_called = true` にする。クリティカルセクションの**前**に呼ぶ。

### 3.2 XLogRegisterBuffer()（line 246）

変更したバッファ（ページ）を登録する。

```c
void XLogRegisterBuffer(uint8 block_id, Buffer buffer, uint8 flags);
```

| フラグ | 意味 |
|--------|------|
| `REGBUF_STANDARD` | 標準ページレイアウト。`pd_lower`〜`pd_upper` の空き領域を FPI から省略し WAL を削減する |
| `REGBUF_WILL_INIT` | REDO 時にページを完全に再初期化する。FPI を取らない（`REGBUF_NO_IMAGE` 相当） |
| `REGBUF_NO_IMAGE` | FPI を取らない（torn-page 対策なし。特殊なケースのみ） |
| `REGBUF_KEEP_DATA` | FPI を取った場合でも、BufData をレコードに含める（論理デコード用） |
| `REGBUF_FORCE_IMAGE` | 常に FPI を取る（ページの大部分を書き換える場合など） |

`block_id` は 0 始まりの番号で、後述の `XLogRegisterBufData()` や REDO 関数内の `XLogRecGetBlockData()` で同じ番号を使って参照する。

### 3.3 XLogRegisterData()（line 372）

特定のバッファに紐付かない「メインデータ」を登録する。

```c
void XLogRegisterData(const void *data, uint32 len);
```

複数回呼ぶと連結される。REDO 関数では `XLogRecGetData()` で取得する。

### 3.4 XLogRegisterBufData()（line 413）

特定の `block_id` に紐付いたデータを登録する。

```c
void XLogRegisterBufData(uint8 block_id, const void *data, uint32 len);
```

FPI が取られた場合、このデータは**除外される**（`REGBUF_KEEP_DATA` を付けた場合を除く）。REDO 関数では `XLogRecGetBlockData()` で取得する。

### 3.5 XLogInsert()（line 482）

WAL レコードをファイナライズしてログに書き込む。戻り値は書き込んだレコードの終端 LSN。

```c
XLogRecPtr XLogInsert(RmgrId rmid, uint8 info);
```

内部で `XLogRecordAssemble()` によりレコードを組み立て、FPI の要否を判定し、`XLogInsertRecord()` でリングバッファに書き込む。

### 3.6 標準的な使用パターン

```c
/* クリティカルセクション外（XLogEnsureRecordSpace が必要な場合） */
XLogEnsureRecordSpace(max_block_id, ndatas);

START_CRIT_SECTION();
/* 1. ページを変更する */
/* 2. MarkBufferDirty() */

/* 3. WAL レコードを構築・書き込む */
XLogBeginInsert();
XLogRegisterBuffer(0, buffer, REGBUF_STANDARD);
XLogRegisterData(&xlrec, sizeof(xlrec));
XLogRegisterBufData(0, tuple->data, tuple->len);
recptr = XLogInsert(RM_FOO_ID, XLOG_FOO_ACTION);

/* 4. ページ LSN を更新する */
PageSetLSN(page, recptr);

END_CRIT_SECTION();
```

**重要**: `MarkBufferDirty()` は `XLogInsert()` より**前**に呼ぶ。これはバッファマネージャが WAL フラッシュ前にページを書き出さないようにするための LSN インターロックが `MarkBufferDirty()` の時点で機能するためである。

---

## 4. heap_multi_insert の WAL 実装詳細

### 4.1 ファイルと関数の位置

| 関数 | ファイル | 行番号 |
|------|----------|--------|
| `heap_multi_insert()` | `src/backend/access/heap/heapam.c` | 2282 |
| `heap_xlog_multi_insert()` (REDO) | `src/backend/access/heap/heapam_xlog.c` | 492 |

### 4.2 WAL レコードの構造体

`src/include/access/heapam_xlog.h`

```c
/* line 183: メインデータ部（xl_heap_multi_insert ヘッダ） */
typedef struct xl_heap_multi_insert
{
    uint8       flags;     /* 制御フラグ（下記参照） */
    uint16      ntuples;   /* このレコードに含まれるタプル数 */
    OffsetNumber offsets[FLEXIBLE_ARRAY_MEMBER]; /* 各タプルのオフセット番号 */
} xl_heap_multi_insert;
/* XLOG_HEAP_INIT_PAGE の場合は offsets[] を省略（順番に FirstOffsetNumber から割り当て） */

/* line 192: 各タプルのヘッダ（ブロックデータ部に格納） */
typedef struct xl_multi_insert_tuple
{
    uint16  datalen;      /* タプルデータのバイト長（HeapTupleHeader 部は除く） */
    uint16  t_infomask2;  /* タプルヘッダフィールド */
    uint16  t_infomask;
    uint8   t_hoff;
    /* TUPLE DATA FOLLOWS AT END OF STRUCT */
} xl_multi_insert_tuple;
```

**フラグ値**（`src/include/access/heapam_xlog.h:69`）：

```c
#define XLH_INSERT_ALL_VISIBLE_CLEARED   (1<<0)  /* PD_ALL_VISIBLE をクリアした */
#define XLH_INSERT_LAST_IN_MULTI         (1<<1)  /* このバッチの最後のレコード */
#define XLH_INSERT_IS_SPECULATIVE        (1<<2)  /* speculative insert（multi_insert では未使用） */
#define XLH_INSERT_CONTAINS_NEW_TUPLE    (1<<3)  /* 論理デコード用：タプルデータを含む */
#define XLH_INSERT_ON_TOAST_RELATION     (1<<4)  /* TOAST テーブルへの挿入（未使用） */
#define XLH_INSERT_ALL_FROZEN_SET        (1<<5)  /* 全タプルが freeze 済み */
```

**レコードタイプ識別子**：

```c
#define XLOG_HEAP2_MULTI_INSERT  0x50   /* RM_HEAP2_ID と組み合わせて使用 */
```

### 4.3 WAL レコードの物理レイアウト（1 ページ分）

```
XLogRecord（固定ヘッダ）
XLogRecordBlockHeader  [id=0: ヒープページ]
  └─ (FPI の場合) XLogRecordBlockImageHeader
XLogRecordBlockHeader  [id=1: VM ページ]  ← all_frozen_set の場合のみ
  └─ (FPI の場合) XLogRecordBlockImageHeader
XLogRecordDataHeader
メインデータ:
  xl_heap_multi_insert { flags, ntuples }
  OffsetNumber offsets[ntuples]            ← INIT_PAGE の場合は省略
ブロック 0 のデータ（タプルデータ）:
  xl_multi_insert_tuple { datalen, ... }   ← 各タプルの小ヘッダ
  タプルデータ（bitmap + data）
  xl_multi_insert_tuple { datalen, ... }   ← 2 タプル目
  タプルデータ
  ...
ブロック 1 のデータ（VM ページ）         ← all_frozen_set の場合のみ
```

### 4.4 WAL 構築コードの詳細（heapam.c:2469〜2593）

```c
if (needwal)
{
    XLogRecPtr  recptr;
    xl_heap_multi_insert *xlrec;
    uint8       info = XLOG_HEAP2_MULTI_INSERT;
    char       *tupledata;
    int         totaldatalen;
    char       *scratchptr = scratch.data;  /* スタック上の一時バッファ */
    bool        init;
    int         bufflags = 0;

    /* 空ページへの挿入なら INIT_PAGE: ページを再初期化して FPI を省略 */
    init = starting_with_empty_page;

    /* scratch バッファに xl_heap_multi_insert ヘッダを確保 */
    xlrec = (xl_heap_multi_insert *) scratchptr;
    scratchptr += SizeOfHeapMultiInsert;

    /* INIT_PAGE でない場合は offsets[] の領域を確保 */
    if (!init)
        scratchptr += nthispage * sizeof(OffsetNumber);

    /* タプルデータの書き始め位置を記録 */
    tupledata = scratchptr;

    /* フラグとタプル数を設定 */
    xlrec->flags = 0;
    if (all_visible_cleared)
        xlrec->flags = XLH_INSERT_ALL_VISIBLE_CLEARED;
    if (all_frozen_set)
        xlrec->flags = XLH_INSERT_ALL_FROZEN_SET;
    xlrec->ntuples = nthispage;

    /* 各タプルの小ヘッダとデータを scratch バッファに書き出す */
    for (i = 0; i < nthispage; i++)
    {
        HeapTuple heaptup = heaptuples[ndone + i];
        xl_multi_insert_tuple *tuphdr;
        int datalen;

        if (!init)
            xlrec->offsets[i] = ItemPointerGetOffsetNumber(&heaptup->t_self);

        /* 2 バイトアライメント */
        tuphdr = (xl_multi_insert_tuple *) SHORTALIGN(scratchptr);
        scratchptr = ((char *) tuphdr) + SizeOfMultiInsertTuple;

        tuphdr->t_infomask2 = heaptup->t_data->t_infomask2;
        tuphdr->t_infomask  = heaptup->t_data->t_infomask;
        tuphdr->t_hoff      = heaptup->t_data->t_hoff;

        /* HeapTupleHeader の後のデータのみをコピー（bitmap + OID + 列データ） */
        datalen = heaptup->t_len - SizeofHeapTupleHeader;
        memcpy(scratchptr,
               (char *) heaptup->t_data + SizeofHeapTupleHeader,
               datalen);
        tuphdr->datalen = datalen;
        scratchptr += datalen;
    }
    totaldatalen = scratchptr - tupledata;

    /* 論理デコード用フラグ */
    if (need_tuple_data)
        xlrec->flags |= XLH_INSERT_CONTAINS_NEW_TUPLE;
    /* このバッチの最後のレコードか */
    if (ndone + nthispage == ntuples)
        xlrec->flags |= XLH_INSERT_LAST_IN_MULTI;

    if (init)
    {
        info     |= XLOG_HEAP_INIT_PAGE;
        bufflags |= REGBUF_WILL_INIT;
    }
    if (need_tuple_data)
        bufflags |= REGBUF_KEEP_DATA;

    /* WAL レコードの組み立てと書き込み */
    XLogBeginInsert();
    XLogRegisterData(xlrec, tupledata - scratch.data);     /* メインデータ（ヘッダ + offsets） */
    XLogRegisterBuffer(0, buffer, REGBUF_STANDARD | bufflags);  /* ヒープページ */
    if (all_frozen_set)
        XLogRegisterBuffer(1, vmbuffer, 0);                /* VM ページ */

    XLogRegisterBufData(0, tupledata, totaldatalen);       /* タプルデータ */

    XLogSetRecordFlags(XLOG_INCLUDE_ORIGIN);               /* 論理レプリケーション用 */

    recptr = XLogInsert(RM_HEAP2_ID, info);

    /* ページ LSN を更新 */
    PageSetLSN(page, recptr);
    if (all_frozen_set)
        PageSetLSN(BufferGetPage(vmbuffer), recptr);
}
```

### 4.5 タプルデータの省略

WAL に書くタプルデータは**完全な HeapTuple ではない**。以下のフィールドは WAL に含めず REDO 時に再構築する：

| フィールド | 省略理由 |
|----------|---------|
| `t_xmin` | `XLogRecGetXid()` で取得 |
| `t_cmin` | 常に `FirstCommandId` |
| `t_ctid` | ブロック番号とオフセット番号から再構築 |

これにより WAL サイズを削減している。

---

## 5. REDO 関数（heap_xlog_multi_insert）の動作

`src/backend/access/heap/heapam_xlog.c:492`

REDO ルーティンは以下の手順でページを再構築する：

```c
static void
heap_xlog_multi_insert(XLogReaderState *record)
{
    /* 1. メインデータからレコードヘッダを取得 */
    xlrec = (xl_heap_multi_insert *) XLogRecGetData(record);
    XLogRecGetBlockTag(record, 0, &rlocator, NULL, &blkno);

    /* 2. ALL_VISIBLE_CLEARED なら VM をクリア */
    if (xlrec->flags & XLH_INSERT_ALL_VISIBLE_CLEARED)
        visibilitymap_clear(...);

    /* 3. ページを取得または初期化 */
    if (isinit)  /* XLOG_HEAP_INIT_PAGE フラグがある場合 */
    {
        buffer = XLogInitBufferForRedo(record, 0);
        PageInit(page, ...);
        action = BLK_NEEDS_REDO;
    }
    else
        action = XLogReadBufferForRedo(record, 0, &buffer);
        /* BLK_DONE: page.LSN >= record.LSN → スキップ */
        /* BLK_RESTORED: FPI から復元済み → スキップ */
        /* BLK_NEEDS_REDO: redo が必要 */

    /* 4. タプルを復元 */
    if (action == BLK_NEEDS_REDO)
    {
        tupdata = XLogRecGetBlockData(record, 0, &len);  /* ブロック 0 のデータ */

        for (i = 0; i < xlrec->ntuples; i++)
        {
            offnum = isinit ? FirstOffsetNumber + i : xlrec->offsets[i];

            xlhdr = (xl_multi_insert_tuple *) SHORTALIGN(tupdata);
            /* HeapTupleHeader を tbuf に構築 */
            htup->t_infomask2 = xlhdr->t_infomask2;
            htup->t_infomask  = xlhdr->t_infomask;
            htup->t_hoff      = xlhdr->t_hoff;
            HeapTupleHeaderSetXmin(htup, XLogRecGetXid(record)); /* WAL ヘッダから xid を復元 */
            HeapTupleHeaderSetCmin(htup, FirstCommandId);
            ItemPointerSetBlockNumber(..., blkno);
            ItemPointerSetOffsetNumber(..., offnum);

            PageAddItem(page, htup, newlen, offnum, true, true);
        }

        PageSetLSN(page, lsn);
        /* ALL_FROZEN_SET なら PageSetAllVisible(page) */
        MarkBufferDirty(buffer);
    }

    /* 5. ALL_FROZEN_SET なら VM ページも更新（block_id=1） */
    if (xlrec->flags & XLH_INSERT_ALL_FROZEN_SET)
        XLogReadBufferForRedoExtended(record, 1, ...);

    /* 6. 空き領域が少ない場合は FSM を更新 */
    if (action == BLK_NEEDS_REDO && freespace < BLCKSZ / 5)
        XLogRecordPageWithFreeSpace(rlocator, blkno, freespace);
}
```

---

## 6. 現在の実装の動作フロー（1 回の heap_multi_insert 呼び出し）

```
heap_multi_insert(ntuples 個のタプル)
│
├─ タプルの準備（TOAST、ヘッダ設定）
│
└─ ループ: ページがなくなるまで
    │
    ├─ RelationGetBufferForTuple()  ← 空き領域のあるページを取得
    ├─ START_CRIT_SECTION()
    │
    ├─ RelationPutHeapTuple()       ← 1 個目を挿入
    ├─ ループ: ページに入る限り追加挿入
    │
    ├─ visibility map 更新
    ├─ MarkBufferDirty()
    │
    ├─ [needwal] WAL レコード構築
    │   ├─ scratch バッファに xl_heap_multi_insert + offsets[] + タプルデータを書く
    │   ├─ XLogBeginInsert()
    │   ├─ XLogRegisterData()    ← メインデータ（ヘッダ + offsets）
    │   ├─ XLogRegisterBuffer()  ← ヒープページ（+ VM ページ）
    │   ├─ XLogRegisterBufData() ← タプルデータ
    │   └─ XLogInsert()          ← LSN を取得
    │
    ├─ PageSetLSN()
    ├─ END_CRIT_SECTION()
    ├─ UnlockReleaseBuffer()
    └─ ndone += nthispage
```

**ポイント**: 現在の実装では 1 ページにつき 1 つの WAL レコードが生成される。100 タプルが 5 ページにまたがる場合は 5 つの WAL レコードになる。

---

## 7. 複数ページ集約最適化の検討

### 7.1 アイデア概要

複数ページ分のタプルを 1 つの WAL レコードにまとめることで：
- WAL レコードのヘッダオーバーヘッドを削減
- WAL の書き込み回数を削減

### 7.2 技術的な課題

#### バッファ参照数の上限

`XLogRegisterBuffer()` で登録できる `block_id` の数はデフォルト 5 個（`XLR_NORMAL_MAX_BLOCK_ID + 1`）。複数ページを扱う場合は事前に `XLogEnsureRecordSpace()` で拡張が必要。

```c
/* クリティカルセクションの前に呼ぶこと */
XLogEnsureRecordSpace(npages - 1, ndatas);
```

#### クリティカルセクションの範囲

現在の実装はページごとにクリティカルセクションを開閉している。複数ページをまとめるには、複数ページすべてのバッファロックをまたいだクリティカルセクションが必要になり、ロック保持時間が長くなる。

#### REDO 関数の変更

新しい WAL レコード型（または既存型の拡張）に対応した REDO 関数が必要。各ページの `PageSetLSN()` は**同一の LSN**（1 回の `XLogInsert()` の戻り値）でよい。

#### メインデータ構造の変更

現在の `xl_heap_multi_insert` は 1 ページ前提。複数ページ対応のためには：

```
提案構造例:
xl_heap_multi_insert_mpages {
    uint8   nblocks;      /* 対象ページ数 */
    ...
}
ページごとのブロックデータ:
    xl_heap_multi_insert { flags, ntuples, offsets[] }
    xl_multi_insert_tuple + データ × ntuples
```

#### FPI の扱い

複数ページをまとめた場合でも、各ページの FPI は `XLogRegisterBuffer()` が自動的に判断する。ページごとに FPI の要否が異なるため、FPI を含んだページのタプルデータが WAL に含まれない（`REGBUF_WILL_INIT` または `REGBUF_KEEP_DATA` で制御）。

#### VM ページの扱い

`all_frozen_set` のページには追加で VM ページ（`block_id=1`）が必要。複数ページが all_frozen_set の場合、ページ数に比例して block_id が必要になる。

### 7.3 効果が見込めるシナリオ

- 大量の小さいタプルを COPY 等で一括挿入する場合
- WAL の書き込みレイテンシがボトルネックになっている場合
- ページが密に埋まっており FPI が発生しにくい場合（チェックポイント直後を除く）

### 7.4 効果が限定的なシナリオ

- FPI が頻繁に発生する場合（FPI の場合タプルデータは除外され、ページ全体をコピー）
- タプルが大きく 1 ページに 1〜2 タプルしか入らない場合

---

## 8. 参照先ファイル一覧

| ファイル | 内容 |
|---------|------|
| `src/backend/access/heap/heapam.c:2282` | `heap_multi_insert()` 本体 |
| `src/backend/access/heap/heapam_xlog.c:492` | `heap_xlog_multi_insert()` REDO 関数 |
| `src/include/access/heapam_xlog.h:175` | `xl_heap_multi_insert`, `xl_multi_insert_tuple` 構造体 |
| `src/include/access/xlogrecord.h:41` | `XLogRecord`, `XLogRecordBlockHeader` 構造体 |
| `src/backend/access/transam/xloginsert.c` | `XLogBeginInsert()` 等 WAL 構築 API |
| `src/backend/access/transam/README:399` | WAL 設計思想・コーディングガイド |
| `src/include/access/xlog_internal.h` | `XLogRecData` 構造体 |
| `src/include/access/xloginsert.h` | `REGBUF_*` フラグ定数 |
