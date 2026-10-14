# editor 层 API 审计：实现 vs 功能

> 状态：**已实施使用层**。`editor.rkt` 现为 buffer/view 使用层，用 `rename-out` 暴露意图名、
> 隐藏实现名；实现层 `editor/*.rkt` 未改。下方为审计依据（改前状态）。

判定标准：

| 标记 | 含义 |
|---|---|
| **F 功能** | 主语是 buffer / view，名字表达**用户意图 / 可观察行为**，签名不暴露内部表示 |
| **I 实现** | 名字表达**内部机制 / 表示**，或签名暴露下层类型（track / slot / viewport / history 值） |
| **M 混合** | 名字像功能，但签名/返回值泄漏实现类型 |
| **N 非对象** | 主语根本不是 buffer / view（值层） |

统计（按 API 概念粗算，struct-out 算 1 条）：

| 模块 | F | I | M | N | 小计 |
|---|---:|---:|---:|---:|---:|
| `state.rkt` | 9 | 6 | 2 | 0 | 17 |
| `ops.rkt` | 33 | 8 | 1 | 0 | 42 |
| `query.rkt` | 28 | 8 | 1 | 0 | 37 |
| `attributes.rkt` | 10 | 3 | 0 | 0 | 13 |
| `render.rkt` | 4 | 0 | 0 | 0 | 4 |
| `history.rkt` | 0 | 0 | 0 | 15 | 15 |
| **合计** | **84 (66%)** | **25 (20%)** | **4 (3%)** | **15 (12%)** | **128** |

结论：约 2/3 是干净的「buffer/view + 功能名」；要找的是 25 条实现 + 4 条混合 + 15 条非对象。

---

## F 功能（保留）

**state**：`buffer?` `buffer-name` `buffer-views` `view?` `view-buffer` `view-selections` `make-buffer` `buffer-add-view!` `buffer-close-view!` `buffer-close!` `buffer-set-name!`

**ops**：`op-type`(及 7 个 `op-*`) `buffer-edit!` `buffer-replace!` `view-nav!` `view-left!` `view-right!` `view-up!` `view-down!` `view-home!` `view-end!` `view-set-selections!` `view-set-point!` `view-select-all!` `view-ensure!` `view-ensure-cursor-position!` `view-scroll!` `view-set-mode!` `view-toggle-line-numbers!` `view-resize!` `view-copy-text` `buffer-undo!` `buffer-redo!` `buffer-clear-history!` `buffer-reset-history!` `buffer-set-history-enabled!`

**query**：`buffer-string` `view-string` `buffer-range-text` `view-range-text` `buffer-char-at` `view-char-at` `buffer-face-at` `buffer-readonly-at?` `view-face-at` `view-readonly-at?` `view-point` `view-point-line` `view-point-column` `view-primary` `view-primary-range` `view-selection-count` `view-cursor-screen-position` `view-point->screen-position` `view-screen-position->point` `view-mode` `view-line-numbers?` `view-width` `view-height` `view-visible-range` `buffer-can-undo?` `buffer-can-redo?` `buffer-depth` `buffer-history-enabled?`

**attributes**：`buffer-face-range!` `buffer-readonly-range!` `buffer-face-cell!` `buffer-readonly-cell!` `buffer-face-line!` `buffer-readonly-line!` `buffer-face-batch!` `buffer-readonly-batch!` `buffer-face-range-batch!` `buffer-readonly-range-batch!`

**render**：`display-entry` `display-entry-cursor-position` `render-display` `render-display-patch`

---

## I 实现（要找出来）

| 名称 | 为什么是实现 |
|---|---|
| `state/buffer`（ctr） | 裸构造器，应用 `make-buffer` |
| `state/view`（ctr） | 裸构造器，应用 `buffer-add-view!` |
| `state/buffer-history` | 直接吐 `history` 值（内部版本栈） |
| `state/buffer-merge` | （已删除：隐式合并移除） |
| `state/view-viewport` | 直接吐 `viewport` 结构 |
| `state/->document` | 类型强制转换 |
| `ops/edit-op` + `-?`/`-run` | 扩展机制；`run` 是内部字段（tag 已删） |
| `ops/buffer-apply-if-version!` | 名字是机制（CAS + version） |
| `ops/view-char-nav!` | 按 `which` 分派的机制外壳，功能名已有 `view-left!` 等 |
| `ops/view-visual-nav!` | 同上（`up?`） |
| `ops/view-set-top-line!` | viewport 内部量 |
| `ops/view-set-left-column!` | viewport 内部量 |
| `ops/view-set-anchor!` | viewport 内部量 |
| `ops/view-set-anchor-point!` | viewport 内部量（点形式） |
| `query/buffer-face` | 返回整条 `track` |
| `query/buffer-readonly` | 返回整条 `track` |
| `query/buffer-face-row` | 返回裸 `vector` 行 |
| `query/buffer-readonly-row` | 返回裸 `vector` 行 |
| `query/buffer-slot-ref` | 收 `slot` 句柄 |
| `query/view-top-line` | viewport 内部量 |
| `query/view-left-column` | viewport 内部量 |
| `query/view-anchor` | viewport 内部量（`(values line dc)`） |
| `attributes/buffer-set-face!` | 收整条 `track` |
| `attributes/buffer-set-readonly!` | 收整条 `track` |
| `attributes/buffer-slot-set!` | 收 `slot` 句柄 |

## M 混合（功能名，实现签名 —— 按规则保留功能名，收窄签名）

| 名称 | 功能名 | 实现泄漏 |
|---|---|---|
| `state/buffer-document` | 读当前文档 | 返回 `document` 值 |
| `state/view-document` | 读当前文档 | 返回 `document` 值 |
| `ops/buffer-seal!` | （已删除：无隐式合并可切） |
| `query/view-anchor-point` | 读锚点位置 | 语义依赖 viewport 锚实现 |

## N 非对象（主语不是 buffer/view）

| 名称 | 说明 |
|---|---|
| `history.rkt` 全部 15 条 | `history-open` `history-document` `history-record` `history-merge` `history-undo` … 主语是 `history` 值 |

> 另有 `editor.rkt` 再导出的 `text/base`（`selection`/`selections`/`point`/`range`/`change`）、`text/document`、`view/base`（`screen`）、`view/compose`（`pane`）等值词汇——这是 README 明说的「值词汇表」，**有意公开**，不计入本审计。

---

## 同名 / 近名冲突（「实现和功能命名一样」的实例）

这些是**同一个操作**同时有实现级与功能级两个名字，处置统一为**功能名**（实现名内部化）：

| 概念 | 实现名（现） | 功能名（保留） | 状态 |
|---|---|---|---|
| view 选区写 | `set-view-selections!` | `view-set-selections!` | ✅ 已隐藏实现名 |
| buffer 名写 | `set-buffer-name!` | `buffer-set-name!` | ✅ 已隐藏实现名 |
| view viewport 写 | `set-view-viewport!` | `view-scroll!` / `view-set-mode!` … | ✅ 已隐藏实现名 |
| 整体 face | `buffer-face` / `buffer-set-face!` | `buffer-face-at` / `buffer-face-range!` | ⬜ 待隐藏 |
| 整体 readonly | `buffer-readonly` / `buffer-set-readonly!` | `buffer-readonly-at?` / `buffer-readonly-range!` | ⬜ 待隐藏 |
| 纵向滚动位置 | `view-top-line` / `view-set-top-line!` | `view-visible-range` / 新增 `view-scroll-to-line!` | ⬜ 待改 |
| 横向滚动位置 | `view-left-column` / `view-set-left-column!` | `view-visible-range` / 新增 `view-scroll-to-column!` | ⬜ 待改 |
| 锚点 | `view-anchor` / `view-set-anchor!` / `view-set-anchor-point!` | `view-visible-range` / 新增 `view-scroll-to-point!` | ⬜ 待改 |

## 建议的功能命名对照（实现名 → 功能名）

| 实现名（现） | 建议功能名 | 动作 |
|---|---|---|
| `view-set-top-line!` | `view-scroll-to-line!` | 改名（或内部化） |
| `view-set-left-column!` | `view-scroll-to-column!` | 改名（或内部化） |
| `view-set-anchor!` / `view-set-anchor-point!` | `view-scroll-to-point!` | 合并改名 |
| `buffer-face` / `buffer-readonly` | （无，用 `*-at` / `*-row`） | 隐藏 |
| `buffer-set-face!` / `buffer-set-readonly!` | （无，用 `*-range!/cell!/line!`） | 隐藏 |
| `buffer-face-row` / `buffer-readonly-row` | `buffer-face-line` / `buffer-readonly-line`（读方向） | 改名成对 |
| `buffer-slot-ref` / `buffer-slot-set!` | 移到「特性/槽」模块 | 移出 editor |
| `view-char-nav!` / `view-visual-nav!` | （无，用 `view-left!` 等） | 隐藏 |
| `buffer-apply-if-version!` | `buffer-commit-if-unchanged!` | 可选改名 |
| `buffer-seal!` | （已删除） |
| `buffer-merge` | —— | （已删除） |
| `buffer-history` | —— | 隐藏（留 `buffer-can-undo?` 等） |
| `->document` | —— | 内部化 |
| `history.rkt` 全部 | —— | 不再从 `editor.rkt` 再导出 |
