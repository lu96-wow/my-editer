# lab-rebuild 架构

`lab/` 的重构版：功能不变，但把三件事显式拆开 —— **核心 / 命令 / 插件**，并把
**可配置状态**收进 `config/`。骨架先立，细节再填。

```
                    core/  （仓库根的编辑器平台，无终端）
                      ↑
lab-rebuild/
  base/        可复用原语（无 app 依赖）
    input.rkt       事件 → 绑定键（依赖 racket-tui 事件类型）
    face.rkt        动态 face（palette-color）+ 分层外观（face-stack），#:prefab
    brackets.rkt    括号配对 + 深度高亮填充（纯，含增量）
    path.rkt        路径小工具（basename）
    layout/         area / split / focus / main（纯几何）
  ui/          view-model（纯，只依赖 core 平台）
    tree.rkt buffers.rkt slot.rkt mode.rkt
  lang/        语言服务（纯：文本 → 文档 / 候选；不认识 app / editor）
    ident.rkt       行 / 光标处标识符 / 补全前缀
    source.rkt      #lang + require 模块路径 + 顶层定义名（启发式，不做展开）
    docs.rkt        标识符 → bluebox（DrRacket 式，不抽 HTML 正文）
    complete.rkt    前缀 → 候选（基础命名空间 + require 导出 + 本地定义）
  core/        ★应用核心：唯一的状态 + 唯一的动作
    state.rkt       app 结构 + 派生量 + layout 缓存 + **钩子**
    panes.rkt edit-panes.rkt paths.rkt
    actions/        唯一改 state / editor 的地方（按域拆）
      core.rkt  tree.rkt  modal.rkt  file.rkt  focus.rkt  lang.rkt
    actions.rkt     聚合出口
  command/     ★命令层
    table.rkt       binding → 命令描述（符号 / (符号 . 参数)），不认识行为
    registry.rkt    命令名 → handler（转发到 core actions + 插件接缝）
    dispatch.rkt    did + 额外表（模态）+ 事件 → 选表 → 跑命令
  plugin/      ★插件层
    attr/           属性插件（后台 place，只写属性、不改文本）
      api.rkt brackets.rkt lex.rkt words.rkt syntax.rkt
      shadow.rkt machine.rkt registry.rkt
      runner.rkt runner-place.rkt worker.rkt manager.rkt
    input/          输入插件（主进程同步，会改文本）
      api.rkt auto-pair.rkt registry.rkt
    seam.rkt        core ↔ 插件层接缝（唯一认识两边的地方）
  config/      ★可配置状态（纯数据 / 参数）
    defaults.rkt    布局默认、初始编辑格尺寸、插件 worker 数 / history bound
    keys.rkt        binding → 命令描述（默认键位表）
    plugins.rkt     启用哪些属性 / 输入插件（只给名字）
    syntax.rkt      关键字表 / 参与高亮的扩展名
    theme/          主题机制 + dark / light + (current-theme)
  app/         装配层（唯一把上面全部接起来的地方）
    app.rkt         init + 事件入口
    render.rkt      每帧准备 + 分隔线 + 补全弹层 + state 行
  backend/tui.rkt   racket-tui：patch → ANSI；读事件
  main.rkt
  smoke*.rkt
```

## 三条主线

### 一、核心 / 命令 / 插件 分开

```
   app 层
     │  装配：cs（键位表）+ plugins（manager）+ hooks
     ▼
  command/  ── 命令名 ──►  core/actions  ──►  editor / state
     │                         ▲
     │  输入插件钩子            │ 关文档钩子（反向）
     ▼                         │
  plugin/input             core/state（hooks）
  plugin/attr  ◄── seam ──►  core/state
```

- **core** 只做「改状态」：`core/actions/*` 是唯一写 `app` / `editor` 的地方。
  core **不认识**命令名、binding、插件实现；需要跨层副作用（如关文档清插件状态）时，
  通过 `core/state.rkt` 的**钩子**（`app-hook-add!` / `app-notify!`）反向通知。
- **command** 把「功能」包成「命名命令」：`table.rkt`（数据）+ `registry.rkt`（行为）+
  `dispatch.rkt`（选择）。键位表只写命令名，命令名与行为在 registry 一处对应。
- **plugin** 分两类：
  - `plugin/attr/`：不碰文本，可丢后台进程算（括号 / 词 / 关键字高亮）。
  - `plugin/input/`：按键同步、会改文本（自动配对）。
  - `plugin/seam.rkt`：唯一同时认识 core 与 manager 的模块。

依赖方向是 DAG：`base → (tui)`、`ui → core`、`core → base + ui`、
`command → base + core + plugin`、`plugin → base + core(平台) + core(state)`、
`config → base`、`app → 全部`、`backend → app + config + plugin`。
`lang` 是纯库（只吃文本 / 模块名），`core/actions/lang.rkt` → `lang`。

### 二、可配置状态集中在 `config/`

以前散落在各处的「可调项」现在只有一处事实源：

| 项 | 位置 | 谁能改 |
|----|------|--------|
| 键位表（binding → 命令名） | `config/keys.rkt` | 改键位 / 换命令名 |
| 启用哪些属性 / 输入插件 | `config/plugins.rkt` | 增删插件（只给名字） |
| 语法关键字表 / 扩展名 | `config/syntax.rkt` | 换语言 / 调色顺序 |
| 布局默认、worker 数、history bound | `config/defaults.rkt` | 调运行参数 |
| 主题（颜色） | `config/theme/` | 换配色 / `(current-theme …)`；槽位在 `slots.rkt` |

要点：
- `config/plugins.rkt` **只给名字**，实现由插件层的目录（`plugin/attr/registry.rkt`、
  `plugin/input/registry.rkt`）解析。于是主进程与后台 worker 读同一份启用集，两边一致。
- 颜色只在 `config/theme/`；插件 / view-model 只产出**逻辑 face**（symbol 或 `palette-color`），
  文档存逻辑 face，不存 RGB。
- 布局算法内在常量（`min-pane-width` / `split-gap`）留在 `base/layout`，不属于可配置状态。

**主题结构（把「能定义颜色的地方」拆开）**：

```
config/theme/
  slots.rkt   所有槽位声明：static-face-slots（13 个 face）/ palette-slots（bracket word keyword）
              / overlay-slots（selection） + build-theme + theme-missing-slots
  dark.rkt    固定颜色表（face-fg / face-bg / default / overlays / palettes）+ build-theme
  light.rkt   同上
  theme.rkt   机制：face / overlay / palette → (fg bg)
  main.rkt    汇总 + (current-theme)
```

- 色值全是**固定字面量**（`#f` = 该维不设 / `(r g b)`），运行时不做任何颜色计算。
- 要加一个可配色的 face / 色板：在 `slots.rkt` 加一行，两个主题补上颜色；
  `smoke-theme.rkt` 会检查「两主题覆盖全部槽位」。
- `cursor` 由后端按反色处理，不做主题槽位；`line-number` 由 core 发出，`selection` 由 core 发出。

### 三、事件 → 命令 → 动作

```
backend/tui  read-event
  → app-handle-input  (resize / mouse 先分流)
     → app-dispatch!
         前缀模式：dispatch-run-direct（只看该前缀的表，不回落）
         否则：   dispatch-run cs did (mode-tables m …) ev app
                   → command/table 选出「命令描述」
                     → command/registry 解释成 handler
                       → core/actions 改 state / editor
```

- 「当前是谁」= did（不是焦点）：树 / 文档列表 / 状态栏各有自己的 did 表，编辑文档用全局表。
- 模态（输入 / 确认 / 前缀）是 dispatch 的**额外表**，不是偷偷换 command-set。
- 后缀兜底：prompt 焦点跑掉就取消；焦点落在编辑 leaf 就设为 active；再 tick 插件。

### 编辑 → 插件 → 属性

```
编辑命令 editor-view-*!  → 返回 core 的 change
  command/registry 把 change 交给 plugin/seam 的 plugin-note-change!
    → manager.pending 存 (l0 c0 l1 c1 inserted)
app-prepare! → app-plugin-tick!（seam）
  manager-sync!  按 document 版本 token 派活（新版本才发；发 diff 不发整篇）
  manager-poll!  结果回来，token 仍是当前版本 + 全插件到齐 才写回
    → 逐格 face-compose 叠层 → 文档高亮轨（括号背景 + 语法前景共存）
```

**钩子**：`core/actions/core.rkt` 的 `app-forget-document!` 在清理 core 资源后
`(app-notify! a 'document-closed did)`；`plugin/seam.rkt` 在装配时用
`app-hook-add!` 把 `manager-forget!` 挂上去。于是 core 不 require 插件层。

### 语言服务（文档查询 / 补全）

只做两件事，**不做 LSP、不做诊断 / 纠错**；数据管线参照 racket-langserver，但
只取它“查文档 / 给候选”那部分，按 lab 的分层重写：

```
光标/前缀  lang/ident + lang/source ─► lang/docs | lang/complete
                                           │
                       core/actions/lang.rkt（开 *docs* 缓冲 / 进 complete 模态）
                                           │
                       command/registry（命令）/ config/keys（键位）
```

- **文档查询**（`C-p d`）：取光标处标识符，用 `setup/xref` 按「(候选模块, 名字)」
  反查定义 tag（会跟到 re-export 的原始定义），再取 `scribble/blueboxes` 的字符串
  （类别 + 签名 / 契约）。**照 DrRacket 的做法：只展示 bluebox**，不抓文档 HTML、
  不剥 markdown（所以查文档不联网、不依赖 racket-langserver，首次数十毫秒）。结果在
  光标**下一行的浮窗**显示（`docs` 模态，`app/render.rkt` 的 `app-docs-panes`）：
  Enter/Esc 关，上下 / PageUp·PageDown 滚。
- **补全**（`Tab`，`Ctrl+N` / `C-p c` 同效）：前缀来自 `lang/ident`，候选 = 基础命名空间 + 各
  require 导出（`module->exports`，按模块缓存）+ 文件顶层定义名（`lang/source` 启发式扫描），
  过滤排序。上下选择、Tab/Enter/右 接受、Esc 取消；继续打字/退格会实时重算（前缀空则退出）。
  选中项的 bluebox 文档展在菜单**下侧**（同一个实线框，中间一条分隔线）；菜单 / 文档都是
  高 deep 的装饰 pane，不占布局、不动焦点。
- 两个浮层都是**高 deep 的装饰 pane**（`app/render.rkt` 的 `app-complete-panes` /
  `app-docs-panes`，由 `app-overlay-panes` 汇总），不占布局、不动焦点、不碰 editor，
  只改 `mode`（`complete` / `docs`）；都用 box-drawing 实线框（`frame-pane` / `box-line`）。
- **候选模块**由 `lang/source` 估出来（`#lang` 语言 + 顶层 `(require …)`，剥掉
  `only-in` / `prefix-in` / `for-syntax` 等包装，相对字符串路径按文档所在目录解析）；
  不做宏展开，因此白盒 / 生成名可能漏，但普通文件够用。
- **依赖**：只用 Racket 自带的 `setup/xref` / `scribble/xref` / `scribble/blueboxes`；
  不依赖 racket-langserver（只借鉴了它 / DrRacket 的思路）。

## 关键约定

- **一个事实只存一处**：pane 身份在 `core/panes`、路径在 `core/paths`、模态在 `app.mode`、
  布局在 `app.layout`、命令名对应行为在 `command/registry`、可调项在 `config/`。
- **改 layout 输入必须走 `core/state.rkt` 的 setter**（否则缓存过期）。
- **渲染前必须走 `app-prepare!`**（刷 state 槽位 + 取窗格）；增量后端也不能绕。
- **动作只在 `core/actions/`**；`command/registry.rkt` 只做「功能 → 命令」转发；
  `config/keys.rkt` 只做「binding → 命令名」。
- **core 不 require command / plugin**（反向用钩子 + seam）。
- **插件不改 text**；只写属性轨，且必须过 manager 的版本闸门。
- **前缀键**：`mode` 用 `#f | prompt | prefix | complete | docs` 表达输入转移态；前缀下一键
  只查它自己的表（不回落 normal）；
  处理完若还是同一个前缀就退出，否则保留 → 支持任意嵌套。
- **命令描述**统一 `(event app . args) -> any`；前缀表里放命令名（不是裸 lambda）。

## 跑 / 测

```
racket lab-rebuild/main.rkt [根目录]
racket lab-rebuild/smoke.rkt         # base / command / ui 协议
racket lab-rebuild/smoke-plugin.rkt  # 插件层（含后台 place runner）
racket lab-rebuild/smoke-bracket.rkt # 括号增量 vs 全量（随机）
racket lab-rebuild/smoke-app.rkt     # 集成（无终端）
racket lab-rebuild/smoke-state.rkt   # state 行增量更新回归
racket lab-rebuild/smoke-lang.rkt    # 语言层（ident / source / docs / complete）
racket lab-rebuild/smoke-lang-app.rkt # 语言服务集成（补全 / 文档）
raco test lab-rebuild                # 全部（含 state / theme 回归）
```

## 左栏开 / 关（`Ctrl+B`）

`app` 增加 `sidebar?`：`#f` 时 `compute-layout` 的左栏宽为 0、主区占满整宽；
`app-main-w` 也随 `sidebar?` 变宽（state 行 padding 跟着变）。

`Ctrl+B` → `toggle-sidebar`（`core/actions/focus.rkt` 的 `app-toggle-sidebar!`）：
- 焦点在左栏 → 关掉，焦点移到当前编辑窗格（**没有编辑窗格则置空**，不放到底部槽）；
- 左栏已关 → 打开并聚焦左栏。

旧的 `Ctrl+O`（左右栏焦点切换）已删除；焦点移动用 `C-p` 前缀 + 方向键，
或 `Ctrl+B` 连带（开→聚焦左栏，关→回编辑格）。

## 与 lab 的差异一览

| # | lab | lab-rebuild |
|---|-----|-------------|
| 1 | 命令表直接存 handler lambda | 表存**命令描述**；行为在 `command/registry` |
| 2 | `app/commands.rkt` 与 `keys/` 都在 app | 拆成 `command/`（行为 + 派发）与 `config/keys.rkt`（数据） |
| 3 | 插件清单硬编码在 `plugin/registry.rkt` | 启用集在 `config/plugins.rkt`（名字），目录在插件层 |
| 4 | 输入插件在 `app/input-plugins.rkt` | 独立 `plugin/input/`（api + auto-pair + registry） |
| 5 | core 动作直接调 `app-plugin-forget!` | core 只 `app-notify!`，`plugin/seam` 挂钩子 |
| 6 | 主题在顶层 `theme/` | 收进 `config/theme/` |
| 7 | 语法关键字表写死在 `plugin/syntax.rkt` | 移到 `config/syntax.rkt` |
| 8 | `history-bound` / worker 数写死 | `config/defaults.rkt` |

## state 行增量更新

底部 state 行（焦点 / 行列 / 文件名）以前每变一次就 `state->document` 重建整篇 +
`editor-view-assign!`。现在 `app/render.rkt` 只算 old→new 的**最小 diff**：

1. 公共前缀 / 后缀 → 旧中间段与 `new-mid`；
2. 选中旧中间段，`editor-view-insert-ignore-readonly!` 插 `new-mid` 替换（空 = 纯删）；
3. 只给**新插入**的字符补 `state` face + 只读（其余格随编辑平移）；
4. `editor-view-clear-history!`（状态栏不进撤销栈）；
5. `editor-view-set-left-column! / -top-line!` 钉回 0。

第 5 步是必须的：插字后光标落在行尾（列 = 宽度），`editor-view-insert-ignore-readonly!`
内部的 `ensure` 会把 `left-column` 推到 1 —— 渲染就从第 2 列开始，`tree/edit` 变成 `ree/dit`。
state 行是展示槽，永远钉在左上角。

回归在 `lab-rebuild/smoke-state.rkt`（长度 / 整行只读 / 整行 face / undo 不变）。

## 还没动（以后）

- `base/input.rkt` 仍直接依赖 racket-tui 的事件类型（换后端要改这里）。
- 绑定词表把可打印字符塌成 `'text`，y/n 仍要回看原始 event（`cmd-answer`）。
  要彻底解决需给绑定加「按字符」形态。
- `size-warning` 仍未显示。
- prompt 单槽（要嵌套再改栈）。
