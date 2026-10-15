# command —— 命令层（输入 token → lambda）

只提供**能力**，不规定策略：把一串输入 token 绑到一个 lambda，表可以组合，
后加入的表覆盖前面的。事件、循环、重绘、位置分派仍归宿主。

```
key.rkt     键令牌（纯）
mouse.rkt   鼠标令牌（纯）
keymap.rkt  token 表 = trie（纯）：构造 / 查询 / 合并（键和鼠标共用）
tui.rkt     racket-tui 适配：event->key / event->mouse / mouse-position + 有状态读键
main.rkt    入口（全部再导出）
```

## token

token 是不透明、`equal?` 可比的值。**键盘和鼠标共用同一套表**。

```racket
(key 'left)                 ; ←
(key 'p 'ctrl)              ; Ctrl+P
(key 'x 'ctrl 'alt)         ; Ctrl+Alt+X

(mouse 'press 'left)            ; 普通左键按下
(mouse 'press 'left 'ctrl)      ; Ctrl+左键（严格：不写修饰 = 无修饰）
(mouse 'scroll 'up 'shift)      ; Shift+滚轮上
(mouse 'move #f)                ; 移动（无 button）
```

修饰顺序固定 `ctrl alt shift`。可打印字符取小写符号（终端分不清
Ctrl+A / Ctrl+Shift+A）。鼠标 action ∈ `press release move scroll`，
button ∈ `left middle right`（press/release）| `up down`（scroll）| `#f`（move）。
**位置不进 token**，进 handler 的 ctx。

## 表

`keys` 的每条绑定写成一对方括号：**最后一格是 lambda，前面是要按的 token**。

```racket
(define edit-keys
  (keys
   [(key 'left)                    (λ () (move 'left))]
   [(key 'x 'ctrl) (key 's 'ctrl)  (λ () (save))]          ; 键序列 C-x C-s
   [(mouse 'press 'left)           (λ () (place-cursor))])) ; 鼠标单 token
```

表是一棵 trie：token → 子树（前缀）或 token → 过程（叶子）。

## 组合

```racket
(keymap-merge (list base-keys plugin-keys user-keys))   ; 后表赢
```

- 同一条序列：后面的叶子替换前面的；
- 同一 token 下两边都是子树：递归合并，各自不冲突的续键都保留；
- 一边叶子一边子树：后面的整体替换前面的（前缀也算「同一个 token」）。

鼠标常用「全局表 ⊕ 按命中的面板选上下文表」，一样是 `keymap-merge`。

## 读键 / 分派

```racket
(define km     (keymap-merge (list edit-keys global-keys)))
(define reader (make-key-reader km))

(define-values (status proc) (key-reader-feed! reader ev))
;; status 'command : 命中叶子，proc = 命中的过程，**由宿主调用**
;;        'prefix  : 命中前缀，继续等下一个键
;;        'unbound : 没命中，回到根 —— 宿主可把它当文本 / 提示
;;        'ignored : 不是按键事件（鼠标 / resize / null）
(proc ctx)     ; ← 宿主自己调用；ctx 由宿主造（world / event / 命中的 panel+point …）
```

命令层**只路由、不调用**：这样鼠标/键盘统一，handler 能拿位置，也支持数据驱动
world（proc 拿得到 world）。

鼠标没有序列，直接单步：

```racket
(define m (event->mouse ev))              ; mouse-event → 鼠标 token | #f
(define-values (s p) (keymap-step mousemap m))
(when (eq? s 'command) (p ctx))
```

位置相关全在宿主（core 已有能力）：

```racket
(define-values (row col) (mouse-position ev))            ; 1-based → 0-based
(define panel (panel-at panels row col))                 ; 命中
(define pt    (panel-screen-position->point panel row col)) ; 屏幕 → 文档 point
```

## 纯 / 不纯的分界

`key.rkt`、`mouse.rkt`、`keymap.rkt` 不 require `tui`，可单测；`tui.rkt` 是唯一碰
racket-tui 的模块。换后端只换 `tui.rkt`。
