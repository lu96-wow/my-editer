# 功能面读写覆盖

粒度定义（由文本轨道结构决定）：

| 粒度 | 含义 | 表示 |
|---|---|---|
| **cell** | 单个字符格 | `(line, col)`，col 是字符索引 |
| **row** | 一整行 | 行号（行 = string；属性行 = vector） |
| **range** | 区间 | `(range start end)`，可跨行 |
| **document** | 整篇 | 整条 track / buffer |

「使用层」= `editor.rkt`；「实现层」= `editor/*.rkt` / `text/*`。

---

## 1. 文本（内容）

| 粒度 | 读 | 写 |
|---|---|---|
| cell | `buffer-char-at` / `view-char-at` | `buffer-set-char!` |
| row | `buffer-line` / `view-line` | `buffer-set-line!` |
| range | `buffer-range-text` / `view-range-text` | `buffer-edit!`（按选区）/ `buffer-replace-range!`（按区间） |
| document | `buffer-string` / `view-string` | `buffer-set-document!` |
| 复制 | `view-copy-text` / `view-selection-text` | — |

文本写都进 history；`buffer-edit!` 作用于 view 的选区，其余作用于 buffer。

## 2. 属性（端口 face / readonly）

| 粒度 | 读 | 写 |
|---|---|---|
| cell | `buffer-face-at` / `buffer-readonly-at?` / `view-*` | `buffer-face-cell!` / `buffer-readonly-cell!` |
| row | `buffer-face-row` / `buffer-readonly-row` | `buffer-face-line!` / `buffer-readonly-line!` |
| range | `buffer-face-any?` / `buffer-readonly-any?` / `buffer-editable?` | `buffer-face-range!` / `buffer-readonly-range!` |
| batch | — | `buffer-face-batch!` / `buffer-readonly-batch!` / `buffer-face-range-batch!` / `buffer-readonly-range-batch!` |
| document | 逐格 / 逐行读 | `buffer-face-all!` / `buffer-readonly-all!` |

属性写就地改端口盒，**不进 history**。整篇设默认值时回惰性表示（O(1)）。

### 槽（slot，与端口分开）

| 粒度 | 读 | 写 |
|---|---|---|
| document | `buffer-slot-ref` | `buffer-slot-set!`（读改写：`document-edit-slot`） |
| atom | `document-slot-atom` | 经 box |

槽是 opaque 的 per-document 存储，无 cell / row 粒度。

## 3. 历史

| 操作 | 读 | 写 |
|---|---|---|
| 可用性 | `buffer-can-undo?` / `buffer-can-redo?` | `buffer-undo!` / `buffer-redo!` |
| 版本预览 | `buffer-undo-target` / `buffer-redo-target` | — |
| 深度 / 上限 | `buffer-depth` / `buffer-history-limit` | — |
| 开关 | `buffer-history-enabled?` | `buffer-set-history-enabled!` |
| 提交 | — | `buffer-edit!` / `buffer-replace-range!` / `buffer-set-line!` / `buffer-set-char!` / `buffer-set-document!` / `buffer-begin-undo-step!` · `buffer-end-undo-step!` · `buffer-with-undo-step` |
| 清空 | — | `buffer-clear-history!` / `buffer-reset-history!` |

`buffer-undo-target` / `buffer-redo-target` 返回目标版本文本（`string | #f`），只预览不推进栈。

## 4. 选区

| 粒度 | 读 | 写 |
|---|---|---|
| whole set | `view-selections` / `selections-items` / `selections-count` | `view-set-selections!` |
| primary | `view-primary` / `view-primary-range` / `view-point`（+ line / column） | `view-set-point!` |
| 增 / 删项 | — | `view-add-selection!` / `view-remove-selection!` |
| 扩展 | — | 导航 `extend?` / `selections-extend` |
| 全选 | — | `view-select-all!` |
| 复制 | `view-copy-text` / `view-selection-text` / `view-range-text` | — |
| 归一 | `selections-normalize` / `selections-dedupe` / `selections-clamp` | 经 `view-set-selections!` |

## 5. 合并

合并**完全显式**：`buffer-edit!` 每次调用 = 一个新撤销步；一组操作合成一步用 `buffer-with-undo-step`（程序）或 `session-edit!`（交互）。事务内第一次提交即 record，之后 merge。
