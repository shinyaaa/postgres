# pg_subtrans の SLRU 廃止・dshash 化 — 実現可能性検討レポート

対象: PostgreSQL master (PG19 devel 相当, 本リポジトリ HEAD)
検討対象の提案: Andres Freund が pgsql-hackers で提起した方向性
（2022 年の "Smoothing the subtrans performance catastrophe" スレッド等での発言。
subxid→parent マッピングを SLRU ではなく共有メモリ上のハッシュテーブルで保持し、
最終的にはスナップショット/procarray の subxid 配列も不要にする、というもの）

---

## 0. 結論（サマリ）

**実現可能。ただし一括ではなく 2 段階に分けるべきで、難易度は段階ごとに大きく異なる。**

- **Stage 1: pg_subtrans SLRU → 共有ハッシュ置き換え（スナップショット側は現状維持）**
  - 実現性: **高い**。API 表面が小さく（外部呼び出し箇所は書き込み 3 箇所・読み取り 8 箇所）、
    永続性が不要であることはコード上のコメント・設計として明確に保証されている。
    pgstat が「静的共有メモリ上の in-place DSA + dshash を、startup プロセスを含む
    全プロセスから使う」という完全な先行事例になっている。
  - 効果: suboverflow 時の SLRU ページスラッシング（いわゆる subtrans 性能崖）の解消、
    ゼロページ書き出し I/O の消滅、`SubTransSetParent` の書き込みスケーラビリティ改善
    （同一ページ 32K xid 分がバンクロックで直列化 → 128 パーティションに分散）。
  - 最大のリスク: **メモリ上限問題**。SLRU はディスクにスピルできる（xid あたり 4 バイト・密）
    のに対し、ハッシュはメモリ常駐（エントリあたり実質 24〜32 バイト）。
    「長時間スナップショット保持 + サブトランザクション多用」ワークロードで
    無制限成長し得る。特に**スタンバイの WAL リプレイ中に挿入が失敗した場合の扱い**
    （ERROR にできない）が最難関の設計課題。

- **Stage 2: スナップショット subxip / PGPROC subxid キャッシュの廃止（提案の (a) の部分）**
  - 実現性: **条件付き**。可視性判定ホットパス（`XidInMVCCSnapshot`）が現在の
    ロックフリー SIMD 探索（`pg_lfind32`）から LWLock 取得を伴うハッシュ参照に変わるため、
    **dshash に現状存在しないロックフリー読み取りの追加**（あるいは同等の低コスト参照手段）
    がほぼ前提条件になる。Stage 1 単独でも価値があるため、切り離して進めるのが妥当。

---

## 1. 前提の妥当性検証: 「SLRU で持つ理由はもう無い」は正しいか

提案の根拠 2 点をコードで確認した。**いずれも正しい。**

### 1.1 永続性は不要（clog/multixact との違い）

- `src/backend/access/transam/subtrans.c:6-20`（ヘッダコメント）:
  「現在オープン中のトランザクションの情報だけ覚えていればよい。クラッシュをまたいで
  データを保存する必要はなく、XLOG との相互作用も無い。起動時にはアクティブページを
  単にゼロクリアする」と明記。
- fsync しない: SLRU 登録時に `.sync_handler = SYNC_HANDLER_NONE`（subtrans.c:253）。
  `SlruPhysicalWritePage` は sync_handler が無い場合 fsync 要求を出さない（slru.c:1057）。
  つまり**ダーティページの pg_pwrite はバッファ追い出しとチェックポイント時にだけ発生し、
  それすら正しさのためではない**（`CheckPointSUBTRANS` のコメント subtrans.c:352-355:
  「正しさの観点では不要。バックエンドではなくチェックポインタが書く確率を上げるためだけ」）。
- 起動時ゼロクリア: `StartupSUBTRANS`（subtrans.c:301-342、呼び出しは xlog.c:6237, 6522）。
  pg_rewind / ベースバックアップも pg_subtrans を「起動時にゼロクリアされる」扱い
  （filemap.c:147, basebackup.c:187）。
- クラッシュ後に唯一「生き残る」書き手である 2PC は、リカバリ時に
  `RecoverPreparedTransactions` → `ProcessTwoPhaseBuffer` → `SubTransSetParent`
  （twophase.c:2089, 2301）で**再構築される**。ハッシュでも同じ経路でそのまま再構築できる。

→ 「クラッシュ非永続・再構築可能」という性質は完全にコードに裏付けられており、
**インメモリ構造への置き換えに正当性がある。**

### 1.2 ゼロばかりのページへの I/O が発生している

- `pg_subtrans` は xid 空間に対する**密な配列**（xid あたり 4 バイト、1 ページ = 8KB = 2048 xid
  ぶん…実際には BLCKSZ/4 xid）。トップレベル xid のスロットもゼロのまま確保される。
- `ExtendSUBTRANS` は `GetNewTransactionId` から **XidGenLock 保持中に**毎ページ先頭 xid で
  呼ばれ（varsup.c:201）、スタンバイでも `RecordKnownAssignedTransactionIds` が
  観測 xid のギャップ分すべてを延長する（procarray.c:4462-4467）。
- サブトランザクションを使わないワークロードでも、xid 消費に比例して全ゼロページが
  生成され、バッファ追い出し・チェックポイントで書き出される。

→ ハッシュ化すれば**実際に割り当てられた subxid の分しかメモリを使わず、I/O はゼロ**になる。
サブトランザクション非使用時のコストが文字通り消える。この主張も正しい。

### 1.3 現行実装の性能上の弱点（置き換えの動機の再確認)

- PG17 で SLRU がバンク化され（バンク = 16 バッファ、slru.c:145-146）、
  `subtransaction_buffers` GUC（既定 0 = 自動、上限 8MB 相当まで自動チューニング、
  subtrans.c:207-215, guc_parameters.dat:2903-2912）が導入されて単一 `SubtransSLRULock`
  時代よりは改善済み。
- しかし本質的な問題は残る:
  1. **suboverflow 崖**: スナップショットが suboverflowed になると、可視性判定のたびに
     `SubTransGetTopmostTransaction` が走る（snapmgr.c:1913, 1942）。参照される xid 範囲が
     SLRU バッファ（最大 8MB = xid 1600 万個ぶん）を超えると、可視性判定がディスク読み込みに
     化ける。これが GitLab 事例などで知られる「subtrans カタストロフ」。
  2. **書き込み直列化**: `SubTransSetParent` はバンクロックを排他取得して 1 ワード書く
     （subtrans.c:103-120）。連続する xid は同一ページ（= 同一バンク）に落ちるため、
     全バックエンドの subxid 割り当てが実質同じロックに集中する。clog にある
     group-update 最適化も subtrans には無い。

---

## 2. 置き換え対象の API 表面と全呼び出し箇所

置き換えは `access/subtrans.h` の API を維持したまま実装を差し替える形で可能。
外部呼び出し箇所は以下で全部（網羅調査済み）。

### 書き込み `SubTransSetParent` — 3 箇所
| 箇所 | 文脈 | ハッシュ化の含意 |
|---|---|---|
| xact.c:712-714 `AssignTransactionId` | **全サブトランザクションで無条件**に直接の親を記録（キャッシュ溢れ時のみではない。README:378-380 も明記） | ハッシュへの insert に置換。挿入頻度 = subxid 割り当て頻度 |
| twophase.c:2301 `ProcessTwoPhaseBuffer`（リカバリ） | 2PC の子 xid を**トップ xid に平坦化して**記録 | そのまま insert に置換可 |
| procarray.c:1341 `ProcArrayApplyXidAssignment`（スタンバイ） | XLOG_XACT_ASSIGNMENT 受信時に 64 個ずつ、**トップ xid を親として**記録し KnownAssignedXids から除去 | **リプレイ中の insert 失敗が許されない**（→ §5.1） |

### 読み取り — `SubTransGetParent` 2 箇所 + `SubTransGetTopmostTransaction` 6 箇所
| 箇所 | 文脈 |
|---|---|
| transam.c:158 / 212 (`TransactionIdDidCommit/DidAbort`) | clog が `SUB_COMMITTED` の瞬間だけ親へ再帰。可視性ホットパスの一部だが発生頻度は低い |
| procarray.c:1606 `TransactionIdIsInProgress` | suboverflow 時の最終フォールバック（ProcArrayLock は**解放済み**の状態で呼ばれる。procarray.c:1572） |
| snapmgr.c:1913 / 1942 `XidInMVCCSnapshot` | suboverflowed スナップショットでの可視性判定（プライマリ / スタンバイ） |
| lmgr.c:725 / 768 `XactLockTableWait` 系 | 行ロック待ちでトップ xid に付け替える。高頻度 |
| heapam.c:9259 `HeapCheckForSerializableConflictOut` | SSI の conflict-out 判定 |

### ライフサイクル API
| API | 現状 | ハッシュ化後 |
|---|---|---|
| `ExtendSUBTRANS`（varsup.c:201, procarray.c:1233, 4466） | ページのゼロ初期化 | **no-op 化して削除可**（XidGenLock 中の仕事が減る = 副次的な改善） |
| `StartupSUBTRANS`（xlog.c:6237, 6522） | アクティブページのゼロクリア | 空ハッシュの初期化のみ |
| `CheckPointSUBTRANS`（xlog.c:8063） | ダーティページ書き出し | **no-op 化して削除可** |
| `TruncateSUBTRANS`（xlog.c:7883 チェックポイント, xlog.c:8364 リストアポイント[EnableHotStandby 時]） | `GetOldestTransactionIdConsideredRunning()` より古いセグメントを unlink | **横断スキャンして horizon より古いエントリを削除**（dshash_seq_init 排他 + delete_current で実装可能。チェックポイント頻度なら許容コスト） |

### 意味論の対応
- SLRU のゼロ値（親なし）⇔ ハッシュの「エントリ不在」。等価に写像できる。
- 読み手は `TransactionXmin` より古い xid を参照しない（subtrans.c:138, 176 の Assert）。
  つまり**エントリの生存期間は「全バックエンドの最古 xmin より新しい間」**で、
  これは現行の Truncate horizon（`GetOldestTransactionIdConsideredRunning`）と同一。
  → 掃除の正しさの理屈は現行と全く同じものが使える。
- `AssignTransactionId` の順序制約（「xid が PGPROC 以外の共有領域に現れる前に
  subtrans エントリを作る」xact.c:703-706）は、パーティションロック下の insert が
  読み手のロック取得と順序付けされるため自然に満たせる。
- 論理デコードは pg_subtrans に**依存しない**（snapbuild.c:22-38 に明記。subxid→top の
  対応は ReorderBufferAssignChild が WAL から独自管理）。影響なし。

---

## 3. 受け皿としての dshash + 静的確保メモリの適性

### 3.1 先行事例: pgstat がまさに同じ構成で動いている

`pgstat_shmem.c`（StatsShmemInit, 171-253 行付近）が実証している構成:

1. postmaster 起動時に固定サイズの通常共有メモリを確保し、
   `dsa_create_in_place(raw_dsa_area, size, tranche, NULL)` で DSA を載せる
   （「postmaster は DSM を使えないため必須」というコメントあり。pgstat_shmem.c:185-188）。
2. `dsa_set_size_limit(dsa, init_size)` を一時的に掛けて dshash の制御構造・バケット配列を
   静的領域内に確保し、その後 limit を解除（または維持）する（pgstat_shmem.c:197-211）。
3. 各バックエンドは `dsa_attach_in_place` + `dsa_pin_mapping` + `dshash_attach` で接続。
4. **startup プロセス（リカバリ中）もこの dshash に書き込んでいる**
   （pgstat_replslot.c:110-131 は `RecoveryInProgress()` を Assert した上で共有ハッシュを更新）。

→ 「静的確保メモリ + dshash を、全バックエンド + startup プロセスから使う」という
提案の構成要素はすべて in-core に実績がある。Andres の言う「静的確保」は
`dsa_set_size_limit(area, 静的サイズ)` で DSM 追加確保を封じる形（完全固定）と、
limit を緩めて DSM で弾力的に成長させる形の両方を選べる。

### 3.2 dshash の特性と懸念

| 特性 | 内容 | 本用途への含意 |
|---|---|---|
| ロック | 128 パーティション固定（dshash.c:55-62）、参照は LW_SHARED 可（dshash.c:406-407） | 連続 xid がパーティションに分散するため、SLRU の「同一ページ = 同一バンクロック集中」より書き込みスケーラビリティは大幅に良い |
| 参照コスト | `dshash_find` は palloc も dsa_allocate もしない。ハッシュ計算 + LWLock + バケット走査のみ | Stage 1 の参照経路（suboverflow 時のみ）には十分。Stage 2 のホットパスには LWLock が重い（→ §6） |
| リサイズ | 倍々成長。**全 128 パーティションロックを排他取得**して全要素を再ハッシュ（dshash.c:893-967） | レイテンシスパイク要因。起動時に想定サイズへプリサイズして回避すべき |
| 縮小 | 非対応（「growing のみ」dshash.c:8-9）。削除エントリは dsa フリーリストへ戻るのみで、初期（in-place）セグメントは OS に返らない（dsa.c:36-40, 1909-1934。追加 DSM セグメントのみ空になれば解放される） | 定常運用ではフリーリスト再利用で回るが、スパイク後にフットプリントが残る |
| 挿入失敗 | `dsa_allocate` が OOM で ERROR（`DSHASH_INSERT_NO_OOM` で NULL 返しも可。dshash.c:501-506, 1035-1041） | プライマリでは ERROR = トランザクションアボートで許容可能。**スタンバイでは不可**（→ §5.1） |
| クリティカルセクション | find は安全（アロケーションなし）。insert は ERROR し得るため不可 | 現行の呼び出し箇所はいずれもクリティカルセクション外なので問題なし |

### 3.3 代替案: 共有メモリ dynahash（ShmemInitHash 系）

固定上限・全要素事前確保・リサイズなし（shmem_hash.c:154-157, dynahash.c:117-123）。
- 長所: リサイズストールなし、レイテンシ予測可能、postmaster 静的確保と完全に整合。
- 短所: 上限超過は即 `out of shared memory` ERROR。上限を大きく取ると常時その分を消費
  （dshash + DSA なら初期領域は小さくして弾力成長させる選択肢がある）。

**推奨は dshash**。理由は (1) パーティションロック内蔵で読み取り共有モードがある、
(2) pgstat 先行事例との対称性、(3) キャップ付き弾力成長（上限 GUC + DSM）という
中間解を取れること。ただし起動時プリサイズでリサイズを実質封じる運用が前提。

---

## 4. 設計スケッチ（Stage 1）

- **キー/値**: `TransactionId → TransactionId`（8 バイト）。dshash エントリヘッダ
  MAXALIGN(16B) を足して実質 24〜32 バイト/エントリ。
  将来の 64-bit XID 化とも相性が良い（SLRU のページ番号写像問題が消える）。
- **確保**: postmaster 静的共有メモリに in-place DSA（pgstat 方式）。サイズは新 GUC
  （例: `subtrans_hash_size`、既定は shared_buffers 比例の自動チューニング）。
  `dsa_set_size_limit` で上限を制御。
- **insert**: `SubTransSetParent` → `dshash_find_or_insert`。既存の冪等性
  （同値なら何もしない、有効な親の上書きは Assert 違反。subtrans.c:110-120）を踏襲。
- **lookup**: `SubTransGetParent` → `dshash_find`(shared)。不在 = InvalidTransactionId。
  `SubTransGetTopmostTransaction` の親チェーン歩行はそのまま
  （1 ホップごとに find。インメモリなのでディスク I/O 崖が消えるのが本質的改善）。
- **掃除**: チェックポイント/リストアポイントの `TruncateSUBTRANS` 相当で
  `dshash_seq_init(exclusive)` + horizon より古いキーを `dshash_seq_delete_current`。
  128 パーティションを 1 つずつ排他するだけなので同時実行への影響は限定的。
- **起動**: `StartupSUBTRANS` は空テーブル初期化。2PC 再構築（twophase.c:2301）は無変更。
- **削除される複雑さ**: `ExtendSUBTRANS`（XidGenLock 中の仕事が減る）、
  `CheckPointSUBTRANS`、pg_subtrans ディレクトリ、SLRU wraparound/ページ写像、
  basebackup / pg_rewind の特別扱い。
- **監視**: `pg_stat_slru` の subtrans 行が消える。代替の統計ビュー
  （エントリ数、メモリ使用量、最大到達量）を用意するのが望ましい。

---

## 5. リスクと未解決課題（重要度順）

> **改訂注**: 本節の各リスクに対する根本的な解決策の設計は
> `feasibility_subtrans_dshash_solutions_ja.md` にまとめた。
> 要点: 世代（epoch）別の固定メモリプール + 不変ソート済みスピルにより、
> 5.1 は「失敗モードを増やさずメモリ有界化」、5.2 は「リサイズの構造的排除」、
> 5.3 は「write-once 性を利用した RCU 型 lock-free 読み取り」で解決する。

### 5.1 【最重要】メモリ上限とスタンバイのリプレイ

SLRU の暗黙の美点は**ディスクへのスピル**だった。ハッシュ化で失われるものを直視する必要がある。

- 保持しなければならないエントリ数 = 「最古の実行中 xmin 以降に割り当てられた subxid 数」。
  これは**ワークロード依存で非有界**。例: 長時間トランザクションが xmin を数時間留め、
  その間 SAVEPOINT 多用ワークロードが 10K subxid/秒を割り当てると
  約 36M エントリ/時 ≒ **0.9〜1.2 GB/時** の成長（現行 SLRU なら xid 窓 36M × 4B = 144MB の
  ディスクで済む）。
- プライマリ側の失敗は許容可能: insert OOM → `AssignTransactionId` で ERROR →
  当該トランザクションのアボート。到達点として妥当（wraparound 由来の ERROR が既にある
  場所であり、クリティカルセクション外）。エラー時点で xid は割り当て済みだが未コミットの
  ままアボート処理されるため正しさは保てる。ただしエラーメッセージ/ヒント設計は必要。
- **スタンバイ側が本当に難しい**: 挿入箇所は `ProcArrayApplyXidAssignment`（WAL リプレイ中）。
  ここで OOM したら ERROR = リカバリ停止（実質 PANIC）。取り得る設計は:
  1. **リカバリコンフリクトの新種**を作り、horizon を留めている古いスナップショット保持
    バックエンドをキャンセルして掃除 → リトライ（`ResolveRecoveryConflictWithSnapshot`
    類似の機構。設計・実装コストが大きいが最も筋が良い）。
  2. スタンバイでは上限超過時に**リプレイを待機**させ、restartpoint 掃除で空きを待つ
    （プライマリ由来で horizon が進まない場合はデッドロックし得るため単独では不十分）。
  3. 十分大きな上限 + DSM による弾力成長で「実質起きない」に倒す（それでも OS OOM の
    リスクは残る）。
  現実解は 3 を既定にしつつ 1 を併設、と考えられる。**ここが本提案の設計上の最難関**であり、
  コミュニティ議論でも必ず論点になる。

### 5.2 リサイズストール

倍々リサイズは全 128 ロック排他 + 全再ハッシュ。トランザクション処理の心臓部で発生させて
よい代物ではない。→ 起動時に GUC からプリサイズし、定常運用でリサイズが起きない設計にする
（あるいは dshash に段階的リサイズを実装する。dshash.c:20-21 に「将来課題」と明記されている）。

### 5.3 Stage 2（subxip 廃止）のホットパス性能

現状の速い経路は「スナップショットにコピーした subxip を `pg_lfind32`（SIMD・ロックフリー）
で走査」(snapmgr.c:1902, 1958)。subxip を廃止すると、[xmin, xmax) 内の xid の可視性判定が
毎回 LWLock 付きハッシュ参照になる。ホットな更新競合ワークロードでは後退し得る。
- 前提条件: dshash へのロックフリー読み取り追加（epoch/バージョンカウンタ方式など）、
  もしくは per-backend の小さなローカルキャッシュ併用。
- 削減されるメモリ（Stage 2 で初めて得られる）:
  スナップショットごとの subxip = `(64+1) × (MaxBackends+max_prepared_xacts) × 4B`
  （MaxBackends=100 で約 26KB/スナップショット。procarray.c:410-411, 2018-2022）、
  PGPROC ごとの 64 エントリキャッシュ 256B（proc.h:43, 255）、
  `TransactionIdIsInProgress` のワークスペース、シリアライズ経路の特例
  （snapmgr.c:1756-1757）等。加えて GetSnapshotData から subxid コピーのループ
  （procarray.c:2280-2302）が消え、suboverflowed という概念自体が不要になる。
- KnownAssignedXids（スタンバイ、`(64+1)×procs×5B`）の簡素化も視野に入るが、
  これはさらに別の大工事。

### 5.4 その他

- `XactLockTableWait`（lmgr.c:725）は suboverflow と無関係に呼ばれるため、
  Stage 1 でも参照頻度はゼロではない。インメモリ参照なので性能上はむしろ改善方向。
- `TransactionIdDidCommit` の SUB_COMMITTED 窓（transam.c:144-165）はコミット手順の
  一時状態 + 2PC で参照される。ハッシュのエントリは horizon 基準で掃除される限り
  この窓でも必ず生きているため、現行と同じ理屈で正しい。
- pg_upgrade: 影響なし（非永続）。pg_rewind / basebackup: 除外リストから
  pg_subtrans を外すだけ。
- `subtransaction_buffers` GUC の互換性: 廃止（deprecate）して新 GUC へ移行。

---

## 6. 段階的移行プランと工数感

1. **Stage 1**: subtrans.c の実装差し替え（API 維持）+ 掃除機構 + GUC + 監視ビュー
   + スタンバイ OOM 方針。パッチ規模はコア数千行オーダー。
   コミュニティ的な争点は §5.1 に集中すると予想される。
   ベンチマーク必須項目: (a) subxid 非使用ワークロードの中立性、
   (b) suboverflow ワークロード（savepoint 多用 + 長時間スナップショット）での改善、
   (c) スタンバイのリプレイ速度、(d) チェックポイント時の掃除コスト。
2. **Stage 1.5（任意）**: 親を直接トップ xid で記録する平坦化（スタンバイ・2PC は既に
   トップ xid で記録している。プライマリだけが直接の親を記録しており、揃えると
   `SubTransGetTopmostTransaction` が 1 ホップになる）。immediate parent に依存する
   利用者が本当にいないかの確認が前提。
3. **Stage 2**: dshash ロックフリー読み取り（または代替）→ subxip / PGPROC キャッシュ /
   suboverflowed の廃止。効果は大きいが検証負荷も大きい独立プロジェクト。

---

## 7. 総括

- 「pg_subtrans を SLRU で持つ理由はもう無い」という Andres の現状認識は、
  コード上の事実（非永続・fsync なし・起動時ゼロクリア・2PC/スタンバイでの再構築可能性）
  と完全に整合する。
- 受け皿となる基盤（in-place DSA + dshash、startup プロセスからの利用実績）は
  pgstat という形で既に in-core に存在し、技術的な未知数は小さい。
- 提案の利点 (b)（ゼロページ I/O の消滅、suboverflow 崖の解消、書き込み分散）は
  Stage 1 だけで得られ、実装リスクも管理可能。**まず Stage 1 を切り出して進める価値がある。**
- 提案の利点 (a)（スナップショット/procarray のメモリ削減）は Stage 2 であり、
  ロックフリー読み取りの追加という dshash 側の拡張が事実上の前提。
- 最大の設計課題は**「ディスクスピルの喪失」に対する答え**（上限、成長、スタンバイの
  リプレイ中 OOM の扱い）。ここに説得力のある設計を用意できるかが、
  コミュニティ提案としての成否を分ける。
