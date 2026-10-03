# core 设计

后端无关的编辑器核心：纯值代数 + 视图/文档模型 + editor 聚合。
寻址按**操作对象**定键，一帧渲染输出后端无关的 `screen`。

---

## 0. 数据模型

```
editor          = { documents : (listof document-entry)     ; 不可变骨架
                    views     : (listof view)
                    next-document, next-view                ; id 分配器
                    clipboard-box }                          ; box(#f | clipboard)

document-entry  = { id }                       ⊕ { name-box, history-box }
view            = { id, did }                   ⊕ { viewport-box, selections-box,
                                                     sync-box, link-box }
history         = { past, current, future, limit, enabled? }
snapshot        = { document, selections, who, merge-tag }

--- 文本层值 ---
document        = { text : track }              ⊕ { highlight-box, readonly-box }
                  ;; 不可变文本是版本身份；属性是就地可变覆盖层
viewport        = { top-line, top-segment, left-column, width, height, mode, line-numbers? }
screen          = { width, height, rows : (vectorof (listof run)), cursors, regions }
```

两条贯穿性不变量：

1. **身份不可变，其余全进 box；box 引用只 `set-box!` 内容，从不替换。**
   → 只有「增/删文档、增/删视图」产新 `editor`；其余全是就地改。
2. **`document-entry` 不另存 document 值**：当前文档 = `history.current.document`（单一事实源）。

---

## 1. 层与依赖方向

```
L0 text/base   track · line · point · selection · range · change · edit · width
                  纯值代数；不认识 editor / view / 屏幕
L1 text        document（文本值 + 属性 box）
               command （多光标编辑：选区集 → 新 document + selections + changes）
L2 view/base   layout（vrow：buffer 行 ↔ 视觉行）· viewport（纯显示，不含光标）· screen
L3 view        project（文本通道）· overlay（光标/选区通道）· render（合成）
               patch（screen 差量）· compose（多 pane 合成）
L4 editor      state · history · command · query · attributes · render · layout · sync · change
```

依赖方向：

```
L0 ◀── L1 ◀────────────┐
L0 ◀── L2 ◀── L3 ◀─────┴── L4
```

- **只有 L4 知道「editor」这个聚合**；L1 只知道 document，L2/L3 只知道 viewport/screen。
- L3 的 project/overlay 是**平行两条通道**（文本 vs 视图），在 render 合成。
- L4 内部：`state` 造/删，`command` 就地改，`query` 只读，`attributes` 属性覆盖层，
  `history` 哑栈，`view`/`sync` 传播，`layout`/`render` 出屏。

---

## 2. 核心流

**写（输入）**

```
host 原始事件
  └─▶ 选 vid（宿主决定焦点）
        └─▶ editor-view-*!  （就地改 box）
              ├─ 编辑类  : text/command 算 (新 doc, selections, changes)
              │            └─ editor-view-install! → step
              │                 └─ editor-document-history-record!（记步）
              ├─ 导航/视口: view-ensure!（滚进光标）+ sync 传播
              ├─ 作者属性: document 属性 box 就地改（出带，不碰 history）
              └─ 结构类  : state 增/删 → 新 editor（返回）
```

**读（query）**

```
editor-view-* ed vid       视图级：光标 / 选区 / 视口 / 屏幕坐标 / 渲染
editor-document-* ed did   文档级：文本 / 名称 / 属性 / history
```

**出（渲染）**

```
editor-set-layout!  ── 把 rectangle 的 w/h 落到各 view（ensure/滚动/鼠标换算要用）
editor-render-layout ed rectangles active w h
   └─ 每 rectangle: render(document, viewport, selections)
        ├─ viewport-vrows             (L2)
        ├─ project(document × vrows)  → 文本 run（含行号栏）   (L3)
        └─ overlay(selections × vrows) → cursors / regions     (L3)
        └─ screen
   └─ compose: panes→screen（多窗格）
```

---

## 3. API 寻址网格

**一切按「操作对象」定键**：

```
                        视图态（选区 / 视口 / 光标）        文档态（文本 / 属性 / history / 名称）
按 vid   editor-view-*        ✔                                 糖（→ did）
按 did   editor-document-*     —                                 ✔
按句柄   editor-document-handle-*  —                             异步/版本敏感写
全局     editor-*             构造 · 增删 · 剪贴板 · 布局 · 渲染
```

**文档级读**

```racket
editor-document-string           ed did → string
editor-document-highlight-at     ed did line col
editor-document-readonly-at?     ed did line col
editor-document-highlight-row    ed did line
editor-document-readonly-row     ed did line
editor-document-highlight-range? ed did l0 c0 l1 c1
editor-document-readonly-range?  ed did l0 c0 l1 c1
editor-document-editable?        ed did l0 c0 l1 c1
editor-document-change-text      ed did ch → string
editor-document-handle           ed did → document
editor-document-view-list        ed did → (listof vid)
```

**属性写**

```racket
;; 视图级：作用于选区（selection）
editor-view-highlight!            ed vid face
editor-view-readonly!             ed vid flag
editor-view-highlight-selections! ed vid face
editor-view-readonly-selections!  ed vid flag

;; 文档级：显式 range / cell / line / batch
editor-document-highlight-range!       ed did r face
editor-document-readonly-range!        ed did r flag
editor-document-highlight-cell!        ed did line col face
editor-document-readonly-cell!         ed did line col flag
editor-document-highlight-line!        ed did line face
editor-document-readonly-line!         ed did line flag
editor-document-highlight-batch!       ed did fills
editor-document-readonly-batch!        ed did fills
editor-document-highlight-range-batch! ed did runs
editor-document-readonly-range-batch!  ed did runs
editor-document-set-highlight!         ed did track
editor-document-set-readonly!          ed did track

;; 句柄级：版本敏感（异步）
editor-document-handle-set-highlight!  doc track
editor-document-handle-set-readonly!   doc track
editor-document-handle-highlight-batch!       doc fills
editor-document-handle-readonly-batch!        doc fills
editor-document-handle-highlight-range-batch! doc runs
editor-document-handle-readonly-range-batch!  doc runs
```

**内容写**

```racket
editor-view-edit!                  op 级 + 记一步 → (values changes ok?)
editor-view-assign!                值级 + 封口（不记步）
editor-view-apply-text-if-version! 值级 CAS + 记一步 → applied?
```

---

## 4. 返回值约定

> **`*!` = 就地改。返回 `void`，除非该操作有「结果」或「失败状态」：**
> - 结果 + 状态 → `(values 结果 ok?)`（编辑：`(values changes ok?)`）
> - 只有状态（被只读挡 / 无可撤销 / 版本不匹配）→ `boolean`
> - 只有结果 → 结果（渲染出 `screen`）
> - 再无别的 → `void`

---

## 5. 入口与逃逸口

入口 `editor.rkt` 只留 **操作（`editor-*`）+ 值词汇（裸名）**。

- 值词汇由入口直接转发：`point` / `selection` / `range` / `change` / `document` /
  `screen` / `patch` / `compose`。
- 只 require 入口即可：构造 `point`/`selection`/`range` 调 API、用
  `document-open` + 属性填构造 payload、消费 `screen`/`piece`。
- `except-out` 掉的内部件：
  - **editor 骨架字段**：`editor`（构造器，留 `editor?`）· `editor-documents/-views/-next-document/-next-view/-clipboard-box`
  - **身份 struct**：`document-entry` · `view` · `entry-immutable/-mutable` · `view-immutable/-mutable` + accessors · `make-document-entry/-view`
  - **内部查找**：`editor-document-entry` · `editor-view-ref` · `editor-view-document` · `editor-document-history` · `document-id-of` · `first-view-of-document`
  - **history 哑栈**：`history`/`snapshot` + 全部 `history-*`/`default-history-limit`
  - **属性裸原子/视图句柄**：`editor-view-document-handle` · `editor-view-highlight-atom` · `editor-view-readonly-atom`
  - **document 内部**：表示（`-immutable/-mutable/-im/-mut`）· 裸写口（`document-set-*!`/`-*-atom`）·
    编辑机制（`document-edit-*`/`-insert/-delete/-replace/-paste*`）· `document-text`（返回 track）·
    `document-highlight`/`document-readonly`（返回属性轨）· `document-aligned?`
  - **point 字符导航**：`point-left/right/home/end`（吃 track）
- 保留的公开值：`editor?` · `editor-document-handle`（异步句柄）· `editor-clipboard` ·
  `document?`/`document-open`/`document->string`/`document-*-fill(-batch)` · `clipboard` ·
  `point`/`selection`/`range`/`change` · `screen`/`piece`/`pane`/`rectangle`。
- `editor-view-document` 只在内部用；host 用 `editor-document-handle ed (editor-view-document-id ed vid)`。
- 备注：`except-out` 不除 `struct:` **语法绑定**（`struct:editor`/`struct:view`/`struct:document-entry` …）。
  这些是不可作值的语法名（accessor 已除，`match` 结构模式也用不了），不构成逃逸口。

---

## 6. 命名约定

**函数 / 类型 / accessor / 字段 = 全称；参数 / 局部变量 = 短名。**

- `ids` → `id-list` · `views` → `view-list`
- `col` → `column` · `pos` → `position` · `seg` → `segment`
- `rect` → `rectangle`（连同 accessors / 字段）
- `pos<? /=? / <=?` → `position<? / =? / <=?`
- 复合：`editor-view-{point,left}-column` · `editor-view-set-left-column!` ·
  `editor-view-top-segment` · `editor-view-{point,screen-position}->…`

**不能展开的参数**（Racket 单命名空间，会与 struct/accessor 名相撞）：

| 参数 | 想叫 | 与何相撞 |
|---|---|---|
| `ed` | `editor` | struct `editor`（`struct-copy` 会炸） |
| `doc` | `document` | struct `document` |
| `sels` | `selections` | struct `selections` |
| `chg` | `change` | struct `change` |
| `vp` | `viewport` | struct `viewport` |
| `vid` | `view-id` | accessor `view-id` |

struct **字段名**同时决定自动生成的 accessor 名（`(struct point (line column))` → `point-column`），
字段名与局部变量名是同一个 token，所以字段位置（struct 字段表 / `struct-copy` 的 `[field …]`）
保留全称，其余同名 token 用短名。

---

## 7. 属性与 history

属性（高亮 / 只读）是 **document 级、出带（out-of-band）** 的可变覆盖层：

- **不记 history**：属性写改 document 里的 box，不创建步、不改 `history.current`。
- undo/redo 只交换**文本文档值**，因此只还原文本编辑，不还原属性。
- 因为 document 是 box 的持有者，同一 document 值的所有快照都看到同一份最新属性。
- 异步写回（LSP 高亮 / 诊断）直接改 document 句柄，O(1)，不经过 history。
