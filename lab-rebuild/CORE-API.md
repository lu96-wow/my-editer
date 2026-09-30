# lab/ 用到的 core API 清单

来源：`lab/*.rkt`（当前工作区版本）。
`core/` 未做任何改动。

分层（按“谁碰 core / 谁碰 io”）：

| lab 文件 | 角色 | 碰 core | 碰 io |
|---|---|---|---|
| `input.rkt` | 抽象输入类型（key/text/pointer/resize） | 否 | 否（纯值） |
| `layout.rkt` | 布局代数（pane-id / rect） | 否 | 否（纯数据） |
| `theme.rkt` | face → RGB | 否 | 否（纯数据） |
| `fs.rkt` | 文件系统（list/read/create/mkdir/delete） | 否 | `racket/file` |
| `editor.rkt` | app 状态 + 文档管理 + 视图管理（复用/切换/关视图）+ 焦点 + 布局操作 + 编辑格输入 | **是（重）** | `racket/file` |
| `tree.rkt` | 文件树 / 已打开视图表（结构 + 输入 + 投影，`v` 切换） | **是** | 经 `fs.rkt` |
| `status.rkt` | 状态栏投影 | **是（轻）** | 否 |
| `command.rkt` | 全局键位 + 分发 | 否（只调 lab 自己的函数） | 否 |
| `init.rkt` | 装配 + 渲染 | **是** | 否 |
| `tui.rkt` | 后端：tui 事件 ↔ input；screen → 字节 | **是（screen/patch）** | `tui` |

---

## 一、按 lab 文件列（用了哪些 core API）

### `lab/editor.rkt`（最重）
- 生命周期：`editor-add-document`（值/`did`）、`editor-add-view`、`editor-add-document-view`、
  `editor-close-view`、`editor-close-document`
- 视图管理：`editor-views` / `view-id` / `view-did`（列出可用视图）、
  `first-view-of-document`（复用文档已有视图）、`editor-view-set-size`（视图落进窗格尺寸）
- 身份/查找：`editor-document-entry`、`document-entry-document`、`editor-view-document-id`、
  `editor-view-document-name`
- 读文本：`editor-view-string`、`document->string`
- 编辑：`editor-view-insert`、`editor-view-backspace`、`editor-view-delete`
- 导航：`editor-view-left`、`editor-view-right`、`editor-view-up`、`editor-view-down`、
  `editor-view-home`、`editor-view-end`、`editor-view-scroll`
- 剪贴板/历史：`editor-view-copy`、`editor-view-paste`、`editor-view-undo`、`editor-view-redo`
- 选区/定位：`editor-view-set-point`、`editor-view-set-selections`、`editor-view-selections`、
  `editor-view-screen-pos->point`、`editor-view-height`
- 值/类型：`point`、`selection`（构造）、`selection-anchor`、`selections-one`、`selections-primary`
- 测试里：`editor-open`、`editor-documents`

### `lab/tree.rkt`
- 整份重建文档：`editor-view-assign`、`document-open`、`document-highlight-fill`
- 视图表（视图模式）：`app-open-views`、`editor-view-document-name`、`editor-view-point-line` /
  `editor-view-point-col`、`app-pane-of-view`
- 光标/视口：`editor-view-point-line`、`editor-view-set-point`、`editor-view-set-top-line`
- 只读标签：`editor-view-readonly-range`、`range-of`
- 读：`editor-view-string`、`editor-view-document`（测试）
- 编辑/导航：`editor-view-insert`、`editor-view-backspace`、`editor-view-delete`、
  `editor-view-left/right/up/down`、`editor-view-scroll`
- 鼠标：`editor-view-screen-pos->point`
- 值：`point`、`document-highlight-at`（测试）
- 测试里：`editor-open`、`editor-add-document-view`

### `lab/status.rkt`
- 读：`editor-view-document-id`、`editor-view-document-name`、`editor-view-point-line`、`editor-view-point-col`
- 写：`editor-view-assign`
- 值：`document-open`、`document-highlight-fill`

### `lab/init.rkt`
- 构造：`editor-open`、`editor-add-document-view`
- 布局/渲染：`editor-set-layout`、`editor-render-layout`、`rect`（struct）
- 测试：`document-highlight-at`、`editor-view-document`、`editor-view-string`、
  `screen-width`、`screen-height`、`screen-row`、`run-face`、`run-text`

### `lab/tui.rkt`
- 差量渲染：`screen-patch`、`piece-row`、`piece-col`、`piece-text`、`piece-attr`
- 帧尺寸：`screen-width`、`screen-height`
- （`format-*` / `put-bytes` / `flush!` / 事件 struct / `build-input` / `with-tui` 来自 `tui`，不是 core）

### `lab/command.rkt`
- **不直接用 core**：只调 lab 的 `editor-resize-focus`、`quit-request`、`app` 字段。

### `lab/layout.rkt` / `lab/input.rkt` / `lab/theme.rkt` / `lab/fs.rkt`
- **不 require core**（fs 只用 `racket/file`）。

---

## 二、反向索引（core API → 谁在用）

### 生命周期 / 结构（core/editor/state.rkt）
| API | 用于 |
|---|---|
| `editor-open` | init, editor(test), tree(test) |
| `editor-add-document` | editor（`app-open`） |
| `editor-add-view` | editor（`app-show`）/ tree（视图模式新建视图） |
| `editor-add-document-view` | editor（`add-editor-pane`/`app-close`）, init, tree(test) |
| `editor-close-view` | editor（`app-show`/`app-close`/`app-close-view`/`layout-close!`） |
| `editor-close-document` | editor（`app-close`） |
| `editor-document-entry` | editor（`app-save-did`/`app-dirty?`） |
| `document-entry-document` | editor |
| `editor-view-document-id` | editor, status |
| `editor-view-document-name` | editor, status |

### 读（core/editor/query.rkt）
| API | 用于 |
|---|---|
| `editor-view-string` | editor, tree, init(test) |
| `editor-view-point-line` | tree, status |
| `editor-view-point-col` | status |
| `editor-view-height` | editor（翻页） |
| `editor-view-selections` | editor（鼠标扩选锚点） |
| `editor-view-screen-pos->point` | editor, tree |

### 编辑 / 导航 / 剪贴板（core/editor/command.rkt）
| API | 用于 |
|---|---|
| `editor-view-insert` | editor, tree |
| `editor-view-backspace` | editor, tree |
| `editor-view-delete` | editor, tree |
| `editor-view-left/right/up/down` | editor, tree |
| `editor-view-home/end` | editor |
| `editor-view-scroll` | editor, tree |
| `editor-view-undo/redo` | editor |
| `editor-view-copy/paste` | editor |
| `editor-view-set-point` | editor, tree |
| `editor-view-set-selections` | editor |
| `editor-view-set-top-line` | tree |
| `editor-view-assign` | tree, status |
| `editor-view-readonly-range` | tree |

### 渲染 / 布局（core/editor/layout.rkt + query/change）
| API | 用于 |
|---|---|
| `editor-set-layout` | init |
| `editor-render-layout` | init |
| `rect`（struct） | init |
| `screen-patch` / `piece-*` | tui |
| `screen-width/height/row`、`run-face/text` | init(test) |

### 文本层（core/text）
| API | 用于 |
|---|---|
| `document-open` | tree, status |
| `document->string` | editor |
| `document-highlight-fill` | tree, status |
| `document-highlight-at` | init(test) |
| `point` | editor, tree |
| `range-of` | tree |
| `selection` / `selection-anchor` / `selections-one` / `selections-primary` | editor |

---

## 三、非 core（io / 后端）依赖

- `racket/file`：`file-exists?`、`file->string`、`display-to-file`、`file-name-from-path`、
  `directory-exists?`、`directory-list`、`make-directory`、`delete-directory/files`、`delete-file`
  → `lab/fs.rkt`、`lab/editor.rkt`
- `tui`：`key-event`/`paste-event`/`mouse-event`/`resize-event`/`mods-*`、`build-input`、
  `with-tui`、`get-window-size`、`loop-input/stop`、`format-*`、`put-bytes`、`flush!`
  → 只在 `lab/tui.rkt`
