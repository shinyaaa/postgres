# pg_stat_lock / pg_stat_get_backend_lock 実負荷検証レポート

対象: PostgreSQL master (20devel, `6d4ca6d`)、累積統計システムのロック統計。
ビルド: `./configure --prefix=$HOME/pgi --enable-debug --enable-cassert --without-icu CFLAGS="-O0 -g3"`
(ICU/flex は環境になかったため `--without-icu` + `apt-get install flex` で対応)。
サーバは非 root ユーザ (`pgtest`) で起動。`deadlock_timeout=1s`, `log_lock_waits=on`。

すべての結論は実負荷の観測に基づく。ソース読解は観測の裏付けにのみ使用した。

---

## 結論(サマリ)

| 検証項目 | 結果 |
|---|---|
| `waits` が実施回数と一致 | ✅ 完全一致(1→1, 3→3, 2→2) |
| `wait_time` の単位 | ✅ **ミリ秒(ms)**。実測待ち時間と一致。±1000倍の単位バグは無し |
| `wait_time` の型 | ✅ `double precision`(小数 msを表示、例 `2499.441`) |
| 二重集計 | ✅ 無し。global と backend が完全一致 |
| global ↔ backend 整合性 | ✅ 単一待機者で完全一致。global ≥ Σbackend の関係も成立 |
| 不正PID入力 | ✅ クラッシュ無し。999999/0/-1 → 0行。存在するが未追跡の aux → 0行 |
| `fastpath_exceeded` | ✅ global・backend 双方で増加 |
| 負値/NaN/Inf/巨大値 | ✅ 無し |

**planted な「typo/単位バグ」は master には存在しない。** `pg_stat_us_to_ms()` の typo は
コミット `71fa15a` で修正済みで、その修正が正しく効いていることを実測で確認した。

唯一の意味論的注意点(バグではなく設計):`deadlock_timeout`(既定1s)未満で解消する
ロック待ちは **一切カウントされない**(§4)。

---

## 1. 実測 vs 統計値 対照表(根拠ログ付き)

| テスト | ロック種別 | 実施回数 | 実測待ち時間(壁時計) | `waits` | `wait_time`(ms) | 判定 |
|---|---|---|---|---|---|---|
| advisory ×1 | advisory | 1 | 2.508 s | **1** | **2499.441** | ✅ ms一致 |
| advisory ×3 | advisory | 3 | 4.823 s (合計) | **3** | **4794.183** | ✅ ms一致・二重集計無し |
| 行ロック ×2 | transactionid | 2 | 5.027 s (合計) | **2** | **5004.043** | ✅ ms一致 |
| backend整合 ×1 | advisory | 1 | — | global=**1** / backend=**1** | global=**2506.584** / backend=**2506.584** | ✅ 完全一致 |
| 短時間待ち | advisory | 1 | 0.406 s (<1s) | **0** | **0** | ⚠ 設計上カウントされない(§4) |

補足: `wait_time` は常に壁時計値より僅かに小さい(例 2499ms vs 2508ms)。これは統計側が
**サーバ内部でロック待ち開始時刻(deadlock timeout start)** から計測するのに対し、壁時計は
psql 起動・パース等のクライアント側往復を含むため。整合的で正常。

もし±1000倍の単位バグがあれば `2.5` か `2500000` になるはずだが、そのいずれでもない。

---

## 2. 単位・型・二重集計のソース的裏付け(観測の後追い)

観測された「µs保存 / ms表示」は以下と一致する。

- 計測箇所 `src/backend/storage/lmgr/proc.c:1612-1614` — **µs** で加算:
  `pgstat_count_lock_waits(type, (PgStat_Counter) secs * 1000000 + usecs)`
  (`(PgStat_Counter)` を乗算前に適用しており int64 で計算、オーバフロー無し)
- 保存 `src/include/pgstat.h:352` — `PgStat_Counter wait_time; /* time in microseconds */`
- 表示 `src/backend/utils/adt/pgstatfuncs.c:1761` — `Float8GetDatum(pg_stat_us_to_ms(wait_time))`
- 変換 `pgstatfuncs.c:1457-1461` — `return (double) val_us / 1000.0;`(µs→ms、÷1000)

二重集計が無い理由:global (`pgstat_lock.c` の `PendingLockStats`→`pgStatLocal.shmem->lock`) と
backend (`pgstat_backend.c` の `PendingBackendStats.pending_lock`→backend共有エントリ) は
**独立した pending バッファと独立した共有ストレージ**。1回の待機で両者へ各 +1 され、
各々別経路で flush される。同一イベントを平行に数える設計のため両者は「等しい」(合計ではない)。
実測で global==backend(2506.584 完全一致)を確認しこれを裏付けた。

---

## 3. 該当コミットの diff 確認(単位の一貫性)

- `8c579bd` "Add backend-level lock statistics" — `pg_stat_get_backend_lock(pid)` 追加。
- `c776550` "Change stat_lock.wait_time to double precision" —
  **保存単位を ms→µs に変更すると同時に、表示側へ ÷1000 変換を同一コミットで追加**。
  `proc.c` の計測も `msecs` → `secs*1000000+usecs` に変更。よって表示は ms のまま一貫。
  master 上に「µs保存だが変換無し(=1000倍)」の中間状態は存在しない。
- `3eca140` "Fix loss of precision" — `val_ms * 0.001` → `val_ms / 1000.0`(同一倍率、FP精度改善)。
- `71fa15a` "Fix typo in pg_stat_us_to_ms()" — **引数名 `val_ms`→`val_us` のみのリネーム**。
  演算 `/1000.0` は不変 = **挙動に影響なし**。したがって `71fa15a^` をビルドしても
  数値挙動は同一(diff から自明のため再ビルド比較は省略)。単位バグは実在しなかった。

---

## 4. 唯一の注意点: deadlock_timeout 未満の待ちは非カウント(設計)

`proc.c:1601` のガード `if (deadlock_state != DS_NOT_YET_CHECKED)` の内側でのみ
`pgstat_count_lock_waits()` が呼ばれる。すなわち **待ち時間が `deadlock_timeout`(既定1s)を
超えて deadlock チェックが走った待機のみ** が統計に載る。

実測(§1 最終行):0.4s の advisory 待ちは `waits=0, wait_time=0`。

これは `log_lock_waits` と同じ発火条件で、機能追加時からの意図的設計(性能クリティカルな
ロック獲得パスにカウンタを置かないため)。バグではないが、**pg_stat_lock は短時間の競合を
取りこぼし、総ロック待ち時間を過小計上する**という意味論を利用者は理解する必要がある。
今回の double化/typo 修正コミット由来の退行ではない。

---

## 5. backend単位の堅牢性(不正入力)

`pg_stat_get_backend_lock()` 観測結果(いずれもクラッシュ/assertion 無し):

| 入力 | 結果 |
|---|---|
| 自PID (`pg_backend_pid()`) | 12行(全 locktype) |
| 999999(存在しない) | 0行 |
| 0 / -1 | 0行 |
| walwriter PID | 12行(全0)— 追跡対象 bktype |
| checkpointer PID | 0行 — 非追跡 bktype |

aux プロセスで 12行/0行 に分かれるのは `pgstat_tracks_backend_bktype()`
(`pgstat_backend.c`)の設計通り(WAL writer は追跡、checkpointer/bgwriter/io worker/
autovac launcher は非追跡)。整合的で正常。

---

## 6. 再現スクリプト

`verification/lock-stats/repro/` に格納(要 `PGI=$HOME/pgi` のインストールと
`deadlock_timeout=1s`、非root起動)。

| スクリプト | 内容 |
|---|---|
| `test_advisory.sh` | advisory ×1、B の実測待ち計測 |
| `test_advisory_n.sh` | advisory ×3、reset→計数一致・二重集計無し |
| `test_rowlock.sh` | 行UPDATE 競合(transactionid ロック)×2 |
| `test_backend.sh` | FIFO で持続セッションBを制御、global↔backend 一致 |
| `test_fastpath2.sh` | 多パーティション AccessShareLock で fastpath_exceeded |
| `test_short.sh` | deadlock_timeout 未満待ち → 非カウント(§4) |

2セッション制御は bash バックグラウンドジョブ + `date` 実測、持続セッションは
名前付きパイプ(`mkfifo`)で実装。
