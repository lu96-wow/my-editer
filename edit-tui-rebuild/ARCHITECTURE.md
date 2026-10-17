# edit-tui-rebuild 架构

> 这份文档只描述**现在**的分层与边界；为什么这样设计见 `DESIGN.md`。
> 所有规则都由 `test/layers.rkt` 机器检查，写在这里是因为人读得比测试快。

## 1. 一条数据通路

```
终端事件
  │  runtime/tui-adapter.rkt（纯适配）
  ▼
base/event.rkt
  │  dispatch/pipeline.rkt（纯）
  │    subject 解析 + 规则层序（dispatch/rules.rkt）+ command 查找
  ▼
command(ctx) ──► transition{ state', effects }
  │                        │
  │                        │ effects/interpreter.rkt（IO）
  │                        │ effects/engine.rkt（core 写）
  ▼                        ▼
state'  ──────────────────  engine（可变，唯一）
  │
  │  projection/geometry → projection/render（纯，读 state + engine-view）
  ▼
bytes ──► runtime/run.rkt（唯一 put-bytes）
```

渲染前的每帧同步（写 core buffer 的那些）由 `environment.panel-syncs` 驱动，
runtime 只负责遍历，不认识任何具体面板。

## 2. 层序（依赖只能往下）

| 层 | 目录 | 内容 | 允许依赖 |
|---|---|---|---|
| 0 | `base/` | id / event / effect / transition / keymap / status-part | 自己 |
| 1 | `model/` | state / workspace / layout / input / chrome / save | 0–1 |
| 2 | `env/` | environment / role / mode / scope / command / rule / doc-type / input-command / plugin / defaults | 0–2 |
| 3 | `effects/` | engine（core 拥有者）/ panel（面板↔引擎）/ interpreter（IO） | 0–1, 3 |
| 4 | `projection/` | geometry / status / render | 0–4 |
| 5 | `dispatch/` | context / rules / pipeline | 0–5 |
| 6 | `chrome/` | slot（status/input 槽）/ input（输入栏 API） | 0–6 |
| 7 | `bootstrap/` | panel（spec→install）/ commands/* / defaults（core-env） | 0–7 |
| 8 | `plugins/` | filetree/ + resource/ + builtin（default-env） | 0–8 |
| 9 | `runtime/` | run / tui-adapter | 全部 |
| — | `main.rkt` | 公共面（只 require/provide） | 全部 |

两条跨层例外，都是**词汇**而不是实现：

- `edit-tui/command/{key,mouse,command}.rkt`：token 与 command 结构，任何层都可以 require；
- `edit-tui/core-render/`、`core/`：见下面白名单。

## 3. 有副作用的模块（白名单）

其余所有模块必须是纯的（`world-step` 可 headless 重放）。全部副作用只有 8 处：

| 模块 | 副作用 |
|---|---|
| `effects/engine.rkt` | core buffer / view 的唯一可变拥有者（create / remove / apply） |
| `effects/panel.rkt` | 面板的 core 对象创建/销毁、写面板 buffer（`panel-sync-buffer!`） |
| `effects/interpreter.rkt` | 文件读写、文档开关、保存、退出 |
| `chrome/slot.rkt` | 安装 status/input 两个 core view + 每帧写 status buffer |
| `plugins/filetree/scan.rkt` | 读目录（`directory-list` / `file-exists?`） |
| `plugins/filetree/commands.rkt` | 建/删文件前存在性检查（写盘本身发 effect） |
| `plugins/*/panel.rkt` | 写各自面板的 buffer |
| `runtime/run.rkt` | 终端 IO、`spawn` / `timer` 线程、`put-bytes` |

`core/...` 只允许出现在：`effects/engine.rkt`、`effects/panel.rkt`、
`projection/{geometry,render}.rkt`、`bootstrap/commands/{table,focus}.rkt`、`runtime/run.rkt`。

`tui` / `read-event` / `put-bytes` / 线程只允许出现在 `runtime/run.rkt`。

## 4. 状态归位

```racket
(struct state (window workspace input chrome runtime ids confirm store))
```

- `workspace` 里放**框架级**的会话信息：docs / views / regions / layout / focus /
  `root`（工作区根，状态栏按它投影相对路径）/ `placement`（等待放进 panel 的 view）；
- `focus` 可以是 `view-id` 或 `region-id`：切分（`C-w ←→↑↓`）拆出的是**空 region**，
  焦点落在 region 上，下一次开文档就装进去；
- `confirm` 是保存确认队列（quit / close-doc 用，属于框架）；
- region 是“一块位置里可切换的成员”：sidebar / chrome 槽都是多成员 region，
  `active` 决定显示谁，`role.switchable?` 决定 Tab 能不能切；
- `store` 是插件命名空间：`store['filetree]`、`store['resources]` …
  面板自己的 UI 状态都在这里，拔掉插件就跟着消失；
- 文档是不是“基础设施”（状态栏 / 输入栏 / 插件面板）由 `doc-meta.internal?` 声明，
  框架不再维护 “哪些 mode 是 chrome” 的字面量列表。

## 5. 信号与钩子

```
command ──▶ transition{state+effects}
              │
              │  runtime: 1) 解释 effect（文本落地、发信号）
              ▼
          信号队列 ──▶ hook（priority 降序，纯：state engine-view args -> transition）
              │
              ▼  hook 又可加 effect / emit 信号 -> 再来一轮（上限 8）
```

- 信号点：`document-opened` / `after-edit` / `after-nav` / `focus-changed`；
- **hook 在 effect 解释之后跑**（`runtime/run.rkt` 的 `settle`），所以读到的是新文本；
- hook 的 proc 拿只读 `engine-view`，与命令的 `ctx.engine` 同源，不能写 engine。

## 6. 两条“不留后遗症”的派发规则

- **未命中就丢 pending**：`C-x` 后按未绑定键 -> 清空前缀、报告完整序列、不插入字符；
- **消息只活到下一次动作**：按键 / 粘贴 / 鼠标按下抬起会先清 `chrome.message`，
  移动 / resize / 内部事件不清。提示不会常驻状态栏。

两条都在 `dispatch/pipeline.rkt`，`test/dispatch.rkt` + `test/runtime.rkt` 覆盖。

## 7. 扩展点（都是数据）

| 想加的东西 | 加在哪 |
|---|---|
| 命令 | `env.commands` |
| 键位 / 前缀 / 全局键 | `env.keymaps` 或 `env.rules`（**规则**，别覆盖 `global` 表） |
| 条件键表 | `env.rules` + `env.scopes` |
| 文档 mode / 按扩展名匹配 | `env.modes` + `env.doc-types` |
| 状态栏段 | `plugin.status-parts`（追加语义） |
| 输入栏提交 | `env.input-commands` |
| 区域行为 | `env.roles`（splittable? / close-policy / focusable? / target?） |
| 面板 | `plugin.panels`（`panel-spec`）+ 宿主调 `panel-spec-install!` |
| 同一位置放多个面板 | 多次 install 传同一个 `region-id`；`Tab`（`switch-member`）切 active |
| 插件自己的状态 | `state.store` + `plugin-state*` |
| 每帧同步 | `panel-spec.sync`（自动进 `env.panel-syncs`） |
| 旁观者逻辑（改完文本要重算什么） | `env.hooks`：`hook {point, when, priority, proc}` |
| 给文本上色 | `set-faces-effect doc fills` |
| 替换一段文本（补全） | `replace-range-effect view range text` |
| 把光标夹回窗口（布局刚变） | `ensure-view-effect view` -> core 的 `view-ensure!` |
| 浮层弹窗 | `workspace.floats`（region + view，不在 layout 里）+ `projection/float.rkt` → 作为 `deep` 更高的 panel 交给 core；**所有显示都是 document**，擦除由 core 的 diff 负责 |
| 临时改变按键含义 | `state.input.modes` 挂一张 keymap（最高规则层） |

## 8. 约定（不变量）

这些是代码里靠不住的“口头约定”，现在都写在这里；能做成数据的已经做成数据。

### 8.1 信号与钩子

| 约定 | 在哪 |
|---|---|
| 标准信号点只有 `document-opened` / `after-edit` / `after-nav` / `focus-changed` | `base/signal.rkt` 的 `signal-points`（数据，可查） |
| **hook 只在 `settle` 里跑**（effect 解释之后），`dispatch` 不跑 | `runtime/run.rkt`、`dispatch/pipeline.rkt` 注释 |
| 同一 `point` 按 `priority` 降序；同 priority 按注册顺序（稳定排序） | `dispatch/hooks.rkt` |
| hook 可以再 emit；多轮直到队列空，上限 8 轮（防自激） | `dispatch/hooks.rkt` 的 `max-rounds` |
| hook 的 `proc` 拿**只读** `engine-view`（与命令的 `ctx.engine` 同源），写 engine 必须发 effect | `env/hook.rkt` |
| effect 顺序：命令的在前，hook 的在后 | `dispatch/hooks.rkt` 的 `loop` |

### 8.2 什么算“一次编辑”

| 写 | 发 `after-edit`？ |
|---|---|
| `edit` / `insert` / `undo` / `redo` / `replace-range` | ✅ |
| `set-text-effect`（整篇展示替换：状态栏 / 面板 / 浮层） | ❌ |
| `set-faces-effect`（上色） | ❌（否则 hook 自激） |

实现在 `effects/interpreter.rkt` 的 `edit-write?`；补全插件额外按 doc 过滤一次。

### 8.3 显示一律用 document

| 显示物 | 实现 |
|---|---|
| 编辑器 / 文件树 / 资源列表 / 文档面板 | region + view（buffer 支撑） |
| 状态栏 / 输入栏 | 同一个 region 的两个 view（chrome 槽） |
| 补全浮层 | **不在 layout 里的 region + view**（`workspace.floats`） |

所以：**没有“额外绘制”的 UI**。要显示新东西就建 document，用
`set-text-effect` / `set-faces-effect` / `select-effect` 写它。

### 8.4 浮层（`workspace.floats`）

- 是 region + view，**不进 layout 树**；
- 每帧由 `projection/float.rkt` 按 anchor view 的光标算矩形，作为 `deep 1` 的 panel 交给 core；
- 鼠标命中**先查浮层**（`runtime/run.rkt` 的 `subject-for`），不会穿透到下面的编辑器；
- role 用 `'panel`（不可聚焦）→ 焦点始终留在编辑器；上下键靠**临时键表**接管；
- 因为它是真的 panel，擦除 / 遮挡 / 移动全由 core 的增量 diff 负责。

### 8.5 布局变化后的光标夹取

- `engine-sync-view!` 在尺寸**真的变了**之后调用 core 的 `view-ensure!`（自动）；
- 需要立刻夹（例如刚打开底部面板）时发 `ensure-view-effect`；
- 只在尺寸变化时 ensure，所以用户主动滚动不会被抢回来。

### 8.6 文档元数据

- `doc-meta.internal?` = 基础设施文档（chrome / 面板 / 浮层）：不保存、不进资源列表、
  不能当 placement 目标、不上色；
- 由创建方声明（`effects/panel.rkt` 的 `panel-create-view!` 默认 `#t`），
  框架不维护“哪些 mode 是 chrome”的字面量列表。

## 9. 约束怎么保证

`test/layers.rkt` 检查四件事，任何一条破了就红：

1. 每个模块开头有 `;;; layer  :` 与 `;;; effect :` 声明；
2. `(require ...)` 的边符合第 2 节的层序；
3. `core/` 与文件系统 IO 的模块在白名单里；
4. `tui` / 线程只出现在 runtime。

另外 `test/plugin-detach.rkt` 保证 `core-env` 里没有任何插件痕迹：
只用框架也能编辑 / 切分 / 关闭 / 保存确认 / 退出。
