# command —— 命令层（输入 token → lambda）

只提供**能力**，不规定策略：把一串输入 token 绑到一个 lambda，表可以组合，
合并**冲突直接报错**。事件、循环、重绘、位置分派仍归宿主。

```
key.rkt     键令牌（纯）
mouse.rkt   鼠标令牌（纯）
keymap.rkt  keymap（表 = trie）+ keytable（表列表操作对象，纯）
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

## 操作对象 keytable（两个 API）

`keytable` 是一个可变的**表列表**。所有操作走两个 API：

```racket
(define kt (make-keytable base-keys))            ; 也可 (make-keytable) 空表起步
(keytable-merge! kt plugin-keys)                 ; ① 合并表：冲突 → error
(keytable-lookup kt (list (key 'left)))          ; ② 查表：status + 过程
```

| API | 作用 |
|---|---|
| `keytable-merge!` | 把一张或多张 `keys` 表并进列表；冲突直接 `error` |
| `keytable-lookup` | 在一串 token（前缀序列）上查 |

**合并冲突直接报错，且是原子的**（失败不改动表）：

- 同一条序列两个叶子（两个过程抢同一个键）；
- 同一序列一边叶子、一边子树（一个过程遮住更长的序列）。

同前缀、不同续键可以共存：`C-x C-s` 与 `C-x C-c` 都保留，`C-x` 是共享前缀。

```racket
(keytable-merge! kt (keys [(key 'x 'ctrl) (key 's 'ctrl) (λ () (save))]))
(keytable-merge! kt (keys [(key 'x 'ctrl) (key 'c 'ctrl) (λ () (quit))]))  ; OK
(keytable-merge! kt (keys [(key 'x 'ctrl) (λ () …)]))                     ; error：与 C-x C-s 冲突
```

## 查表

```racket
(keytable-lookup kt seq)
;; => (values 'command proc)  某张表精确命中叶子
;;           'prefix  #f      没有叶子，但有表以该序列为前缀（还有续键）
;;           'unbound #f      哪张表都没有这条路径
```

## 读键 / 分派

```racket
(define kt     (make-keytable edit-keys global-keys))
(define reader (make-key-reader kt))

(define-values (status proc) (key-reader-feed! reader ev))
;; status 'command : 命中叶子，proc = 命中的过程，**由宿主调用**
;;        'prefix  : 命中前缀，继续等下一个键
;;        'unbound : 没命中，清空前缀 —— 宿主可把它当文本 / 提示
;;        'ignored : 不是按键事件（鼠标 / resize / null）
(proc ctx)     ; ← 宿主自己调用；ctx 由宿主造（world / event / 命中的 panel+point …）
```

命令层**只路由、不调用**：这样鼠标/键盘统一，handler 能拿位置，也支持数据驱动
world（proc 拿得到 world）。

鼠标没有序列，给单元素序列：

```racket
(define m (event->mouse ev))                          ; mouse-event → 鼠标 token | #f
(define-values (s p) (keytable-lookup mousetable (list m)))
(when (eq? s 'command) (p ctx))
```

## 运行时动态修改

`keytable` 是可变对象，读键器持有它的引用，所以合并**立刻生效**（正在等前缀也行）：

```racket
(keytable-merge! kt (keys [(key 't 'ctrl) (λ () …)]))   ; 下一个键就能用
(set-keytable-tables! kt '())                           ; 整份清空 / 替换
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
