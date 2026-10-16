# edit-tui/app/api —— app 公共 API 面

`api/` 是 app 的**稳定可用面**；`app/*.rkt` 是实现。用法：

```racket
(require "edit-tui/app/api/main.rkt")   ; 只 require 这一份即得全表面
;; 或按功能只 require 需要的转发模块，如 "edit-tui/app/api/ops.rkt"
```

转发模块**只转发、不放逻辑**；实现模块改名 / 拆分 / 收紧 `provide`，`api/` 的名字不动。
直接用 `app/*.rkt` 也能跑，但那份不属于稳定面。收紧后的实现面（如 `resource-register!`
这类内部登记函数）不会出现在 `api/` 下。

## 功能转发模块

| api 模块 | 转发 | 功能 |
|---|---|---|
| `intent.rkt` | `../intent.rkt` | 效果即数据：状态意图 / 效果意图 |
| `world.rkt` | `../world.rkt` | 世界状态 + `ctx` / `drag` / `mode` / `app-event` + 派生 |
| `panel-ref.rkt` | `../panel-ref.rkt` | panel 稳定身份与当帧解析 |
| `role.rkt` | `../role.rkt` | leaf 角色注册表（splittable? / close-policy） |
| `doc-kind.rkt` | `../doc-kind.rkt` | document 类型 → 命令表 + per-document 表层 |
| `base-keys.rkt` | `../base-keys.rkt` | 基础键表（edit / motion / pointer / focus） |
| `ops.rkt` | `../ops.rkt` | 操作根对象的纯原语 |
| `resource.rkt` | `../resource.rkt` | 资源（document / view）创建与装配 |
| `step.rkt` | `../step.rkt` | 纯状态转移 |
| `render.rkt` | `../render.rkt` | `world → bytes` + 焦点边框投影 |
| `loop.rkt` | `../loop.rkt` | `run-app`（唯一不纯入口） |
| `main.rkt` | 聚合以上 | require 即得全表面 |

## 函数（按功能）

### intent —— 效果词汇

| 类别 | 名字 |
|---|---|
| 构造糖 | `modify` `modify/silent` |
| 状态意图 | `(update f dirty?)` |
| 效果意图 | `(edit view op)` `(select view sel)` `(scroll view delta)` `(spawn id thunk)` `(post ev)` `(invoke thunk)` `(open-doc make f)` |
| 判定 | `intent?` `state-intent?` `effect?` `intent-kind` |

### world —— 世界状态

| 类别 | 名字 |
|---|---|
| 构造 | `make-world` |
| 结构 | `world` `ctx` `mode` `drag` `app-event`（含各自访问器） |
| 派生 | `world-panels` `world-panel-refs` `world-panels+refs` `world-ref->view` `world-ref->panel` `world-focus-view` `world-overlay-views` |
| 纯更新 | `world-resize` `world-focus-on` `world-push-mode` `world-pop-mode` `world-set-status` `world-set-pending` `world-set-drag` `world-set-layout` `world-set-floats` `world-stop` `mark-dirty` `mark-clean` |

### panel-ref —— 面板身份

| 类别 | 名字 |
|---|---|
| 身份 | `panel-ref` `leaf-ref` `float-ref` |
| 解析 | `ref->view` `ref->panel` |
| 可聚焦 | `focusable-ref?`（只有 leaf；浮窗永不占焦点） |
| panels ↔ refs | `panels->refs` `placements->refs` `panel->ref` |

### role —— leaf 角色注册表

`role`（`role-name` / `role-splittable?` / `role-close-policy`）· `define-role!` · `role-of` · `role-known?`

### doc-kind —— document 类型

`doc-kind` · `define-doc-kind!` · `kind->keytable` · `buffer-set-kind!` `buffer-kind` · `buffer-add-table!` `buffer-remove-table!` `buffer-clear-tables!` `buffer-keytables` · `view-kind` `view-tables`

### base-keys —— 基础键表

`edit-keys` · `motion-keys` · `pointer-keys` · `focus-keys`

### ops —— 操作原语（全部返回 `(listof intent)`）

| 类 | 原语 |
|---|---|
| layout | `layout-op` · `mount-view` `clear-view` · `show-pane` `hide-pane` `toggle-pane` `delete-pane` · `split-pane` `move-pane` `resize-seam` |
| 切分 / 关闭（读 role） | `splittable-leaf?` · `split-focused` · `split-left` `split-right` `split-up` `split-down` · `close-focused` |
| floats | `floats-op` · `add-float` `remove-float` |
| modes / overlays | `push-mode` `pop-mode` · `open-overlay` `close-overlay` |
| focus | `focus-on` · `focus-leaf` · `focus-move` |
| **focus（文档）** | `focus-edit`（通用）· `focus-insert` · `focus-delete-backward` `focus-delete-forward` · `focus-undo` `focus-redo` · `focus-cursor-left/right/up/down/home/end` · `focus-select` `focus-select-range` `focus-select-begin` `focus-select-update` · `focus-scroll` |
| session | `show-status`（写状态行）· `quit`（退出） |

### resource —— 资源

`make-resources` · `resources?` `resources-list` · `make-document` `open-document!` · `view-into`

### runtime

| 模块 | 函数 |
|---|---|
| `step` | `world-step` `world-step*` |
| `render` | `draw-world` `world-display-panels` |
| `loop` | `run-app` |

## 表 / 注册表（运行时数据）

| 表 | 定义处 | 键 → 值 | 写入 |
|---|---|---|---|
| role 注册表 | `role.rkt` | `symbol → role` | `define-role!` |
| doc-kind 注册表 | `doc-kind.rkt` | `symbol → doc-kind` | `define-doc-kind!` |
| per-buffer kind | `doc-kind.rkt`（weak eq） | `buffer → symbol` | `buffer-set-kind!` |
| per-buffer 表层 | `doc-kind.rkt`（weak eq） | `buffer → (listof keytable)` | `buffer-add-table!` / `buffer-remove-table!` |
| `world.internal` | `world` 字段 | `symbol → (world payload → world + intents)` | 命令里放 / 接 `app-event` |
| `world.modes` | `world` 字段 | `(listof mode)`，栈顶在前 | 命令里 `modify` |
| keytable | `command` 层 | `(listof keymap)` | `make-keytable` / `keytable-merge!` |

## 命名规约

- **`world-*`**：world 的派生值 / 纯更新（`world-panels` / `world-focus-on`）。
- **`*-ref` / `ref->*`**：稳定身份及其解析（`leaf-ref` / `ref->view`）。
- **`*->*`**：纯转换（`panels->refs` / `placements->refs` / `ref->view`）。
- **`make-*`** 构造值；**`define-*!`** 注册；**`*-add!` / `*-remove!` / `*-set-!`** 写表。
- **intent 构造糖不带 `!`**（`modify` / `edit` / `select` …）；core 的写操作才带 `!`。
- ops 原语是**构造器**不是执行器：返回 `(listof intent)`，无副作用，名字按行为。
- `main.rkt` 只再导出；`api/*.rkt` 只转发。

## 值词汇（symbol 值域）

| 词汇 | 值 |
|---|---|
| role 名 | `'editor` `'panel` …（开放集，见 `role.rkt`） |
| close-policy | `'hide` `'delete` `'keep-last` |
| panel-ref kind | `'leaf` `'float` |
| drag kind | `'seam` `'select` …（step 只解释 `'seam`） |
| axis / side | `'lr` `'tb` / `'before` `'after` |
| dir | `'left` `'right` `'up` `'down`（`panel-move` 另有 `'front` `'back`） |
| dock | `'left` `'right` `'top` `'bottom` `'center`/`#f` |
| borders | `'up` `'down` `'left` `'right` |
| face | `'window-border` `'focused-border` `'float-border`（见 `theme/frame.rkt`） |
| intent | `update` `edit` `select` `scroll` `spawn` `post` `invoke` `open-doc` |
| app-event kind | `'task-done` …（开放，见 `world.internal`） |

架构 / 数据流 / 扩展点见 `../README.md`。
