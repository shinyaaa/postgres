# HTML スニペット集（本文を組み立てるための部品）

`{{CHAPTER_BODY}}` や `{{SIDEBAR_TOC}}` 等に差し込む HTML の定型。`page-template.html` /
`index-template.html` と組み合わせて使う。クラス名は `assets/style.css` に対応している。

---

## 節見出し（アンカー付き）

サイドバーからジャンプできるよう、節には `id` を必ず付ける。

```html
<h2 id="sec-1-1">1.1　データベースクラスタの物理配置</h2>
<h3 id="sec-1-1-1">1.1.1　ベースディレクトリの構成</h3>
```

## 図（Mermaid + キャプション）

```html
<figure>
  <pre class="mermaid">
flowchart TB
    subgraph Page["ページ (8KB)"]
        H["PageHeaderData"]
        L["ラインポインタ配列"]
        F["空き領域"]
        T["タプル群"]
    end
    H --> L --> F --> T
  </pre>
  <figcaption>図 1.1: ヒープページのレイアウト</figcaption>
</figure>
```

シーケンス図の例:

```html
<figure>
  <pre class="mermaid">
sequenceDiagram
    participant BE as バックエンド
    participant BM as バッファマネージャ
    participant SM as ストレージ
    BE->>BM: ページ要求 (buffer_tag)
    BM->>BM: バッファテーブル探索
    BM->>SM: ディスクから読み込み
    SM-->>BM: ページ
    BM-->>BE: バッファ参照
  </pre>
  <figcaption>図 8.2: バッファ読み込みの流れ</figcaption>
</figure>
```

## SQL / シェルの実行例

```html
<div class="example">
  <span class="example-label">SQL</span>
  <pre><code>SELECT lp, lp_off, t_xmin, t_xmax
FROM heap_page_items(get_raw_page('sample', 0));</code></pre>
</div>

<div class="example">
  <span class="example-label">実行結果</span>
  <pre><code> lp | lp_off | t_xmin | t_xmax
----+--------+--------+--------
  1 |   8160 |    726 |      0
  2 |   8128 |    727 |      0</code></pre>
</div>
```

## 補足ボックス

```html
<div class="note"><strong>メモ</strong>PostgreSQL 16 以降では …</div>
<div class="info"><strong>関連</strong>詳細は <a href="ch09.html">第9章 WAL</a> を参照。</div>
<div class="warn"><strong>注意</strong>この設定は本番環境では …</div>
```

## サイドバー TOC（全ページ共通・現在位置をハイライト）

現在表示中の章 `<li>` に `class="current"`、現在節 `<a>` に `class="current"` を付ける。

```html
<ol>
  <li class="current">
    <a class="chap-title" href="ch01.html">第1章 データベースクラスタ</a>
    <ol class="sect">
      <li><a class="current" href="ch01.html#sec-1-1">1.1 物理配置</a></li>
      <li><a href="ch01.html#sec-1-2">1.2 テーブルファイル</a></li>
    </ol>
  </li>
  <li>
    <a class="chap-title" href="ch02.html">第2章 プロセスとメモリ構造</a>
    <ol class="sect">
      <li><a href="ch02.html#sec-2-1">2.1 プロセス構成</a></li>
    </ol>
  </li>
</ol>
```

## 前後ナビ（`{{PAGER}}`）

```html
<a class="prev" href="ch01.html">
  <span class="dir">← 前の章</span>
  <span class="ttl">第1章 データベースクラスタ</span>
</a>
<a class="next" href="ch03.html">
  <span class="dir">次の章 →</span>
  <span class="ttl">第3章 クエリ処理</span>
</a>
```

先頭章では `prev` を省略、最終章では `next` を省略する。

## トップページの章カード（`{{TOC_CARDS}}`）

```html
<a class="toc-card" href="ch01.html">
  <span class="num">第1章</span>
  <span class="title">データベースクラスタ</span>
  <span class="desc">クラスタ・データベース・テーブルの物理的な格納構造を解説する。</span>
</a>
```
