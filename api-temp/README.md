# api-temp —— core API 用法演示

分两层讲，**互不混在一个文件里**：

- `api/` —— **底层原理**：只讲 `core/api.rkt`（低层公开面）+ 必要的子模块。
  这是「一个 document 的一个 viewport」的机制。
- `editor/` —— **最终 API**：只讲 `core/editor.rkt` 的 `editor-*`。
  这是应用真正会用的那一层（把底层拼成「可编辑的编辑器」）。

```
api-temp/
├── api/
│   ├── 1-edit.rkt    point / selection / selection-set / edit-desc / change / buffer / document / 事件
│   ├── 2-attr.rkt    attr-desc / attrs(unit) / document 属性写 / read-only 守卫
│   └── 3-render.rkt  width / window / 视觉行(vrow,wrap-segments,layout-*) / render-line / screen / project / mirror
└── editor/
    ├── 1-edit.rkt    构造·生命周期 / 查询 / 编辑命令 / 导航 / editor-command / 视图命令 / 账本 / link
    ├── 2-attr.rkt    editor 属性命令 / 文本+属性一条命令 / read-only 守卫
    └── 3-render.rkt  editor->screen / attrs-provider / 位置↔屏幕坐标
```

```bash
racket api-temp/api/1-edit.rkt
racket api-temp/api/2-attr.rkt
racket api-temp/api/3-render.rkt
racket api-temp/editor/1-edit.rkt
racket api-temp/editor/2-attr.rkt
racket api-temp/editor/3-render.rkt
```

每个 API 的写法统一是：

```racket
;; 名字 : 输入 → 输出
;;   设计：为什么存在 / 为什么这样设计
;;   用法：什么时候用、注意什么
(show "调用表达式" 结果)        ; 打印 => 实际值
```

## editor 的数据模型（看 id / count 前先读）

`editor` = **documents**（打开文档）⊕ **views**（视口）⊕ **focus**（焦点 vid）⊕ 发号器。

- **did**（document id）：管「哪个文档」——文本 / 属性 / 账本 / 历史策略。
- **vid**（view id）：管「哪个视口」——光标 / 选区 / 滚动 / 尺寸 / 模式。
- 一个文档可以开多个 view（分屏），各有独立光标，所以文档和视图是两个生命周期。
- id 是**稳定句柄**（单调递增、关闭后不复用），不是 list 下标；命令按 id 定位，
  `editor-view-*` 收 vid、程序面 `editor-document-*` 收 did，focus 只是「解析 vid 的糖」。
- **count**：`editor-document-count` = 打开了几个文档；`editor-view-count` = 有几个视口。

完整解释见 `editor/1-edit.rkt` 顶部的注释块。

## 两个入口

| 入口 | 是什么 | 演示在 |
|---|---|---|
| `core/api.rkt` | **低层公开面**：point / selection / edit-desc / change / buffer / document / window / screen … | `api/` |
| `core/editor.rkt` | **平台面**：`editor-*`（把底层拼成编辑器）。**不重导出** `api.rkt` | `editor/` |

- `api/` 的文件只 `require` `core/api.rkt`（`3-render.rkt` 另加几个子模块）。
- `editor/` 的文件 `require` `core/editor.rkt` + `core/api.rkt`（因为 `editor-*` 的输入/输出里
  还是低层值：`point` / `edit-desc` / `caret` / `read-only-key` …）。

门面是**显式白名单，故意很窄**。有些能力不在 `core/api.rkt` 里，要直接 require 子模块：

| 不在 `core/api.rkt` 门面 | 住在哪 |
|---|---|
| `selection-map-edit` / `selections-normalize` / `selections-primary-index` | `core/atom/selection.rkt` |
| `history-*` / `step-*` | `core/unit/history.rkt`（应用面用 `editor-undo/redo`） |
| `attrs-replace-descs` | `core/unit/attrs.rkt`（应用面用 `document-replace-attr`） |
| `vrow` / `wrap-segments` / `layout-clip` / `layout-wrap` / `window-vrows` / `line-range->runs` | `core/viewport/layout.rkt` |
| `render-line` / `glyph` / `rendered-line` | `core/viewport/render.rkt` |
| `screen` 构造器（门面只给读口 / compose） | `core/unit/screen.rkt` |
| `snap-left-col` / `check-mode` | `core/viewport/window.rkt` |

## 三个最容易踩的点

1. **op 有三种形状，跨层不能混用**
   - `buffer op`：`buffer-op-*`，形状 `buffer selection → edit-desc` → 喂 `document-edit-at`（api 层）。
   - `edit-desc`：一次具体替换 → 喂 `document-apply-edit`（api 层）。
   - `editor op`：`edit-*`，形状 `editor did selection → edit-desc` → 喂 `editor-command` /
     `editor-view-edit`（editor 层）。

2. **很多函数返回多个值**
   - `(values editor report)`：`editor-edit` / `editor-command` / `editor-*-undo` /
     `editor-document-put-attr` / `editor-document-apply-attrs` …
   - `(values document change-result)`：`document-apply-change`；
   - `(values document desc/#f)`：`document-apply-edit` / `document-edit-at`；
   - `(values row col)` / `(values line col)`：投影与反投影。
   用 `define-values` / `let-values` 接。

3. **provider 有两种形状（同名不同值）**
   - `window->screen` 的 provider：`buffer line → runs`（api 层）；
   - `editor->screen` 的 provider：`editor did line → runs`（editor 层，`attrs-provider` 属于这层）。
   所以 `empty-face-provider` 也有两个版本。

## 其它约定

- **属性 key**：core 只解释 `'read-only`（守卫用）；其余 key 对 core 不透明，由你定义。
  只读区内编辑返回 `#f`；要强写用 `#:trusted? #t`。
- **坐标**：`point.col` 是**字符索引**；`screen` / `vrow` / `run-col` 是**显示列**（宽字符占 2）。
  两者用 `index->column` / `column->index` 换算。
