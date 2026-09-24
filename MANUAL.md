# EDITOR MANUAL —— 完整手册

纯函数式、持久化、后端无关的编辑器核心。所有值是**不可变数据**，所有操作是
`data -> lambda -> data` 的纯函数。本手册覆盖两个公开入口的全部 API：签名、参数、
语义与示例。

## 目录

- [0. 入口与快速开始](#0-入口与快速开始)
- [1. 命名契约（寻址轴）](#1-命名契约寻址轴)
- [2. 低层公开面 `core/api.rkt`](#2-低层公开面-coreapirkt)
  - [2.1 point（位置原子）](#21-point位置原子)
  - [2.2 selection / selection-set](#22-selection--selection-set)
  - [2.3 edit-desc（文本变更原子）](#23-edit-desc文本变更原子)
  - [2.4 attr-desc / change](#24-attr-desc--change)
  - [2.5 attrs（属性单元）](#25-attrs属性单元)
  - [2.6 buffer（纯文本值）](#26-buffer纯文本值)
  - [2.7 document / batch](#27-document--batch)
  - [2.8 window / layout / mirror](#28-window--layout--mirror)
  - [2.9 project / render / screen](#29-project--render--screen)
  - [2.10 事件 / 宽字符](#210-事件--宽字符)
- [3. editor 平台 `core/editor.rkt`](#3-editor-平台-coreeditorrkt)
  - [3.1 构造 / 生命周期](#31-构造--生命周期)
  - [3.2 查询（editor / document / view）](#32-查询editor--document--view)
  - [3.3 文档级读（did）](#33-文档级读did)
  - [3.4 视图读（vid / 焦点）](#34-视图读vid--焦点)
  - [3.5 视图写（vid / 焦点）](#35-视图写vid--焦点)
  - [3.6 选区与选区集](#36-选区与选区集)
  - [3.7 编辑原语 editor-command](#37-编辑原语-editor-command)
  - [3.8 编辑动作（op 值）](#38-编辑动作op-值)
  - [3.9 用户命令（导航 / 撤销 / 焦点）](#39-用户命令导航--撤销--焦点)
  - [3.10 属性](#310-属性)
  - [3.11 历史策略](#311-历史策略)
  - [3.12 视口同步 link](#312-视口同步-link)
  - [3.13 行号栏](#313-行号栏)
  - [3.14 投影](#314-投影)
  - [3.15 change-report](#315-change-report)
- [4. 配方](#4-配方)
- [5. 类型、不变量、违约](#5-类型不变量违约)
- [6. 范围](#6-范围)

---

## 0. 入口与快速开始

两个公开入口，按需 `require`：

```racket
(require "core/api.rkt")      ; 低层：point / selection / edit-desc / change / buffer / document / window / screen / 事件
(require "core/editor.rkt")   ; editor 平台：构造 + 编辑命令 + 导航 + 撤销 + 投影
```

`core/editor.rkt` **不重导** `core/api.rkt`。内部机制（`state.rkt` / `write.rkt` /
`reaction.rkt`）不在入口里，不用碰。

```racket
(require "core/api.rkt")
(require "core/editor.rkt")

;; 用户编辑：焦点光标处插入，光标前进，可撤销
(define ed (editor-open "hello\nworld"))
(define-values (ed* report) (editor-edit ed (edit-insert "hi ")))
(editor-document->string ed*)     ; => "hi hello\nworld"
(editor-point ed*)                ; => (point 0 3)
(change-report-texts report)      ; => (list (edit-desc (point 0 0) (point 0 0) "hi "))

;; 程序编辑：显式位置，不动任何光标
(define-values (ed2 _r) (editor-document-edit-at ed* 0 (point 1 0) (edit-insert "> ")))
(editor-point ed2)                ; 仍是 (point 0 3)

;; 渲染
(define scr (editor->screen ed2))  ; 一帧（后端无关的 screen）
(screen-height scr)                ; => 帧高（行数）
(screen-row scr 0)                 ; => 第 0 行的 run 列表 (listof run)
```

---

## 1. 命名契约（寻址轴）

看名字先判断**寻址轴**，再判断动作：

| 前缀 | 寻址 / 用途 | 例 |
|---|---|---|
| `editor-view-*` | 显式 **vid** | `editor-view-set-mode`、`editor-view-unlink` |
| `editor-*` | **焦点 view** 糖（视图状态 / 命令） | `editor-point`、`editor-mode`、`editor-goto` |
| `editor-document-*` | 显式 **did**（文档级读 / 写 / 账本） | `editor-document-attrs`、`editor-document-apply-attrs` |
| `editor-{open,open-document,close-*,focus-*,add-view}` | 生命周期 / 结构 | `editor-open-document` |
| `editor-command[-batch]` / `editor-edit` | 编辑原语 / 焦点编辑 | — |

低层同理：`window-*`（显式 view 值）、`document-*`（文档值）、`buffer-*`（纯文本值）；
低层没有「焦点」概念，寻址靠值本身。

通用后缀：`?` 谓词；`X->Y` 转换；`set-` 设字段；`put-` 安装整个值；
`apply-` 施加变更；`open`/`empty`/`compose` 构造。

---

## 2. 低层公开面 `core/api.rkt`

### 2.1 point（位置原子）

`(struct point (line col))` —— 唯一位置表示，0-based，`col` 是**字符索引**（不是显示列）。

| 名字 | 签名 | 语义 |
|---|---|---|
| `point` | `(point line col)` | 构造位置 |
| `point?` | `(point? v)` | 谓词 |
| `point-line` | `(point-line p)` | 行 |
| `point-col` | `(point-col p)` | 列（字符索引） |
| `point<?` | `(point<? a b)` | 字典序小于 |
| `point=?` | `(point=? a b)` | 相等 |
| `point<=?` | `(point<=? a b)` | 偏序 ≤ |
| `pos<?` / `pos=?` / `pos<=?` | `(pos<? l1 c1 l2 c2)` | 直接比较 (line,col) |
| `point-clamp` | `(point-clamp p line-count line-length)` | 夹到 `[0,line-count) × [0,line-length]`；`line-length` 为 0 → NaN 时原样 |

```racket
(point<? (point 0 3) (point 1 0))  ; => #t
(point-clamp (point 9 9) 3 (lambda (l) 5))  ; line-length 可为函数或数
```

### 2.2 selection / selection-set

`(struct selection (anchor head))` —— 选区；空选区（anchor=head）即光标。范围恒为 `[min,max)`。

| 名字 | 签名 | 语义 |
|---|---|---|
| `selection` | `(selection anchor head)` | 构造 |
| `selection?` | `(selection? v)` | 谓词 |
| `caret` | `(caret p)` | 空选区（光标） |
| `caret?` | `(caret? s)` | 是否空选区 |
| `caret-point` | `(caret-point s)` | 空选区的点（含方向无关） |
| `selection-anchor` / `selection-head` | `(selection-anchor s)` | 两端点 |
| `selection-point` | `(selection-point s)` | head 点（光标语义下=caret） |
| `selection-range` | `(selection-range s)` | `(values start end)`，正向 |
| `selection-empty?` | `(selection-empty? s)` | 是否空 |
| `selection-with-head` | `(selection-with-head s p)` | 换 head 的新选区 |
| `selection-with-anchor` | `(selection-with-anchor s p)` | 换 anchor 的新选区 |
| `selection-map-head` | `(selection-map-head f s)` | 对 head 施 `point→point` |
| `selection-map-anchor` | `(selection-map-anchor f s)` | 对 anchor 施 |
| `selection-map-both` | `(selection-map-both f s)` | 对两端施 |

`(struct selection-set (name selections leader-index))` —— 命名选区集（多选区的单位）。

| 名字 | 签名 | 语义 |
|---|---|---|
| `selection-set?` | `(selection-set? v)` | 谓词 |
| `selection-set-open` | `(selection-set-open name sels [leader-index 0])` | 构造（规范化：排序/去重/合并） |
| `selection-set-name` | `(selection-set-name g)` | 名字（`#f` 匿名） |
| `selection-set-selections` | `(selection-set-selections g)` | 区间集 |
| `selection-set-leader` | `(selection-set-leader g)` | leader 选区（值） |
| `selection-set-leader-index` | `(selection-set-leader-index g)` | leader 下标 |
| `selection-set-put-leader` | `(selection-set-put-leader g s)` | 设 leader |
| `selection-set-add` / `selection-set-remove` | `(selection-set-add g sels)` | 并/差集 |
| `selection-set-map` | `(selection-set-map g f)` | 对每个选区施 `selection→selection` |
| `selection-set-clear` | `(selection-set-clear g)` | 收敛为单个 leader 选区 |
| `selection-set-normalize` | `(selection-set-normalize g)` | 重新规范化 |
| `selection-set-map-edit` | `(selection-set-map-edit g descs)` | 编辑后重定位（free 语义） |
| `selection-set-advance-leader` | `(selection-set-advance-leader g descs)` | 编辑后推进 leader（leader 语义） |

### 2.3 edit-desc（文本变更原子）

`(struct edit-desc (start end new-text))` —— 一次替换 `[start,end) → new-text`。

| 名字 | 签名 | 语义 |
|---|---|---|
| `edit-desc` | `(edit-desc start end new-text)` | 构造 |
| `edit-desc?` | `(edit-desc? v)` | 谓词 |
| `edit-desc-start` / `-end` / `-new-text` | | 字段 |
| `edit-desc-after-position` | `(edit-desc-after-position d)` | 插入文本之后的点 |
| `edit-desc-map-position` | `(edit-desc-map-position d p)` | 编辑前位置 → 编辑后（`#f`=落在删除区） |
| `edit-desc-inverse` | `(edit-desc-inverse d old-text)` | 生效 desc + 旧文本 → 逆 desc |
| `edits-normalize` | `(edits-normalize who descs)` | 规范化一批（按起点倒序、查重叠） |
| `edits-map-position` | `(edits-map-position descs p)` | 过一串 desc 的位置映射 |
| `edits-span` | `(edits-span descs)` | `(values first-line last-line)`（施加顺序无关） |

### 2.4 attr-desc / change

`(struct attr-desc (start end key op val))` —— 属性变更；同行、半开、零宽 = no-op。
`(struct change (texts attrs))` —— **唯一跨层变更值**（文本 + 属性）。

| 名字 | 签名 | 语义 |
|---|---|---|
| `attr-desc` | `(attr-desc start end key op val)` | 构造（`op` ∈ `'set` / `'remove`） |
| `attr-desc?` | `(attr-desc? v)` | 谓词 |
| `attr-desc-start` / `-end` / `-key` / `-op` / `-val` | | 字段 |
| `attr-desc-empty?` | `(attr-desc-empty? d)` | 零宽 → `#t` |
| `attr-set` | `(attr-set start end key val)` | 构造「设属性」 |
| `attr-remove` | `(attr-remove start end key)` | 构造「删属性」 |
| `change` | `(change texts attrs)` | 构造变更集 |
| `change?` | `(change? v)` | 谓词 |
| `change-texts` / `change-attrs` | | 读字段 |
| `edits->change` | `(edits->change ds)` | 纯文本变更 |
| `attrs->change` | `(attrs->change as)` | 纯属性变更 |
| `change-empty?` | `(change-empty? c)` | 无文本也无属性 |
| `change-text-only?` | `(change-text-only? c)` | 仅文本 |
| `change-attr-only?` | `(change-attr-only? c)` | 仅属性 |

### 2.5 attrs（属性单元）

`(struct attrs ...)` —— 行内属性区间（通用 key→hash），随编辑移动。core 只解释保留 key
`read-only`（`read-only-key`）。

| 名字 | 签名 | 语义 |
|---|---|---|
| `attrs?` | `(attrs? v)` | 谓词 |
| `attrs-empty` | `(attrs-empty line-count)` | 空属性（按行数） |
| `attrs-line-count` | `(attrs-line-count a)` | 行数 |
| `attrs-at` | `(attrs-at a p)` | 某点的属性 hash |
| `attrs-runs` | `(attrs-runs a line line-length)` | 某行的 `(list start end hash)` |
| `attrs-key-runs` | `(attrs-key-runs a line line-length key)` | 某行某 key 的段 `(list start end val)` |
| `attrs-range-runs` | `(attrs-range-runs a start end)` | 区间内每行的属性段 |
| `attrs-apply-edit` | `(attrs-apply-edit a d)` | 属性随文本 desc 移动 |
| `attrs-apply-attr` | `(attrs-apply-attr a who d)` | 施加一条 `attr-desc` |
| `attrs-apply-attr-batch` | `(attrs-apply-attr-batch a who ds)` | 批量施加 |
| `attrs-desc-inverse` | `(attrs-desc-inverse a d)` | 属性 desc 的逆 |
| `attrs-check` | `(attrs-check a line-count)` | 结构自检（越界/重叠报错） |
| `read-only-key` | | 保留 key `'read-only` |
| `attr-read-only?` | `(attr-read-only? h)` | hash 是否带 `read-only #t` |

### 2.6 buffer（纯文本值）

`(struct buffer (content tick))` —— 纯文本；`tick` 是文本版本。

| 名字 | 签名 | 语义 |
|---|---|---|
| `buffer?` | `(buffer? v)` | 谓词 |
| `buffer-open` | `(buffer-open s)` | 从字符串建 |
| `buffer-content` | `(buffer-content b)` | 行向量存储 |
| `buffer->string` / `buffer->lines` | | 导出 |
| `buffer-line-count` / `-line-ref` / `-line-length` | | 行几何 |
| `buffer-clamp-point` | `(buffer-clamp-point b p)` | 按 buffer 夹点 |
| `buffer-point->offset` / `buffer-offset->point` | | 点 ↔ 字符偏移 |
| `buffer-range-text` | `(buffer-range-text b s e)` | 区间文本 |
| `buffer-clamp-edit-descs` | `(buffer-clamp-edit-descs b descs)` | 把 descs 夹到合法域 |
| `buffer-content-eq?` | `(buffer-content-eq? a b)` | 文本是否相同 |
| `buffer-tick` | `(buffer-tick b)` | 文本版本 |
| `buffer-edit-desc-inverse` | `(buffer-edit-desc-inverse b d)` | 用编辑前 buffer 求逆 |
| `buffer-op-insert` | `(buffer-op-insert text)` | `(buffer selection → edit-desc)` |
| `buffer-op-insert-char` / `-newline` | `(buffer-op-insert-char ch)` | 同上 |
| `buffer-op-backspace` / `-delete` | | 同上（含选择） |
| `buffer-op-splice` | `(buffer-op-splice start end text)` | 显式区间替换 |

`buffer-op-*` 是**动作值**：`op = (buffer selection → (or/c #f edit-desc))`，传给
`document-edit-at` / `editor-command`。

### 2.7 document / batch

`(struct document (buffer attrs attr-tick))` —— 可编辑根；`document-apply-change` 是唯一漏斗。

| 名字 | 签名 | 语义 |
|---|---|---|
| `document?` | `(document? v)` | 谓词 |
| `document-open` | `(document-open s)` | 从字符串建 |
| `document-buffer` / `document-attrs` | | 取纯文本 / 取属性 |
| `document->string` / `->lines` | `(document->string d)` | 导出 |
| `document-line-count` / `-line-ref` / `-line-length` | | 行几何 |
| `document-clamp-point` | `(document-clamp-point d p)` | 夹点 |
| `document-point->offset` / `-offset->point` | | 点 ↔ 偏移 |
| `document-range-text` | `(document-range-text d s e)` | 区间文本 |
| `document-clamp-edit-descs` | `(document-clamp-edit-descs d descs)` | 夹 descs |
| `document-text-tick` / `-attr-tick` | | 文本 / 标注版本 |
| `document-content-eq?` / `-attrs-eq?` | `(document-content-eq? a b)` | 文本 / 标注是否同一 |
| `document-apply-change` | `(document-apply-change d ch #:trusted? [trusted? #f])` | **唯一漏斗**；返回 `(values document change-result/#f)` |
| `document-apply-edit` | `(document-apply-edit d desc #:trusted? [trusted? #f])` | 文本单条；返回 `(values document 生效desc/#f)` |
| `document-apply-edit-batch` | `(document-apply-edit-batch d descs #:trusted? [trusted? #f])` | 文本批；返回 `(values document 生效descs 逆)` |
| `document-edit-at` | `(document-edit-at d p op #:trusted? [trusted? #f])` | 给位置与 op 算 desc 再施加 |
| `document-put-attr` | `(document-put-attr d key line c0 c1 val)` | 单段写属性（走漏斗） |
| `document-remove-attr` | `(document-remove-attr d key line c0 c1)` | 单段删属性 |
| `document-replace-attr` | `(document-replace-attr d key spans #:lines [l0 0] [l1 末行])` | **替换**某 key 在一段行范围（`spans` = `(list (list line c0 c1 val))`；单行 = `#:lines L L`） |
| `document-attrs-at` / `-runs` / `-key-runs` | | 属性读 |
| `change-result` | `(struct change-result ...)` | 一次变更的完整结果 |
| `change-result?` | `(change-result? v)` | 谓词 |
| `change-result-applied-texts` / `-applied-attrs` | | 生效 descs（施加顺序） |
| `change-result-text-inverses` / `-attr-inverses` | | 逆（与 applied 平行） |
| `change-result-erased-restores` | | 被文本抹掉的属性（原坐标补回） |
| `change-result-replay` | `(change-result-replay res)` | 正向 change |
| `change-result-undo` | `(change-result-undo res)` | 撤销 change 序列 |

**`#:trusted?`**：默认 `#f`（守 read-only）；`#t` 跳过守卫。撤销/重放走 `#:trusted? #t`。

### 2.8 window / layout / mirror

`(struct window (document selection-set mode top-line left-col top-seg height width line-numbers?))`
—— 视口：文档引用 + 选区集 + 滚动/尺寸 + 行号开关。

| 名字 | 签名 | 语义 |
|---|---|---|
| `window?` | `(window? v)` | 谓词 |
| `window-open` | `(window-open d [height 24] [width 80])` | 从文档建 |
| `window-document` / `window-buffer` | | 文档 / 其纯文本 |
| `window-set-document` | `(window-set-document w d)` | 换绑文档（夹光标） |
| `window-point` | `(window-point w)` | primary 光标 |
| `window-selections` | `(window-selections w)` | 选区集（列表） |
| `window-primary` / `window-primary-index` | | primary 选区 / 下标 |
| `window-set-point` | `(window-set-point w p)` | 设成单个光标 |
| `window-set-selections` | `(window-set-selections w sels [primary-index 0])` | 设一组 |
| `window-add-selections` / `-remove-selections` | | 并 / 差 |
| `window-add-selection` / `-remove-selection` | | 单条 |
| `window-set-primary` / `-set-primary-index` | | 设 primary |
| `window-selection-member?` | `(window-selection-member? w s)` | 集合成员判定 |
| `window-map-selections` | `(window-map-selections w f)` | 对每个选区施 `selection→selection` |
| `window-map-primary` | `(window-map-primary w f)` | 仅 primary |
| `window-map-points` | `(window-map-points w f)` | 对每个 head 施 `point→point`（坍缩） |
| `window-clamp-selections` | `(window-clamp-selections w)` | 夹紧并规范化 |
| `window-selection-set` / `-name` | | 选区集值 / 名 |
| `window-put-selection-set` | `(window-put-selection-set w g)` | 安装选区集 |
| `window-clear-selection-set` | `(window-clear-selection-set w)` | 收敛为单个 leader |
| `window-mode` / `-height` / `-width` | | 读 |
| `window-top-line` / `-left-col` / `-top-seg` | | 滚动位置（显示坐标） |
| `window-line-numbers?` | `(window-line-numbers? w)` | 行号栏开关 |
| `window-set-mode` / `-set-size` / `-set-top-line` / `-set-left-col` / `-set-top-seg` / `-set-line-numbers` | | 写 |
| `window-vscroll` / `-hscroll` | `(window-vscroll w delta)` | 相对滚动 |
| `window-clamp-view` | `(window-clamp-view w)` | 视口夹回合法域 |
| `window-gutter-width` / `-content-width` | `(window-gutter-width w)` | 行号栏宽 / 正文宽（派生） |
| `window-vrows` | `(window-vrows w)` | 视觉行向量 `(vectorof vrow)`（内部，未进 `api.rkt`） |
| `window-point->screen` | `(window-point->screen w [p])` | 点 → `(values row col)` / `#f` |
| `window-screen->point` | `(window-screen->point w row col)` | 屏幕 → `(values line col)` / `#f` |
| `window-scroll` | `(window-scroll w delta)` | 按 mode 滚视觉行 |
| `window-ensure-point` | `(window-ensure-point w)` | 滚动使 primary 可见 |
| `window-visual-move` | `(window-visual-move w delta)` | 全部光标按视觉行移动 |
| `window-left` / `-right` / `-up` / `-down` / `-home` / `-end` | | 视口级导航 |
| `point-left` / `-right` / `-home` / `-end` | `(point-left b p)` | 纯点运动（buffer 级） |
| `point-up` / `-down` | `(point-up w p)` | 视觉行移动（window 级） |
| `wrap-segments` | `(wrap-segments text width)` | 折行段 `(list (cons start end))`（内部） |
| `layout-clip` / `layout-wrap` | | vrow 布局（内部） |
| `line-range->runs` | `(line-range->runs b line start end [provider])` | 一行切片 → runs（内部） |
| `mirror-point` | `(mirror-point d-src p d-dst)` | 逻辑映射（行固定、列按比例） |
| `mirror-window` | `(mirror-window w-src w-dst)` | 源视口投到目标视口（不改文档/选区） |

### 2.9 project / render / screen —— 屏幕帧与绘制

`window->screen` / `editor->screen` 把视口投影成**后端无关的一帧** `screen`，后端
（终端 / GUI）拿它画。**坐标单位**：`col` / `start-col` / `end-col` 都是**显示列**
（0-based，宽字符按 `char-display-width` 换算），与 `point.col`（字符索引）不同。

**`face` 是应用自定义的语义值**（`any/c`）——结构随你，core 只搬运、不解释；
`face-provider` 返回什么，`run-face` / `cursor-face` / `region-face` 就是什么。
约定常用 `(hash 'face 'keyword)`，但用符号 / struct / 任何值都行；provider 未覆盖的段，
core 给 `#f`（纯“无 face”，不发明任何值），由前端自行处理。

**数据流**：

```
buffer ──render──▶ glyph ──layout──▶ vrow ──project──▶ row-runs ┐
window(selection-set) ─────────────────────────────▶ cursors/selections ┤
                                                                        └─▶ screen
face-provider : buffer × line → (list start end face)   ; 派生 face 在此注入，不进文档
```

#### screen（一帧）

`(struct screen (height width row-runs cursors selections))`（结构不透明，只给读口）

| 读口 | 签名 | 返回 | 语义 |
|---|---|---|---|
| `screen?` | `(screen? v)` | bool | 谓词 |
| `screen-height` | `(screen-height s)` | nat | **帧高**（行数） |
| `screen-width` | `(screen-width s)` | nat | 帧宽（列数） |
| `screen-row` | `(screen-row s i)` | `(listof run)` | 第 i 行的 run，**按 col 升序**；越界报错 |
| `screen->rows` | `(screen->rows s)` | `(listof (listof run))` | 所有行（共 `height` 个） |
| `screen-row->string` | `(screen-row->string s i)` | string | 第 i 行的纯文本（run 空隙补空格、末尾裁掉） |
| `screen-cursors` | `(screen-cursors s)` | `(listof cursor)` | 所有光标点（含 primary） |
| `screen-selections` | `(screen-selections s)` | `(listof region)` | 所有选中区段（跨行切成多段） |
| `screen-cursor-row` / `-cursor-col` | `(screen-cursor-row s)` | int | primary 光标的行 / 列（无 → `-1`） |
| `screen-primary-cursor` | `(screen-primary-cursor s)` | `cursor`/`#f` | primary 光标值 |

行内容用 `screen-row` / `screen->rows`（list，**不暴露内部 vector**），不是 `screen-height`
（那只是行数）。行内可有空隙：run 未覆盖的列 = 一个空格。

#### run（一行里的一段文本）

`(struct run (col text face))`

| 名字 | 签名 | 类型 | 语义 |
|---|---|---|---|
| `run` | `(run col text face)` | — | 构造 |
| `run?` | `(run? v)` | bool | 谓词 |
| `run-col` | `(run-col r)` | nat（显示列） | 这段文本从哪一列开始 |
| `run-text` | `(run-text r)` | string | 文本（不含换行；原字符，宽字符不展开） |
| `run-face` | `(run-face r)` | any/c | **语义** face：结构应用自定（如 `(hash 'face 'keyword)` 或符号）；未覆盖段为 `#f`；core 不解释、不给颜色 |

#### cursor / region（视图 overlay）

`(struct cursor (row col face primary?))`：`row`/`col` 显示坐标，`face` 是自定义语义值（如
`(hash 'face 'cursor)`），`primary?` 标记主光标。
`(struct region (row start-col end-col face))`：`[start-col,end-col)` 半开，`face` 同上（如
`(hash 'face 'selection)`）。

| 名字 | 签名 | 语义 |
|---|---|---|
| `cursor` / `cursor?` / `cursor-row` / `cursor-col` / `cursor-face` / `cursor-primary?` | `(cursor row col face primary?)` | 光标 overlay |
| `region` / `region?` / `region-row` / `region-start-col` / `region-end-col` / `region-face` | `(region row start-col end-col face)` | 选中区 overlay |

#### pane（合成屏里的一块）

`(struct pane (id x y screen))`：把子帧 `screen` 的左上角贴在合成屏 `(x,y)`（可负，超出裁掉）；
`id` 供 `screen-compose` 匹配 `active-id`，只有 active pane 的光标透出。

| 名字 | 签名 | 语义 |
|---|---|---|
| `pane` / `pane?` / `pane-id` / `pane-x` / `pane-y` / `pane-screen` | `(pane id x y screen)` | 合成屏的一块子帧 |

#### 怎么画（最小终端渲染器）

对每一行 r：

1. `runs = (screen-row scr r)`；列游标 `col` 从 0 起。
2. 若 `(> (run-col run) col)`，先补 `(- (run-col run) col)` 个空格（run 之间的空隙）。
3. 按 `run-face` 映射出的样式输出 `run-text`；`col ← (run-col run) + string-display-width(run-text)`。
4. 行尾可补空格到 `screen-width`。

再叠加：`screen-selections`（把区间文本重画成选择样式）→ `screen-cursors`（把光标画成一格）。
**`face` → 样式是应用的事**。

```racket
(define (face-style face)                  ; face : any/c；#f = 无 face（provider 未覆盖）
  (and (hash? face)
       (case (hash-ref face 'face #f)
         [(keyword) 'info] [(comment) 'green] [(read-only) 'error]
         [(selection) 'selection] [(cursor) 'cursor] [else #f])))

(define (draw-screen scr)                   ; 伪代码；真终端 = 光标移动 + 样式转义
  (for ([runs (in-list (screen->rows scr))] [row (in-naturals)])
    (define col 0)
    (for ([run (in-list runs)])
      (when (> (run-col run) col) (emit-spaces (- (run-col run) col)))   ; 补空隙
      (emit-styled (face-style (run-face run)) (run-text run))
      (set! col (+ (run-col run) (string-display-width (run-text run))))))
  (for ([g (in-list (screen-selections scr))])   ; 选择区叠加
    (emit-region (region-row g) (region-start-col g) (region-end-col g)))
  (for ([c (in-list (screen-cursors scr))])      ; 光标叠加
    (emit-cursor (cursor-row c) (cursor-col c) (cursor-primary? c))))
```

`screen->string` 是上面「只画文档文本」的简化版（测试 / 无前端驱动用）。

#### 拼屏与增量

| 名字 | 签名 | 语义 |
|---|---|---|
| `screen-compose` | `(screen-compose height width panes active-id)` | 把 `(listof pane)` 贴到大屏；文本/选区按 x/y 平移，**只透出 active pane 的光标** |
| `screen-damage` | `(screen-damage old new)` | 需要**整行重绘**的行号（文本 ∪ overlay 变化）；`#f` = 整屏重绘（帧尺寸变化） |

#### 投影 API

| 名字 | 签名 | 语义 |
|---|---|---|
| `window->screen` | `(window->screen w [face-provider empty-face-provider])` | 视口 → 一帧 |
| `editor->screen` | `(editor->screen ed [face-provider empty-face-provider])` | 焦点视图 → 一帧 |
| `editor-view->screen` | `(editor-view->screen ed vid [face-provider empty-face-provider])` | 某视图 → 一帧 |
| `empty-face-provider` | `(empty-face-provider b line)` | 缺省 provider（总是空） |
| `screen-empty` | `(screen-empty height width)` | 空帧（无 run / 光标 / 选区） |
| `screen->string` | `(screen->string s)` | 只把文档文本摊平成纯文本（测试用） |
| `render-line` | `(render-line b i [provider])` | 一行 → glyph 向量（内部） |
| `window-vrows` | `(window-vrows w)` | 视觉行向量（内部） |
| `line-range->runs` / `wrap-segments` / `layout-clip` / `layout-wrap` | | 布局/runs 原语（内部） |

### 2.10 事件 / 宽字符

| 名字 | 签名 | 语义 |
|---|---|---|
| `struct:modifiers` | `(struct modifiers (control alt shift meta))` | 修饰键 |
| `modifiers` / `modifiers?` / `modifiers-control` / `-alt` / `-shift` / `-meta` | | |
| `struct:text-event` | `(struct text-event (text modifiers))` | 文本输入 |
| `text-event` / `text-event?` / `-text` / `-modifiers` | | |
| `struct:key-event` | `(struct key-event (key modifiers))` | 按键 |
| `key-event` / `key-event?` / `-key` / `-modifiers` | | |
| `struct:mouse-press-event` | `(struct mouse-press-event (button x y modifiers))` | 鼠标按下 |
| `struct:mouse-wheel-event` | `(struct mouse-wheel-event (direction x y modifiers))` | 滚轮 |
| `struct:resize-event` | `(struct resize-event (rows cols))` | 终端尺寸变化 |
| `struct:quit-event` | `(struct quit-event ())` | 退出 |
| `char-display-width` | `(char-display-width c)` | 字符显示宽（宽=2，组合=0） |
| `string-display-width` | `(string-display-width s)` | 串显示宽 |
| `index->column` | `(index->column s i)` | 字符索引 → 显示列 |
| `column->index` | `(column->index s col)` | 显示列 → 字符索引 |
| `snap-column-forward` | `(snap-column-forward s L)` | 显示列吸附到字符起点 |

### 2.11 数据结构字段速查

值都不可变；不透明结构只给谓词 / 读口 / 具名构造（不透 `struct` 构造器）。

| 结构 | 字段（名 : 类型） | 说明 |
|---|---|---|
| `point` | `line : nat`、`col : nat` | 0-based；`col` 是**字符索引** |
| `selection` | `anchor : point`、`head : point` | 范围 `[min,max)`；`anchor=head` 即光标 |
| `selection-set` | `name : symbol/#f`、`selections : (nonempty-listof selection)`、`leader-index : nat` | 已规范化 |
| `edit-desc` | `start : point`、`end : point`、`new-text : string` | 替换 `[start,end)` |
| `attr-desc` | `start : point`、`end : point`、`key : symbol`、`op : 'set / 'remove`、`val : any` | 同行、半开 |
| `change` | `texts : (listof edit-desc)`、`attrs : (listof attr-desc)` | 唯一跨层变更值 |
| `attrs` | 不透明 | 行内属性；`attrs-line-count` 读行数 |
| `buffer` | `content`（行向量）、`tick : nat` | 不透明；`tick` = 文本版本 |
| `document` | `buffer : buffer`、`attrs : attrs`、`attr-tick : nat` | 不透明 |
| `window` | `document`、`selection-set`、`mode : 'clip/'wrap'`、`top-line : nat`、`left-col : nat`、`top-seg : nat`、`height : nat`、`width : nat`、`line-numbers? : bool` | 不透明；`width` 含行号栏 |
| `change-result` | `applied-texts`、`applied-attrs`、`text-inverses`、`attr-inverses`、`erased-restores` | 一次变更的结果（施加顺序） |
| `change-report` | `texts : (listof edit-desc)`、`attrs : (listof attr-desc)` | 命令第二返回值 |
| `run` | `col : nat`、`text : string`、`face : any/c` | 屏幕一行里的一段；`face` 结构应用自定，未覆盖段为 `#f` |
| `cursor` | `row : nat`、`col : nat`、`face : any/c`、`primary? : bool` | 视图 overlay |
| `region` | `row : nat`、`start-col : nat`、`end-col : nat`、`face : any/c` | 视图 overlay |
| `pane` | `id : any`、`x : int`、`y : int`、`screen : screen` | 合成屏的一块子帧 |
| `screen` | `height : nat`、`width : nat`、`row-runs : (vectorof (listof run))`、`cursors : (listof cursor)`、`selections : (listof region)` | 不透明；后端据此画 |

字符索引 vs 显示列：**`point.col` 是字符索引**；**`window.left-col` / `run-col` /
`cursor-col` / `region-*-col` / vrow 都是显示列**（已按宽字符换算）。换算只经
`index->column` / `column->index` / `snap-column-forward`。

---

## 3. editor 平台 `core/editor.rkt`

### 3.1 构造 / 生命周期

| 名字 | 签名 | 语义 |
|---|---|---|
| `editor-open` | `(editor-open text [height 24] [width 80] #:name [name "*scratch*"] #:history? [history? #t] #:line-numbers? [line-numbers? #f])` | 单文档单视图；返回 `editor` |
| `editor-open-document` | `(editor-open-document ed text [height 24] [width 80] #:name [name "*scratch*"] #:focus? [focus? #f] #:history? [history? #t] #:line-numbers? [line-numbers? #f])` | 新文档 + 视图；返回 `(values editor did)` |
| `editor-add-view` | `(editor-add-view ed did [height 24] [width 80] [p (point 0 0)] #:sync [sync 'free] #:focus? [focus? #f] #:link [link #f] #:line-numbers? [line-numbers? #f])` | 加视图；返回 `(values editor vid)` |
| `editor-close-view` | `(editor-close-view ed vid)` | 关视图（改焦点到剩余首个） |
| `editor-close-document` | `(editor-close-document ed did)` | 关文档及其全部视图 |
| `editor-focus-view` | `(editor-focus-view ed vid)` | 聚焦视图 |
| `editor-focus-document` | `(editor-focus-document ed did)` | 聚焦该文档首个视图 |
| `editor-document-set-name` | `(editor-document-set-name ed did name)` | 重命名文档 |
| `editor?` | `(editor? v)` | 谓词 |

`#:history?` = 该文档默认是否记历史；`#:focus?` 默认 `#f`（不抢焦点）；
`#:sync` ∈ `'free | 'follow`；`#:link` = 视口同步链接名。

### 3.2 查询（editor / document / view）

| 名字 | 签名 | 语义 |
|---|---|---|
| `editor-document-count` | `(editor-document-count ed)` | 文档数 |
| `editor-view-count` | `(editor-view-count ed)` | 视图数 |
| `editor-documents` | `(editor-documents ed)` | document-entry 列表 |
| `editor-views` | `(editor-views ed)` | view 列表 |
| `editor-focus` | `(editor-focus ed)` | 焦点 vid（`#f` 表示无） |
| `editor-document-id` | `(editor-document-id ed)` | 焦点视图的 did |
| `editor-document-view` | `(editor-document-view ed [did])` | 该文档第一个 vid（无 → `#f`） |
| `editor-view-document-id` | `(editor-view-document-id ed vid)` | 某视图的 did |
| `view-id` | `(view-id v)` | 投影：视图 id |
| `view-sync` | `(view-sync v)` | 投影：同步策略 |
| `document-entry-id` / `document-entry-name` | | 投影：文档 id / 名 |

### 3.3 文档级读（did）

`did` 缺省 = 焦点文档。

| 名字 | 签名 | 语义 |
|---|---|---|
| `editor-document` | `(editor-document ed [did])` | 取 document 值 |
| `editor-document-buffer` | `(editor-document-buffer ed [did])` | 取纯文本 buffer |
| `editor-document-attrs` | `(editor-document-attrs ed [did])` | 取属性 |
| `editor-document-name` | `(editor-document-name ed [did])` | 文档名 |
| `editor-document->string` / `->lines` | `(editor-document->string ed [did])` | 导出 |
| `editor-document-line-count` | `(editor-document-line-count ed [did])` | 行数 |
| `editor-document-line-ref` | `(editor-document-line-ref ed did i)` | 第 i 行文本 |
| `editor-document-line-length` | `(editor-document-line-length ed did i)` | 第 i 行长 |
| `editor-document-clamp-point` | `(editor-document-clamp-point ed did p)` | 夹点 |
| `editor-document-point->offset` / `-offset->point` | | 点 ↔ 偏移 |
| `editor-document-range-text` | `(editor-document-range-text ed did s e)` | 区间文本 |
| `editor-document-text-tick` / `-attr-tick` | `(editor-document-text-tick ed [did])` | 文本 / 标注版本 |
| `editor-document-content-eq?` | `(editor-document-content-eq? ed b1 b2)` | 两文档文本是否同 |
| `editor-document-attrs-eq?` | `(editor-document-attrs-eq? ed b1 b2)` | 两文档标注是否同 |

### 3.4 视图读（vid / 焦点）

`editor-view-*` 收显式 `vid`；`editor-*` 是焦点糖。

| 名字 | 签名 | 语义 |
|---|---|---|
| `editor-view-point` / `editor-point` | `(editor-view-point ed vid)` | 光标 |
| `editor-view-primary` / `editor-primary` | | primary 选区 |
| `editor-view-primary-index` / `editor-primary-index` | | primary 下标 |
| `editor-view-selections` / `editor-selections` | | 选区列表 |
| `editor-view-selection-set` / `editor-selection-set` | | 选区集 |
| `editor-view-selection-set-name` / `editor-selection-set-name` | | 选区集名 |
| `editor-view-window` / `editor-window` | | window（只读） |
| `editor-view-buffer` | `(editor-view-buffer ed vid)` | 该视图的纯文本 |
| `editor-view-document` | `(editor-view-document ed vid)` | 该视图的 document |
| `editor-view-height` / `editor-height` | | 可见高 |
| `editor-view-width` / `editor-width` | | 可见宽 |
| `editor-view-top-line` / `editor-top-line` | | 顶部行 |
| `editor-view-left-col` / `editor-left-col` | | 水平滚动列 |
| `editor-view-top-seg` / `editor-top-seg` | | 折行段 |
| `editor-view-mode` / `editor-mode` | | `'clip` / `'wrap` |
| `editor-view-line-numbers?` / `editor-line-numbers?` | | 行号栏开关 |
| `editor-view-sync` / `editor-sync` | | 同步策略 |
| `editor-view-link` / `editor-link` / `editor-links` | | 链接名；全部链接名 |
| `editor-view-history-enabled?` / `editor-document-history-enabled?` | | 历史策略 |
| `editor-view-point-left` / `editor-point-left` | `(editor-point-left ed p)` | 点算子（不碰 buffer/window） |
| `editor-view-point-right` / `editor-point-right` | | |
| `editor-view-point-home` / `editor-point-home` | | |
| `editor-view-point-end` / `editor-point-end` | | |
| `editor-view-point-up` / `editor-point-up` | | 视觉行上移 |
| `editor-view-point-down` / `editor-point-down` | | 视觉行下移 |

### 3.5 视图写（vid / 焦点）

| 名字 | 签名 | 语义 |
|---|---|---|
| `editor-view-set-point` / `editor-set-point` | `(editor-view-set-point ed vid p)` | 设光标 |
| `editor-view-set-selections` / `editor-set-selections` | `(editor-view-set-selections ed vid sels [primary-index 0])` | 设选区集 |
| `editor-view-add-selections` / `editor-add-selections` | `(editor-view-add-selections ed vid sels #:primary? [primary? #f])` | 并 |
| `editor-view-remove-selections` / `editor-remove-selections` | | 差 |
| `editor-view-add-selection` / `editor-add-selection` | `(editor-view-add-selection ed vid s #:primary? [primary? #f])` | 单条并 |
| `editor-view-remove-selection` / `editor-remove-selection` | | 单条差 |
| `editor-view-set-primary` / `editor-set-primary` | | 设 primary 选区 |
| `editor-view-set-primary-index` / `editor-set-primary-index` | | 设 primary 下标 |
| `editor-view-selection-member?` / `editor-selection-member?` | | 成员判定 |
| `editor-view-collapse-selections` / `editor-collapse-selections` | | 回单光标 |
| `editor-view-map-selections` / `editor-map-selections` | | 遍历全部选区 |
| `editor-view-map-primary` / `editor-map-primary` | | 仅 primary |
| `editor-view-map-points` / `editor-map-points` | | 遍历 head |
| `editor-view-put-selection-set` / `editor-put-selection-set` | | 安装选区集 |
| `editor-view-clear-selection-set` / `editor-clear-selection-set` | | 清除选区集 |
| `editor-view-put-window` / `editor-put-window` | `(editor-view-put-window ed vid w)` | 裸写整个 window（文档须相符） |
| `editor-view-set-size` / `editor-set-size` | `(editor-view-set-size ed vid height width)` | 尺寸 |
| `editor-view-set-mode` / `editor-set-mode` | | `'clip`/`'wrap` |
| `editor-view-set-top-line` / `editor-set-top-line` | | 顶部行 |
| `editor-view-set-left-col` / `editor-set-left-col` | | 水平滚动列 |
| `editor-view-set-top-seg` / `editor-set-top-seg` | | 折行段 |
| `editor-view-set-line-numbers` / `editor-set-line-numbers` | | 行号栏 |
| `editor-view-set-sync` / `editor-set-sync` | | 同步策略 |
| `editor-view-set-document` / `editor-set-document` | | 改看另一文档 |

所有 `editor-view-*` **只动指定 view**，不读也不改焦点，不镜像；同文档其它视图不受影响。

### 3.6 选区与选区集

见 §3.4/§3.5。核心约定：

- 视图至少有一个选区；空选区 = 光标。多光标 = 多个选区。
- `editor-edit` 对集合内**每个**选区算 `op`，同坐标系的 descs 一次原子施加、一步撤销；
  相邻选区产生重叠 desc 时先**合并成包络重算**（如 backspace 越界删除）。
- **选区集**有名字与 leader；`editor-put-selection-set` 安装、`editor-clear-selection-set`
  清除（收敛为单个 leader）。**何时清除由上层决定**。

### 3.7 编辑原语 editor-command

```racket
(editor-command ed op
  #:attrs      [attr-plan #f]                     ; (editor did (listof edit-desc) → (listof attr-desc))
  #:view       [vid (view-id (editor-focused-view ed))]
  #:selection  [selection #f]                     ; 默认该 view 的选区集
  #:trusted?   [trusted? #f]                      ; 跳 read-only 守卫
  #:reaction   [reaction 'none]                   ; 'none / 'map / 'leader
  #:record?    [record? 'default]                 ; 'default（跟随文档）/ #t / #f
  #:pre-point  [pre-point #f])                    ; 记账用的编辑前光标
;; → (values editor (or/c #f change-report))
```

| 参数 | 取值 | 语义 |
|---|---|---|
| `op` | `(editor did selection → (or/c #f edit-desc))` | 对每个选区算文本变更；`#f` = 该选区不变 |
| `#:attrs` | 计划函数 | 在文本 descs 夹紧后求值，坐标为「文本生效之后」；与文本合成**同一条 change** |
| `#:view` | vid | 目标视图（决定选区上下文、reaction、pre-point） |
| `#:selection` | 选区列表 | 覆盖默认选区集 |
| `#:trusted?` | bool | `#t` 跳过只读守卫 |
| `#:reaction` | `'none` / `'map` / `'leader` | 见下 |
| `#:record?` | `'default` / `#t` / `#f` | 是否记一步账本 |
| `#:pre-point` | point | 撤销回落位置 |

`reaction`：

| 值 | 行为 | 谁用 |
|---|---|---|
| `'none` | 字面不动，只把光标/视口夹回合法域 | 程序默认 |
| `'map` | 每个同文档视图各自把光标映射过这次编辑（不滚屏） | 程序显式 |
| `'leader` | 目标视图推进到插入后 + ensure；其余 free 映射 / follow 镜像 | 用户编辑 |

```racket
(editor-command-batch ed ch
  #:view #:trusted? #:reaction #:record? #:pre-point)   ; 直接施加现成 change
```

**薄封装**（只固定策略取值，不重复实现）：

| 名字 | 签名 | = |
|---|---|---|
| `editor-view-edit` | `(editor-view-edit ed vid op)` | `editor-command` + `#:view vid` + `'leader` + `'default` |
| `editor-edit` | `(editor-edit ed op)` | 焦点视图版 |
| `editor-document-edit-at` | `(editor-document-edit-at ed did p op #:reaction [reaction 'none] #:trusted? [trusted? #f] #:record? [record? 'default])` | did + 位置 + op |
| `editor-document-edit-at-batch` | `(editor-document-edit-at-batch ed did descs ...)` | did + 现成 descs 批 |
| `editor-document-apply-edits` | `(editor-document-apply-edits ed did descs #:record? [record? 'default])` | did + 文本批（`'none`） |
| `editor-document-apply-attrs` | `(editor-document-apply-attrs ed did attrs #:record? [record? 'default])` | did + 属性批（`'none`） |

```racket
;; 用户：焦点处插入，光标前进，可撤销
(editor-edit ed (edit-insert "x"))

;; 程序：文档 0 的 (1,0) 处插入，不动光标、不记账
(editor-document-edit-at ed 0 (point 1 0) (edit-insert "> ") #:reaction 'none #:record? #f)

;; 一条命令同时改文本 + 属性（把插入的 "X" 标只读）
(editor-command ed (edit-insert "X")
  #:selection (list (caret (point 0 1)))
  #:attrs (lambda (_ed _did texts)
            (for/list ([d (in-list texts)])
              (attr-set (edit-desc-start d) (edit-desc-after-position d) read-only-key #t)))
  #:reaction 'leader #:record? #t)
```

### 3.8 编辑动作（op 值）

| 名字 | 签名 | 语义 |
|---|---|---|
| `edit-insert` | `(edit-insert text)` | 用 `text` 替换每个选区 |
| `edit-insert-char` | `(edit-insert-char ch)` | 单字符 |
| `edit-newline` | `(edit-newline)` | 插入 `"\n"` |
| `edit-backspace` | `(edit-backspace)` | 删选区 / 光标前一字符 |
| `edit-delete` | `(edit-delete)` | 删选区 / 光标后一字符 |
| `edit-splice` | `(edit-splice start end text)` | 逃生门：显式区间替换 |

`op : editor did selection → (or/c #f edit-desc)`。低层对应 `buffer-op-*`
（`buffer selection → edit-desc`）。

### 3.9 用户命令（导航 / 撤销 / 焦点）

| 名字 | 签名 | 语义 |
|---|---|---|
| `editor-view-left` / `editor-left` | `(editor-view-left ed vid)` | 左移（每个选区各走一步） |
| `editor-view-right` / `editor-right` | | 右移 |
| `editor-view-up` / `editor-up` | | 视觉行上移 |
| `editor-view-down` / `editor-down` | | 视觉行下移 |
| `editor-view-home` / `editor-home` | | 行首 |
| `editor-view-end` / `editor-end` | | 行尾 |
| `editor-view-goto` / `editor-goto` | `(editor-view-goto ed vid p)` | 跳到点并 ensure |
| `editor-view-scroll` / `editor-scroll` | `(editor-view-scroll ed vid delta)` | 滚视觉行 |
| `editor-view-follow` / `editor-follow` | `(editor-view-follow ed vid)` | 以该视图 window 为准镜像 follow / link 成员 |
| `editor-view-undo` / `editor-undo` | `(editor-view-undo ed vid)` | 撤销；返回 `(values editor report)` |
| `editor-view-redo` / `editor-redo` | | 重做 |

`editor-document-can-undo?` / `-can-redo?` / `-undo-depth` / `-redo-depth`：
账本查询（did 缺省 = 焦点）。

### 3.10 属性

| 名字 | 签名 | 语义 |
|---|---|---|
| `editor-document-attrs-at` | `(editor-document-attrs-at ed did p)` | 某点全部属性 hash |
| `editor-document-attrs-runs` | `(editor-document-attrs-runs ed did line)` | 某行属性段 |
| `editor-document-attrs-key-runs` | `(editor-document-attrs-key-runs ed did line key)` | 某行某 key 段 |
| `editor-document-apply-attrs` | `(editor-document-apply-attrs ed did attrs #:record? 'default)` | 批量写属性 |
| `editor-document-put-attr` | `(editor-document-put-attr ed did key line c0 c1 val #:record? 'default)` | 单段 set |
| `editor-document-remove-attr` | `(editor-document-remove-attr ed did key line c0 c1 #:record? 'default)` | 单段 remove |
| `editor-document-replace-attr` | `(editor-document-replace-attr ed did key spans #:lines [l0 0] [l1 末行] #:record? 'default)` | **替换**某 key 在一段行范围（`spans` = `(list (list line c0 c1 val))`；单行 = `#:lines L L`） |
| `read-only-key` / `attr-read-only?` | | core 解释的保留 key |

```racket
;; 单段：把文档 0 第 0 行 [0,3) 标成只读（走 change 漏斗，可撤销）
(editor-document-put-attr ed 0 read-only-key 0 0 3 #t)

;; 替换式：整屏重算某来源的标注（旧值自动消失；读口输出可直接写回）
(editor-document-replace-attr ed 0 'lsp-token
  '((0 0 5 face) (1 0 3 warn)))
```

### 3.11 历史策略

| 名字 | 签名 | 语义 |
|---|---|---|
| `editor-document-history-enabled?` | `(editor-document-history-enabled? ed [did])` | 该文档默认是否记账 |
| `editor-set-history-enabled` | `(editor-set-history-enabled ed on?)` | 切焦点视图所属文档 |
| `editor-view-set-history-enabled` | `(editor-view-set-history-enabled ed vid on?)` | 切某视图所属文档 |
| `editor-document-clear-history` | `(editor-document-clear-history ed [did])` | 清账本 |
| `editor-view-clear-history` | `(editor-view-clear-history ed vid)` | 清账本 |

派生 / 只读文档用 `#:history? #f`。命令的 `#:record?` 覆盖文档策略。

### 3.12 视口同步 link

`link` 是视图上的符号名（`#f` = 不参与）。同 link 的视图**可跨文档**，窗口视口按
`mirror-window` 同步；不参与文档内容耦合。

| 名字 | 签名 | 语义 |
|---|---|---|
| `editor-view-set-link` | `(editor-view-set-link ed vid link #:align? [align? #t] #:from [from #f])` | 设某视图链接（解链用 `#f`） |
| `editor-set-link` | `(editor-set-link ed link #:align? [align? #t] #:from [from #f])` | 焦点糖 |
| `editor-link-views` | `(editor-link-views ed name vids #:align? [align? #t] #:from [from #f])` | 组替换语义 |
| `editor-view-unlink` | `(editor-view-unlink ed vid)` | 退出链接 |
| `editor-view-link` / `editor-link` / `editor-links` | | 读链接名 |

- `#:align? #t`（默认）：设链后立即对齐；基准 = `#:from`（若在组内）→ 焦点视图
  （若在组内）→ 组内第一个成员。
- `link` 类型受 `check-link` 校验（符号 / `#f`）。

```racket
;; 两个视图（可跨文档）链接为 "pair"，并对齐
(editor-link-views ed 'pair (list (editor-document-view ed 0) (editor-document-view ed 1)))
```

### 3.13 行号栏

| 名字 | 签名 | 语义 |
|---|---|---|
| `window-line-numbers?` / `window-set-line-numbers` | `(window-set-line-numbers w on?)` | 开关（视图状态） |
| `window-gutter-width` | `(window-gutter-width w)` | 栏宽 = 当前视口行号上界的位数 + 1（不超过总宽-1） |
| `window-content-width` | `(window-content-width w)` | 正文宽 = 总宽 − 栏宽 |
| `editor-view-set-line-numbers` / `editor-set-line-numbers` | `(editor-view-set-line-numbers ed vid on?)` | 平台开关 |
| `editor-view-line-numbers?` / `editor-line-numbers?` | | 读 |
| `editor-open` / `editor-open-document` / `editor-add-view` 的 `#:line-numbers?` | | 开文档即开 |

行号是**视图装饰**：`project` 把 `'line-number` face 的 run 前置到 `row-runs`，并把
光标/选区列右移栏宽（屏幕列 = 正文列 + 栏宽）；`layout` 一律用正文宽。wrap 只在 buffer
行首段显示行号；点 gutter 落到行首。

### 3.14 投影

`face-provider : editor did line → (listof (list start end face))`。`face` 是**应用自定义**的语义值
（`any/c`）：provider 返回什么，`run.face` 就是什么；未覆盖段为 `#f`；`attrs-provider key` 只是把该 key 的 **value 原样**当 face。

| 名字 | 签名 | 语义 |
|---|---|---|
| `editor->screen` | `(editor->screen ed [face-provider empty-face-provider])` | 焦点视图 → 帧 |
| `editor-view->screen` | `(editor-view->screen ed vid [face-provider empty-face-provider])` | 某视图 → 帧 |
| `editor-point->screen` / `editor-view-point->screen` | `(editor-point->screen ed)` | 光标 → 屏幕坐标 |
| `editor-screen->point` / `editor-view-screen->point` | `(editor-screen->point ed row col)` | 屏幕 → 位置 |
| `empty-face-provider` | | 缺省 provider（空） |
| `attrs-provider` | `(attrs-provider key)` | 把属性某 key 物化成 provider |

```racket
;; 关键字高亮（派生，不存）
(define (syntax-face ed did line)
  (for/list ([m (regexp-match-positions* #rx"\\bdefine\\b" (editor-document-line-ref ed did line))])
    (list (car m) (cdr m) (hash 'face 'keyword))))
(editor->screen ed syntax-face)

;; 或把属性 key 直接当 face 源
(editor->screen ed (attrs-provider 'face))
```

### 3.15 change-report

`(struct change-report (texts attrs))` —— 编辑命令的第二个返回值。

| 名字 | 签名 | 语义 |
|---|---|---|
| `change-report?` | `(change-report? v)` | 谓词 |
| `change-report-texts` | `(change-report-texts r)` | 生效文本 descs（**施加顺序**，坐标逐条推进） |
| `change-report-attrs` | `(change-report-attrs r)` | 生效属性 descs（施加顺序） |
| `change-report-first-line` / `-last-line` | `(change-report-first-line r)` | 受影响行区间（texts ∪ attrs 投影） |

`#f` 报告 = 什么都没发生（空 change / 被守卫拒）。前端可据此驱动增量重算、诊断刷新或
**跨文档内容同步**（把 texts+attrs 原样施加到别的文档）。

---

## 4. 配方

### 4.1 多光标：对每个选区替换

```racket
(define ed1 (editor-set-selections ed
              (list (selection (point 0 0) (point 0 3))
                    (selection (point 0 8) (point 0 11)))))
(define-values (ed2 _) (editor-edit ed1 (edit-insert "XX")))   ; 一次替换两处、一步撤销
```

### 4.2 Shift 扩选

```racket
(editor-map-primary ed
  (lambda (s) (selection-with-head s (editor-point-right ed (selection-head s)))))
```

### 4.3 插入 + 标只读（一条命令、一步撤销）

见 §3.7 示例。

### 4.4 跨文档内容同步（应用层）

```racket
(define (sync ed did-target report)
  (if (not report) ed
      (let-values ([(ed* _)
                    (editor-command-batch ed
                      (change (change-report-texts report) (change-report-attrs report))
                      #:view (editor-document-view ed did-target)
                      #:trusted? #t #:record? 'default)])
        ed*)))
```

### 4.5 跨文档视口同步

```racket
(editor-link-views ed 'pair (list vA vB))   ; 滚动/导航任一，另一个按行固定/列比例跟随
```

### 4.6 拼屏渲染

```racket
(define left  (editor-view->screen ed 0 face-provider))
(define right (editor-view->screen ed mvid face-provider))
(screen-compose rows cols
                (list (list 'left 0 0 left) (list 'right left-w 0 right))
                'left)                       ; 只透出活动窗格的光标
```

### 4.7 编辑到指定文档并保持历史

```racket
(editor-document-edit-at ed did p op #:reaction 'map #:record? #t)  ; 记一步；'map 让光标跟随
```

---

## 5. 类型、不变量、违约

**核心类型**（均不可变）：`point`、`selection`、`selection-set`、`edit-desc`、`attr-desc`、
`change`、`attrs`、`buffer`、`document`、`window`、`vrow`、`run`、`cursor`、`region`、`screen`、
`change-result`、`change-report`、各类事件。

**不变量**：

- `point.col` 是**字符索引**；`window.left-col` / `vrow` 是**显示列**；偏移是字符偏移。
  三套坐标只经 `index->column` / `column->index` 换算。
- `selection-set.selections` 非空、已规范化；leader 按下标给出。
- `attr-desc` 同行、半开、零宽 = no-op；同一 key 的区间不重叠。
- 任一视图的 `window.document` 必是某个 `document-entry` 的 document。
- `buffer` / `window` / `screen` 不透出 struct 构造器，只给谓词、读口与具名构造（规范化）。

**违约**（判据：是否有「最近合法解释」）：

- 有唯一合法解释 → **夹紧/归一**：越界位置夹到合法域；零宽 `attr-desc` = no-op；
  反向 selection 用 `selection-range` 取正向。
- 没有合法解释 → **报错**：反向 edit 区间、跨行属性区间、未知 `sync`/`op`、非法 `link`、
  不存在的 vid/did、`editor-view-put-window` 文档不符。

**只读守卫**：默认开；`#:trusted? #t`（`document-apply-change` / `editor-command*`）跳。
没有全局开关。

---

## 6. 范围

本手册只覆盖 `core/`：低层公开面 `core/api.rkt` 与 editor 平台 `core/editor.rkt`。
窗口管理（layout / panel / shell）、文件树 / 状态栏组件、终端后端、示例应用都不在本仓库，
均由使用方在 core 之上（L6）自行构建，只允许使用上述两个入口。
