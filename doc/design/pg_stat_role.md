# pg_stat_role: ロールごとの累積統計ビュー 設計書

- 対象バージョン: PostgreSQL 19 (master) を想定
- ステータス: 設計提案 (実装前)

---

## 1. 目的と背景

PostgreSQL の累積統計システム (Cumulative Statistics System) は現在、
データベース単位 (`pg_stat_database`)、リレーション単位
(`pg_stat_user_tables` など)、関数単位、バックエンド単位
(`pg_stat_get_backend_*`) などの粒度で統計を提供しているが、
**「どのロールがどれだけクラスタ資源を使ったか」** を累積的に知る手段がない。

現状の代替手段には次の限界がある。

| 代替手段 | 限界 |
|---|---|
| `pg_stat_activity` | 現在のスナップショットのみ。切断後の履歴が残らない |
| バックエンド統計 (`PGSTAT_KIND_BACKEND`) | 切断とともに消滅する (`write_to_file = false`)。ロール単位への集約はビューの読み手が毎回行う必要があり、過去分は集約不能 |
| `pg_stat_statements` | contrib であり、クエリ単位。エビクションで古いエントリが消える。トランザクション数・セッション時間などは持たない |
| サーバログ集計 | `log_line_prefix` 等からの外部集計が必要で運用コストが高い |

そこで、ロールを主キーとする累積統計ビュー `pg_stat_role` をコアに追加する。

### 1.1 想定ユースケース

- **U1: マルチテナントの資源計上 (チャージバック)**
  テナント = ロールという構成で、テナントごとのトランザクション数・
  ブロックI/O・一時ファイル使用量などを課金・容量計画に使う。
- **U2: コネクションプーラ経由のテナント識別**
  PgBouncer 等のプーラが単一のログインロールで接続し、クライアント割当時に
  `SET ROLE tenant_x` を発行する構成 (RLS ベースのマルチテナントで一般的)。
- **U3: アプリケーション/チーム単位の負荷把握**
  アプリごとに接続ロールを分けている環境で、どのアプリが負荷源かを特定する。
- **U4: 異常検知**
  特定ロールのデッドロック数・ロールバック率の急増などを監視する。

**非目標 (Non-goals):** 本機能はセキュリティ監査 (誰が何をしたかの証跡) を
目的としない。監査はログ/pgAudit の領分であり、累積カウンタは証跡たり得ない。
また、リソース*制限* (クォータ) も対象外である。統計は観測のみを提供する。

---

## 2. 前提整理: PostgreSQL における「ロール」の2つの概念

本設計の中心論点を議論する前に、用語を厳密にする。

### 2.1 セッションロール (session role / session user)

- `GetSessionUserId()` (`src/backend/utils/init/miscinit.c`) が返すロール。
- 接続時の認証で確立され、以後は superuser による
  `SET SESSION AUTHORIZATION` でのみ変更可能。事実上、接続ごとに固定。
- `pg_stat_activity.usesysid` / `usename` はこれを表示する
  (`backend_status.c` の `st_userid`)。
- `current_setting('session_authorization')`、`session_user` に対応。

### 2.2 カレントロール (current role / current user)

- `GetUserId()` が返すロール。権限チェックの主体。
- 次の契機で変化する:
  1. `SET ROLE` / `SET LOCAL ROLE` (GUC `role` の assign フック
     `assign_role`、`src/backend/commands/variable.c:1026`)
  2. `SET SESSION AUTHORIZATION` (同 `assign_session_authorization`、
     `variable.c:912`。セッションロールとカレントロールの両方を変える)
  3. `ALTER ROLE ... SET role` / 関数の `SET` 句 (同じく GUC 機構経由)
  4. **SECURITY DEFINER 関数の実行中** (`fmgr_security_definer` が
     `SetUserIdAndSecContext()` を直接呼ぶ。GUC 機構を経由しない)
  5. 保守コマンドのセキュリティ制限コンテキスト (autovacuum、`REINDEX`、
     論理レプリケーション apply など。これも `SetUserIdAndSecContext()`)
- `current_user`、`current_setting('role')` に対応。

### 2.3 既存機能の帰属先の前例

| 既存機能 | 帰属先 |
|---|---|
| `pg_stat_activity.usename` | セッションロール |
| ログの `log_line_prefix %u` | セッションロール |
| `pg_stat_statements.userid` | **カレントロール** (`GetUserId()` をクエリ実行時に取得、`pg_stat_statements.c:1311`) |
| `pg_stat_progress_*` ビュー | 実行バックエンドのセッションロール |

つまりコア/エコシステムに両方の前例があり、「どちらが正しい」は自明でない。
これが本設計の中心論点である。

---

## 3. 中心論点: 帰属ディメンションとビュー構成

検討する選択肢は次の4つである。

- **案A**: 2つの別ビュー — `pg_stat_session_role` と `pg_stat_current_role`
- **案B**: 単一ビュー・複合キー — `(session_roleid, current_roleid)` の組ごとに1行
- **案C**: 単一ビュー・セッションロールのみ
- **案D**: 単一ビュー・カレントロールのみ

### 3.1 評価軸

1. **ユースケース充足度** — 特に U1/U2 (マルチテナント計上) を満たすか
2. **意味論の明確さ** — 「この行の数値は何か」を一文で説明できるか。
   トランザクション途中・クエリ途中でロールが変わるケースで
   カウンタの帰属が well-defined か
3. **実行時オーバーヘッド** — 計上バケット切替の頻度とコスト。
   特にホットパス (行単位で起こりうる SECURITY DEFINER 切替) を汚さないか
4. **メモリ/ディスク量** — 共有統計ハッシュ (dshash) のエントリ数、
   `pgstat.stat` ファイルサイズの上限挙動
5. **UI の単純さ** — 監視クエリの書きやすさ、二重計上の誤読リスク
6. **ライフサイクル管理** — `DROP ROLE` 時の掃除、リセット関数の意味論
7. **前例との整合性** — 既存ビュー群との一貫性、学習コスト

### 3.2 意味論上の根本問題 (全案共通の前提)

どの案でも避けて通れない事実:

**(a) カレントロールは1つのクエリの内部でも変わる。**
SECURITY DEFINER 関数が行ごとに呼ばれれば、行ごとに `GetUserId()` が
切り替わる。ブロック読取カウンタ等を厳密にカレントロールへ帰属させるには
`fmgr_security_definer` の入口/出口で全カウンタのスナップショット差分を
取る必要があり、ホットパスに許容不能なコストを載せる。

**(b) トランザクション粒度のカウンタは「1ロール」に紐づかないことがある。**
`xact_commit` は、途中で `SET ROLE` したトランザクションでは
「どのロールのコミットか」が本質的に曖昧である。何らかの規約
(例: コミット時点のロールに帰属) を*定義*するしかない。

**(c) セッション粒度のカウンタ (`sessions`, `session_time`) は
セッションに紐づく。** カレントロール別に分けるなら「その時間帯に
有効だったロールのバケットに時間を積む」という時間分割の規約が要る。

これらは「厳密なカレントロール帰属」が実装不能であることを意味する。
後述の通り、案Dはカレントロールの定義を弱めて (GUC レベルに限定して)
この問題を回避する。

### 3.3 案A: 2つの別ビュー (`pg_stat_session_role` + `pg_stat_current_role`)

**構成:** すべての計上ポイントで2回カウントする。統計 Kind も2つ
(`PGSTAT_KIND_SESSION_ROLE`, `PGSTAT_KIND_CURRENT_ROLE`)。

**利点:**
- 両方のユースケース (接続主体の把握と実効主体の把握) を単純な
  ビューで提供できる。各ビュー単体の意味論は明快。
- 各ビューの合計はそれぞれクラスタ全体と一致し、二重計上の誤読が
  起きにくい (ビューをまたいで合算する人はいない、という期待)。

**欠点:**
- **全計上ポイントのコストが2倍。** ペンディングエントリも共有ハッシュ
  エントリも統計ファイルも2倍。フラッシュコールバックも2本。
- 3.2(a)(b)(c) の意味論問題は解決しない。`pg_stat_current_role` 側は
  結局「弱いカレントロール」定義 (案D参照) を採らざるを得ず、そうなると
  **2ビューの差分は「SET ROLE を使った分」だけ**になる。非プーラ環境では
  両ビューがほぼ同一内容になり、差が出る環境 (プーラ) では
  セッションロール側はプーラのログインロール1行に縮退してほぼ無意味。
  つまり**どの環境でも片方のビューはほぼ死蔵される。**
- 相関情報 (セッションロール X が current role Y として何をしたか) は
  2つの周辺分布からは復元できない。「両方欲しい」動機の核心が
  相関であるなら、案Aはそれに応えられていない。
- ドキュメント/リセットAPI/DROP ROLE 処理/テストがすべて2系統。
  ユーザーは毎回「どちらを見るべきか」を判断させられる。

**評価:** コストが素朴に2倍になる一方、追加で得られる情報は
「SET ROLE 分の差分」のみで、相関という本質的な付加価値はない。
費用対効果が悪く、採用しない。

### 3.4 案B: 単一ビュー・複合キー `(session_roleid, current_roleid)`

**構成:** 統計エントリのキーをロールの組にする。実装上は
`PgStat_HashKey.objid` (uint64, `pgstat_internal.h:58`) の上位/下位 32bit に
2つの Oid をパックできるため、フレームワーク的には実現可能。
ビューは2つのロール列を持ち、周辺分布は `GROUP BY` で得る。

**利点:**
- **情報量が最大。** 両周辺分布に加えて相関も得られる唯一の案。
  「プーラロール経由で tenant_x として実行された分」を直接特定できる。
- 1行は1回だけカウントされるので、`SUM()` すればクラスタ全体と一致する。

**欠点:**
- **カーディナリティが O(ロール数²) に開きうる。** 実運用は
  「ログインロール数 × SET ROLE 先ロール数」で通常は穏当だが、
  上限保証がない。dshash と統計ファイルは可変長で伸びるため、
  多数のロールが相互に SET ROLE する病的ケースでメモリと
  `pgstat.stat` が肥大する。統計 Kind として初の「オブジェクト数を
  超えてエントリが増える」Kind になり、運用の予見性を損なう。
- **UI が恒常的に複雑。** 最頻ユースケース (単一ロールの数値が見たい)
  ですら `GROUP BY` が要る。監視ツールの対応コストも上がる。
  誤って両列で二重に集計するミスも誘発しやすい。
- `DROP ROLE` 時にキーの**どちらの半分**にも該当エントリがあり得るため、
  全エントリ走査 (`pgstat_drop_matching_entries()` 相当) が必要。
  リセット関数の引数仕様も (どちらのロール指定か) 複雑化する。
- 3.2 の意味論問題はそのまま残る (current 側の定義を決める必要がある)。
- 前例がない。既存の可変数 Kind はすべて「実在オブジェクト1個 = 1エントリ」。

**評価:** 相関が取れる点は唯一の本質的優位だが、その相関を必要とする
具体的な監視要件は U1〜U4 のいずれにもない (U2 はテナント別の値が
取れれば足り、経由プーラの内訳までは要らない)。上限のない
カーディナリティと恒常的な UI 複雑化という代償が、仮説的な便益に
見合わない。**将来の拡張候補として温存**し、初期設計では採用しない
(§9 参照。案Dは案Bへの後方互換な拡張パスを閉ざさない)。

### 3.5 案C: 単一ビュー・セッションロールのみ

**構成:** `pgstat_bestart()` 後に確定するセッションロールをキーに計上。
`SET SESSION AUTHORIZATION` (superuser のみ、稀) の時だけバケットを切替。

**利点:**
- **意味論が最も安定。** バケット切替が事実上ゼロで、3.2 の問題が
  ほぼ消える (トランザクション途中の切替が実質起きない)。実装が最も簡単。
- `pg_stat_activity.usename` / ログの `%u` と同じ軸なので、
  スナップショット・ログ・累積統計を同じキーで突合できる。

**欠点:**
- **U2 (プーラ + SET ROLE) で完全に無力。** すべての作業がプーラの
  ログインロール1行に積まれる。RLS ベースのマルチテナント —
  本機能の最有力ユースケース — で使い物にならない。
  トランザクションプーリングが標準になった現代の接続構成と相性が最悪。
- 「アプリごとにログインロールを分けている」環境 (U3) では機能するが、
  その環境では案Dでも同じ結果が得られる (後述)。つまり
  **案Cが案Dに勝つ環境が存在しない。**

**評価:** 実装は最も楽だが、最重要ユースケースを落とす。採用しない。

### 3.6 案D: 単一ビュー・カレントロールのみ (採用案)

**構成:** 単一ビュー `pg_stat_role`、1ロール = 1行。帰属先は
**「GUC レベルの実効ロール」** と定義する:

> **帰属ロール (attribution role)** = 直近に GUC 機構
> (`role` / `session_authorization` の assign フック) を通じて確立された
> カレントロール。`SetUserIdAndSecContext()` による一時的な切替
> (SECURITY DEFINER 関数、セキュリティ制限コンテキスト) は
> **帰属を変えない**。

すなわち、ログイン直後はセッションロールに等しく、`SET [LOCAL] ROLE` /
`SET SESSION AUTHORIZATION` / `ALTER ROLE ... SET role` / 関数 `SET` 句で
切り替わり、SECURITY DEFINER の内部では呼び出し側のまま維持される。

**この定義が 3.2 の問題を解決する仕組み:**

- (a) ホットパス問題: SECURITY DEFINER 切替で帰属を変えないため、
  `fmgr_security_definer` には一切手を入れない。バケット切替は
  GUC の assign フックという低頻度地点 (高々ステートメント単位) に限られる。
- (b) トランザクション粒度: 「コミット/アボート処理時点の帰属ロールに
  計上する」と規約化する。`SET LOCAL ROLE` はトランザクション終了時に
  GUC 巻き戻しで元に戻るが、統計計上 (`AtEOXact_PgStat`) は GUC の
  end-of-xact 処理より前に走るため、「そのトランザクションを主に実行した
  ロール」に自然に帰属する。エッジケース (途中の `SET ROLE`) は
  「最後に有効だったロール」に寄せると文書化する。
- (c) セッション粒度: `sessions` (接続数) は接続確立時の帰属ロール
  (= ログインロール) に計上。`session_time` / `active_time` /
  `idle_in_transaction_time` は「その時間帯の帰属ロールのバケットに積む」。
  これは規約というより**機能**である — プーラ環境でテナントごとの
  実行時間が取れる。

**利点:**

- **全ユースケースを1つの軸でカバーする。**
  - `SET ROLE` を使わない環境 (直接接続、アプリ別ログインロール):
    帰属ロール ≡ セッションロールなので、**案Cと完全に同じ結果**になる。
    つまり案Cの長所は案Dに包含される。
  - プーラ + `SET ROLE` 環境 (U2): テナントロールに正しく帰属する。
    案Cが落とす最重要ケースを拾う。
- **意味論を一文で説明できる:** 「`SET ROLE` 系コマンドで最後に
  設定した実効ロールに計上される。SECURITY DEFINER では変わらない」。
  SECURITY DEFINER を除外することは、資源計上の観点でも正しい —
  テナント A が呼んだ definer 関数のコストは (関数所有者ではなく)
  テナント A の消費である。
- **`pg_stat_statements.userid` と同じ側の軸**であり、既存の
  デファクト per-user 統計と整合する (あちらは純粋な `GetUserId()` だが、
  トップレベルクエリで観測する限り両者は一致する)。
- 単一 Kind・単一ビュー・1オブジェクト1エントリで、メモリ・ファイル・
  リセット・DROP ROLE のすべてが既存 Kind (database, subscription) と
  同型。エントリ数の上限は「ロール数」で自明に抑えられる。
- 各行は1回だけカウントされ、`SUM()` = クラスタ全体 (± 共有カタログ分の
  規約) が成り立ち、二重計上の誤読がない。

**欠点と反論:**

- *セッションロール軸の情報が失われる。*
  → 失われるのは「`SET ROLE` した分が誰のセッションだったか」のみ。
  リアルタイムには `pg_stat_activity` (usename ≠ current 表示だが
  接続主体は分かる)、証跡としてはログ `%u` が既に存在し、
  累積統計がこの軸を持つ必然性は薄い。監査は非目標 (§1.1)。
- *ロール切替を伴う瞬間のカウンタ帰属が規約依存になる。*
  → (b)(c) の通り規約を文書化する。累積統計は元来この種の近似を含む
  (例: `pg_stat_database` のセッション時間も報告タイミング依存)。
- *`GetUserId()` と厳密には一致しない (definer 内で乖離する)。*
  → 意図的な仕様であり、ドキュメントに明記する。「definer 関数内の
  コストを関数所有者に付けたい」という要望には `pg_stat_user_functions`
  と `pg_stat_statements` (track = all) が既に応えている。

### 3.7 比較まとめと結論

| 評価軸 | 案A (2ビュー) | 案B (複合キー) | 案C (session) | 案D (current) |
|---|---|---|---|---|
| U1 テナント計上 (直結続) | ○ | ○ | ○ | ○ |
| U2 プーラ + SET ROLE | ○ (current側のみ) | ○ | **×** | ○ |
| U3 アプリ別ロール | ○ | ○ | ○ | ○ |
| 意味論の単純さ | △ (2軸の使い分け) | × (2列キー) | ◎ | ○ (規約明文化で解決) |
| 実行時オーバーヘッド | × (全点2倍) | △ | ◎ | ○ (切替は GUC 頻度) |
| エントリ数上限 | ロール数×2 | **上限なし (R²)** | ロール数 | ロール数 |
| UI/監視クエリ | △ (2ビュー選択) | × (常に GROUP BY) | ◎ | ◎ |
| DROP ROLE/リセット | △ (2系統) | × (全走査) | ○ | ○ |
| 前例整合 | △ | × (前例なし) | ○ (activity系) | ○ (statements系) |

**結論: 案D を採用する。**
単一ビュー `pg_stat_role` とし、帰属先は「GUC レベルの実効ロール
(カレントロール)」とする。決め手は次の3点:

1. `SET ROLE` を使わない環境では案Cと同じ値になるため、案Dは案Cの
   **上位互換**であり、案Cを選ぶ積極的理由が存在しない。
2. 案A・案Bが追加で提供する情報 (セッション軸/相関) に、コストを
   正当化する具体的ユースケースがない。特に案Aは「どの環境でも片方の
   ビューが死蔵される」構造的欠陥を持つ。
3. SECURITY DEFINER を帰属から除外する規約により、唯一の実装上の
   難所 (ホットパスでのバケット切替) が消え、既存 Kind と同程度の
   複雑さで実装できる。

なお案Bへの拡張パスは閉ざされない: 将来、相関の実需が示されたら
`pg_stat_role_detail` のような別 Kind を追加すればよく、本設計の
`pg_stat_role` はその周辺分布ビューとしてそのまま両立できる。

---

## 4. カラム設計

### 4.1 カラム選定の方針

1. **`pg_stat_database` との照合可能性を最優先する。**
   ロールに帰属可能な既存カウンタは、`pg_stat_database` と同じ列名・
   同じ型・同じ単位で提供する。運用者は
   「Σ pg_stat_role.x ≒ Σ pg_stat_database.x」という突合を必ず行うため、
   命名や単位の独自改良 (§4.2) はしない。
2. **累積カウンタのみを載せる。** `numbackends` のような時点値は
   累積ビューに混ぜない (時点値は `pg_stat_activity` の集約で得られる)。
3. **計上コストが自明に小さいものだけを Phase 1 に含める。**
   具体的には (i) 既存のセッショングローバルカウンタ
   (`pgBufferUsage`, `pgWalUsage`) の差分スナップショットで取れるもの、
   (ii) 既存の低頻度報告関数 (`pgstat_report_*`) への1行追加で取れるもの。
   リレーション別ペンディングの畳み込みを要する `tup_*` 系は Phase 2 (§4.5)。
4. **各カウンタの帰属タイミングを明文化する** (§4.3 の「帰属」列)。
   原則は「計上ポイント実行時点の帰属ロール」だが、セッション終了系
   カウンタのみ例外を設ける (§4.3-h)。

### 4.2 命名の決定

- **`roleid`** — 候補は `userid` (`pg_stat_statements` の前例)、
  `usesysid` (`pg_stat_activity` の前例)、`roleid` (`pg_auth_members` の
  前例) の3つ。**`roleid` を採る。** 理由: (i) 本ビューには `NOLOGIN` の
  グループロールも行を持ちうる (`SET ROLE` の対象になるため)。"user" 系の
  名前はログイン可能ロールを連想させ誤解を招く。(ii) `usesysid` は
  廃止済み `pg_user` 由来の歴史的遺物で、新規採用する理由がない。
- **`rolname`** — `pg_authid.rolname` をそのまま使う
  (`datname` / `subname` と同じ「カタログ列名を流用する」流儀)。
  `rolename` などへの正規化はしない。
- **`blks_read` / `blks_hit`、時間列の `double precision` ミリ秒** —
  `pg_stat_database` の略記・型・単位に合わせる。`pg_stat_io` の新しい
  流儀 (`reads` / `hits`、`numeric` マイクロ秒) とは不整合になるが、
  本ビューの照合相手は `pg_stat_database` であり、そちらとの一貫性を優先。
- **`wal_records` / `wal_fpi` / `wal_bytes`** — `pg_stat_wal` および
  `pg_stat_statements` の列名・型 (`wal_bytes` は uint64 のため `numeric`)
  に合わせる。

### 4.3 カラム一覧 (Phase 1)

凡例 — 帰属: **[T]** = 計上ポイント実行時点の帰属ロール /
**[C]** = 接続時点の帰属ロール (= セッションロール) /
**[S]** = バケット切替時に時間・差分を分割して各ロールへ

| # | 列名 | 型 | 単位 | 計上ポイント | 帰属 |
|---|---|---|---|---|---|
| 1 | `roleid` | `oid` | — | (`pg_roles.oid`) | — |
| 2 | `rolname` | `name` | — | (`pg_roles.rolname`) | — |
| 3 | `xact_commit` | `bigint` | 回 | `AtEOXact_PgStat()` | [T] |
| 4 | `xact_rollback` | `bigint` | 回 | `AtEOXact_PgStat()` | [T] |
| 5 | `blks_read` | `bigint` | ブロック | `pgBufferUsage` 差分 | [S] |
| 6 | `blks_hit` | `bigint` | ブロック | `pgBufferUsage` 差分 | [S] |
| 7 | `blk_read_time` | `double precision` | ms | `pgBufferUsage` 差分 | [S] |
| 8 | `blk_write_time` | `double precision` | ms | `pgBufferUsage` 差分 | [S] |
| 9 | `wal_records` | `bigint` | 件 | `pgWalUsage` 差分 | [S] |
| 10 | `wal_fpi` | `bigint` | 件 | `pgWalUsage` 差分 | [S] |
| 11 | `wal_bytes` | `numeric` | バイト | `pgWalUsage` 差分 | [S] |
| 12 | `temp_files` | `bigint` | 個 | `pgstat_report_tempfile()` | [T] |
| 13 | `temp_bytes` | `bigint` | バイト | `pgstat_report_tempfile()` | [T] |
| 14 | `deadlocks` | `bigint` | 回 | `pgstat_report_deadlock()` | [T] |
| 15 | `session_time` | `double precision` | ms | 状態遷移時の時間計上 | [S] |
| 16 | `active_time` | `double precision` | ms | 同上 | [S] |
| 17 | `idle_in_transaction_time` | `double precision` | ms | 同上 | [S] |
| 18 | `sessions` | `bigint` | 個 | `pgstat_report_connect()` | [C] |
| 19 | `sessions_abandoned` | `bigint` | 個 | `pgstat_report_disconnect()` | [C] |
| 20 | `sessions_fatal` | `bigint` | 個 | `pgstat_report_disconnect()` | [C] |
| 21 | `sessions_killed` | `bigint` | 個 | `pgstat_report_disconnect()` | [C] |
| 22 | `parallel_workers_to_launch` | `bigint` | 個 | `pgstat_update_parallel_workers_stats()` | [T] |
| 23 | `parallel_workers_launched` | `bigint` | 個 | 同上 | [T] |
| 24 | `stats_reset` | `timestamptz` | — | リセット時 | — |

グループごとの詳細仕様:

**(a) 識別列 (#1-2)**
`pg_roles` との JOIN で得る (統計エントリ側には持たない)。ドロップ済み
ロールの遺残エントリは JOIN で自然に非表示になる。`rolname` は表示用の
利便であり、主キーはあくまで `roleid` (ロール名変更で行の同一性は不変)。

**(b) トランザクション (#3-4)**
コミット/アボート処理時点 ([T]) の帰属ロールに計上する。
`SET LOCAL ROLE` 中のコミットは、統計計上が GUC 巻き戻しより先に走るため
LOCAL 先のロールに帰属する (§3.6-b の規約通り。文書化必須)。
2PC は `pg_stat_database` と同じ扱い: `COMMIT PREPARED` を実行した
セッションの帰属ロールに `xact_commit` が付く (PREPARE したロールでは
ない)。パラレルワーカー自身のトランザクションは `pg_stat_database` 同様
計上しない。

**(c) ブロック I/O (#5-8)**
`pgBufferUsage` の shared block カウンタ
(`shared_blks_read/hit`, `shared_blk_read_time/write_time`) の
差分スナップショット方式 ([S]): バケット切替時 (§5.3) と統計フラッシュ時に
前回スナップショットとの差分を現帰属ロールへ計上する。

- **`pg_stat_database` とは計測系統が異なることを文書化する。**
  `pg_stat_database.blks_*` はリレーション統計の畳み込み由来
  (テーブル/インデックスアクセスのみ) だが、本ビューはカタログアクセス等を
  含む全 shared buffer アクセスを数える。したがって
  Σ `pg_stat_role.blks_read` ≥ Σ `pg_stat_database.blks_read` となる。
  系統を混ぜて「一致しない」と混乱させないための明記であり、
  むしろ資源計上としてはこちらが正確 (カタログ参照もそのロールの消費)。
- ローカルバッファ (一時テーブル) は Phase 1 では数えない
  (`pg_stat_database` にも相当列はなく、必要なら将来 `local_blks_*` を追加)。
- `blk_read_time` / `blk_write_time` は `track_io_timing = off` のとき 0
  (`pg_stat_database` と同じ)。差分スナップショットの副産物として
  取れるため Phase 1 に含める (初版設計からの変更点。§5.5 参照)。

**(d) WAL (#9-11)**
`pgWalUsage` の差分スナップショット ([S])。`pg_stat_database` には
存在しない列だが追加する。理由: U1 (チャージバック) では書き込み量の
ロール別把握が本質的で、`wal_bytes` はストレージ・レプリケーション帯域の
コストに直結する。計上機構は (c) とスナップショットを共有するため
追加コストは実質ゼロ。列仕様は `pg_stat_wal` と同一なのでクラスタ全体値
(`pg_stat_wal`) との突合も自然にできる。

**(e) 一時ファイル (#12-13)**
`pgstat_report_tempfile()` は一時ファイル削除時 (クエリ終了時) に走る。
その時点 ([T]) の帰属ロールに計上。関数 `SET` 句などでクエリ内に帰属が
変わった場合も「報告時点のロール」という単一規約で処理する。

**(f) デッドロック (#14)**
`pgstat_report_deadlock()` 時点 ([T])。デッドロックエラーを受けた側の
セッションの帰属ロールに計上される (原因を作った側ではない) ことを
文書化する。

**(g) 時間 (#15-17)**
`backend_status.c` の状態遷移処理 (`backend_status.c:610` 付近) で計上。
バケット切替時に経過時間を旧ロールへ締めるため、1セッションの時間が
複数ロールに分割されうる ([S])。これは仕様であり機能である —
プーラ環境で「テナントごとの実行時間」が取れる (§3.6-c)。
内部はマイクロ秒の `PgStat_Counter`、表示は `pg_stat_database` に合わせ
`double precision` ミリ秒。

**(h) セッション数 (#18-21) — 帰属規約の唯一の例外**
`sessions` は接続確立時のロール ([C]、事実上ログインロール) に計上する。
終了系 3 列 (`sessions_abandoned` / `sessions_fatal` / `sessions_killed`)
は切断時に走るが、**切断時点の帰属ロールではなく接続時点のロール [C] に
計上する**。理由:

- 行内不変条件
  `sessions_abandoned + sessions_fatal + sessions_killed ≤ sessions` を
  ロールごとに成立させるため。切断時のロールに付けると、
  `SET ROLE tenant_x` 中に kill されたセッションが
  「`sessions = 0` なのに `sessions_killed = 1`」という行を作り、
  監視クエリ (kill 率 = killed / sessions など) が破綻する。
- 「セッションの開始と終了は同じ主体の事象」という直観に沿う。

実装は接続時の帰属ロールを別変数に保持するだけ (§5.3)。
なお `SET SESSION AUTHORIZATION` してもセッション数は再カウントしない。

**(i) パラレルワーカー (#22-23)**
リーダーのクエリ終了時 ([T])。`pg_stat_database` の同名列 (PG18 追加) と
同じソースから取る。

**(j) `stats_reset` (#24)**
エントリ生成時は NULL、`pg_stat_reset_role_stats()` 実行時に設定
(`pg_stat_database.stats_reset` と同じ挙動)。

### 4.4 計上スコープ (どのプロセスが計上するか)

| プロセス | 計上 | 理由 |
|---|---|---|
| 通常のクライアントバックエンド | ○ | 本ビューの対象 |
| パラレルワーカー | × | (i) バッファ/WAL 使用量は `ExecParallelFinish()` → `InstrAccumParallelQuery()` (`execParallel.c:1262`, `instrument.c:299`) が**常に**リーダーの `pgBufferUsage` / `pgWalUsage` に合算するため、ワーカー側でも差分計上すると二重計上になる。リーダー側で一括計上する (パラレルバキューム等の合算機構も同様)。(ii) トランザクション数は `pg_stat_database` と同じく除外 |
| autovacuum ワーカー | × | 帰属ロールが実質ブートストラップスーパーユーザーに固定され、そこへ I/O を積んでも監視上の意味がない。autovacuum の I/O は `pg_stat_io` が backend type 軸で既にカバー |
| walsender / バックグラウンドワーカー | × | セッション統計の対象外 (`pgstat_should_report_connstat()`、`pgstat_database.c:387` と同じ線引き) |

判定は「`pgstat_report_connect()` が接続を数えるプロセス
(= 通常のクライアントバックエンド) でのみロール統計を有効化する」に
一本化し、`pg_stat_database` のセッション統計と同じ境界を使う。

### 4.5 採用しなかった / 先送りしたカラム

| 列 | 判定 | 理由 |
|---|---|---|
| `tup_returned` / `tup_fetched` / `tup_inserted` / `tup_updated` / `tup_deleted` | **Phase 2** | リレーション別ペンディングのフラッシュ時に DB エントリへ畳み込む既存構造 (`pgstat_relation.c`) では、計上発生時とフラッシュ時で帰属ロールが乖離しうる。バケットクローズ時の強制畳み込みが必要で、Phase 1 の複雑さを不当に上げる。追加時は #6 (`blks_hit`) の直後に置く (メジャーリリース間の列順変更は許容) |
| `numbackends` 相当 | 不採用 | 時点値。`SELECT usename, count(*) FROM pg_stat_activity GROUP BY 1` で得られる。ただし `pg_stat_activity.usename` はセッションロール軸なので、厳密な「現在の帰属ロール別接続数」は取れないことをドキュメントに注記 |
| `conflicts` + リカバリ競合内訳 | 不採用 | スタンバイ限定の事象で、`pg_stat_database_conflicts` が DB 軸で提供済み。ロール軸の需要が示されたら将来追加可能 (計上点 `pgstat_report_recovery_conflict()` に1行足すだけ) |
| `checksum_failures` / `last_checksum_failure` | 不採用 | ストレージ破損はロールの資源消費でも行動でもなく、「どのロールが踏んだか」に監視価値がない |
| `last_autovac_time` 等 | 対象外 | DB/リレーション固有の概念 |
| クエリ実行数・実行時間 | 不採用 | `pg_stat_statements` の領分 (userid 軸で既に取れる)。コアの本ビューはセッション/トランザクション/資源系に限定 |
| I/O 詳細 (evictions, fsyncs, hits by context...) | 不採用 | `pg_stat_io` の backend type 軸の領分。軸の直交性 (role × 概要 vs backend type × 詳細) を保つ |

### 4.6 ビュー定義 (DDL)

`src/backend/catalog/system_views.sql` に追加:

```sql
CREATE VIEW pg_stat_role AS
    SELECT
        r.oid AS roleid,
        r.rolname,
        s.xact_commit,
        s.xact_rollback,
        s.blks_read,
        s.blks_hit,
        s.blk_read_time,
        s.blk_write_time,
        s.wal_records,
        s.wal_fpi,
        s.wal_bytes,
        s.temp_files,
        s.temp_bytes,
        s.deadlocks,
        s.session_time,
        s.active_time,
        s.idle_in_transaction_time,
        s.sessions,
        s.sessions_abandoned,
        s.sessions_fatal,
        s.sessions_killed,
        s.parallel_workers_to_launch,
        s.parallel_workers_launched,
        s.stats_reset
    FROM pg_roles r,
         LATERAL pg_stat_get_role_stats(r.oid) AS s;
```

設計メモ:

- **`pg_authid` ではなく `pg_roles` を JOIN する。** `pg_authid` は
  superuser 以外読めないため、ビューが一般ユーザーに対して空になる
  事故を避ける (`pg_stat_database` が world-readable な `pg_database` を
  JOIN しているのと同じ構図)。
- **統計エントリを持たないロールは行を出さない。**
  `pg_stat_database` は全 DB を出す前例だが、ロールは DB より遥かに
  多くなりうる (LDAP 同期環境で数千など) うえ、大半が一度も活動しない。
  `pg_stat_get_role_stats()` がエントリ不在時に 0 行を返す
  (`pg_stat_get_subscription_stats` 型の SRF) ことで LATERAL JOIN が
  自然にフィルタになる。

### 4.7 サポート関数と不変条件

`src/include/catalog/pg_proc.dat` に追加:

| 関数 | 戻り値 | 説明 |
|---|---|---|
| `pg_stat_get_role_stats(oid)` | `setof record` (0/1行、OUT 列は §4.3 の #3-24) | 指定ロールの全カウンタ。エントリ不在なら 0 行。`provolatile = 's'`, `proparallel = 'r'` (他の pgstat SRF と同じ。`stats_fetch_consistency` によるスナップショットが自動で効く) |
| `pg_stat_reset_role_stats(oid)` | `void` | 指定ロールの統計をリセット (`pg_stat_reset_subscription_stats` と同型)。NULL で全ロール分リセット |

**行内不変条件 (テストで検証する):**

- `sessions_abandoned + sessions_fatal + sessions_killed ≤ sessions`
  (§4.3-h の帰属規約 [C] により保証)
- `active_time + idle_in_transaction_time ≤ session_time`
  (報告粒度による誤差を除く。`pg_stat_database` と同水準)

**クラスタ全体値との照合 (ドキュメントに明記する):**

- Σ `xact_commit` / Σ `sessions` 等 ≒ `pg_stat_database` の合計
  (フラッシュタイミング差と §4.4 のスコープ差のみ)
- Σ `blks_*` は `pg_stat_database` の合計と**一致しない** (§4.3-c、
  計測系統が異なる)
- Σ `wal_*` ≒ `pg_stat_wal` のバックエンド由来分
  (バックグラウンドプロセスの WAL は含まない)

---

## 5. 実装設計

### 5.1 統計 Kind の追加

`src/include/utils/pgstat_kind.h`:

```c
/* stats for variable-numbered objects */
#define PGSTAT_KIND_DATABASE      1
#define PGSTAT_KIND_RELATION      2
#define PGSTAT_KIND_FUNCTION      3
#define PGSTAT_KIND_REPLSLOT      4
#define PGSTAT_KIND_SUBSCRIPTION  5
#define PGSTAT_KIND_BACKEND       6
#define PGSTAT_KIND_ROLE          7   /* per-role statistics */

/* stats for fixed-numbered objects */
#define PGSTAT_KIND_ARCHIVER      8   /* 以下、既存の固定 Kind を +1 */
...
```

- 可変 Kind グループの末尾に挿入し、固定 Kind を繰り下げる
  (`PGSTAT_KIND_BACKEND` = 6 が挿入されたときと同じ流儀)。
- Kind ID は `pgstat.stat` に永続化されるため
  **`PGSTAT_FILE_FORMAT_ID` をバンプする** (`pgstat.h:221`)。
  メジャーリリース内でのみ許される変更であり問題ない。

`src/backend/utils/activity/pgstat.c` の `pgstat_kind_builtin_infos[]`:

```c
[PGSTAT_KIND_ROLE] = {
    .name = "role",

    .fixed_amount = false,
    .write_to_file = true,
    /* ロールは共有オブジェクトなので全 DB から見える必要がある */
    .accessed_across_databases = true,

    .shared_size = sizeof(PgStatShared_Role),
    .shared_data_off = offsetof(PgStatShared_Role, stats),
    .shared_data_len = sizeof(((PgStatShared_Role *) 0)->stats),
    .pending_size = sizeof(PgStat_StatRoleEntry),

    .flush_pending_cb = pgstat_role_flush_cb,
    .reset_timestamp_cb = pgstat_role_reset_timestamp_cb,
},
```

- ハッシュキーは `{kind = PGSTAT_KIND_ROLE, dboid = InvalidOid,
  objid = (uint64) roleoid}`。ロールは共有オブジェクトなので
  `dboid = InvalidOid` (レプリケーションスロット Kind と同型)。
- `write_to_file = true` — 案Dの存在意義 (切断後も残る累積値) の核心。

### 5.2 データ構造

`src/include/pgstat.h`:

```c
typedef struct PgStat_StatRoleEntry
{
    PgStat_Counter xact_commit;
    PgStat_Counter xact_rollback;
    PgStat_Counter blks_read;
    PgStat_Counter blks_hit;
    PgStat_Counter blk_read_time;   /* microseconds */
    PgStat_Counter blk_write_time;  /* microseconds */
    PgStat_Counter wal_records;
    PgStat_Counter wal_fpi;
    uint64         wal_bytes;
    PgStat_Counter temp_files;
    PgStat_Counter temp_bytes;
    PgStat_Counter deadlocks;
    PgStat_Counter session_time;            /* microseconds */
    PgStat_Counter active_time;             /* microseconds */
    PgStat_Counter idle_in_transaction_time;    /* microseconds */
    PgStat_Counter sessions;
    PgStat_Counter sessions_abandoned;
    PgStat_Counter sessions_fatal;
    PgStat_Counter sessions_killed;
    PgStat_Counter parallel_workers_to_launch;
    PgStat_Counter parallel_workers_launched;

    TimestampTz stat_reset_timestamp;
} PgStat_StatRoleEntry;
```

新規ファイル `src/backend/utils/activity/pgstat_role.c` に、
`pgstat_database.c` と同型の実装を置く:
`pgstat_prep_role_pending()`, `pgstat_role_flush_cb()`,
`pgstat_fetch_stat_roleentry()`, 各種 `pgstat_report_role_*()`。

### 5.3 帰属ロールの追跡

バックエンドローカルに帰属ロールを1つ保持する:

```c
/* pgstat_role.c */
static Oid pgstat_attribution_roleid = InvalidOid;  /* 現在の帰属ロール */
static Oid pgstat_connect_roleid = InvalidOid;      /* 接続時の帰属ロール
                                                     * (§4.3-h のセッション
                                                     * 終了系カウンタ専用) */
```

更新契機は2箇所のみ:

1. **接続確立時**: `pgstat_bestart()` 後 (`InitPostgres` 内)、
   セッションロールで初期化。同時に `sessions` を +1。
2. **GUC assign フック**: `assign_role()` / `assign_session_authorization()`
   (`variable.c`) から `pgstat_report_role_change(Oid newroleid)` を呼ぶ。
   GUC のトランザクション巻き戻し (SET LOCAL の復元、ABORT 時の復元) も
   assign フック経由で通るため、追跡漏れがない。

`pgstat_report_role_change()` は:
- 時間系カウンタとブロックI/O (§5.4) の未計上分を旧ロールの
  ペンディングエントリに畳み込み (バケットクローズ)、
- `pgstat_attribution_roleid` を更新する。

`SetUserIdAndSecContext()` には**一切手を入れない** (§3.6 の規約)。
これによりパラレルワーカー・autovacuum 等での偽帰属も避けられる
(パラレルワーカーはリーダーの GUC を復元するため、ワーカー内の計上も
正しくリーダーの帰属ロールに載る)。

### 5.4 計上ポイント

既存の `pg_stat_database` 向け計上ポイントに、帰属ロールへの計上を併設する:

| カウンタ | 計上ポイント (既存関数に追記) |
|---|---|
| `xact_commit` / `xact_rollback` | `AtEOXact_PgStat()` (現在 DB エントリに計上している箇所) |
| `sessions` | `pgstat_report_connect()` (`pgstat_database.c`)。同時に `pgstat_connect_roleid` を確定 |
| `sessions_abandoned` / `sessions_fatal` / `sessions_killed` | `pgstat_report_disconnect()`。`pgstat_connect_roleid` に計上 (§4.3-h) |
| `session_time`, `active_time`, `idle_in_transaction_time` | `pgstat_count_conn_*` マクロ群 (`pgstat.h:675` 付近、呼び出し元は `backend_status.c:610` の状態遷移処理)。既存マクロを DB/ロール両建てに拡張 |
| `temp_files` / `temp_bytes` | `pgstat_report_tempfile()` |
| `deadlocks` | `pgstat_report_deadlock()` |
| `blks_read` / `blks_hit` / `blk_read_time` / `blk_write_time` | `pgBufferUsage` のスナップショット差分。バケットクローズ時 (§5.3) と `pgstat_report_stat()` のフラッシュ時に、前回スナップショットとの差分を現帰属ロールに計上 |
| `wal_records` / `wal_fpi` / `wal_bytes` | `pgWalUsage` のスナップショット差分 (上と同じタイミングで一括処理) |
| `parallel_workers_*` | `pgstat_update_parallel_workers_stats()` |

計上はすべて §4.4 のスコープ判定 (通常のクライアントバックエンドのみ、
パラレルワーカー除外) の内側で行う。
ペンディングは標準機構 (`pgstat_prep_pending_entry()`) をそのまま使う。
通常のバックエンドでは同時にペンディングを持つロールエントリは
高々 1〜2 個 (SET ROLE 直後のみ 2 個) であり、フラッシュコストは
`pg_stat_database` 1 エントリ分とほぼ同等。**新 GUC は追加しない**
(既存の `track_counts` の傘下とする)。

### 5.5 初期実装から除外するカウンタ (Phase 2)

`tup_returned/fetched/inserted/updated/deleted` は初期実装から外す
(§4.5)。理由:

- `tup_*` はリレーション別ペンディング (`pgstat_relation.c`) の
  フラッシュ時に DB エントリへ畳み込まれる構造であり、フラッシュ時点の
  帰属ロールと計上発生時のロールが乖離しうる。正確化には
  バケットクローズ時のリレーションペンディング強制畳み込みが必要で、
  初期パッチの複雑さを不当に上げる。
- コミュニティ投稿時のパッチ分割 (レビュー容易性) の観点でも、
  コア機構 + 基本カウンタを Phase 1 とするのが妥当。

なお初版設計で Phase 2 としていた `blk_read_time` / `blk_write_time` は、
`pgBufferUsage` 差分スナップショット (§4.3-c) の副産物として追加コストなく
取れることが判明したため Phase 1 に繰り上げた。同じ理由で `wal_*` 3列も
Phase 1 に含める (§4.3-d)。

### 5.6 ライフサイクル

- **DROP ROLE**: `DropRole()` (`src/backend/commands/user.c`) に
  `pgstat_drop_transactional(PGSTAT_KIND_ROLE, InvalidOid, roleoid)` を追加
  (サブスクリプション/DB と同型。ROLLBACK されれば統計も残る)。
- **エントリ生成**: 遅延生成 (初回計上時)。`CREATE ROLE` では何もしない。
- **クラッシュ時**: 統計ファイルはクリーンシャットダウン時のみ書かれる
  既存挙動に従う (クラッシュで全統計消失、遺残エントリ問題も同時に消える)。
- **pg_upgrade**: 既存 Kind 同様、統計は引き継がない。
- **リセット**: `pg_stat_reset_role_stats(oid)`。
  `pg_stat_reset()` (DB 単位) はロール統計に触れない —
  ロールは共有オブジェクトであり DB 単位リセットの対象外
  (`pg_stat_reset_shared('role')` 系に寄せるかは §9 のオープン課題)。

### 5.7 可視性・権限

- ビューの行は**全ユーザーに可視**とする。`pg_stat_database` /
  `pg_stat_user_tables` が他者の活動量カウンタを既に世界公開している
  現状と整合し、行フィルタの複雑さを避ける。
- カウンタは活動量のみで、クエリ文字列等の機微情報を含まない。
- より厳格な運用が必要なサイトは
  `REVOKE SELECT ON pg_stat_role FROM PUBLIC` +
  `GRANT ... TO pg_read_all_stats` で自衛できる (ビューなので可能)。
  行レベルの絞り込み (`has_privs_of_role()` フィルタ) は
  「monitoring ツールが全体を見られない」副作用が大きく、初期実装では
  採らない (§9)。
- `pg_stat_reset_role_stats()` の実行権限はデフォルト superuser、
  `pg_stat_reset_*` 系の慣例に従い `GRANT` 可能とする。

---

## 6. 動作例

```sql
-- プーラ構成: pooler ロールでログインし、テナントに SET ROLE する
-- (pooler が tenant_a のメンバーである前提)
SET ROLE tenant_a;
BEGIN;
INSERT INTO orders VALUES (...);
COMMIT;                          -- xact_commit は tenant_a に +1
RESET ROLE;

SELECT rolname, xact_commit, blks_read, active_time
FROM pg_stat_role
ORDER BY active_time DESC;

   rolname  | xact_commit | blks_read | active_time
 -----------+-------------+-----------+-------------
  tenant_a  |        1523 |     88123 |   9231882.1
  tenant_b  |         310 |      9021 |    831021.9
  pooler    |          12 |        45 |      1021.3   ← SET ROLE 前のわずかな分
```

SECURITY DEFINER の例: `tenant_a` が `admin` 所有の definer 関数を呼んでも、
その関数内のブロック読取・コミットは `tenant_a` に計上される (§3.6 の規約)。

---

## 7. テスト計画

- `src/test/regress/sql/stats.sql` に追加:
  - 接続ロールへの基本計上 (sessions, xact_commit)
  - `SET ROLE` 後の帰属切替、`RESET ROLE` での復帰
  - `SET LOCAL ROLE` + COMMIT/ROLLBACK の帰属規約
  - SECURITY DEFINER 関数内の計上が呼び出し側ロールに載ること
  - `pg_stat_reset_role_stats()` の効果と `stats_reset` 更新
  - `DROP ROLE` 後にビューから行が消えること /
    トランザクション内 DROP ROLE + ROLLBACK で統計が残ること
- TAP テスト: クリーン再起動をまたいだ統計の永続化
  (`t/030_stats_cleanup_replica.pl` 等の既存パターンに準拠)、
  `pg_stat_have_stats('role', 0, oid)` によるエントリ存在確認。
- レギュレッションの並列実行でロール統計が相互干渉しないよう、
  テスト専用ロール名の規約 (`regress_stat_role_*`) を使う。

## 8. ドキュメント計画

- `doc/src/sgml/monitoring.sgml`: ビュー・列の説明。特に
  **帰属規約 (SET ROLE 系で切替わり、SECURITY DEFINER では切替わらない)**
  を独立段落で明記する。`pg_stat_activity.usename` (セッションロール)
  との軸の違いに注意書きを置く。
- `pg_stat_reset_role_stats()` を関数一覧に追加。
- リリースノート項目案を含める。

## 9. オープン課題 (コミュニティ議論に委ねる点)

1. **行の可視性**: 世界公開 (本設計) vs `pg_read_all_stats` +
   自ロールのみ。マルチテナント事業者からの要望次第で再考。
2. **Phase 2 カウンタ**: `tup_*` 系の畳み込み実装 (§4.5)。
   一時テーブル用の `local_blks_*` を足すかどうかも同時に判断。
3. **リセット API の形**: 専用関数 (本設計) vs
   `pg_stat_reset_shared('role')` への統合。
4. **複合キー拡張** (§3.4 案B): 相関の実需が示された場合の
   `pg_stat_role_detail` 追加。本設計とは独立に追加可能。
5. **ビュー名**: `pg_stat_role` (単数、`pg_stat_database` に整合) を
   採るが、`pg_stat_roles` を好む向きもありうる。

---

## 付録A: 却下案の要約

| 案 | 却下理由 (要約) |
|---|---|
| A: `pg_stat_session_role` + `pg_stat_current_role` の2ビュー | 全計上コスト2倍。相関は取れず、差分情報は「SET ROLE 分」のみ。どの環境でも片方が死蔵される |
| B: `(session, current)` 複合キー単一ビュー | エントリ数に上限がなく (O(R²))、UI が恒常的に複雑。相関を要する具体ユースケースが現状ない。将来拡張として温存 |
| C: セッションロールのみ | プーラ + SET ROLE (RLS マルチテナント) で無力。案Dの真部分集合であり、Cが勝る環境が存在しない |
| バックエンド統計の読取時集約 | `write_to_file = false` のため切断で消え、累積要件を満たさない |

## 付録B: 変更ファイル一覧 (Phase 1 見積り)

| ファイル | 変更内容 |
|---|---|
| `src/include/utils/pgstat_kind.h` | `PGSTAT_KIND_ROLE` 追加、固定 Kind 繰り下げ |
| `src/include/pgstat.h` | `PgStat_StatRoleEntry`、関数宣言、`PGSTAT_FILE_FORMAT_ID` バンプ |
| `src/include/utils/pgstat_internal.h` | `PgStatShared_Role`、内部宣言 |
| `src/backend/utils/activity/pgstat_role.c` | **新規**: 計上・フラッシュ・フェッチ |
| `src/backend/utils/activity/pgstat.c` | Kind 情報テーブル追加 |
| `src/backend/utils/activity/pgstat_database.c` | 接続/tempfile/deadlock 計上点の両建て化 |
| `src/backend/utils/activity/pgstat_xact.c` | コミット/アボート計上の両建て化 |
| `src/backend/utils/activity/backend_status.c` | 時間カウンタの両建て化 |
| `src/backend/commands/variable.c` | `assign_role` / `assign_session_authorization` から帰属切替通知 |
| `src/backend/commands/user.c` | `DropRole()` に `pgstat_drop_transactional()` |
| `src/backend/utils/adt/pgstatfuncs.c` | `pg_stat_get_role_stats()`, `pg_stat_reset_role_stats()` |
| `src/include/catalog/pg_proc.dat` | 関数カタログエントリ (+ `catversion.h` バンプ) |
| `src/backend/catalog/system_views.sql` | `pg_stat_role` ビュー定義 |
| `doc/src/sgml/monitoring.sgml` | ドキュメント |
| `src/test/regress/sql/stats.sql` ほか | テスト |
