# PostgreSQL GDB helpers

# フォーク後に子プロセスを追跡するデフォルト設定
# postmaster アタッチ時はこれを有効にすると fork 先のバックエンドを追跡できる
# (launch.json の "Attach to postmaster" 設定で使用)
# set follow-fork-mode child
# set detach-on-fork on

# List の各要素を表示するマクロ
define pgl
    set $i = 0
    set $cell = ((List *)$arg0)->elements
    set $len = ((List *)$arg0)->length
    while $i < $len
        printf "[%d] %p\n", $i, $cell[$i].ptr_value
        set $i = $i + 1
    end
end
document pgl
  pgl <List *>: List の各要素のポインタを表示する
end

# MemoryContext ツリーを再帰的に表示するマクロ
define pmctx
    printf "%s\n", ((MemoryContext)$arg0)->name
    set $child = ((MemoryContext)$arg0)->firstchild
    while $child != 0
        printf "  %s\n", ((MemoryContext)$child)->name
        set $child = ((MemoryContext)$child)->nextchild
    end
end
document pmctx
  pmctx <MemoryContext>: MemoryContext の名前と直接の子を表示する
end

# バックトレースをシグナルハンドラ越しに見やすく表示
define pbt
    bt full
end
document pbt
  pbt: bt full のエイリアス
end
