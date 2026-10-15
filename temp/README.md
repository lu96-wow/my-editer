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
| `03-editing.rkt` | 编辑算子、多光标、只读守卫 | 使用层 |
| `04-navigation.rkt` | 光标移动、扩选、自定义导航、视口滚动 | 使用层 |
| `05-history.rkt` | undo / redo / 记步 / 显式事务 | 使用层 |
| `06-attributes.rkt` | face / readonly / 开放槽 的读写 | 使用层 + 实现层（槽） |
| `07-query.rkt` | 文本、点、选区、坐标换算、视口状态查询 | 使用层 |
| `09-multiview.rkt` | 一份文档多视图，编辑时兄弟视图重基准 | 使用层 + `text/rebase.rkt` |
| `10-session.rkt` | 编辑会话：连续编辑合并、打断收步 | 会话层 `editor/session.rkt` |
| `13-panel-core.rkt` | panel 进 core：rect 驱动 view 尺寸 + 内置边框 + 一次 diff | 使用层 |
| `14-perf.rkt` | 400×120 增量渲染性能基准 | `render-display-patch` |
| `15-hotspots.rkt` | 渲染热点拆分（compose / patch / project） | 实现层 `view/compose` `view/patch` |
| `16-dirty-fuzz.rkt` | 脏区增量渲染随机 fuzz：增量屏 == 全量屏 | `render-display-patch` |
| `17-verify.rkt` | 布局 + 增量渲染验证；真终端交互 | `panels-sync!` |
| `18-command.rkt` | 命令层：键序列表 + 组合 + racket-tui 输入 | `edit-tui/command` |
| `19-bench-neighbor.rkt` | panel 方向导航 / 深度前后 的开销（每次按键一次的 O(N) 查询） | `view/panel.rkt` |
| `20-layout-tree.rkt` | 布局树：tree → panels → screen（显隐 / 移动 / cuts） | `edit/layout` |
| `21-interactive-layout.rkt` | 交互：命令层 C-b 开关面板 + 鼠标拖接缝（with-tui） | `edit/layout` + `edit-tui/command` |

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
会话层   editor/session.rkt         显式合并的交互封装（镜像导航）
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

使用层的操作（除改名外）：

- 文本 cell/row：`buffer-set-char!` / `buffer-set-line!` / `buffer-replace-range!` / `buffer-set-document!` / `buffer-line` / `view-line`
- 属性：`buffer-face-all!` / `buffer-readonly-all!` / `buffer-face-row` / `buffer-readonly-row` / `buffer-face-any?` / `buffer-readonly-any?` / `buffer-editable?`
- 历史：`buffer-undo-target` / `buffer-redo-target` / `buffer-history-limit`
- 选区：`view-add-selection!` / `view-remove-selection!` / `view-selection-text`
- **显式事务**：`buffer-with-undo-step` / `buffer-begin-undo-step!` / `buffer-end-undo-step!`
- **会话**：`make-edit-session` / `session-edit!` / `session-*!` / `session-break!`
  其中程序写镜像 `session-set-document!` / `session-replace-range!` / `session-set-line!` /
  `session-set-char!` / `session-commit-if-unchanged!` **默认独立成步**（先收步再写）。

## 合并模型：完全显式

编辑本身**不含合并策略**：`buffer-edit!` 每次调用 = 一个新撤销步。要合成一步：

- 程序：`(buffer-with-undo-step b (lambda () ...))`（或手动 `begin/end`）；
- 交互：`(make-edit-session b)` —— 编辑走 `session-edit!`（自动合并），
  导航 / 选区 / undo 走 `session-*!`（自动收步）。见 `10-session.rkt`。

事务内**第一次提交就 record**、之后 merge，所以打开的步立刻可见
（`buffer-depth` 已 +1、`buffer-can-undo?` = `#t`），忘记收步也不会丢。

使用层**不导出**（要用于高级场景就直接 require 实现模块）：

- 裸构造/字段：`buffer`、`view`、`buffer-history`、`view-viewport`
- 文档值：`buffer-document`、`view-document`、`->document`、`document-*`
- 整轨/句柄：`buffer-face`、`buffer-readonly`、`buffer-set-face!`、`buffer-set-readonly!`、
  `buffer-slot-ref`、`buffer-slot-set!`
- 视口内部量：`view-anchor`、`view-top-line`、`view-left-column`、`view-set-anchor!`
- 机制：`edit-op`、`view-char-nav!`、`view-visual-nav!`、`history-*`

高级逃生通道（示例里用到）：

```racket
(require (only-in "../core/editor/state.rkt" buffer-document)
         (only-in "../core/editor/attributes.rkt" buffer-slot-set!)
         (only-in "../core/editor/query.rkt" buffer-slot-ref)
         (only-in "../core/text/document.rkt" document-editable?))
```

## 提交的返回值约定

| 家族 | 返回 | 函数 |
|---|---|---|
| 文本提交 | `#f \| (listof change)`：`#f`=拒绝、`'()`=无变更 | `buffer-edit!` / `buffer-replace-range!` / `buffer-set-line!` / `buffer-set-char!` / `buffer-set-document!` |
| 版本 CAS | `applied?` | `buffer-commit-if-unchanged!` |
| 撤销 / 重做 | `ok?` | `buffer-undo!` / `buffer-redo!` |
| 历史开关 / 事务 | `void` | `buffer-clear-history!` / `buffer-reset-history!` / `buffer-set-history-enabled!` / `buffer-begin-undo-step!` / `buffer-end-undo-step!` |
| 事务块 | thunk 的返回值 | `buffer-with-undo-step` |

例：`(buffer-edit! b v op)`。需要布尔时用 `(and ret #t)`。

## 唯一写入口

`buffer` / `view` 的裸 setter（`set-view-selections!`、`set-view-viewport!`、`set-buffer-*!`）
**不在公共 API**（定义在内部的 `editor/state-data.rkt`，`state.rkt` 用 `except-out` 裁掉）。
改状态一律走提交壳：

| 想改 | 用 |
|---|---|
| view 选区 | `view-set-selections!` / `view-set-point!` / `view-select-all!` / 导航算子 |
| view 视口 | `view-scroll!` / `view-scroll-to-line!` / `view-scroll-to-point!` / `view-set-mode!` / `view-resize!` … |
| buffer 文档 | `buffer-edit!` / `buffer-set-document!` / `buffer-commit-if-unchanged!` |
| buffer 历史 | `buffer-undo!` / `buffer-redo!` / `buffer-clear-history!` … |

## 两个容易踩的点

1. **槽必须在任何 document 创建之前声明**（`document-open` 时会 `freeze-slots!`）。
   所以 `06-attributes.rkt` 里 `define-document-slot` 写在 `make-buffer` 之前。
   又因为注册表是进程级的，**一个进程只能声明一次槽**——所以每个示例用独立进程运行。
2. **`point` 的列是字符索引，不是显示列**（宽字符算 1 个索引、2 个显示列）。
   从屏幕坐标反推点要用 `view-screen-position->point`，别拿终端列号直接造点。
