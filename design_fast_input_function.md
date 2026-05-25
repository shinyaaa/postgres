# 設計提案: 型入力関数の「軽量エントリポイント」申告機構

**ステータス**: 設計調査（実装は int4 の例示スケッチのみ）
**対象**: COPY FROM をはじめとする「文字列 → 内部値(Datum)」変換ホットパスの高速化
**モデル**: planner support function (`pg_proc.prosupport`) 機構

---

## 1. 問題定義とオーバーヘッドの内訳

### 1.1 現状の呼び出し経路

COPY FROM (text/CSV) は 1 フィールドごとに型入力関数を呼ぶ:

- `CopyFromTextLikeOneRow()` (`src/backend/commands/copyfromparse.c:1046`)
  → `InputFunctionCallSafe(&in_functions[m], string, typioparams[m], att->atttypmod, escontext, &values[m])`
- `in_functions[]` は `BeginCopyFrom` 内で
  `CopyFromTextLikeInFunc()` (`src/backend/commands/copyfrom.c:204`) が
  `getTypeInputInfo()` → `fmgr_info()` で構築する。

`InputFunctionCallSafe()` (`src/backend/utils/fmgr/fmgr.c:1585`) の中身:

```c
LOCAL_FCINFO(fcinfo, 3);                       /* (1) スタック確保 */
if (str == NULL && flinfo->fn_strict) { ... }  /* (2) strict 判定 */
InitFunctionCallInfoData(*fcinfo, flinfo, 3, InvalidOid, escontext, NULL); /* (3) 6 フィールド初期化 */
fcinfo->args[0].value = CStringGetDatum(str);  fcinfo->args[0].isnull = false; /* (4) 引数梱包 */
fcinfo->args[1].value = ObjectIdGetDatum(typioparam); fcinfo->args[1].isnull = false;
fcinfo->args[2].value = Int32GetDatum(typmod); fcinfo->args[2].isnull = false;
*result = FunctionCallInvoke(fcinfo);          /* (5) 間接呼び出し (*fn_addr)(fcinfo) */
if (SOFT_ERROR_OCCURRED(escontext)) return false; /* (6) ソフトエラー検査 */
... NULL 整合性チェック ...                       /* (7) */
```

その先 `int4in()` (`src/backend/utils/adt/int.c:316`) は実質:

```c
char *num = PG_GETARG_CSTRING(0);              /* fcinfo->args[0] を読む */
PG_RETURN_INT32(pg_strtoint32_safe(num, fcinfo->context)); /* 実処理 + isnull=false */
```

### 1.2 削れるコスト

「実処理」は `pg_strtoint32_safe(const char *s, Node *escontext)`
(`src/backend/utils/adt/numutils.c:388`) であり、**既に escontext 対応・fcinfo 非依存**。
ホットパスで純粋に無駄なのは (1)(3)(4)(5)(7) と `PG_GETARG_*`/`PG_RETURN_*` のラッピング:

| 項目 | 内容 | 数百万行 × 列での影響 |
|---|---|---|
| (1) LOCAL_FCINFO | union のスタック確保（3 引数分 = base + 3×NullableDatum） | 軽微だが毎回 |
| (3) InitFunctionCallInfoData | flinfo/context/resultinfo/fncollation/isnull/nargs の 6 書き込み | 毎回 |
| (4) 引数梱包 | 3 引数 × (value, isnull) = 6 書き込み + 型変換マクロ | 毎回 |
| (5) FunctionCallInvoke | `(*fcinfo->flinfo->fn_addr)(fcinfo)` の**間接呼び出し**（分岐予測・インライン化阻害） | 毎回 |
| GETARG/RETURN | args 配列の読み戻し、isnull 書き戻し | 毎回 |

過去の PoC（int2/int4/int8/float4/float8 の入力関数 OID を直書きし `pg_strtoint32_safe` 等を直接呼ぶ）で
text/CSV の整数中心ワークロードで **3〜8% 短縮**。`DirectInputFunctionCallSafe()`
(`src/backend/utils/fmgr/fmgr.c:1640`) は「直接 C 関数ポインタ」版だが、**依然 LOCAL_FCINFO と引数梱包を行う**
ため (1)(3)(4)(7) を削れていない点に注意（真の fcinfo-free ではない）。本提案は fcinfo を一切作らない。

### 1.3 真の問題（動機）

PoC の高速化自体ではなく、**「int4 の入力 = `pg_strtoint32_safe`」という型↔変換処理の対応を
呼び出し側 (COPY) に手書きで複製した**こと。これは単一真実源（`pg_type.typinput` → `pg_proc`）の
外にコピーを作る leaky abstraction / 契約の二重化であり、本家が `int4in` の中身を変えると
気づかぬまま COPY 側がズレる。**特別扱いを呼び出し側に散らさず、型/関数自身に申告させたい。**

---

## 2. 候補設計

軽量 ABI（共通の入口シグネチャ）をまず定義する。input 関数の guts が既に取る形に合わせる:

```c
/* fmgr.h に追加する想定 */
typedef bool (*FastInputFunction) (const char *str,
                                   Oid typioparam,
                                   int32 typmod,
                                   Oid collation,
                                   fmNodePtr escontext,   /* Node *、ソフトエラー */
                                   Datum *result);        /* 戻り: 成功=true */
```

`str == NULL` は strict 規約により呼び出し側で処理（後述）。`typioparam`/`typmod`/`collation` は
渡すが、無視できる型はそのまま無視してよい（int4 等）。**必要な型（typmod が意味を持つ numeric/varchar、
collation が意味を持つ型）は、その型が fast 入口を申告しない（NULL を返す）ことで安全に従来経路へ落ちる。**

### (a) COPY ローカル直書き（試作した方式）

`CopyFromTextLikeOneRow` 内で `in_functions[m].fn_oid` を見て `F_INT4IN` 等なら
`pg_strtoint32_safe` を直接呼ぶ。

- 速度: ◎（最短）。抽象の純度: ✗（契約二重化・leaky）。影響範囲: COPY のみ。本家受容性: ✗。

### (b) fmgr 入力ラッパ層に OID テーブルを集約

`InputFunctionCallSafe` 内に「OID → 軽量関数ポインタ」表を持ち、合致したら fcinfo を作らず直接呼ぶ。

- 速度: ○（ただしホットパスに表引きが入る）。抽象の純度: △（複製を 1 箇所に集約しただけ。真実源外なのは同じ）。
  影響範囲: `InputFunctionCallSafe` 全呼び出し元が自動で恩恵。本家受容性: △（拡張型を救えない、表の保守が残る）。

### (c) 型/関数が軽量入口を申告（本提案）

入力関数が、prosupport 流の「サポート関数」経由で自分の fast 入口を core に申告する。
呼び出し側は OID 直書きせず、申告があれば自動で速い経路、無ければ従来 fmgr 経路。

- 速度: ○〜◎（申告解決を**セットアップ時 1 回**に寄せればホットパスは直接呼び出しのみ）。
  抽象の純度: ◎（対応は型/関数側に閉じ、真実源の隣に置かれる）。影響範囲: 任意の呼び出し元 + 拡張型。
  本家受容性: ○（既存 prosupport の拡張プロトコルに乗る）。

### 比較表

| 観点 | (a) COPYローカル | (b) fmgr OID表 | (c) 型/関数が申告 |
|---|---|---|---|
| 速度 | ◎ 最短 | ○ 表引き分損 | ○〜◎ 解決をセットアップ時に寄せれば最短 |
| 抽象の純度 | ✗ 契約二重化 | △ 集約しただけ | ◎ 真実源の隣 |
| 影響範囲 | COPY のみ | 全 InputFunctionCallSafe 呼出元 | 全呼出元 + 拡張型 |
| 拡張型対応 | ✗ | ✗ | ◎ |
| 後方互換 | n/a | ○ | ◎ 申告無→従来経路 |
| 本家受容性 | ✗ | △ | ○ prosupport 前例あり |
| 実装規模 | 小 | 中 | 中〜大 |

---

## 3. 推奨設計（(c) の具体化）

### 3.1 申告先: 既存 `pg_proc.prosupport` を再利用（新カタログ列を足さない）

`prosupport` は `regproc prosupport BKI_DEFAULT(0) BKI_LOOKUP_OPT(pg_proc)`
(`src/include/catalog/pg_proc.h:58`) で、関数に紐づく「core へ関数固有情報を供給する」汎用フックである。
起源スレッドのタイトルも *"Allowing extensions to supply operator-/function-specific info"*（planner 限定ではない）。
サポート関数は**未知の request ノードには NULL を返す**プロトコルなので、新 request 種別を足すだけで拡張できる。

→ **入力関数 `int4in` に `prosupport => 'int4in_support'` を `pg_proc.dat` で付与**するだけ。
新カタログ列・新 SQL 構文・catalog version 以外の bootstrap 変更は不要。

> 代替: 専用の新列 `pg_proc.proinputfast`（または `pg_type.typinputfast`）。
> メリットはホットパスでの解決が単純（OidFunctionCall 不要）。デメリットはカタログ列追加の重さと、
> pg_type 案だと「関数ではなく型に紐づく」ため prosupport 流と不整合。**第一候補は prosupport 再利用、
> 反対が強ければ専用列にフォールバック**（§7 の論点1）。

### 3.2 リクエストノードと申告 ABI

`src/include/nodes/supportnodes.h` に追加:

```c
typedef struct SupportRequestInputFunction
{
    NodeTag     type;
    /* input: 呼び出し側が「この条件で速く呼びたい」を伝える */
    int32       typmod;         /* 既知なら。可変なら -1 を渡す */
    Oid         collation;
    Oid         typioparam;
    /* output: サポート関数が埋める。扱えなければ fn を NULL のまま返す */
    FastInputFunction fn;       /* NULL = fast 入口なし → 従来経路 */
} SupportRequestInputFunction;
```

サポート関数は、与えられた `typmod`/`collation` を**自分が完全に無視してよい場合に限り** `fn` を埋める。
typmod/collation が意味を持つ型は、その条件下では `fn = NULL` を返して従来経路に落とす（§4 意味論一致）。

### 3.3 ルックアップとキャッシュ（質問3への回答）

**`FmgrInfo` には何も足さない。** `FmgrInfo` (`src/include/fmgr.h:56`) は超ホット構造体であり、
さらに `fmgr_info_cxt_security()` の builtin 高速パス (`src/backend/utils/fmgr/fmgr.c:168-180`) は
**pg_proc を一切引かずに return する**ため、ここに fast 入口を解決させると builtin（=int4in 等まさに狙う型）で
解決できないという致命的な矛盾が起きる。

→ 解決は**呼び出し側のセットアップ時に 1 回**行い、結果ポインタを呼び出し側構造体にキャッシュする。

```c
/* lsyscache.c に薄いヘルパ（prosupport の get_func_support と同型） */
FastInputFunction
get_fast_input_function(Oid input_func_oid, Oid typioparam,
                        int32 typmod, Oid collation)
{
    RegProcedure support = get_func_support(input_func_oid); /* lsyscache.c:2083 既存 */
    SupportRequestInputFunction req;
    SupportRequestInputFunction *res;

    if (!OidIsValid(support))
        return NULL;
    req.type = T_SupportRequestInputFunction;
    req.typmod = typmod; req.collation = collation; req.typioparam = typioparam;
    req.fn = NULL;
    res = (SupportRequestInputFunction *)
        DatumGetPointer(OidFunctionCall1(support, PointerGetDatum(&req)));
    return res ? res->fn : NULL;
}
```

COPY 側は `cstate` に `FastInputFunction *fast_in_functions`（in_functions と並列の配列）を持ち、
`CopyFromTextLikeInFunc()` で 1 回解決。ホットパスでは表引きも OidFunctionCall も無く、純粋な間接呼び出し 1 回。

### 3.4 ホットパスの分岐（質問4の strict/soft-error 整合）

```c
if (cstate->fast_in_functions[m] != NULL)
{
    /* strict 規約を呼び出し側で再現（InputFunctionCallSafe と同一） */
    if (string == NULL)        /* fn_strict 相当。入力関数は全て strict */
        { nulls[m] = true; values[m] = (Datum) 0; }   /* str==NULL → NULL 結果 */
    else if (!cstate->fast_in_functions[m](string, typioparams[m],
                                           att->atttypmod, att_collation,
                                           (Node *) cstate->escontext, &values[m]))
    {
        /* fast 入口は失敗時 escontext を埋めて false を返す（後段の ON_ERROR 分岐は不変） */
    }
}
else
    /* 従来 InputFunctionCallSafe(...) */
```

`InputFunctionCallSafe` の NULL 整合性チェック (`fmgr.c:1614-1626`) は、入力関数が
str に対し NULL/非NULL を正しく返すかの保険。fast 入口は契約上「成功なら必ず非 NULL Datum、
失敗なら escontext を埋めて false」なので等価に保てる。

---

## 4. 意味論の完全一致（セキュリティ＝振る舞い等価）

| 項目 | 従来 `InputFunctionCallSafe` | fast 入口での担保 |
|---|---|---|
| strict (NULL素通し) | `str==NULL && fn_strict` で NULL 結果 (`fmgr.c:1593`) | 呼出側で同条件分岐（全 input 関数は strict） |
| ソフトエラー | `escontext` を fcinfo->context に渡し `SOFT_ERROR_OCCURRED` 判定 | 同一 `escontext` を直接引数で渡す。guts は既に `errsave`/`ereturn` 使用 (`miscnodes.h`) |
| errcode/メッセージ | guts の `ereturn` がそのまま | **同じ guts を呼ぶ**ので完全一致（int4→`pg_strtoint32_safe`） |
| typmod | 入力関数に Int32 引数で渡る | typmod が意味を持つ型は `fn=NULL` を返し従来経路へ |
| collation | 現状 `InputFunctionCallSafe` は `InvalidOid` 固定で渡す | 同様に扱う or collation 依存型は申告しない |
| typioparam | 配列/ドメイン要素型などで使用 | 引数で渡す。使う型は無視せず利用、扱えなければ申告しない |
| ドメイン制約 | COPY は別途 `InputFunctionCallSafe(NULL,...)` で制約検査 (`copyfromparse.c:1074`) | ドメインの入力関数 `domain_in` は申告しない → 従来経路（制約検査ロジック不変） |
| 配列/レコード/レンジ | 合成型の入力関数が要素ごとに `InputFunctionCallSafe` を呼ぶ | 合成型自体は申告しない。要素型が将来申告すれば §6 で恩恵 |
| polymorphic | anyelement 等 | 型解決は呼出側の責務（typioparam 経由）。申告しない型は従来通り |

**原則: 少しでも条件が合わなければサポート関数は `fn=NULL` を返し、必ず従来経路にフォールバックする。**
これにより「速くなるが振る舞いが変わる」事故を構造的に防ぐ。

---

## 5. 後方互換と拡張機能（質問5）

- **申告しない既存型・サードパーティ型**: `prosupport` 未設定 or 当該 request に NULL → 完全に従来 fmgr 経路。挙動ゼロ変化。
- **拡張がこの機構を採用**: 拡張の入力関数に `CREATE FUNCTION ... SUPPORT myinput_support` を付け、
  サポート関数が `T_SupportRequestInputFunction` に応答するだけ。PGXS 互換は prosupport と同じ（既存機構）。
- **バージョン跨ぎ安全性**: 古い拡張は新 request を知らず NULL を返す（プロトコル既定）→ 安全に無視。
  新 core × 古い拡張、新拡張 × 古い core（request 未定義なら core が呼ばない）いずれも安全。
- **`FastInputFunction` ABI の安定性**: シグネチャを将来変えると拡張が壊れる。初版で typioparam/typmod/collation/
  escontext を全て含め、以後**追加のみ・破壊的変更なし**を約束する（fmgr ABI の慣行）。

---

## 6. 波及効果（質問6）

`InputFunctionCallSafe`/`InputFunctionCall` の他の呼び出し元も、同じ「セットアップ時解決＋ホットパス分岐」
パターンを採れば恩恵を受ける（機構自体は汎用）:

- `array_in` / `record_in` / `range_in` / `multirange_in`: 要素型の入力をループで呼ぶ。要素型が申告すれば速くなる。
- `domain_in`: 基底型の入力 + 制約。基底型申告で速くなり得る（制約検査は不変）。
- `pg_input_is_valid` / `pg_input_error_message`（`1939d262` で追加の scaffolding）: ソフトエラー経路そのもの。
- 一般の「文字列→値」変換（SPI、PL 引数変換等）。

副作用: ホットパス分岐 1 個（`fast_in_functions[m] != NULL`）が増えるが、セットアップ時解決なので
非対応型でのオーバーヘッドは実質ゼロ。**初版は COPY のみに適用し、他は将来パッチに分割**するのが安全。

---

## 7. リスク・未解決の論点と、想定反論への回答

1. **prosupport 再利用は「planner用」の流用では？**
   → 起源スレッドの趣旨は「関数固有情報を core に供給する汎用フック」。とはいえ運用上 planner 文脈と
   混ざるため、専用列 `proinputfast` 案も提示済み（§3.1）。**ハッカーズに両論併記で諮るのが妥当。**
2. **3〜8% のために ABI/カタログを増やす価値があるか？**
   → 削るのは契約二重化（保守リスク）であって、速度は副次効果。「真実源を一本化したまま速くする」点が本質。
   COPY は大規模 ETL のボトルネックであり、累積効果は無視できない。
3. **`FmgrInfo` 肥大化リスク** → 本提案は **FmgrInfo を変更しない**（§3.3）。これが builtin 高速パス問題の回避にもなる。
4. **意味論ズレ事故** → 「条件不一致は必ず NULL 申告＝従来経路」設計で構造的に防止（§4）。
   同じ guts を呼ぶため errcode/メッセージは定義上一致。
5. **JIT/将来の COPY 改善と競合？** → 直交。JIT 化された式評価とは別レイヤ。むしろ fast 入口は JIT からも呼べる。
6. **未確認の前例** → int4 等を COPY で特別扱いして fmgr を回避した「採否が確定した」スレッドは確認できず、
   本提案は新規性が高い可能性（§8）。提案前にアーカイブの手動確認を推奨。

---

## 8. 参考にした既存スレッド/コミット（確認済み URL）

**ソフトエラー（保持すべき意味論の出自）**
- 設計スレッド *"Error-safe user functions"*（Nikita Glukhov, 2022-10-03、Tom Lane が再設計）:
  https://www.postgresql.org/message-id/3bbbb0df-7382-bf87-9737-340ba096e034@postgrespro.ru
  / 索引 https://postgrespro.com/list/thread-id/2618949
  / 命名議論 https://www.postgresql.org/message-id/3676101.1670342821@sss.pgh.pa.us
- コミット *"Add test scaffolding for soft error reporting from input functions"* — Tom Lane, 2022-12-09,
  `1939d262` （`pg_input_is_valid()` 追加、PG16）:
  https://git.postgresql.org/gitweb/?a=commitdiff&h=1939d2628&p=postgresql.git
  / https://github.com/postgres/postgres/commit/1939d262
- **未確認**: `escontext`/`ErrorSaveContext`/`ereturn`/`errsave`/`InputFunctionCallSafe` 本体を導入した
  *インフラ*コミットの正確なハッシュ（scaffolding と同 2022-12 系列だが、本環境は浅いクローン(50コミット)で
  ローカル解決不可）。フルクローンで `git log --grep="escontext"` にて要確認。

**prosupport（設計テンプレート）**
- 設計スレッド *"Allowing extensions to supply operator-/function-specific info"* — Tom Lane, 2019-01-20:
  https://www.postgresql.org/message-id/15193.1548028093@sss.pgh.pa.us
  / 索引 https://postgrespro.com/list/thread-id/2422410
- コミット *"Create the infrastructure for planner support functions"* — Tom Lane, PG12,
  `74dfe58a5927b22c744b29534e67bfdd203ac028`:
  https://github.com/postgres/postgres/commit/74dfe58a5927b22c744b29534e67bfdd203ac028
- 解説: https://www.cybertec-postgresql.com/en/optimizer-support-functions/

**COPY 性能・ソフトエラー連携**
- *"Make COPY format extendable"* スレッド（Andres Freund が、行/フィールドコスト削減後は
  dispatch/関数呼び出しコストが支配的になると指摘）:
  https://www.mail-archive.com/pgsql-hackers@lists.postgresql.org/msg161454.html
- *"Optimizing ResourceOwner to speed up COPY"* — Tomas Vondra:
  https://www.postgresql.org/message-id/84f20db7-7d57-4dc0-8144-7e38e0bbe75d@vondra.me
- COPY `SAVE_ERROR_TO`（後に `ON_ERROR`）— Alexander Korotkov, 2024-01-16, `9e2d870119`:
  https://git.postgresql.org/gitweb/?a=commitdiff&h=9e2d870119&p=postgresql.git
- COPY skipped-tuple 進捗 — Masahiko Sawada, 2024-01-25, `729439607`:
  https://git.postgresql.org/gitweb/?a=commitdiff&h=729439607&p=postgresql.git

**未確認（引用前に要確認）**: 「COPY で int4 等を特別扱いし fmgr を回避」する採否確定スレッドは発見できず（新規性の可能性）。
expanded-datum / JIT 式評価の出自コミットは本調査では未取得。

---

## 9. 最小 PoC スケッチ（int4 のみ・ビルド非保証）

### 9.1 型定義（`src/include/fmgr.h`）

```c
typedef bool (*FastInputFunction) (const char *str, Oid typioparam, int32 typmod,
                                   Oid collation, fmNodePtr escontext, Datum *result);
```

### 9.2 リクエストノード（`src/include/nodes/supportnodes.h`） — §3.2 参照

### 9.3 int4 の fast 入口とサポート関数（`src/backend/utils/adt/int.c`）

```c
/* fcinfo を作らない軽量入口。guts はカタログの真実源 (int4in) と同一の pg_strtoint32_safe */
static bool
int4in_fast(const char *str, Oid typioparam, int32 typmod,
            Oid collation, Node *escontext, Datum *result)
{
    int32 r = pg_strtoint32_safe(str, escontext);   /* numutils.c:388、既に escontext 対応 */
    if (SOFT_ERROR_OCCURRED(escontext))
        return false;
    *result = Int32GetDatum(r);
    return true;
}

Datum
int4in_support(PG_FUNCTION_ARGS)
{
    Node *rawreq = (Node *) PG_GETARG_POINTER(0);
    if (IsA(rawreq, SupportRequestInputFunction))
    {
        SupportRequestInputFunction *req = (SupportRequestInputFunction *) rawreq;
        /* int4 は typmod/collation/typioparam を無視してよい → 無条件で申告 */
        req->fn = int4in_fast;
        PG_RETURN_POINTER(req);
    }
    PG_RETURN_POINTER(NULL);   /* 未知 request は NULL（プロトコル既定） */
}
```

### 9.4 カタログ申告（`src/include/catalog/pg_proc.dat`）

```
# 既存 int4in に prosupport を付与（新規 OID で int4in_support を定義）
{ oid => '...', proname => 'int4in', prorettype => 'int4',
  proargtypes => 'cstring oid int4', prosupport => 'int4in_support', prosrc => 'int4in' },
{ oid => '...', proname => 'int4in_support', prorettype => 'internal',
  proargtypes => 'internal', prosrc => 'int4in_support' },
```

### 9.5 呼び出し側解決（`src/backend/commands/copyfrom.c` の `CopyFromTextLikeInFunc`）

```c
getTypeInputInfo(atttypid, &func_oid, typioparam);
fmgr_info(func_oid, finfo);
/* 1 回だけ解決し並列配列にキャッシュ。typmod は列の atttypmod、collation は attcollation */
cstate->fast_in_functions[attnum-1] =
    get_fast_input_function(func_oid, *typioparam, atttypmod, attcollation);
```

ホットパス分岐は §3.4 のとおり。**実装は int4 のみ**に留め、他型・他呼出元は本家での合意後に段階導入する。

---

## 10. 移行手順（提案する場合）

1. `FastInputFunction` 型と `SupportRequestInputFunction` ノード、`get_fast_input_function()` を追加（挙動変化なし）。
2. int4in にサポート関数を実装し、COPY text/CSV のみ分岐を追加。回帰テスト（特に `COPY ... ON_ERROR`、
   ドメイン、配列列、ソフトエラーのメッセージ一致）を緑に。
3. ベンチ（§下の注意）で 3〜8% を再現確認。
4. ハッカーズに「prosupport 再利用 vs 専用列」を両論併記で提案。合意後に int2/int8/float4/float8、続いて
   他呼出元（array_in 等）へ拡大。

> **ベンチ注意（本コンテナ）**: CPU スロットリングでノイズ大。ベースラインと候補を**別ポートの 2 サーバで
> 同時起動し交互計測**してドリフト相殺。unlogged テーブル + `fsync=off` + 事前ウォームアップ + 複数回の中央値で比較。
