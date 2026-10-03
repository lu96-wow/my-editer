# core 重建：设计审计与目标 API

> 目标：**功能与行为完全不变，只重排 API**（寻址一致、操作对象正确、砍掉转发层）。
> 本文先过一遍现有 core 的数据模型 / 层 / 核心流，再列问题，最后给目标寻址网格。

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
viewport        = { top-line, top-seg, left-col, width, height, mode, line-numbers? }
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
- L3 的 project/overlay 是**平行两条通道**（文本 vs 视图），在 render 合成——这是渲染层的核心切分。
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
              │            └─ editor-view-set! → step
              │                 └─ editor-document-history-record!（记步）
              ├─ 导航/视口: view-ensure!（滚进光标）+ sync 传播
              ├─ 作者属性: document 属性 box 就地改 + history-set-current
              └─ 结构类  : state 增/删 → 新 editor（返回）
```

**读（query）**

```
editor-view-* ed vid     视图级：光标 / 选区 / 视口 / 屏幕坐标 / 渲染
editor-document-* ed did  文档级：文本 / 名称 / 属性 / history
```

**出（渲染）**

```
editor-set-layout!  ── 把 rect 的 w/h 落到各 view（ensure/滚动/鼠标换算要用）
editor-render-layout ed rects active w h
   └─ 每 rect: render(document, viewport, selections)
        ├─ viewport-vrows        (L2)
        ├─ project(document × vrows)  → 文本 run（含行号栏）   (L3)
        └─ overlay(selections × vrows) → cursors / regions     (L3)
        └─ screen
   └─ compose: panes→screen（多窗格）
```

---

## 3. API 现状：寻址网格（问题现场）

| 寻址键 | 命名空间 | 覆盖 |
|---|---|---|
| 全局（无 id） | `editor-*` | blank / open / documents / views / clipboard / layout / render / 结构增删 |
| `vid` | `editor-view-*` | 光标 / 选区 / 视口 / sync / render ✔ · **属性读 ✘** · **属性写（选区版 ✔ / 坐标版 ✘）** · **文本读 ✘** |
| `did` | `editor-document-*` | 名称 / history ✔ · 属性写 ✔ · **属性读 ✘** · **文本读 ✘** |
| 句柄 | `editor-document-handle-*` | 属性写（版本敏感）✔ |

---

## 4. 问题清单

### A. 寻址不对称（读只有 vid，写已有 did）

| # | 现状 | 问题 |
|---|---|---|
| A1 | `editor-view-string ed vid` | 文档文本读，只有 vid 版；**无 `editor-document-string ed did`** |
| A2 | `editor-view-highlight-at` / `-readonly-at?` / `-highlight-row` / `-readonly-row` / `-highlight-range?` / `-readonly-range?` / `-editable?` | 属性是**文档级**，读只有 vid 版；写已有 did 版 |
| A3 | `editor-view-document-handle ed vid` | 只有 vid→handle；**无 `editor-document-handle ed did`** |
| A4 | — | **无 `editor-document-views ed did`**（did → 它的 vids） |
| A5 | `editor-view-document-name` + `editor-document-name` | 前者是后者的糖（可保留，但要成对：见 A1） |

### B. 操作对象错（挂在错的键上）

| # | 现状 | 应属 |
|---|---|---|
| B1 | `editor-view-highlight-range!` / `-readonly-range!` / `-cell!` / `-line!` / `-batch!` / `-range-batch!` | **显式坐标**写 → 文档级（`editor-document-*`），不是 view |
| B2 | `editor-view-highlight!` / `-readonly!` / `-highlight-selections!` / `-readonly-selections!` | **作用选区** → 视图级 ✔（正确） |
| B3 | `editor-view-editable?` | 文档谓词 → did |
| B4 | `editor-view-change-text ed vid ch` | change 是文档级 → did |
| B5 | `editor-view-document-handle` | `editor-view-document` 的**纯重复** |

> B1/B2 是同一族（属性写）里两类操作对象混用同一前缀的典型：全叫 `editor-view-*`，
> 但一半吃「选区」（视图态），一半吃「坐标」（文档态）。这是本次重建最核心的切割点。

### C. 冗余 / 暴露 / 不合适

| # | 现状 | 问题 |
|---|---|---|
| C1 | `editor-document-handle-*` 6 个 | 与 `editor-document-*`（did）语义只差「版本 vs 当前」，但**返回约定不同**（handle 返回 doc，did 返回 void） |
| C2 | `editor-view-ref` / `editor-document-entry` / `editor-view-document` | 暴露内部结构（view / document-entry / 文本层 document），是逃逸口，需明确标为低层 |
| C3 | `editor-view-highlight-atom` / `-readonly-atom` | 暴露裸 box |
| C4 | `editor-view-set!` 返回 `step` | 暴露内部原语结构；且 `editor-view-assign!` = `set!` + seal，两者重复 |
| C5 | `change` / `range` 词汇表 | 既有裸名又有 `editor-change` / `editor-range`，双名 |
| C6 | 属性写函数共 **26 个** | 14 view + 6 did + 6 handle，成对膨胀 |
| C7 | 返回约定 | 编辑 → `(values changes ok?)`；undo/redo → `ok?`；CAS → `applied?`；其余 → `void` |
| C8 | `editor-view-*-ignore-readonly!` | 程序编辑成对膨胀（与用户编辑成对，可接受，但值得统一） |

---

## 5. 目标 API（寻址网格）

**一切按「操作对象」定键**：

```
                        视图态（选区 / 视口 / 光标）        文档态（文本 / 属性 / history / 名称）
按 vid   editor-view-*        ✔                                 糖（→ did）
按 did   editor-document-*     —                                 ✔
按句柄   editor-document-handle-*  —                             异步/版本敏感写
全局     editor-*             构造 · 增删 · 剪贴板 · 布局 · 渲染
```

### 目标清单（改动，行为不变）

**文档级读（补 did，vid 变糖）**
```racket
editor-document-string           ed did            ; A1
editor-document-highlight-at     ed did line col   ; A2
editor-document-readonly-at?     ed did line col
editor-document-highlight-row    ed did line
editor-document-readonly-row     ed did line
editor-document-highlight-range? ed did l0 c0 l1 c1
editor-document-readonly-range?  ed did l0 c0 l1 c1
editor-document-editable?        ed did l0 c0 l1 c1
editor-document-change-text      ed did ch         ; B4
editor-document-handle           ed did → document ; A3
editor-document-views            ed did → (listof vid) ; A4
```

**属性写：按操作对象切成两族**
```racket
;; 视图级：作用于选区（selection）
editor-view-highlight!            ed vid face
editor-view-readonly!             ed vid flag
editor-view-highlight-selections! ed vid face
editor-view-readonly-selections!  ed vid flag

;; 文档级：显式 range / cell / line / batch（迁到 did）
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
… （6 个，保留）
```

**删除纯转发 / 重复**
```racket
editor-view-document-handle        ; 删（= editor-view-document）        B5
editor-view-string                 ; 保留为糖，或删
editor-view-highlight-at / -readonly-at? / … ; 保留为糖（→ did 版）
```

---

## 5.1 重建进展（core-rebuild/）

已落地（`core-rebuild-test` 1530 全绿）：

**A 组（文档级读补 did，vid 变糖）**
- 新增：`editor-document-string` · `-highlight-at` · `-readonly-at?` · `-highlight-row`
  · `-readonly-row` · `-highlight-range?` · `-readonly-range?` · `-editable?`
  · `-change-text` · `-handle` · `-views`
- `editor-document-handle` 落在 state.rkt（对称于 `editor-view-document-handle`）

**B 组（属性写：只有 did，vid 只管选区）**
- `editor-document-*`（did）= 属性写唯一入口：`set` / `batch` / `range-batch` / `range` /
  `cell` / `line`；**纯 box 写，不碰 history**。
- `editor-view-*`（vid）= 只有 4 个「**作用选区**」命令（`highlight!` / `readonly!` /
  `highlight-selections!` / `readonly-selections!`）：读选区算区间 → 转发 did 版。
- **删掉了 10 个坐标版 vid 糖**（`-range!/-cell!/-line!/-batch!/-range-batch!`）。
  文档对象就用 did：调用方拿 `editor-view-document-id` 把 vid 换成 did，再调 did 函数。
- 删掉 `editor-view-author-edit!` 一族。

属性写函数数：**22**（4 vid + 12 did + 6 handle），从原来的 26/32 降下来。

**C 组（部分）：内容写原语收进去**
- `editor-view-set!` → 重命名 **`editor-view-install!`**（内部件）。
- `step` / `step-*` / `editor-view-install!` / `editor-document-history-record!`
  从 **入口 `editor.rkt` except-out**（模块仍 provide，供内部/测试用）——
  与 core 已有的「裸 box setter 只在模块内、入口不导出」同一模式。
- 公开内容写面只剩三个自包含调用：
  ```racket
  editor-view-edit!                  op 级 + 记一步 → (values changes ok?)
  editor-view-assign!                值级 + 封口（不记步）
  editor-view-apply-text-if-version! 值级 CAS + 记一步 → applied?
  ```
- 值级 + 记步（无 CAS）可用 `editor-view-edit!` 包一个 op 表达。行为不变。

**C 组（部分）：词汇表按裸名导出（单名）**
- 删掉入口的 `rename-in`；`change` / `range` 及其访问器按**裸名**导出，与已有的裸名 `rect` 一致。
- 规则明确为：**操作 = `editor-*`；值词汇表 = 裸名**。
- 仅 `view-change-text` 一个操作仍改名为 `editor-view-change-text`。
- ❗ 还没做：`point` / `selection` / `screen` 及其词汇也**未从入口导出**，
  宿主必须伸手到低层。这是同一个原理的下一步（入口应导出其 API 用到/产出的值词汇表）。

**C 组（部分）：词汇表导出（入口自足）**
- `editor.rkt` 直接转发值层（裸名）：
  ```racket
  text/base/point.rkt   text/base/selection.rkt   text/base/range.rkt
  text/base/change.rkt  text/document.rkt
  view/base/screen.rkt  view/patch.rkt            view/compose.rkt
  ```
- `editor/change.rkt` 不再当词汇转发器，只留 `editor-document-change-text` + `view-change-text`。
- 补全 range 词汇（`range-of` / `range-empty?` / `range-normalize` / `range=?`）。
- 现在只 require 入口就能：构造 `point`/`selection`/`range` 调 API、用 `document-open`+属性填
  构造 payload、消费 `screen`/`piece`。
- ⚠️ 代价（留给 C1）：`text/document.rkt` 是整模块转发，所以 `document-set-highlight!` /
  `document-*-atom` 这类裸 box 写口现在也能从入口拿到。C1（逃逸口）时再 `except-out` 收窄。

**C 组（部分）：返回约定统一**

一条规则（公开 147 个 `editor-*`，除逃逸口）：

> **`*!` = 就地改。返回 `void`，除非该操作有「结果」或「失败状态」：**
> - 结果 + 状态 → `(values 结果 ok?)`（编辑：`(values changes ok?)`）
> - 只有状态（被只读挡 / 无可撤销 / 版本不匹配）→ `boolean`
> - 只有结果 → 结果（渲染出 `screen`）
> - 再无别的 → `void`

修掉了三个例外：
- `editor-set-layout!` → `void`（原返回 editor，就地无意义）
- `editor-render-layout*!` → `screen`（原 `(values editor screen)`，editor 就地未变 → 冗余）
- `editor-document-handle-*`（6）→ `void`（原返回 document，实测调用点全部丢弃）

**C 组（部分）：逃逸口收窄（入口只留「操作 + 值词汇」）**

按能力核对后的结论：唯一真正的**能力缺口是枚举**（原本只能靠返回内部 struct 的
`editor-documents`/`editor-views`）；其余逃逸口都是多余。

- 新增公开枚举：`editor-document-ids` · `editor-view-ids`（内部走 `editor-documents`/`editor-views`）。
- 入口 `except-out` 掉：
  - **editor 骨架字段**：`editor`（构造器，留 `editor?`）· `editor-documents/-views/-next-document/-next-view/-clipboard-box`
  - **身份 struct**：`document-entry` · `view` · `entry-immutable/-mutable` · `view-immutable/-mutable` + 其 accessors · `make-document-entry/-view`
  - **内部查找**：`editor-document-entry` · `editor-view-ref` · `editor-view-document` · `editor-document-history` · `document-id-of` · `first-view-of-document`
  - **history 哑栈**：`history`/`snapshot` + 全部 `history-*`/`default-history-limit`
  - **属性裸原子/视图句柄**：`editor-view-document-handle` · `editor-view-highlight-atom` · `editor-view-readonly-atom`
  - **document 内部**：表示（`-immutable/-mutable/-im/-mut`）· 裸写口（`document-set-*!`/`-*-atom`）·
    编辑机制（`document-edit-*`/`-insert/-delete/-replace/-paste*`）· `document-text`（返回 track）· `document-aligned?`
  - **point 字符导航**：`point-left/right/home/end`（吃 track）
- 保留的公开值：`editor?` · `editor-document-handle`（异步句柄）· `editor-clipboard` ·
  `document?`/`document-open`/`document->string`/`document-*-fill(-batch)` · `clipboard` · `point`/`selection`/`range`/`change` · `screen`/`piece`/`pane`/`rect`。
- 决定：`editor-view-document` 收掉（统一 `editor-document-handle ed (editor-view-document-id ed vid)`）；
  文本层值编辑（`document-insert/…`）收掉（编辑是 editor 的事，构造值才是 document 的事）。

入口现在只剩：**操作（`editor-*`）+ 值词汇（裸名）**。测试 1529 全绿。

**命名：全称（反缩写）**

缩写一律展开（32 文件，440/440）：
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

→ 规则：**函数 / 类型 / accessor = 全称；字段名 = 全称；参数 / 局部变量 = 短名**。

注意：struct **字段名**会决定自动生成的 accessor 名（`(struct point (line column))` → `point-column`），
而字段名和局部变量名在源码里是**同一个字符串**（同一 token）。所以改字段时不能一刀切：
- 字段位置（struct 字段表 / `struct-copy` 的 `[field …]`）→ 保留全称；
- 其余同名 token（参数、`let`、局部）→ 回退短名（`column`→`col`、`segment`→`seg`、`position`→`pos`、`operation`→`op`）。

### 关键决定：属性写不碰 history（以前的 who 标记是 artifact）

旧实现让属性写更新 `current` 的 `who=vid`，于是 redo 会还原到「发起那次属性写的视图」。
这是重新用 `author-edit!`（为**内容**编辑而设、会替换 document）带来的副作用：属性写在原地改 box，
`current.document` 本来就是同一个对象，`history-set-current` 改的只有 `who/selections`，对属性本身无作用。

**决定：属性写 = 文档级、出带（out-of-band），不创建步、不改 current**。实测差异（cross-view）：

```
OLD (标 who):  redo 后 vid0=(0,0)  vid1=(0,2)   ; redo 被属性写“劫持”到 vid1
NEW (did-only): redo 后 vid0=(0,1)  vid1=(0,2)   ; redo 还原到**文本步**发起视图
```

NEW 才是 undo/redo 应有的语义（还原文本编辑的视图）。这改了一处被测试钉住的行为
（`core-rebuild-test/editor/command.rkt` 的 cross-view 块），已按新语义更新。

## 6. 重建原则

1. **键 = 操作对象**：选区/视口 → vid；文本/属性/名称/history → did；版本敏感写 → handle。
2. **无纯转发层**：`editor-view-*-handle`、`editor-view-*-at`（vid 版）要么删，要么是明确的一行糖且成对齐全。
3. **返回约定统一**：写操作返回 `void`（需要结果的显式查询）；编辑返回 `(values changes ok?)` 是特例，单独文档化。
4. **逃逸口集中**：`editor-view-ref` / `editor-document-entry` / `editor-view-document` / `*-atom` 放到一个明确的 `low-level` 区，不与主 API 混排。
5. **功能不变**：所有改动是「同一实现挂到正确的键」；测试作为回归网（core 1530 + lab 37 + lab1 28）。
