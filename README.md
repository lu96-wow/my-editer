# edit —— core / layout / core-render / theme

文本编辑器。分层清楚，各层只做一件事，**都在 Racket 里可单测**。

## 目录

| 目录 | 职责 | 依赖 |
|---|---|---|
| `core/` | 文本引擎 + 渲染值（buffer / view / document / history；`piece` / `screen` / face 端口） | 无 |
| `edit-tui/base/` | **face 值定义**（`(face fg bg attrs)` + 读写）—— 生产者 / 消费者共用的基础词汇 | 无 |
| `edit-tui/layout-base/` | 布局 = 一堆面板（`rect` + 四边可选边框 + `deep` + 边框 `face`）+ 定位 | core（`display-entry`） |
| `edit-tui/core-render/` | 渲染后端：把 core 渲染值 / 布局边框画成 tui 序列 | core、base、layout-base、tui |
| `edit-tui/theme/` | 统一主题：face 符号 → 样式（fg bg attrs），装进 tui 样式表 | tui |

```
core 渲染值 (piece) ─┐
                     ├─▶ core-render ─▶ tui 序列 ─▶ put-bytes     （宿主决定何时）
layout 边框 (panel) ─┘         ▲
                              theme：face 符号 → 颜色
```

## layout —— 面板 + 定位（纯几何）

布局就是**一块块面板**，不必布满屏幕。没有树 / solver。

```racket
(struct rect  (x y w h))
(struct panel (id rect borders deep face))
;; borders : (listof 'up 'down 'left 'right)   四条边各自可选（靠屏幕边的不画）
;; deep    : 越大越在上；浮窗 / 弹窗 = deep 高的 panel
;; face    : 边框 face 符号（颜色在 theme）
```

| API | 作用 |
|---|---|
| `rect` `rect-right` `rect-bottom` `rect-inset` `rect-inset-sides` `rect-split` `rect-contains?` | 矩形算术（`rect-split` 拆左右 / 上下） |
| `make-panel` | 构造面板（`#:deep` `#:face`） |
| **`panel-content`** | **内部区域**：外框按「存在的边」各内缩 1 |
| `panel-at` `panel-find` | 命中（deep 最大）/ 按 id 找 |
| `panels->entries` | 面板 + `id→view` → `display-entry`（用内容区定位） |

**边框怎么画不在 layout** —— 在 `edit-tui/core-render/border.rkt`。

## core-render —— 统一渲染后端

把两种绘制数据都画成 tui 序列；**不自己输出**（何时 `put-bytes` 由宿主决定）。

| 模块 | API | 作用 |
|---|---|---|
| `render.rkt` | `render-piece` `render-pieces` `render-clear` `face-fragment` | core `piece` → tui 序列 |
| `border.rkt` | `panels->border-runs` `panels->decorations` | 布局 `panel` 边框 → run / 装饰 `pane` |

face 值本身在 `edit-tui/base/face.rkt`（见上表）。

- `piece.attr` = `face` 或 `(overlay . face)`（overlay ∈ `cursor` / `cursor-secondary` / `selection`）。
- 边框：每块框**自己画自己的**（只用 `─ │ ┌ ┐ └ ┘`，无跨框 T/十字）；同格重叠 **deep 高的覆盖低的**；每段 run 带该框的 `face` / `deep`。
- **增量 / 清旧位置**：边框作为 decoration 进 core 的 `render-display`，与内容同处一张 screen；`screen-patch` 逐格 diff，框移动 / 消失的旧格自动清掉。

## theme —— 统一主题（字段与 face 一致）

```racket
(struct rgb   (r g b))
(struct style (fg bg attrs))     ; 和 face 同字段
;; fg/bg : #f | (rgb r g b) | 0..255
;; attrs : (listof 'bold 'dim 'italic 'underline 'blink 'reverse)
```

主题**数据拆两份**（后面还能再拆）：

| 文件 | 内容 |
|---|---|
| `theme/core.rkt` | `core-theme`：渲染核心（正文 / 语法 / 属性 / 光标 / 选区） |
| `theme/frame.rkt` | `frame-theme`：框架（窗口 / 聚焦 / 浮窗边框） |
| `theme/theme.rkt` | 机制：`rgb` / `style` / `define-theme!` |
| `theme/main.rkt` | 入口：**require 即安装**（顶层 `define-theme!`） |

```racket
(require "edit-tui/theme/main.rkt")   ; 不用再手动 install
```

`define-theme!` 把 style 转成 racket-tui 样式表（`style-define!`），渲染层用 `style->bytes` 取。覆盖某项：require 之后再 `(define-theme! …)` 同名覆盖。

## 宿主用法

```racket
(require tui
         "edit-tui/layout-base/main.rkt"
         "edit-tui/core-render/main.rkt"
         "edit-tui/theme/main.rkt"      ; require 即安装主题
         "core/editor.rkt")
(define panels (list (make-panel 'editor (rect 0 0 60 16) '())
                     (make-panel 'popup  (rect 14 4 32 8) borders-all
                                 #:deep 10 #:face 'float-border)))
(define entries (panels->entries panels id->view))
(define decorations (panels->decorations panels))

(with-tui
 (λ ()
   (cursor-hide)                                        ; 只用软件光标
   (define-values (new r s) (render-display-patch entries focus 60 16 #f decorations))
   (put-bytes (bytes-append (render-clear) (render-pieces (append r s))))
   ;; 之后增量：old = new
   ))
```

## 约定

- 后端只吃 `piece`（core 渲染值）和 `panel`（布局）；`screen` 是 core 内部 / 宿主的事。
- 颜色一律在 `edit-tui/theme/`；布局只会带 face 符号，不认识颜色。
- 浮窗 = `deep` 更高的 panel；浮窗之间用互不相同的 deep。
