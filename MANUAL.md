# core 使用手册

> 唯一入口：`(require "core/api.rkt")`。
> 本文档是 core 的完整 API 手册：设计思路、每个原子的输入输出、以及它们怎么串起来。

---

## 0. 一句话

core 是一个**纯函数式编辑器核心**：只有底层数据原子 + 它们的纯函数变换。
不含多窗口组合 / 布局 / 命令 / 插件 / 后端。所有结构 `#:transparent`、不可变。

组合出一个编辑器，你只需要五样东西：

```
buffer（文档） + window（视口） + window->screen（投影）
             + events（输入） + screen（输出）
```

---

## 1. 设计思路

### 1.1 哲学：数据 → lambda → 数据

每个函数都是「输入值 → 纯函数 → 输出新值」，不修改输入、无全局可变状态。

### 1.2 机制 vs 策略

core 只给**机制**（原子 + 变换），不给**策略**：

| 不在 core 里 | 为什么 |
|---|---|
| 多窗口布局 | 窗口怎么摆是使用方的策略 |
| 命令/键位 | 哪个键干什么不是核心 |
| 主题/配色 | face 是语义符号，颜色是外部策略 |
| 后端 | core 只产 `screen`、只收 `events` |

### 1.3 三条边界契约

```
           events ──▶ core（纯函数）──▶ screen
          (输入契约)                    (输出契约)
                         ▲
                 edit-desc（文本变更契约，内部串起所有层）
```

---

## 2. 术语

| 词 | 含义 | 出现处 |
|---|---|---|
| `point` | 文档位置 (line col)，0-based | `point` 结构、`window-point` |
| `cursor` | 屏幕上的可见光标（caret） | 仅 `screen-cursor-row/col` |
| 字符索引 | buffer 里的 col（按字符数） | `point-col` |
| 显示列 | width 换算后的列（宽字符=2） | `run-col`、`vrow` 的列 |
| `face` | 语义 face 符号（`'keyword` 等） | glyph/run 的 face |

**坐标一律 0-based。** 列分「字符索引」和「显示列」，函数名用 `index`/`column` 区分。

---

## 3. 原子清单与关联总图

### 3.1 结构一览

```
文本层（无光标）
  point         位置 (line col)
  content       文本 + splice，产出 edit-desc
  properties    行内属性区间（'face 由此进画面）
  marker        会跟着文本移动的点
  overlay       会蒸发的装饰区
  buffer        文档（装配以上所有）
  patch         补丁 delta
  edit          批量编辑应用

视口层（单窗口）
  events        类型化输入事件
  width         字符 ↔ 显示列（宽字符）
  render        行 → glyph（属性变 face 的地方）
  window        视口（buffer + point + 滚动 + 尺寸）
  view          vrow 布局 + 光标/鼠标映射 + 滚动
  screen        一帧画面（run 序列）+ diff + compose
  project       window->screen 投影
```

### 3.2 关联总图

```
                编辑流                         渲染流
   ┌──────────────────────────┐    ┌──────────────────────────┐
   │ event                    │    │ buffer                   │
   │   → window-*（point 驱动）│    │   → render-line → glyph  │
   │   → buffer-*             │    │   → line-range->runs     │
   │   → 新 buffer + edit-desc│    │   → window->screen       │
   │   → 上层用 desc 做同步    │    │   → screen → 后端画      │
   └──────────────────────────┘    └──────────────────────────┘

属性流（写一次，全自动）：
  buffer-put-property → 编辑时自动移动 → window->screen 时变 face → 后端上色
```

---

## 4. 三条契约详解

### 4.1 `edit-desc`（文本变更）

```racket
(struct edit-desc (s-line s-col e-line e-col new-text))  ; 全操作前坐标
;; 删除 [s-line,s-col)..[e-line,e-col)，插入 new-text（可含 \n）
```

- 一次编辑 = 一个 splice。插入/删除/换行/合并/粘贴都是它的特例。
- **编辑原语返回 `(values 新值 desc)`；无操作 desc = `#f`。**
- 导航/状态原语直接返回 `window`（单值）。
- `edit-desc-map-position` / `edit-desc-after-position`：把位置映射过编辑。

### 4.2 `events`（输入）

6 个事件 + 1 个辅助，是**整程序级**的原始输入（不是 window/buffer 级）：

```racket
(struct modifiers (control alt shift meta))              ; 辅助
(struct text-event (text modifiers))                     ; 已解码文本
(struct key-event (key modifiers))                       ; 物理键
(struct mouse-press-event (button x y modifiers))        ; x/y 屏幕坐标
(struct mouse-wheel-event (direction x y modifiers))     ; x/y 屏幕坐标
(struct resize-event (rows cols))                        ; 整终端尺寸
(struct quit-event ())                                   ; 生命周期
```

- `key-event` 的 key：`char`（Ctrl+字符）| `symbol`（'up 'down 'home 'end 'backspace 'delete 'enter 'tab 'escape 等）。
- 鼠标 x/y 是**屏幕坐标**——命中的窗口、映射到 buffer 是使用方的职责（用 `window-screen->point`）。

### 4.3 `screen`（输出）

```racket
(struct run (col text face))                             ; 一段同色文本
(struct screen (rows cols row-runs cursor-row cursor-col)); 一帧画面
;; row-runs : (vectorof (listof run))  每行 run 按 col 升序
;; cursor-* : 光标位置；-1 = 不画
```

- `screen` 是"一张扁平图"，可以是单窗口投影，也可以是 N 块拼成的整屏。
- 后端只消费 `screen`，不认识 buffer/window。

---

## 5. 文本层 API（详细签名）

### 5.1 point —— 位置

| 函数 | 输入 | 输出 |
|---|---|---|
| `point` | line col | point |
| `point<?` / `point=?` / `point<=?` | a b | boolean（字典序） |
| `point-clamp` | c line-count line-length | 夹紧后的 point |
| `point-line` / `point-col` | p | nat |

### 5.2 content —— 文本 + splice

| 函数 | 输入 | 输出 |
|---|---|---|
| `make-content` | — | 空 content（一行 ""） |
| `content-of-string` | s | content |
| `content-of-lines` | (non-empty-listof string) | content |
| `content->string` | c | string |
| `content->lines` | c | (listof string) |
| `content-line-count` | c | nat |
| `content-line-ref` | c i | string |
| `content-current-line` | c | string |
| `content-splice` | c s-line s-col e-line e-col new-text | (values content edit-desc) |
| `content-insert-char` | c ch | (values content edit-desc) |
| `content-insert-string` | c s | (values content edit-desc) |
| `content-newline` | c | (values content edit-desc) |
| `content-backspace` | c | (values content edit-desc) |
| `content-delete` | c | (values content edit-desc) |
| `edit-desc-map-position` | d l c | point \| #f（落在被删区间） |
| `edit-desc-after-position` | d | point（插入后位置） |

gap 定位（都返回新 content）：`content-set-col` / `content-gap-up` / `content-gap-down` / `content-gap-goto`。

### 5.3 properties —— 行内属性

| 函数 | 输入 | 输出 |
|---|---|---|
| `make-properties` | line-count | properties |
| `properties-get` | p line col prop | any \| #f |
| `properties-at` | p line col | hash（该位置全部属性） |
| `properties-put` | p line start end prop val | properties |
| `properties-put-many` | p segs | properties |
| `properties-remove` | p line start end prop | properties |
| `properties-replace-key` | p first last prop segs | properties（清旧写新） |
| `properties-runs` | p line line-length | (listof (list start end plist)) |
| `properties-apply-edit` | p desc | properties（随编辑调整） |

`segs = (listof (list line start end prop val))`。

### 5.4 marker / overlay —— 标记与装饰

| 函数 | 输入 | 输出 |
|---|---|---|
| `make-marker-table` | — | marker-table |
| `marker-table-add` | mt pos [type 'before] | (values marker-table id) |
| `marker-table-remove` | mt id | marker-table |
| `marker-table-get` | mt id | marker \| #f |
| `marker-table-all` / `marker-table-count` | mt | (listof marker) / nat |
| `marker-apply-edit` | m desc | marker |
| `marker-table-apply-edit` | mt desc | marker-table |
| `make-overlay-table` | — | overlay-table |
| `overlay-table-make` | ot start-id end-id [plist (hash)] | (values overlay-table id) |
| `overlay-table-delete` | ot id | overlay-table |
| `overlay-table-at` | ot mt line col | (listof overlay)（按 priority 降序） |
| `overlay-table-runs` | ot mt line line-length | (listof (list start end ovs)) |
| `overlay-table-apply-edit` | ot mt desc | (values overlay-table marker-table) |

### 5.5 buffer —— 文档（装配根）

| 函数 | 输入 | 输出 |
|---|---|---|
| `buffer-open` | s | buffer |
| `buffer->string` / `buffer->lines` | b | string / (listof string) |
| `buffer-line-count` / `buffer-line-ref` | b [i] | nat / string |
| `buffer-splice` | b s-line s-col e-line e-col new-text | (values buffer edit-desc) |
| `buffer-insert-char` | b line col ch | (values buffer edit-desc) |
| `buffer-insert-string` | b line col s | (values buffer edit-desc) |
| `buffer-newline` | b line col | (values buffer edit-desc) |
| `buffer-backspace` | b line col | (values buffer edit-desc) |
| `buffer-delete` | b line col | (values buffer edit-desc) |
| `buffer-put-property` | b line start end prop val | buffer |
| `buffer-get-property` | b line col prop | any \| #f |
| `buffer-remove-property` | b line start end prop | buffer |
| `buffer-put-properties-many` | b segs | buffer（一次 tick） |
| `buffer-make-marker` | b pos [type 'before] | (values buffer id) |
| `buffer-delete-marker` | b id | buffer |
| `buffer-marker-pos` | b id | point \| #f |
| `buffer-make-overlay` | b start-pos end-pos [plist (hash)] | (values buffer id) |
| `buffer-delete-overlay` | b oid | buffer |
| `buffer-mark-dirty` / `buffer-mark-dirty-all` | b [first last] | buffer |
| `buffer-clean` | b | buffer（清 dirty） |

### 5.6 patch / edit —— 批量与补丁

| 函数 | 输入 | 输出 |
|---|---|---|
| `buffer-apply-patches` | b (listof patch) | buffer（按 key 清旧写新） |
| `buffer-content-same?` | a b | boolean（eq? content） |
| `buffer-apply-edits` | b (listof edit-desc) | (values buffer (listof edit-desc)) |
| `edits-map-position` | descs line col | point（跨一串编辑映射） |

---

## 6. 视口层 API（详细签名）

### 6.1 window —— 视口

| 函数 | 输入 | 输出 |
|---|---|---|
| `window-open` | b [height 24] [width 80] | window |
| `window-set-buffer` | w b | window（point 夹紧） |
| `window-set-point` | w p | window |
| `window-set-mode` | w 'clip\|'wrap | window |
| `window-set-top` / `window-set-left` / `window-set-top-seg` | w n | window |
| `window-set-size` | w height width | window |
| `window-scroll` / `window-hscroll` | w delta | window |
| `window-goto` | w l c | window |
| `window-left` / `window-right` / `window-home` / `window-end` | w | window |
| `window-insert-char` | w ch | (values window edit-desc) |
| `window-insert-string` | w s | (values window edit-desc) |
| `window-newline` | w | (values window edit-desc) |
| `window-backspace` | w | (values window edit-desc) |
| `window-delete` | w | (values window edit-desc) |

> **返回值规则**：编辑原语返回 `(values window desc)`；导航/状态原语直接返回 `window`。

### 6.2 view —— vrow 布局 + 映射 + 滚动

| 函数 | 输入 | 输出 |
|---|---|---|
| `vrow` | line start-col end-col | vrow（line=-1 空行） |
| `window-vrows` | w | (vectorof vrow) |
| `line-range->runs` | b li start end | (listof run)（裁剪 + face 合并） |
| `wrap-segments` | text width | (listof (cons start end)) |
| `layout-clip` | b top-line left-col width height | (vectorof vrow) |
| `layout-wrap` | b top-line top-seg width height | (vectorof vrow) |
| `window-point->screen` | w | (values row col) \| (values #f #f) |
| `window-screen->point` | w row col | (values line col) \| (values #f #f) |
| `window-scroll-visual` | w delta | window（按视觉行滚） |
| `window-ensure-point` | w | window（光标跟随滚动） |
| `window-visual-move` | w delta | window（上下按视觉行移动） |

### 6.3 width / render —— 宽度与渲染

| 函数 | 输入 | 输出 |
|---|---|---|
| `char-display-width` | c | 0 \| 1 \| 2 |
| `string-display-width` | s | nat |
| `index->column` | s i | nat（字符索引→显示列） |
| `column->index` | s col | nat（显示列→字符索引） |
| `snap-column-forward` | s L | nat（列吸附到字符起点） |
| `render-line` | b i | rendered-line |
| `glyph` | ch face | glyph |
| `rendered-line` | glyphs | rendered-line |

### 6.4 screen / project —— 画面与投影

| 函数 | 输入 | 输出 |
|---|---|---|
| `make-screen` | rows cols | 空 screen |
| `screen-diff-rows` | old new | (listof row)（变化行） |
| `screen-compose` | rows cols pieces active-id | screen（拼好的大屏） |
| `window->screen` | w | screen（单窗口投影） |

`pieces = (listof (list id x y screen))`；`active-id` 决定谁的光标透出。

---

## 7. 数据流（怎么串起来）

### 7.1 编辑闭环

```racket
(define b  (buffer-open "hello\nworld"))
(define w  (window-open b 10 40))

;; 一个 text-event 进来：
(define-values (w* desc) (window-insert-char w #\X))
;;   w*   : buffer 已换新、point 已推到编辑后位置（window 自动做）
;;   desc : edit-desc，交给上层做多窗口同步/撤销/语言层
```

### 7.2 渲染链

```racket
(define s (window->screen w))       ; buffer → glyph → run → screen
;; 多窗口/状态行：
(define big (screen-compose rows cols
              (list (list 'buf 0 0 (window->screen w1))
                    (list 'status 0 area-h (status-screen)))
              'buf))
```

### 7.3 属性链（写一次，全自动）

```racket
(define b2 (buffer-put-property b 0 1 7 'face 'keyword))
;; 编辑时属性跟着文本走（edit-desc 契约）
;; window->screen 时属性变 run.face
;; 后端 (hash-ref (run-face r) 'face) → 主题 → 颜色
```

### 7.4 输入路由（使用方的职责）

```racket
;; 鼠标 (x,y) 是屏幕坐标，要三步变 buffer 坐标：
;; 1) 命中哪个窗口？（布局知识）
;; 2) (x - win.x, y - win.y) 减偏移
;; 3) window-screen->point w row col → (line col)
```

### 7.5 read-only 区域（显示 + 输入）

`'read-only #t` 属性标出用户不可编辑的区间（如提示区）。编辑守卫在 splice 层拦截，
且 read-only 是**硬边界**：在边界插入什么都不继承，新输入保持干净。

```racket
(define b  (buffer-open "> _"))
(define b1 (buffer-put-property b  0 0 2 'read-only #t))   ; "> " 不可编辑
(define b2 (buffer-put-property b1 0 0 2 'face 'prompt))   ; 顺带提示色
(define w  (window-set-point (window-open b2 1 40) (point 0 3)))  ; 光标放输入区

;; 打字在输入区（col 3）→ 允许；打字在提示区（col 0~1）→ 拒绝（no-op）
;; backspace 到边界 → 拒绝（不能删进提示区）
```

规则：零宽插入在 read-only 区间「内部」→ 拒绝，在边界 → 允许；
非零宽删除与 read-only 区间「重叠」→ 拒绝。

**程序要编辑 read-only 内容**：用宏暂时绕过守卫（不需要手动解锁/上锁）：

```racket
(with-read-only-inhibited
  (buffer-splice b ...))   ; 这段作用域内可改 read-only，退出后自动恢复
```

注意：`inhibit-read-only` 只绕过编辑守卫，不改变硬边界继承——程序编辑 read-only
内容后，新增部分若要继续 read-only，需自行重新标记（这本来就是构造字段的职责）。

---

## 8. 最小编辑器骨架

```racket
(require "core/api.rkt")

(define b (buffer-open "hello"))            ; 开文档
(define w (window-open b 24 80))            ; 开视口

;; 每帧：
(define s (window->screen w))               ; 投影成画面，后端画 s

;; 后端喂入 event 后：
(define-values (w* desc) (window-insert-char w #\X))  ; 处理 text-event
(define w2 (window-right w*))               ; 处理 key-event 'right（直接返回 window）
```

> 命名约定速查：`make-*`（空构造）、`*-open`/`*-of-*`（从数据构造）、`*->*`（投影）、
> `*-set-*`（字段更新）、动词-名词（变换）、`*-apply-edit`（解释 edit-desc）。
