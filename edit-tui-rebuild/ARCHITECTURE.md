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

### 7.1 全景表

| 想扩展 | 加什么数据 | 谁消费 | 触发时机 |
|---|---|---|---|
| 命令 | `env.commands` | `dispatch/run-command` | 键 / 鼠标命中 |
| 键位 / 前缀 | `env.keymaps`、`env.modes[].keymaps` | `dispatch/rules` | 按键 |
| 有条件的键表 | `env.rules`（`scope` + keymap）、`env.scopes` | `dispatch/rules` | 按键（**用规则，别覆盖 `global` 表**） |
| 按键的临时语义 | `env.keymaps[name]` + `state.input.modes` | `dispatch/rules` 第一层 | 模态开着时 |
| 文档类型 → mode | `env.doc-types`（路径匹配） | `effects/interpreter` | 打开文件 |
| 区域行为 | `env.roles`（splittable? / close-policy / focusable? / target? / switchable?） | 命令 + 派发 | 关闭 / 切分 / Tab / placement |
| 面板 | `plugin.panels`（`panel-spec`） | `effects/panel` + `env.panel-syncs` | 装配 / 每帧 |
| 同一位置多个面板 | 多次 install 传同一个 `region-id` | `panel-region-add!` + `switch-member` | Tab |
| 每帧刷新面板 | `panel-spec.sync`（自动进 `env.panel-syncs`） | `runtime/run-frame` | 每帧 |
| **旁观者逻辑** | `plugin.hooks`（`hook`） | `dispatch/hooks.rkt` | 信号出现时 |
| 状态栏段 | `plugin.status-parts`（追加语义） | `projection/status` | 每帧投影 |
| 输入栏提交 | `env.input-commands`（字符串匹配） | `chrome/input` | 输入栏 Enter |
| 插件自己的状态 | `state.store` + `plugin-state*` | 插件自己 | — |
| 给文本上色（**一层** face） | `set-face-layer-effect doc layer fills` | `engine-set-face-layer!`（合成后写回 core） | 命令 / hook 发 |
| 层的顺序 | `env.face-layers`（先低后高） | `runtime/startup!` 交给引擎 | 启动 |
| 后台纯计算 | `submit-service-effect job kind payload` | `runtime/worker.rkt`（独立 place） | 命令 / hook 发 |
| 替换一段文本 | `replace-range-effect view range text` | `effects/interpreter` | 命令 / hook 发 |
| 布局变了夹光标 | `ensure-view-effect view` | `effects/interpreter`（core `view-ensure!`） | 命令 / hook 发 |
| 浮窗 | `workspace.floats`（region + view，不在 layout 里）+ `projection/float.rkt` | `projection/render`（作为 deep 更高的 panel） | 每帧 |

### 7.2 不存在的扩展点（曾经有 / 考虑过，结论是不加）

| 曾经的诱惑 | 结论 |
|---|---|
| `env.handlers`（`internal` 事件 → 过程） | **删掉**：内部事件 / `tick` 直接发信号（point = 事件名 / `tick`），和 `env.hooks` 用同一张表 —— 两个“事件 → transition”的注册表没必要 |
| 插件专用的 `decor` / `highlighter` 注册表 | 不需要：高亮 = 「`after-edit` hook + `set-faces-effect`」 |
| 插件专用的 `completion` / `popup` API | 不需要：浮层 = `workspace.floats` + 一张临时 keymap |
| `panel-spec.id` | **删掉**：没人读；面板身份由 `name / role / mode` 表达 |
| `environment-add-rules` | **删掉**：没有调用者（“为对称而对称”的 API 也是负担） |

### 7.3 回调只有三种，各有触发源

| 注册表 | 形状 | 触发 | 纯度 |
|---|---|---|---|
| `env.hooks` | `(state engine-view args -> transition)` | 信号（`standard-signal-points`） | 纯（可发 effect） |
| `env.panel-syncs` | `(state engine -> any)` | 每帧渲染前 | **不纯**（直接写 core 缓冲） |
| `env.rules` | `scope + keymap` | 按键 / 鼠标 | 纯（查表） |

`panel-syncs` 单独存在的理由：它每帧都跑、且直接写 core，不是“发生了一件事”的旁观逻辑。
暂定：以后若要再收敛，可以让 runtime 每帧发 `before-render` 信号，把面板同步改成
`set-text-effect` / `set-faces-effect`（纯 hook + effect）。

### 7.4 face 分层与后台计算

| 概念 | 位置 | 约定 |
|---|---|---|
| face 分量 | `edit-tui/base/face.rkt`（fg / bg / attrs） | 插件只写自己那一分量 |
| 层的合成 | `model/face-layer.rkt` 的 `compose-layers` | 逐分量合并；同分量后层覆盖；attrs 并集 |
| 层序 | `env.face-layers` | 先低后高；由 `startup!` 交给引擎 |
| 后台服务 | `plugins/worker.rkt` 的 `service-run` | **纯**：只吃 payload、吐结果；payload/result 必须可跨 place |
| 跨进程载荷 | `submit-service-effect` | 不能带 core 的不可序列化值（如版本 token）；用 job-id 对账过期结果 |
| 一个 worker 一条队列 | `runtime/worker.rkt` | 多个插件按提交顺序执行（同一文档的层顺序稳定） |

### 7.5 命名与对称

| 规则 | 例子 |
|---|---|
| `environment-add-X` / `-add-Xs` 成对，但**只导出有调用者的** | `add-hook(s)`、`add-status-part(s)`、`add-panel-sync(s)`；`add-rules` 已删 |
| 状态结构 vs 投影结果 | `region` / `region-panel`，`float` / `float-panel` |
| effect 用动词短语 + `-effect` | `set-text-effect`（整篇设）、`replace-range-effect`（动作）、`ensure-view-effect` |
| engine 的原地写带 `!` | `engine-create-view!`、`engine-ensure-view!`、`panel-region-add!` |
| hook 的 `when` 与 `proc` **同签名** | 都是 `(state engine-view args)`：gate 与动作看到同一份数据 |
| 信号点：过去式 / 发生后 | `document-opened`、`after-edit`、`after-nav`、`focus-changed`；internal 事件名即 point |
| 不能和 `racket/base` 撞名 | `member` → `region-member`（见 §8.6） |

### 7.6 加扩展点前的检查清单

1. 已有注册表能不能表达？（高亮 / 补全 / 文档三个插件全部用已有注册表，没加新表）
2. 新表是否只是“另一种触发时机”？→ 统一到 `env.hooks` 或 `env.panel-syncs`。
3. 新字段有人读吗？（`panel-spec.id` 这种就是负担）
4. 名字会被 `struct-out` 带出去掩盖基础函数吗？
5. 加了以后 `test/layers.rkt`（层序 / 副作用白名单 / 头声明）还能过吗？

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

### 8.6 命名：不要和 `racket/base` 撞名

`(struct-out ...)` 会把构造函数导出到所有 require 它的模块里，撞名会**静默改变语义**：

| 曾经的坑 | 现在 |
|---|---|
| `(struct member (kind key))` → require 的模块里 `(member x lst)` 变成了结构构造器（恒真） | 改名 **`region-member`**（`region-member-key` / `region-member?`） |
| `(struct region ...)`（workspace）与 core 的 `screen` 的 `region` | `projection/render.rkt` 用 `(only-in ... screen? screen-width ...)` 显式收窄 |

新加 struct 前先确认名字没被 `racket/base` / 平台层占用；宁可长一点
（`region-member`、`signal-point`），也不要让“看起来是基础函数”的名字被遮蔽。

### 8.7 文档元数据

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
