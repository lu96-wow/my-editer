# core-render —— racket-tui 显示后端

把 core 画出来的渲染数据（`screen` / `piece`）变成**用 racket-tui 画出的可渲染片段**。
片段在真终端是 `bytes`、在字符图后端是 `op-seq`，两者都直接 `put-bytes`。

## 0. 职责边界

```
core（产生渲染数据）                      core-render（画）
  screen / piece / face  ──────────▶   face 结构 (fg bg attrs)
   face: #f | symbol                     theme: 复用 racket-tui 风格表
                                        render: piece -> 片段
```

- **core 只产生渲染数据**：`screen`、`piece`、face 符号（行号栏是唯一硬编码的裸符号 `'line-number`）。
- **后端只负责画**：定义 face 结构、用 tui 的画法把渲染数据变片段。
- **合并不在后端**：不提供「合并两个 face」的策略；要叠加由写方（插件）读改写。
- **theme 不复用为独立结构**：直接复用 racket-tui 的 `style-define!` / `style->bytes` 表，
  一个 theme 函数只负责「定义颜色」。

## 1. face 结构（`face.rkt`）

```racket
(struct face (fg bg attrs) #:prefab)
;; fg    : #f | symbol       前景分量
;; bg    : #f | symbol       背景分量
;; attrs : (listof symbol)   属性分量（bold / italic / underline …）
```

- **分量值都是符号**，怎么解释由后端决定（后端当成 tui 风格名）。
- **`#f`** 代表默认（core 属性轨的惰性全默认值）。
- 用 `#:prefab`：`patch.rkt` 用 `(overlay . face)` 编码 overlay，后端靠 `pair?` 区分，
  所以 face 不能是 pair。
- **只提供结构 + 读 / 写**，不提供合并：

| 读 | 写（纯，返回新 face，接受 `#f`） |
|---|---|
| `face-fg` `face-bg` `face-attrs` | `face-set-fg` `face-set-bg` `face-set-attrs` |
| `(face fg bg attrs)` 构造 | `face-add-attr` `face-remove-attr` |
| `face?` / `face-empty` | |

**「只写 bg」的插件** = 读旧 face、只改 bg、写回；保留还是覆盖由它自己决定：

```racket
;; 读旧 face（#f = 默认），只换 bg，fg/attrs 保留
(buffer-face-cell! b line col
  (face-set-bg (buffer-face-at b line col) 'bg-bracket-1))
```

## 2. theme（`theme.rkt`）—— 复用 racket-tui 的表

不实现自己的 theme / style。`theme` 就是一批 `style-define!`：

```racket
(require tui)                    ; style-define! / color-rgb-fg / attr-bold … 都来自 tui

(define (define-styles! entries)  ; entries : (listof (list name spec ...))
  (for-each (λ (e) (apply style-define! e)) entries))

;; face 分量名 = 风格名：
;;   (face 'fg-syntax-def 'bg-bracket-1 '(bold))
;; 对应
;;   (style-define! 'fg-syntax-def (color-rgb-fg 120 180 240))
;;   (style-define! 'bg-bracket-1 (color-rgb-bg 48 46 30))
;;   (style-define! 'bold         attr-bold)
(install-default-theme!)          ; 内置一套默认颜色
```

双表 256/16 回退由 racket-tui 负责（`current-registry`）。

overlay 用**语义角色**当风格名（core `patch.rkt` 产出），三种默认色：

```racket
(list 'cursor           attr-reverse)                 ; 主光标（反显块）
(list 'cursor-secondary attr-underline)               ; 副光标（下划线；可换反显 / 底色）
(list 'selection        (color-rgb-bg 60 70 90))      ; 选区（底色）
```

改三个颜色只改 `theme.rkt` 这三行，core / render 都不动。

## 3. 渲染（`render.rkt`）—— 纯函数，片段

```racket
render-piece      : piece          -> 片段   ; 定位 + 样式 + 文本 + 复位
render-pieces     : (listof piece) -> 片段
render-clear      :                -> 序列
face-fragment     : #f|symbol|face -> 序列
```

一个 piece 的片段 = `move + fg + bg + attrs + text + reset`。
`piece.attr` 的两种形态都认识：

| attr | 处理 |
|---|---|
| `face`（含 `#f`、core 的裸符号） | fg/bg/attrs 各自 `style->bytes` 后拼接 |
| `(overlay . face)` | 先底层 face，再叠 overlay 角色名 |

overlay 角色由 core `patch.rkt` 产出（语义，不含颜色）：

| 角色 | 含义 |
|---|---|
| `'cursor` | 主光标 |
| `'cursor-secondary` | 非主光标（多光标） |
| `'selection` | 选区（主 / 副同色） |

**只用软件光标**：core 对每个 selection head 都发一个 cursor 格，所以主 / 副光标
都在 `selection` 片里、都能画出来。物理光标不用后端管：直接调 tui 的 `(cursor-hide)` 一次即可。

**外部决定**：

- 何时渲染（首帧 / 增量 / 重绘）；
- 怎么组合（`render-piece` 的片段可 append，多来源 / 多帧由外部拼）；
- 是否 `put-bytes`（本模块不输出）。

所以后端**不持有上一帧、不自己 diff、不自己 flush**。
所有绘制数据都经 core 的 `render-display-patch` 来（全量就 `old = #f`），
它给的 `render` + `selection` 两个列表交给 `render-pieces` 即可——backend 不碰 `screen`。

## 4. 文件

```
core-render/tui/
  face.rkt      —— face 结构 + 读写操作（纯，无 tui）
  theme.rkt     —— define-styles! / install-default-theme!（require tui，复用其表）
  render.rkt    —— piece -> tui 序列（require tui，纯函数，不输出）
  demo.rkt      —— 宿主示例：真终端画一帧，输出/光标由 demo 自己用 tui 处理
```

没有 backend 汇总模块：**输出（`put-bytes` / `with-tui` / 光标）由宿主直接用 `tui`**；
render/theme 各自 `(require tui)`。换 `tui/char` 就把这两处的 require 改掉（字符图，可无 TTY 测）。

## 5. 草图

```racket
(require tui                              ; 输出 / 生命周期 / 输入
         "core-render/tui/theme.rkt" "core-render/tui/render.rkt"
         "core/editor.rkt")

(install-default-theme!)
(define b (make-buffer "…"))
(define v (buffer-add-view! b 80 24 #:line-numbers? #t))
(view-resize! v 80 24)
(define entries (list (display-entry v 0 0 0)))

(with-tui
 (λ ()
   ;; 只用软件光标：藏物理光标一次
   (cursor-hide)                                    ; 藏物理光标（tui 直接函数）
   ;; 首帧（old = #f）：先清屏，再把 patch 的片拼上
   (define-values (new r s) (render-display-patch entries v 80 24 #f))
   (put-bytes (bytes-append (render-clear) (render-pieces (append r s))))
   ;; 之后外部按需增量：render-display-patch entries v w h new …
   ))
```

## 6. 已跑通 / 待定

跑通（`racket demo.rkt`，真终端出彩色帧，按任意键退出）：

- core buffer/view → `render-display-patch` → `render-pieces` → `put-bytes`；
- face 三分量 → `\e[38;2;…m` / `\e[48;2;…m` / `\e[1m`；
- 三种 overlay 色：主光标 `\e[7m`、副光标 `\e[4m`、选区 `\e[48;2;60;70;90m`。
- 沙箱无 TTY 时把 `theme.rkt` / `render.rkt` 的 `(require tui)` 改成 `tui/char`，用 `char-frame` 看纯文本帧。

待定：

1. **core 行号栏的裸符号 `'line-number`**：现在后端把裸符号当整风格名查（已在 theme 里定义）；
   是否改成给 core 加 `current-gutter-face` 参数，让宿主传 face 值。
2. **主 / 副选区分色**：现在选区不分主副；若要分，core 再加 `'selection-secondary` 角色即可。
3. **attrs 顺序影响 `equal?`**：要不要规范化（排序 / 去重）。
4. **增量片段的样式状态机**：现在按格全发 `move+style+text+reset`；是否做样式去重 + 相邻合并。

## 7. API 速查

`片段` = 真终端 `bytes` / char 后端 `op-seq`，都能直接 `put-bytes`。
face 值 = `#f | symbol | face`（`#f` 默认；`symbol` 是 core 裸符号如 `'line-number`）。

### `face.rkt` —— face 结构 + 读 / 写（纯）

| API | 签名 | 功能 |
|---|---|---|
| `face` | `fg bg attrs -> face` | 构造；`fg/bg : #f|symbol`，`attrs : (listof symbol)` |
| `face?` | `any -> bool` | 是不是 face 结构 |
| `face-fg` `face-bg` `face-attrs` | `face -> …` | 读三分量 |
| `face-empty` | 值 | `(face #f #f '())` |
| `face-set-fg` `face-set-bg` `face-set-attrs` | `(#f\|face) v -> face` | 写一分量，返回新 face；接受 `#f` |
| `face-add-attr` `face-remove-attr` | `(#f\|face) sym -> face` | 增 / 删属性（幂等） |
| `face-attrs?` | `face sym -> bool` | 属性在不在 |

无合并 API；叠加由写方读改写。

### `theme.rkt` —— 复用 tui 表定义颜色

| API | 签名 | 功能 |
|---|---|---|
| `define-styles!` | `(listof (list name spec …)) -> void` | 批量 `style-define!` |
| `install-default-theme!` | `-> void` | 装内置配色 |
| `default-styles` | 值 | 内置配色数据 |

### `render.rkt` —— 渲染数据 -> tui 序列（纯）

| API | 签名 | 功能 |
|---|---|---|
| `render-piece` | `piece -> 片段` | 一格：move + face(含 overlay) + text + reset |
| `render-pieces` | `(listof piece) -> 片段` | 拼多个 piece |
| `render-clear` | `-> 序列` | 清屏 |
| `face-fragment` | `#f\|symbol\|face -> 序列` | 单独把 face 转序列 |

### 输出 / 生命周期：直接用 `tui`

后端不封装输出：宿主要 `with-tui` / `put-bytes` / `cursor-hide` / `read-event` … 直接 `(require tui)`。
组合 core 序列和其它序列（如边框）用 `bytes-append`（char 后端下 `tui/char` 会把 `bytes-append` 换成 `ops-append`）。
