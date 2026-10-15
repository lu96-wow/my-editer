# command —— 命令层（按键序列 → lambda）

只提供**能力**，不规定策略：把一串按键绑到一个 lambda，表可以组合，
后加入的表覆盖前面的。事件、循环、重绘仍归宿主。

```
key.rkt     键令牌（纯）
keymap.rkt  键表 = trie（纯）：构造 / 查询 / 合并
tui.rkt     racket-tui 适配：event->key + 有状态读键
main.rkt    入口（全部再导出）
```

## 键

`(key 名 修饰…)` —— 相等用 `equal?`。

```racket
(key 'left)            ; ←
(key 'p 'ctrl)         ; Ctrl+P
(key 'x 'ctrl 'alt)    ; Ctrl+Alt+X
(key 'space)           ; 空格
```

约束：命名键用符号（`'left 'enter 'tab 'backspace`）；可打印字符取小写符号
（终端分不清 Ctrl+A / Ctrl+Shift+A，字符一律小写）。修饰顺序固定
`ctrl alt shift`。`key->string` 出 `"C-x"` / `"M-left"`。

## 表

`keys` 的每条绑定写成一对方括号：**最后一格是 lambda，前面是要按的键**。

```racket
(define edit-keys
  (keys
   [(key 'left)              (λ () (move 'left))]
   [(key 'backspace)         (λ () (delete))]
   [(key 'x 'ctrl) (key 's 'ctrl) (λ () (save))]))   ; C-x C-s
```

表是一棵 trie：键 → 子树（前缀）或键 → 过程（叶子）。

## 组合

```racket
(keymap-merge (list base-keys plugin-keys user-keys))   ; 后表赢
```

- 同一条序列：后面的叶子替换前面的；
- 同一键下两边都是子树：递归合并，各自不冲突的续键都保留；
- 一边叶子一边子树：后面的整体替换前面的（前缀也算「同一个键」）。

## 读键

```racket
(define km     (keymap-merge (list edit-keys global-keys)))
(define reader (make-key-reader km))

(key-reader-feed! reader ev)
;; → 'handled  命中叶子，过程已执行，回到根
;;   'prefix   命中前缀，继续等下一个键
;;   'unbound  没命中，回到根 —— 宿主可把它当文本 / 提示
;;   'ignored  不是按键事件（鼠标 / resize / null）
```

`event->key` 把 `key-event` 解成键令牌（其余事件 → `#f`）。
`key-reader-pending-string` 给状态栏显示未完成的前缀（如 `"C-x"`）。

宿主循环里按键表未命中且事件是**无修饰可打印字符**时，走文本通道：

```racket
(case (key-reader-feed! reader ev)
  [(unbound) (when (char? (key-event-key ev)) (insert! (string (key-event-key ev))))]
  [else (void)])
```

## 纯 / 不纯的分界

`key.rkt`、`keymap.rkt` 不 require `tui`，可单测；`tui.rkt` 是唯一碰
racket-tui 的模块。换后端只换 `tui.rkt`。
