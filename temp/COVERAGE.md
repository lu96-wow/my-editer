# 功能面读写覆盖检查

粒度定义（由文本轨道结构决定）：

| 粒度 | 含义 | 表示 |
|---|---|---|
| **cell** | 单个字符格 | `(line, col)`，col 是字符索引 |
| **row** | 一整行 | line 号（行 = string；属性行 = vector） |
| **range** | 区间 | `(range start end)`，可跨行 |
| **document** | 整篇 | 整条 track / buffer |

「使用层」= `editor.rkt`（宿主入口）；「实现层」= `editor/*.rkt` / `text/*`。

---

## 1. 文本（内容）

| 粒度 | 读·实现层 | 读·使用层 | 写·实现层 | 写·使用层 |
|---|---|---|---|---|
| cell | `line-ref`（内部） | ✅ `buffer-char-at` / `view-char-at` | `edit-cells` / `line-insert` `line-delete` | ✅ `buffer-set-char!` |
| row | `track-ref` / `line->list` | ✅ `buffer-line` / `view-line` | `edit-rewrite-line` / `track-rewrite` / `line-insert` `line-splice` | ✅ `buffer-set-line!` |
| range | `document-range-text` | ✅ `buffer-range-text` / `view-range-text` | `document-insert` / `-delete` / `-replace` | ✅ `buffer-edit!` / `buffer-replace-range!` |
| document | `document->string` / `document-text` | ✅ `buffer-string` / `view-string` | `document-open` | ✅ `buffer-replace!` |
| 复制 | `document-copy` | ✅ `view-copy-text` | — | — |

**结论**：文本 cell/row/range/document 读写均已覆盖；row 读 = `buffer-line`/`view-line`，cell/row 写 = `buffer-set-char!`/`buffer-set-line!`。

---

## 2. 属性（端口 face / readonly）

| 粒度 | 读·实现层 | 读·使用层 | 写·实现层 | 写·使用层 |
|---|---|---|---|---|
| cell | `document-face-at` / `-readonly-at?` | ✅ `buffer-face-at` / `buffer-readonly-at?`（+`view-*`） | `document-face-fill` | ✅ `buffer-face-cell!` / `buffer-readonly-cell!` |
| row | `document-face-row` / `-readonly-row` | ✅ `buffer-face-row` / `buffer-readonly-row` | `document-edit-face` / `-fill` | ✅ `buffer-face-line!` / `buffer-readonly-line!` |
| range | `document-face-range?` / `-readonly-range?` / `document-editable?` | ✅ `buffer-face-any?` / `buffer-readonly-any?` / `buffer-editable?` | `document-face-fill` | ✅ `buffer-face-range!` / `buffer-readonly-range!` |
| batch | — | — | `document-face-fill-batch` / `-batch*` / `-range-batch` | ✅ `buffer-face-batch!` / `-range-batch!` |
| whole | `document-face` / `document-readonly`（track） | ✅ `buffer-face-at` 逐格 / `buffer-face-row` 逐行 | `document-set-face!` / `-readonly!`（整轨替换） | ✅ `buffer-face-all!` / `buffer-readonly-all!`（#f 回惰性） |

**结论**：属性 cell / row / range / batch / whole 读写均已覆盖（读面已补齐）。

### 槽（slot，与端口分开）
| 粒度 | 读 | 写 |
|---|---|---|
| document | `document-slot-ref` / `buffer-slot-ref` | `document-slot-set!` / `buffer-slot-set!` / `document-edit-slot`（读改写） |
| atom | `document-slot-atom` | 经 box 异步写回 |

无 cell / row（槽是 opaque 的 per-document 存储，设计如此）。

---

## 3. 历史（版本栈）

| 操作 | 读 | 写 |
|---|---|---|
| 可用性 | ✅ `buffer-can-undo?` / `buffer-can-redo?` | — |
| 版本预览 | ✅ `buffer-undo-target` / `buffer-redo-target`（目标文本 `string \| #f`） | — |
| 深度 / 上限 | ✅ `buffer-depth` / `buffer-history-limit` | — |
| 开关 | ✅ `buffer-history-enabled?` | ✅ `buffer-set-history-enabled!` |
| 当前文档 | `history-document`（= `buffer-document`） | `history-set-current` |
| 记步 | ❌ 不能预览 past / future 内容 | `history-record`（仅经 edit 路径）、`buffer-edit!`、`buffer-commit-if-unchanged!` |
| 并步 | ❌ | `history-merge`（仅经 edit 路径）、`buffer-end-undo-step!` |
| 撤销 / 重做 | — | ✅ `buffer-undo!` / `buffer-redo!` |
| 清空 | — | ✅ `buffer-clear-history!` / `buffer-reset-history!` |

**结论**：补了版本预览（`buffer-undo-target` / `buffer-redo-target`）与 `buffer-history-limit`；past / future 内容可读。

---

## 4. 选区（selection）

| 粒度 | 读 | 写 |
|---|---|---|
| whole set | ✅ `view-selections` / `selections-items` / `selections-count` | ✅ `view-set-selections!` |
| primary | ✅ `view-primary` / `view-primary-range` / `view-point`（+line/col） | ✅ `view-set-point!` |
| 增 / 删项 | — | ✅ `view-add-selection!` / `view-remove-selection!` |
| 扩展 | — | ✅ 导航 `extend?` / `selections-extend` |
| 全选 | — | ✅ `view-select-all!` |
| 复制 | ✅ `view-copy-text` / `view-selection-text` / `view-range-text` | — |
| 归一 | ✅ `selections-normalize` / `-dedupe` / `-clamp` | 经 `view-set-selections!` |

**结论**：读写齐全（`view-add-selection!`/`view-remove-selection!`/`view-selection-text` 已补）。

---

## 缺口汇总（✅ = 已补齐）

| 面 | 读 | 写 |
|---|---|---|
| 文本 | ✅ `buffer-line` / `view-line` | ✅ `buffer-set-char!` / `buffer-set-line!` / `buffer-replace-range!` |
| 属性 | ✅ `buffer-face-row` / `buffer-readonly-row` / `buffer-face-any?` / `buffer-readonly-any?` / `buffer-editable?` | ✅ `buffer-face-all!` / `buffer-readonly-all!`（整篇设；默认值回惰性） |
| 历史 | ✅ `buffer-undo-target` / `buffer-redo-target` / `buffer-history-limit` | buffer 层录步/并步（record/merge 仍在 edit 路径内） |
| 选区 | ✅ `view-selection-text` | ✅ `view-add-selection!` / `view-remove-selection!` |

## 已补齐的 API（复用已有实现）

| API | 粒度 | 实现方式 |
|---|---|---|
| `buffer-line` / `view-line` | 文本 row·读 | `track-ref` |
| `buffer-set-char!` | 文本 cell·写 | `document-replace-ignore-readonly`（单格） |
| `buffer-set-line!` | 文本 row·写 | 同上（整行） |
| `buffer-replace-range!` | 文本 range·写 | 记一步 + 所有视图 `selections-rebase` |
| `buffer-face-row` / `buffer-readonly-row` | 属性 row·读 | `document-face-row` / `-readonly-row` |
| `buffer-face-any?` / `buffer-readonly-any?` | 属性 range·读 | `document-face-range?` / `-readonly-range?` |
| `buffer-editable?` | 属性 range·读 | `document-editable?` |
| `buffer-history-limit` | 历史·读 | `history-limit` 访问器 |
| `buffer-undo-target` / `buffer-redo-target` | 历史·读 | `history-undo-target` / `-redo-target` |
| `view-add-selection!` / `view-remove-selection!` | 选区·写 | `selections-add` / `-remove` + `view-set-selections!` |
| `view-selection-text` | 选区·读 | `document-copy` |
| `buffer-face-all!` / `buffer-readonly-all!` | 属性 whole·写 | 默认值 → 惰性 #f（O(1)）；否则全文 range fill |

余下可选（未做）：
- buffer 层显式 `record` / `merge`（现隐藏在 `buffer-edit!` / `buffer-commit-if-unchanged!` / `buffer-end-undo-step!` 里；待讨论）。
