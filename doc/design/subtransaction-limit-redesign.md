# サブトランザクション64個制限の根本解決 — 設計書

- 対象: PostgreSQL master (20devel)
- ステータス: Draft
- 前提: GUC 追加やキャッシュ拡大などの「オーバーフローしにくくする」ワークアラウンドは対象外。
  オーバーフローという概念自体が性能問題を引き起こさないアーキテクチャへの変更を設計する。

---

## 1. 問題の構造分析

### 1.1 「64個制限」の実体

64 という数字は、各バックエンドが共有メモリ（PGPROC）上に広告できる
サブトランザクション XID キャッシュの固定サイズである。

- `src/include/storage/proc.h:43` — `#define PGPROC_MAX_CACHED_SUBXIDS 64 /* XXX guessed-at value */`
- 1 つのトップトランザクションが 65 個目の subxid を割り当てた瞬間、
  そのバックエンドの `subxidStatus.overflowed = true` になる（以後そのトランザクションが終わるまで戻らない）。

重要なのは、**65 個目以降でエラーになるわけではない**こと。サブトランザクション自体は
無制限に作れる。問題は以下の連鎖で「システム全体の読み取り性能」が崩壊することである。

### 1.2 性能崩壊のメカニズム（プライマリ）

1. **割り当て時**: すべての subxid は割り当て時に pg_subtrans（SLRU）へ親 XID を記録する
   （`AssignTransactionId()` → `SubTransSetParent()`、`src/backend/access/transam/xact.c:713`）。
2. **スナップショット取得時**: `GetSnapshotData()` は全バックエンドの subxid キャッシュを
   スナップショットの `subxip[]` にコピーするが、**どれか 1 つのバックエンドでも**
   overflowed なら、スナップショット全体に `suboverflowed = true` が立つ
   （`src/backend/storage/ipc/procarray.c:2288-2310`）。
3. **可視性判定時**: `XidInMVCCSnapshot()`（`src/backend/utils/time/snapmgr.c`）は、
   `suboverflowed` なスナップショットでは `subxip[]` を信用できないため、
   xmin ≤ xid < xmax の範囲に落ちる**すべての未ヒントタプルの XID** について
   `SubTransGetTopmostTransaction()` を呼ぶ。これは pg_subtrans SLRU ページの
   参照を親チェーンの深さぶん繰り返す（ネストが深ければ 1 XID あたり複数ページ参照）。
4. **SLRU の特性が痛みを増幅する**: pg_subtrans は 4 bytes/xid の XID 密配列であり、
   保持ウィンドウは「最古のスナップショット xmin から現在まで」。長時間トランザクションが
   1 本いるだけでウィンドウは数千万〜数億 XID に伸び、ワーキングセットが
   共有バッファ（PG17 以降は `subtransaction_buffers`）を超えてディスク I/O が発生し、
   バンクロック（PG16 以前は単一の SubtransSLRULock）競合と合わさって、
   全バックエンドの全タプル参照が直列化される。

つまり典型的な障害パターンは:

> 「長時間トランザクション 1 本」×「どこか 1 セッションが 64 個超の subxid を使う」
> → 全セッションのスナップショットが suboverflowed
> → 全セッションの可視性判定が pg_subtrans 参照に落ちる
> → SubtransSLRU 待ちで応答時間が数十〜数百倍化

### 1.3 スタンバイではさらに悪い

ホットスタンバイでは実行中 XID を `KnownAssignedXids` で追跡するが、
ここに入り切らない subxid が出ると `procArray->lastOverflowedXid` が進み
（`procarray.c:1257-1361`）、**その XID を超えるまでの間、スタンバイ上の全スナップショットが
suboverflowed 扱い**になる（`procarray.c:2345-2348`）。プライマリで誰かが
サブトランザクションを多用するだけで、スタンバイの読み取りワークロード全体が
pg_subtrans 参照に落ちる。これは「スタンバイの SubtransSLRU 崩壊」としてよく知られた障害である。

### 1.4 真因の特定 —「SLRU の問題」という仮説の精緻化

SLRU（バッファ数の少なさ、単純な LRU、ロック粒度）は**症状が現れる場所**であって、
根本原因ではない。PG17 でバンク分割と `subtransaction_buffers` GUC が入り
（`src/include/access/slru.h` のバンクロック構造）、SLRU 自体はかなり改善されたが、
問題の本質は残っている。真因は次の 2 点に分解できる:

- **(A) スナップショットモデルの構造的欠陥**:
  PostgreSQL の MVCC スナップショットは「実行中 XID の有限列挙」である。
  subxid は列挙が固定長キャッシュ（64個/バックエンド）に収まる場合のみ列挙され、
  収まらなければ「列挙の失敗（suboverflowed）」となり、可視性判定という
  **最もホットな読み取りパス**が、共有・ディスク裏付きの subxid→topxid 変換
  （pg_subtrans）に依存するようになる。
- **(B) ペナルティの全域性**: オーバーフローは起こした 1 バックエンドではなく、
  スナップショットを取る**全バックエンド**に課される。

したがって「根本解決」の定義は次の通り:

> **可視性判定パスから subxid→topxid 解決（pg_subtrans 参照）を排除し、
> 「suboverflowed」という状態そのものを消滅させること。**

SLRU を速くする（バッファ増、バンク分割、バッファプール移行）のは (A)(B) に触れない
ため、要件を満たさない。

---

## 2. 要件

| # | 要件 |
|---|------|
| R1 | サブトランザクション数によらず、可視性判定コストが一定であること（64 という閾値の消滅） |
| R2 | 1 セッションの挙動が他セッションの読み取り性能に影響しないこと |
| R3 | ホットスタンバイでも同じ性質が成り立つこと（`lastOverflowedXid` 機構の廃止） |
| R4 | GUC チューニングを解決手段としないこと |
| R5 | クラッシュリカバリ・2PC・logical decoding・pg_upgrade と整合すること |
| R6 | 段階的に実装・検証可能であること（一括ビッグバン置換の回避） |

---

## 3. 設計候補の比較

### 案A: CSN（Commit Sequence Number）ベーススナップショット【採用】

スナップショットを「実行中 XID の列挙」から「単一のコミット順序番号」に変える。
可視性は「その XID は snapshot CSN 以前にコミットされたか」の 1 点比較になり、
subxid は親と同時に同じ CSN でコミットされるため、**subxid→topxid 変換自体が不要になる**。
suboverflowed・subxip・KnownAssignedXids がすべて概念ごと消える。詳細は §4。

- 長所: R1〜R3 を構造的に満たす唯一の案。スタンバイの KnownAssignedXids 機構
  （複雑さとバグの温床）ごと削除できる。`GetSnapshotData()` が O(実行中バックエンド数)
  から O(1) 近くになる副次効果（高コネクション数でのスケーラビリティ改善）。
- 短所: 変更規模が大きい。コミットプロトコルに「CSN 確定待ち」の同期点が必要。
  xid→CSN マップ（csnlog）という新しい永続構造を持つ（§4.8 で正当化する）。

### 案B: pg_subtrans の共有メモリハッシュ置換【不採用（理由付き）】

pg_subtrans を「XID 密の SLRU」から「実在する subxid のみを持つパーティション化
共有ハッシュ（dshash）」に置き換える案。subxid 数は XID 範囲よりはるかに小さいので
メモリ内に収まりやすく、SLRU ロック・I/O は消える。

- 不採用理由: 保持ウィンドウは今と同じ「最古 xmin から現在まで」であり、
  **長時間トランザクション＋subxid 多用**という、まさに問題のワークロードで
  エントリ数が無制限に伸びる。上限を設ければ溢れた分のディスク退避（＝SLRU の再発明）
  か、suboverflowed 相当の状態が必要になり、根本解決にならない。
  また (B)（ペナルティの全域性）は解消するが (A) は残る。

### 案C: subxid キャッシュの可変長化＋スナップショットの完全列挙【不採用】

PGPROC の 64 固定を可変（DSA 上）にし、スナップショットに常に全 subxid をコピーする案。

- 不採用理由: `GetSnapshotData()` のコストとスナップショットのメモリが
  O(システム全体の実行中 subxid 総数) になる。subxid を 100 万個持つトランザクションが
  1 本あるだけで、全セッションのスナップショット取得が崩壊する。
  ペナルティの場所が可視性判定からスナップショット取得に移るだけで、構造は同じ。

### 案D: SLRU 側の改善（バッファプール移行・バンク増・先読み）【対象外】

コミュニティで進行中の「SLRU を共有バッファプールへ移す」方向は価値があるが、
本問題に対しては §1.4 の通り対症療法であり、要件 R1/R2 を満たさない。
（案A の csnlog 実装基盤としては活用する。）

---

## 4. 採用設計: CSN ベーススナップショット詳細

### 4.1 中心概念

- **CSN**: 64bit の単調増加値。**コミットレコードの終端 LSN** を CSN として用いる。
  - 専用カウンタ方式に対する利点: プライマリとスタンバイで「コミット順序」が
    WAL 順序と構成的に一致するため、順序整合のための追加ログや調停が不要。
    スタンバイはリプレイ位置がそのままスナップショット CSN になる。
- **csnlog**: `FullTransactionId → CSN(8 bytes)` の密マップ。エントリ値は
  次の 4 状態を取る（下位ビットをタグに使う）:
  - `IN_PROGRESS (0)` — 未コミット
  - `COMMITTING` — コミットシーケンス実行中（センチネル値）
  - `csn` — コミット済み（値＝コミットレコード終端 LSN）
  - `ABORTED` — アボート済み（センチネル値）
- **スナップショット**: `{ csn, xmin, xmax }`。`xip[]`/`subxip[]`/`suboverflowed` は
  最終形では持たない。`xmin`/`xmax` は高速パス（範囲カット）と VACUUM 水平線、
  csnlog 切り詰め判断のために残す。

### 4.2 可視性判定（XidInMVCCSnapshot の置換）

```
XidVisibleInSnapshot(xid, snap):
    if xid < snap->xmin:  return "committed 側の既存高速パスへ"   # 変更なし
    if xid >= snap->xmax: return invisible                        # 変更なし
    entry = CSNLogGetEntry(xid)                                   # 8byte アトミック読み
    switch entry:
        IN_PROGRESS: return invisible
        ABORTED:     return invisible
        COMMITTING:  wait_for_committer(xid); retry               # §4.3
        csn:         return (csn <= snap->csn)
```

- **subxid の扱いは topxid と完全に同一**。コミット時に親と全 subxid へ同じ CSN を
  書くため（§4.3）、topxid への変換が不要になる。`SubTransGetTopmostTransaction()` は
  可視性パスから消える。→ R1, R2 達成。
- csnlog 読みは 8 byte アラインなのでロックフリーのアトミックロードで行える
  （SLRU バンクロックはページの load/eviction 時のみ必要）。
- ヒントビット（`HEAP_XMIN_COMMITTED` 等）は従来通り機能するため、csnlog 参照は
  「最近のタプルに最初に触れたときだけ」発生する。アクセス頻度・局所性は現在の
  pg_xact（clog）参照と同等であり、pg_xact が今日ボトルネックでないのと同じ理由で
  スケールする。**「1 バックエンドのオーバーフローで全員が SLRU 連鎖参照」という
  現在の病理（頻度 × チェーン長 × 全域性）とは質的に異なる。**

### 4.3 コミットプロトコル

CSN は「WAL 書き込み」と「可視性の切り替わり」を原子的に見せる必要がある。
順序を以下に固定する:

1. **critical section 内**: topxid と全 subxid の csnlog エントリを `COMMITTING` にする。
   （subxid リストはコミットレコードに載せる現行データをそのまま使う。ページ順に
   ソートして一括更新するため、コストは O(subxid数/ページ内エントリ数) ページタッチ。）
2. コミットレコードを WAL 挿入し、終端 LSN を得る。
3. csnlog の全該当エントリへ LSN（＝CSN）をストア。
4. 共有アトミック変数 `lastStampedCSN` を CAS-max で前進させる。
5. PGPROC から xid を外す（現行の `ProcArrayEndTransaction` 相当は大幅に軽くなる。
   xmin 広告のためのフィールド更新のみで、subxid キャッシュの掃除は不要）。

- **スナップショット取得**: `snap->csn = atomic_read(lastStampedCSN)`。
  ProcArrayLock 下での全 PGPROC 走査・subxid コピーは不要になる。
  `xmin` は従来同様の広告方式（各 PGPROC の xmin の最小）を維持する。
- **COMMITTING に遭遇した読者**: 該当バックエンドのコミット完了を待つ
  （ConditionVariable。頻度は「コミットの 2〜3 の間の数マイクロ秒窓に同じ XID を
  参照した場合」のみで極めて稀）。待った後に再読すれば csn か ABORTED が見える。
  正しさの根拠: `snap->csn = X` のとき、コミット LSN ≤ X になり得るトランザクションは
  手順 1 が LSN 確定より先行するため、必ず `COMMITTING` 以降の状態で観測される。
  よってスナップショットは常にコミット順序のプレフィックスと一致する。
- **アボート**: 通常パスで `ABORTED` をストア。クラッシュアボート（エントリが
  `IN_PROGRESS`/`COMMITTING` のまま残る）はリカバリ終了時に、実行中でない XID を
  `ABORTED` 扱いする規約で吸収する（clog と同じ考え方。csnlog はコミットレコードの
  redo で再構築されるため、クラッシュ整合は WAL リプレイが保証する）。

### 4.4 サブトランザクション割り当てパスの変更

- `AssignTransactionId()` での `SubTransSetParent()` 呼び出しを**可視性目的では廃止**。
  csnlog の該当エントリは `IN_PROGRESS`（ゼロ）のままでよく、**割り当て時の共有構造への
  書き込みが消える**（現在は subxid 1 個ごとに pg_subtrans ページ書き込み＋
  PGPROC キャッシュ更新が必要）。
- PGPROC の `subxids[64]` キャッシュ、`XidCacheStatus`（`proc.h:43-56`）、
  `GetSnapshotData()` の subxip コピー（`procarray.c:2270-2310`）、
  スナップショットの `subxip/subxcnt/suboverflowed` は最終フェーズで削除。

### 4.5 pg_subtrans の降格（廃止ではない）

subxid→topxid 変換が残って必要な箇所は精査の結果、以下のみ:

| 用途 | 箇所 | 特性 |
|------|------|------|
| 行ロック待ちで待機対象の topxid を得る | `lmgr.c:725,768` (`XactLockTableWait`) | 競合時のみ。既にスリープするコールドパス |
| `SUBCOMMITTED` 状態の親追跡 | `transam.c:144-212` (`TransactionIdDidCommit`) | コミット手順の短い窓のみ |
| リカバリ中の追跡 | `heapam.c:9259` ほか | コールドパス |

よって pg_subtrans は**残すが、可視性ホットパスから完全に外れる**。
`SubTransSetParent()` はこれらの用途のために現行どおり割り当て時に書く
（コールドパス専用になるため、将来的に「ロック競合が起きうる場合のみ遅延記録する」
最適化（Simon Riggs が 2022 年に提案した方向）を追加検証してもよいが、本設計の
必須要素ではない）。バッファ数はデフォルトで十分になる — 読み手がいないため。

### 4.6 ホットスタンバイ

- リプレイ側: コミットレコードの redo で csnlog に CSN（＝そのレコードの LSN）を
  ストアする。プライマリと同一の値になる。
- スタンバイのスナップショット: `snap->csn = 最後にリプレイ済みのコミット LSN`。
  リプレイは単一プロセスなので COMMITTING 待ちすら不要。
- **`KnownAssignedXids`、`lastOverflowedXid`、`RecordKnownAssignedTransactionIds`、
  `XLOG_XACT_ASSIGNMENT` サブ XID 通知の仕組みは全廃**できる
  （これらは「スタンバイ上で実行中 XID を列挙する」ためだけに存在する。
  procarray.c から約 1,500 行の複雑なコードが消える）。
  スタンバイの suboverflow 問題（§1.3）は構造ごと消滅する。→ R3 達成。
- `takenDuringRecovery` の分岐（`snapmgr.c` の subxip 全格納ロジック）も削除。

### 4.7 周辺サブシステムとの整合（R5）

- **2PC**: `PREPARE` 済みトランザクションは csnlog 上 `IN_PROGRESS` のまま
  （＝不可視）。`COMMIT PREPARED` が通常のコミットプロトコル（§4.3）を実行する。
  subxid リストは 2PC 状態ファイルに既に保存されているのでそれを使う。
- **logical decoding**: SnapBuild は歴史的スナップショットを独自構築しており、
  当面は現行の xip ベース表現を内部的に維持できる（decoding はコミット済み
  トランザクションの並べ替えであり、suboverflow 病理の影響外）。
  最終的に CSN ベースへ移行するのは Phase 4 以降の独立作業とする。
- **SSI (predicate.c)**: スナップショットの xmin/xmax は維持されるため
  インターフェース互換。CSN はむしろ将来の SSI 簡素化に有利。
- **スナップショットの export/import**: `{csn, xmin, xmax}` のシリアライズに変わる
  （サイズは縮む）。
- **pg_upgrade**: csnlog は空で初期化。旧クラスタ由来の XID はすべて
  `xid < xmin` の高速パス（clog＋ヒントビット）で解決されるため、
  変換作業は不要。アップグレード後の `nextXid` 未満の XID に csnlog 参照が
  来た場合は「`oldestCSNXid` 未満 → clog にフォールバック」の規約で扱う。
- **XID 周回**: csnlog は内部的に `FullTransactionId`（64bit）でページを索引し、
  周回比較ロジックを持たない（PG17 以降の SLRU は int64 ページ番号対応済み）。

### 4.8 「csnlog も SLRU では？」への回答

その通り、csnlog は SLRU 基盤（PG17 バンク版）上に実装する。しかし §1.4 で
特定した病理の 3 因子がすべて消える点が本質的に異なる:

| 因子 | pg_subtrans（現行） | csnlog（本設計） |
|------|--------------------|------------------|
| 参照頻度 | suboverflow 時、**未ヒントタプル×スナップショット毎** | 未ヒントタプルにつき**一度**（以後ヒントビット。現行 clog と同じ） |
| 1 回のコスト | 親チェーン長ぶんのページ参照（ネスト深で倍増） | 1 エントリのアトミックロード |
| 全域性 | 1 バックエンドの overflow が全員を巻き込む | 他バックエンドの挙動に非依存 |
| 書き込み | subxid 割り当てごと | コミット時に一括（ページ順ソート済み） |
| ウィンドウ | 最古 xmin〜現在 × 4B/xid | 最古 xmin〜現在 × 8B/xid |

保持ウィンドウが 2 倍（8B/xid）になる点は唯一の後退だが、これは
「長時間トランザクションがあると clog/subtrans が伸びる」という既存特性の定数倍であり、
アクセスがコールド（一度きり）なのでディスク常駐でも性能病理にならない。

### 4.9 削除されるもの（複雑性の収支）

- `PGPROC_MAX_CACHED_SUBXIDS`、`XidCache`、`XidCacheStatus`、`SubTransGetTopmostTransaction()` の可視性パス利用
- `Snapshot->subxip/subxcnt/suboverflowed/takenDuringRecovery` と `XidInMVCCSnapshot()` の 4 分岐
- `KnownAssignedXids` 一式、`lastOverflowedXid`、`XLOG_XACT_ASSIGNMENT`
- `GetSnapshotData()` の PGPROC 走査の大半（xmin 計算のみ残る）
- `src/test/isolation/specs/subxid-overflow.spec` はオーバーフロー非存在の
  リグレッションテストに書き換え

---

## 5. 段階的実装計画（R6）

各フェーズは独立にコミット・検証可能で、Phase 2 まで入れば主目的（本問題の解消）は達成される。

- **Phase 0 — 抽象化（準備）**
  可視性判定の入口を `XidVisibleInSnapshot()` に一本化し、`suboverflowed` を
  参照する箇所をすべてこの背後に隠す。挙動変更なし。
- **Phase 1 — csnlog 導入（書き込みのみ）**
  csnlog モジュール（SLRU バンク、int64 ページ、redo、切り詰め）を追加し、
  コミット/アボートパスで §4.3 のストアを行う。読者はまだ従来方式。
  assert ビルドでは全可視性判定で新旧の結果を突き合わせる検証コードを入れる
  （shadow verification）。
- **Phase 2 — プライマリの読者切り替え**
  `XidVisibleInSnapshot()` を CSN 判定に切り替え、`GetSnapshotData()` の
  subxip コピーを停止。この時点で **プライマリの suboverflow 病理は消滅**。
  切り替えは開発者向けビルドオプションで新旧併存させ、性能・正しさ比較後に旧を削除
  （ユーザー向け GUC にはしない — R4）。
- **Phase 3 — スタンバイ**
  リプレイでの csnlog ストア、スタンバイスナップショットの CSN 化、
  KnownAssignedXids 一式の削除。**スタンバイの suboverflow 病理が消滅**。
- **Phase 4 — 後始末と発展**
  PGPROC subxid キャッシュ・Snapshot フィールドの削除、logical decoding の CSN 化、
  `SubTransSetParent` 遅延化の検討。

## 6. リスクと検証計画

| リスク | 対応 |
|--------|------|
| COMMITTING 待ちがコミットレイテンシに現れる | 待ち窓は WAL 挿入〜ストアの数 µs。pgbench（高競合の同一行更新）でレイテンシ分布を回帰確認 |
| csnlog ストアがコミットパスに追加コスト | subxid なしなら 1 ストア。subxid 大量時はページ順一括で O(ページ数)。SAVEPOINT 多用ベンチで測定 |
| 可視性の順序整合バグ | Phase 1 の shadow verification、isolation スイート全件、injection_points で COMMITTING 窓を強制拡大したレース試験 |
| 長時間 Tx 下の csnlog サイズ | 既存 subtrans と同じ切り詰め契機（xmin 水平線）。監視は pg_stat_slru で可視 |
| logical decoding / 2PC の退行 | Phase 2 では従来機構を温存し、対象外に影響を閉じる |

性能実証シナリオ（Before/After で必須）:
1. `pgbench -S`（read only）＋ 裏で「SAVEPOINT を 100 個張る書き込みセッション」＋「長時間 idle in transaction」→ 現行では TPS が 1/10〜1/100 に崩落するのが、劣化ゼロになること
2. 同構成のホットスタンバイ読み取り
3. subxid ゼロの純短時間トランザクション（新方式のオーバーヘッドが誤差範囲であること）

## 7. 先行議論との関係

- CSN スナップショットは Heikki Linnakangas（2014, pgsql-hackers「Commit Sequence
  Number based snapshots」）、Movead Li（2020 リベース）らが試みた方向であり、
  当時の停滞要因は (a) 短トランザクション性能の退行、(b) スタンバイ整合の複雑さだった。
  本設計は (a) に対して PG14 以降の GetSnapshotData 改良と PG17 の SLRU バンク＋
  アトミック 8B 読みを前提に置き、(b) に対して「CSN = コミットレコード LSN」を
  採用して順序調停を WAL に一元化することで、当時より条件が良くなっている。
- SLRU バンク化（PG17, commit `bcdfa5f2e2f`）、Simon Riggs / Andrey Borodin の
  subtrans 競合削減パッチ群（2021–2022）は本設計の前提・補完として位置づける。
