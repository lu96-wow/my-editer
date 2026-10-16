# edit-tui —— 分层架构

`edit-tui` 是 `core`（文本引擎 + 渲染值）之上的 **TUI 宿主层**：向下把 core 的渲染值画到
`racket-tui`，向上提供一个数据驱动的编辑器骨架。各层只做一件事，尽量纯、可单测。

- 本文：**分层 + 目录 + 依赖 + 数据流**（全局视角）。
- 细节看各目录 README：`layout/README.md`、`command/README.md`、`app/README.md`、`app/api/README.md`。
- core 在仓库根 `core/`（不属于 `edit-tui/`，但它是本层的底座）。

## 层次

| 层 | 目录 / 包 | 依赖 | 纯? | 一句话 |
|---|---|---|---|---|
| 终端 | `racket-tui`（`tui`） | — | 不纯 | 读事件、写字节、样式表 |
| 文本/渲染值 | `core/`（仓库根） | 无 | 数据可变，渲染纯 | buffer / view / document / history；`screen` / `piece` / `panel` |
| face 词汇 | `edit-tui/base/` | 无 | 纯 | `(face fg bg attrs)`：生产者 / 消费者共用 |
| 主题 | `edit-tui/theme/` | tui | 安装期副作用 | face 符号 → 样式，装进 tui 样式表 |
| 布局 | `edit-tui/layout/` | core | 纯 | 布局树 → `(listof panel)`；声明式 `spec`；拖缝；浮窗 |
| 命令 | `edit-tui/command/` | tui（仅 `tui.rkt`） | 纯 | 输入 token → 键表 trie → command |
| 渲染后端 | `edit-tui/core-render/` | core、base、tui | 纯 | core 渲染值（`piece`）→ tui 序列 |
| 骨架 | `edit-tui/app/` | core、layout、command、core-render、tui | `step` 纯；`loop`/`render`/`resource` 不纯 | `world` + 纯 `step` + `intent` + 事件循环 |

**依赖方向**（上层依赖下层，箭头指“被依赖”）：

```
tui ◀── command                     （只 command/tui.rkt 碰 tui）
tui ◀── core-render ◀── base/face
tui ◀── theme
tui ◀── app                         （只 loop / render 碰 tui）
core ◀── layout
core ◀── app ──▶ layout, command, core-render
```

没有反向依赖：`core` 不认识宿主；`layout` / `command` 互不认识（app 把它们接起来）。

## 目录

### `base/` —— face 值词汇

```
face.rkt    (struct face (fg bg attrs)) + 读写/构造
```

不依赖任何东西。core 的 `piece.attr`、panel 的 `face` 都用这套词汇；**色值不进 core**。

### `theme/` —— face 符号 → 样式

```
theme.rkt   机制：rgb / style / define-theme!（转成 racket-tui 样式并 style-define!）
core.rkt    渲染核心主题：正文 / 行号 / 语法 / 光标 / 选区
frame.rkt   框架主题：window-border / focused-border / float-border
main.rkt    入口：require 即安装
```

覆盖某项：require 之后再 `(define-theme! …)` 同名覆盖。

### `layout/` —— 布局树（纯几何）

```
tree.rkt    node = leaf | split；split/close/move/show/hide/weight/role
spec.rkt    声明式 pane / lay（直接产出 tree；dock → 边框）
solve.rkt   tree → panels / placements / cuts + 拖缝
float.rkt   浮窗（正交覆盖，不进树）
main.rkt    入口
```

- leaf 字段：`id view borders face weight size visible? role`；
- 相邻面板**共享 1 格接缝**，边框格由 border-owner（deep / weight / 列表序）选 face；
- `panel` 的尺寸真相在 `rect`，view 的 viewport 是派生量（由 core 的 `panels-sync!` 落）。
- 详见 `layout/README.md`。

### `command/` —— 输入 token → command

```
key.rkt      键令牌（纯）
mouse.rkt    鼠标令牌（纯）
command.rkt  command = run / note / input（纯）
keymap.rkt   keymap（trie）+ keytable（表列表）+ 纯 matcher（纯）
tui.rkt      racket-tui 适配：event->key / event->mouse / mouse-position / key-reader
main.rkt     入口
```

- 键盘、鼠标**共用同一套表**；位置不进 token，进 handler 的 ctx；
- 合并冲突**直接报错**（原子）；
- **只路由、不调用**：查表返回 `command`，由宿主执行。
- 详见 `command/README.md`。

### `core-render/` —— `piece` → tui 序列

```
render.rkt  render-piece / render-pieces / render-clear / face-fragment
main.rkt    入口
```

只产出序列，**不自己 put-bytes**；face 的解释在这里（`face-fragment`）。

### `app/` —— 编辑器骨架（实现）

```
intent.rkt     效果即数据：状态意图 update + 效果意图 edit/select/scroll/spawn/post/invoke/open-doc
world.rkt      world / ctx / layer / app-event / drag + 派生 + ref 解析
panel-ref.rkt  panel 稳定身份（leaf id / float key）+ 当帧解析
role.rkt       leaf 角色注册表（splittable? / close-policy）
doc-kind.rkt   document 类型 → 命令表 + per-document 表层
base-keys.rkt  基础小表：edit / motion / pointer / focus
ops.rkt        操作根对象的纯原语（返回 (listof intent)）
resource.rkt   资源创建（唯一造 core 对象的地方）
step.rkt       world-step / world-step*（纯）
render.rkt     world → bytes（+ 焦点边框投影）
loop.rkt       run-app（唯一不纯：读事件 / 跑 intent / 重绘）
plugin.rkt     插件注册 + 声明式载入（define-plugin! / panel-spec / plugins-apply）
slot.rkt       底部共享槽：状态栏 / 输入栏（slot-install / slot-show* / status-sync!）
main.rkt       入口：再导出 app/api/
api/           公共 API 面（见下）
```

- **不纯**只在 `loop.rkt`（循环 / 读事件 / 输出）、`render.rkt`（`panels-sync!` / `put-bytes`）
  与 `resource.rkt`（造 core 对象）；`world-step` 是纯函数，可 headless 重放。
- `world.focus` / `drag.subject` / `ctx.ref` 统一是 **panel-ref**（稳定身份），
  view / panel 每帧解析 —— 换 view、重排布局都不悬空。
- 详见 `app/README.md`。

### `app/api/` —— 公共 API 面

实现模块 `app/*.rkt` 旁边的**稳定面**：每个实现模块一个同名功能转发模块，`api/main.rkt` 聚合。

```
api/main.rkt        require 这一份 = app 的全部可用面
api/intent.rkt      效果词汇
api/world.rkt       世界状态 + 派生
api/panel-ref.rkt   面板身份
api/role.rkt        leaf 角色注册表
api/doc-kind.rkt    document 类型 → 命令表
api/base-keys.rkt   基础键表
api/ops.rkt         操作原语
api/resource.rkt    资源创建
api/step.rkt        纯状态转移
api/render.rkt      world → bytes
api/loop.rkt        run-app
```

只转发、不放逻辑；实现模块改名 / 拆分 / 收紧 `provide` 不影响 `api/` 的名字。
直接用 `app/*.rkt` 也能跑，但那份不属于稳定面。函数 / 注册表 / 命名规约见 `app/api/README.md`。

## 数据流

**事件 → 状态 → 效果 → 重绘**：

```
read-event ─┐
            ├─▶ world-step* (app/step, 纯)   world × event → world + intents
inbox ──────┘        │
                     ├─ update intent  → step 内就地折叠（仍是纯的）
                     └─ effect intent  → loop 效果解释器 (app/loop)
                                              │
                                              ▼
                                         draw-world (app/render)
                                              │  world-panels          : layout/solve  tree → panels
                                              │  panels-sync!          : core/sync  panel.rect → view.viewport
                                              │  render-display-patch  : core/render  panels+focus+cache → piece
                                              │  render-pieces         : core-render  piece → tui 序列
                                              ▼
                                         put-bytes / flush! (tui)
```

**输入 → 命令**（与上面同一个 step）：

```
event ─▶ command/tui: event->key / event->mouse → token
      ─▶ active-keytables (app/step): 拓展层 > per-document > kind 默认 > 全局
      ─▶ keytable-lookup (command/keymap) → command
      ─▶ (λ (ctx) (listof intent))
```

## 纯 / 不纯分界

| 纯（可 headless 测） | 不纯（唯一几处） |
|---|---|
| `core` 查询 / 渲染、`layout`、`command`（除 `tui.rkt`）、`core-render` | `command/tui.rkt`（读事件）、`core` 的编辑提交、`app/loop.rkt`（循环 / 线程 / 输出）、`app/resource.rkt`（造对象） |
| `app/step.rkt`（`world-step`）与全部 intent 构造 / ops 原语 | `app/render.rkt` 的 `panels-sync!` / `put-bytes` |

状态改动统一用 `modify`（world → world）；core 副作用退回成 effect intent，由 loop 解释。

## 扩展点

- 新 document 类型：`define-doc-kind!` + 小表；`open-document! #:kind`（不改 step / loop）。
- 新键位：`keys` 表合并；per-document 覆盖用 `buffer-add-keytable!`。
- 新面板 / 区域：`layout` 的 `pane #:role` + `define-role!`；布局树原语在 `layout/tree.rkt`。
- 新效果：加 intent struct + `loop` 的 `run-intents!` 一个 `match` 分支（`invoke` 是逃生舱）。
- 新内部事件：`world.internal` 注册表，或 `app-event` + `step-internal`。
- 新插件：写一个模块，顶层 `define-plugin!` + `define-doc-kind!` 等；宿主 `require` 即生效（`plugins-apply` 折进当前 layout）。
- 新拓展层（minibuffer / which-key）：`world.layers` 栈；输入 spec 已随 command 存在。

各层 README 有更细的扩展点列表；`app/README.md` 末尾有“能力评估 / 不冗余审计 / 暂定清单”。

## 命名规约

命名 = **域前缀**（一眼看出属于哪层 / 哪个逻辑部分）+ **动词**（一眼看出做什么）。

| 层 | 前缀 / 名字 | 例 |
|---|---|---|
| base | `face-` | `face-fg` `face-has-attr?` `face-set-bg` |
| theme | `style` `rgb` `define-theme!` | — |
| layout | `tree-` `cut-` `float(s)-` `pane` `lay` | `tree-set-view` `cuts-at` `floats-add` `float-rect-at` |
| command | `key-` `mouse-` `keytable-` `command-` `matcher-` `event->` | `key->string` `keytable-lookup` `event->key` |
| core-render | `render-` `face-fragment` | `render-piece` |
| app：world | `world-` | `world-focus-on` `world-set-drag` `world-overlay-views` |
| app：intent | 名词（`edit` `select` …）+ `modify` | `(edit v op)` `(modify f)` |
| app：面板身份 | `panel-ref` `*-ref` `ref->*` `*->refs` | `leaf-ref` `ref->view` `panels->refs` |
| app：文档类型 | `doc-kind` `buffer-*` `view-*` | `doc-kind->keytable` `buffer-add-keytable!` |
| app：操作原语 | 动词（`mount-` `split-` `focus-` `open-` `show-` …） | `mount-view` `split-left` `focus-insert` `open-overlay` |
| app：循环 | `world-step` `draw-world` `run-app` | — |
| app：插件 | `define-plugin!` `panel-spec` `plugins-apply` | — |

动词约定：

| 语义 | 形式 | 例 |
|---|---|---|
| 构造值 | `make-*` | `make-world` `make-float` |
| 注册 / 定义 | `define-*!` | `define-role!` `define-doc-kind!` |
| 纯转换 | `a->b` | `ref->view` `tree->panels` `event->key` |
| 谓词 | `*?` | `face-has-attr?` `focusable-ref?` |
| 纯 world 转换 | `world-<动词>` / `world-set-*` | `world-focus-on` `world-set-status` |
| 原地写（改既有对象 / 表） | `*!` | `buffer-add-keytable!` `keytable-merge!` |
| 返回 intent 的操作 | 动词（无 `!`） | `split-left` `focus-insert` `quit` |

几条取向：

- **`!` 只标“原地写”**（改既有对象 / 表），不标“造新值”或“返回 intent”。
- **纯 world 转换不带 `!`**（返回新 world）：`world-set-status`、`world-focus-on`、`world-mark-dirty`。
- **`focus-*` = 文档操作**（作用于当前焦点 / 主体 view）；面板焦点是 `focus-on` / `focus-leaf` /
  `focus-panel-move`。
- **`layer.keytable` 是 `keytable`**：“表列表”叫 `keytable`，“对某 buffer 追加的层”叫 `buffer-add-keytable!`。

## 约定

- **后端只吃值**：`piece`（core 渲染值）和 `panel`（布局值）；`screen` 是 core / 宿主内部的事。
- **颜色只在 theme**：布局 / core 只带 face 符号。
- **稳定身份用 ref**：跨帧引用面板用 `panel-ref`，不存每帧重算的 panel / 可替换的 view。
- **行为查注册表**：role、doc-kind、keytable 都是数据表；流程里不写死具体区域 / 类型。
- **入口**：宿主用 `app/api/main.rkt`（或 `app/main.rkt`）；细节实现直接 require `app/*.rkt`。
