# core 功能示例（拆分版）

每个文件一个主题，都能单独运行：

```sh
cd edit
racket temp/01-objects.rkt
racket temp/02-selection.rkt
...
```

## 文件索引

| 文件 | 主题 | 主要 API 入口 |
|---|---|---|
| `01-objects.rkt` | buffer / view 的创建、共享、关闭 | 使用层 `editor.rkt` |
| `02-selection.rkt` | 选区：值层构造 + 提交到 view + 查询 | 使用层 + `text/base/selection.rkt` |
| `03-editing.rkt` | 编辑算子、多光标、只读守卫、并步 | 使用层 |
| `04-navigation.rkt` | 光标移动、扩选、自定义导航、视口滚动 | 使用层 |
| `05-history.rkt` | undo / redo / 并步 / 记步开关 | 使用层 |
| `06-attributes.rkt` | face / readonly / 开放槽 的读写 | 使用层 + 实现层（槽） |
| `07-query.rkt` | 文本、点、选区、坐标换算、视口状态查询 | 使用层 |
| `08-render.rkt` | display list → screen（全量 + 增量 + 装饰） | 使用层 + 实现层（decorations） |
| `09-multiview.rkt` | 一份文档多视图，编辑时兄弟视图重基准 | 使用层 + `text/rebase.rkt` |

## 分层速查

```
值层     text/base/*、view/base/*    纯值，随便构造
文档     text/document.rkt           文本 + 端口(face/readonly) + 槽
实现层   editor/state-data.rkt       buffer/view 可变数据（内部）
         editor/state.rkt           对象 + 结构手术（只导出访问器）
         editor/ops.rkt             纯编辑算子 + 提交壳
         editor/query.rkt           读
         editor/attributes.rkt      端口 / 槽写回
         editor/render.rkt          display list → screen
         editor/history.rkt         纯文档版本栈
使用层   editor.rkt                  ★ 宿主只 require 这个
```

## 使用层 vs 实现层

宿主 **只 require `editor.rkt`**，拿到的是 buffer/view 的**意图 API**；内部构造
（`track` / `viewport` / `history` / `slot` / `document` / `edit-op` 字段）都被挡在外面。

实现名 → 使用层的意图名（`rename-out`）：

| 实现名（`editor/ops.rkt`） | 使用层名（`editor.rkt`） |
|---|---|
| `view-set-top-line!` | `view-scroll-to-line!` |
| `view-set-left-column!` | `view-scroll-to-column!` |
| `view-set-anchor-point!` | `view-scroll-to-point!` |
| `buffer-apply-if-version!` | `buffer-commit-if-unchanged!` |
| `buffer-seal!` | `buffer-end-undo-step!` |

使用层**不导出**（要用于高级场景就直接 require 实现模块）：

- 裸构造/字段：`buffer`、`view`、`buffer-history`、`buffer-merge`、`view-viewport`
- 文档值：`buffer-document`、`view-document`、`->document`、`document-*`
- 整轨/句柄：`buffer-face`、`buffer-readonly`、`buffer-set-face!`、`buffer-set-readonly!`、
  `buffer-face-row`、`buffer-readonly-row`、`buffer-slot-ref`、`buffer-slot-set!`
- 视口内部量：`view-anchor`、`view-top-line`、`view-left-column`、`view-set-anchor!`
- 机制：`edit-op`（及 `-run`/`-tag`）、`view-char-nav!`、`view-visual-nav!`、`history-*`

高级逃生通道（示例里用到）：

```racket
(require (only-in "../core/editor/state.rkt" buffer-document)
         (only-in "../core/editor/attributes.rkt" buffer-slot-set!)
         (only-in "../core/editor/query.rkt" buffer-slot-ref)
         (only-in "../core/text/document.rkt" document-editable?))
```

## 提交的返回值约定

编辑类提交函数用一个值编码三态，真值 = 已提交，`#f` = 拒绝：

| 返回 | 含义 |
|---|---|
| `#f` | 被只读守卫拒绝，未提交 |
| `'()` | 提交成功但无变更 |
| `(list change)` | 提交成功，含本次变更描述 |

例：`(buffer-edit! b v op)`。需要布尔时用 `(and ret #t)`。
`buffer-replace!` 返回 `void`（可用 `#:changes` 传入变更描述）；
`buffer-commit-if-unchanged!` 返回 `applied?`。

## 唯一写入口

`buffer` / `view` 的裸 setter（`set-view-selections!`、`set-view-viewport!`、`set-buffer-*!`）
**已从公共 API 移除**（定义在内部的 `editor/state-data.rkt`，`state.rkt` 用 `except-out` 裁掉）。
改状态一律走提交壳：

| 想改 | 用 |
|---|---|
| view 选区 | `view-set-selections!` / `view-set-point!` / `view-select-all!` / 导航算子 |
| view 视口 | `view-scroll!` / `view-scroll-to-line!` / `view-scroll-to-point!` / `view-set-mode!` / `view-resize!` … |
| buffer 文档 | `buffer-edit!` / `buffer-replace!` / `buffer-commit-if-unchanged!` |
| buffer 历史 | `buffer-undo!` / `buffer-redo!` / `buffer-clear-history!` … |

## 两个容易踩的点

1. **槽必须在任何 document 创建之前声明**（`document-open` 时会 `freeze-slots!`）。
   所以 `06-attributes.rkt` 里 `define-document-slot` 写在 `make-buffer` 之前。
   又因为注册表是进程级的，**一个进程只能声明一次槽**——所以每个示例用独立进程运行。
2. **`point` 的列是字符索引，不是显示列**（宽字符算 1 个索引、2 个显示列）。
   从屏幕坐标反推点要用 `view-screen-position->point`，别拿终端列号直接造点。
