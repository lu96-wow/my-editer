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
- `confirm` 是保存确认队列（quit / close-doc 用，属于框架）；
- region 是“一块位置里可切换的成员”：sidebar / chrome 槽都是多成员 region，
  `active` 决定显示谁，`role.switchable?` 决定 Tab 能不能切；
- `store` 是插件命名空间：`store['filetree]`、`store['resources]` …
  面板自己的 UI 状态都在这里，拔掉插件就跟着消失；
- 文档是不是“基础设施”（状态栏 / 输入栏 / 插件面板）由 `doc-meta.internal?` 声明，
  框架不再维护 “哪些 mode 是 chrome” 的字面量列表。

## 5. 扩展点（都是数据）

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

## 6. 约束怎么保证

`test/layers.rkt` 检查四件事，任何一条破了就红：

1. 每个模块开头有 `;;; layer  :` 与 `;;; effect :` 声明；
2. `(require ...)` 的边符合第 2 节的层序；
3. `core/` 与文件系统 IO 的模块在白名单里；
4. `tui` / 线程只出现在 runtime。

另外 `test/plugin-detach.rkt` 保证 `core-env` 里没有任何插件痕迹：
只用框架也能编辑 / 切分 / 关闭 / 保存确认 / 退出。
