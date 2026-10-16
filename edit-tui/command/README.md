# command —— 命令层（输入 token → lambda）

只提供**能力**，不规定策略：把一串输入 token 绑到一个**命令**（过程 + 说明 + 输入需求），
表可以组合，合并**冲突直接报错**。事件、循环、重绘、位置分派仍归宿主。

```
key.rkt     键令牌（纯）
mouse.rkt   鼠标令牌（纯）
command.rkt 命令记录：run / note / input（纯）
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

表是一棵 trie：token → 子树（前缀）或 token → **command**（叶子，见下）。

## 命令：note / input

叶子不是裸过程，而是一份 `command`，把「怎么执行」「叫什么」「要不要先收输入」一起存进表：

```racket
(struct command (run note input))
(struct input   (kind prompt init))

(cmd #:note "保存" (λ () (save)))
(cmd #:note "另存为" #:input (input 'string "文件名: ") (λ (path) (save-as path)))
```

- `note`：`#f | string | (-> string)` —— which-key / 状态栏 / 帮助用的说明；
- `input`：`#f | input`。`kind ∈ string key key-seq number choice any`，
  `prompt` 是提示语，`init` 是初值 / 候选项；
- 裸过程仍可写（note / input 为空），`keys` 自动包成 command。

state 层拿到 `command` 后：

```racket
(if (command-needs-input? cmd)
    ;; 先按 input-spec 收值 v（minibuffer / 补全），再：
    ((command-run cmd) v)
    ((command-run cmd)))
```

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
;; => (values 'command cmd)  某张表精确命中命令（command：run/note/input）
;;           'prefix  #f      没有命令，但有表以该序列为前缀（还有续键）
;;           'unbound #f      哪张表都没有这条路径
```

## which-key / 帮助

说明随表存，所以不必再维护一张「序列 → 文案」表：查当前前缀即可列出后续。

```racket
(keytable-hints kt (list (key 'p 'ctrl)))
;; => (list (cons token cmd-or-#f) ...)      ; #f = 这步还是前缀，还能继续
(keytable-commands kt (list (key 'p 'ctrl)))
;; => (list (cons (listof token) cmd) ...)   ; 展开到完整序列（帮助 / 命令列表）
```

```racket
(for ([h (in-list (keytable-hints kt prefix))])
  (printf "~a  ~a\n" (key->string (car h))
          (or (and (cdr h) (command-note-string (cdr h))) "…")))
```

## 读键 / 分派

```racket
(define kt     (make-keytable edit-keys global-keys))
(define reader (make-key-reader kt))

(define-values (status cmd) (key-reader-feed! reader ev))
;; status 'command : 命中叶子，cmd = 命中的 command，**由宿主执行**
;;        'prefix  : 命中前缀，继续等下一个键
;;        'unbound : 没命中，清空前缀 —— 宿主可把它当文本 / 提示
;;        'ignored : 不是按键事件（鼠标 / resize / null）
(if (command-needs-input? cmd)
    ((command-run cmd) collected-value)   ; ctx 由宿主闭包进 run；位置/世界同理
    ((command-run cmd)))
```

命令层**只路由、不调用**：这样鼠标/键盘统一，handler 能拿位置，也支持数据驱动
world（ctx 由宿主闭包进 run）；需要输入时也只是把 input-spec 交给 state 层。

鼠标没有序列，给单元素序列：

```racket
(define m (event->mouse ev))                          ; mouse-event → 鼠标 token | #f
(define-values (s cmd) (keytable-lookup mousetable (list m)))
(when (eq? s 'command) ((command-run cmd) ctx))
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
