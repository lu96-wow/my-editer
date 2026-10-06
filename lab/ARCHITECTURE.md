# lab 分层与插件化改造笔记

> 目标：把 lab 做成「核心命令平台 + 插件」。本文先给出现状分层、核心/插件判定，
> 再列出**核心与插件混在一起的具体位置**，最后给出目标架构与改造路线。
>
> 对照物：Emacs。
>   - 编辑器引擎（text/buffer/overlay/redisplay）= 根目录 `core/`
>   - 命令循环 / keymap / minibuffer / hook / mode = 平台骨架
>   - 内置命令 = 核心命令
>   - font-lock / completion-at-point / eldoc / electric-pair / dired = 插件（内置包）

---

## 0. 结论速览

- 根目录 `core/`（编辑器引擎）已经是干净的核心，`lab` 不应该往里塞任何业务。
- `lab` 内部大体分了层，但**语言服务（补全 / 文档）被硬编码进了核心平台**，是当前最大的混乱源。
- 属性插件（attr）和输入插件（input）协议已经成型，但**注册是写死的目录**，且派发点埋在核心命令里。
- 文件树、文档列表实际上是「内置包（dired/ibuffer）」，现在放在 `ui/` + `core/actions/`，被当成核心。
- 平台缺少通用扩展点：命令注册、keymap 注册、mode 注册、hook、overlay provider、completion provider、异步 job。

一句话：**引擎层最干净；平台层缺扩展点；语言服务是"伪装成核心的插件"；attr/input 是真插件但接得很死。**

---

## 1. 现状分层图

| 层 | 目录 | 职责 | 现在的定位 |
|---|---|---|---|
| L0 编辑器引擎 | `core/`、`core-test/` | 文本 / document / selection / history / view / patch / screen / attributes | 纯核心（正确） |
| L1 平台骨架 | `lab/base/`、`lab/ui/mode.rkt`、`lab/ui/slot.rkt`、`lab/core/{state,panes,paths,edit-panes}.rkt`、`lab/command/table.rkt`、`lab/command/dispatch.rkt`、`lab/app/`、`lab/backend/tui.rkt` | 布局 / 输入协议 / face / 命令表机制 / 派发 / 应用状态 / 模态 / 事件循环 / 终端 I/O | 应是核心平台 |
| L2 内置命令 | `lab/core/actions/{core,file,focus,tree,modal}.rkt`、`lab/command/registry.rkt` | 打开/关闭/分屏/保存/退出/焦点/文件树动作/prompt | 核心命令（可接受，但含插件耦合） |
| L3 内置包（伪核心） | `lab/lang/`、`lab/core/actions/lang.rkt`、`lab/ui/tree.rkt`、`lab/ui/buffers.rkt` | 补全 / 文档 / 文件树面板 / 文档列表面板 | **应拆成插件**，目前混在核心 |
| L4 插件 | `lab/plugin/attr/*`、`lab/plugin/input/*`、`lab/plugin/seam.rkt` | 高亮（font-lock 类）/ 输入改写 / 接缝 | 真插件，但注册写死、派发点埋在核心 |
| 配置 | `lab/config/{keys,plugins,syntax,defaults}.rkt`、`lab/config/theme/*` | 键位 / 启用插件 / 主题 / 关键字表 | 配置层（部分属于某个插件） |

---

## 2. 逐目录判定：核心 还是 插件

### 2.1 编辑器引擎 —— 纯核心（保持）

```
core/
  editor.rkt           入口
  editor/{state,command,query,attributes,change,render,layout,sync,history,view}.rkt
  text/{document,command,rebase}.rkt  text/base/*  view/{base,project,patch,compose}.rkt
```

这是 Emacs 的「C 核心 + redisplay」。`editor-document-handle-set-highlight!` /
`...-highlight-compose!` 是暴露给插件写属性的核心扩展点，方向正确。**不放任何 app/业务。**

### 2.2 平台骨架 —— 应是核心平台

| 文件 | 角色 | Emacs 对应 |
|---|---|---|
| `base/layout/*` | 窗口切分 + 几何焦点 | 窗口/frame 布局 |
| `base/input.rkt` | racket-tui 事件 → 绑定键 | 事件 → key 解析 |
| `base/face.rkt` | face / palette-color / face-stack 值 | face 属性契约 |
| `base/wrap.rkt`、`base/path.rkt` | 文本/路径小工具 | 工具函数 |
| `ui/slot.rkt` | 底部槽位文档 | minibuffer 显示 |
| `ui/mode.rkt` | `prompt` / `prefix` 模态 | minibuffer / prefix 状态 |
| `core/state.rkt` | 应用状态唯一源 + 钩子 | buffer-local/global 状态、hooks |
| `core/panes.rkt`、`core/edit-panes.rkt`、`core/paths.rkt` | pane 身份 / 分屏树 / did↔path | window / buffer 注册表 |
| `command/table.rkt` | binding → spec 表机制 | keymap |
| `command/dispatch.rkt` | 按 did/mode 选表并执行 | command loop 查 keymap |
| `app/app.rkt` | 装配 + 事件入口 | `startup.el` / init |
| `backend/tui.rkt` | screen patch → ANSI，读事件 | terminal backend |

### 2.3 内置命令 —— 核心命令（可接受）

`core/actions/core.rkt`（打开/关闭/显示/分屏/列表刷新）、`file.rkt`（保存/退出/尺寸）、
`focus.rkt`（焦点/左栏）、`modal.rkt`（前缀/prompt）、`tree.rkt`（文件树动作）。
这些是「编辑器的基本交互」，属于核心命令没有争议。问题是它们在 `command/registry.rkt`
里和插件派发搅在一起（见 §3）。

### 2.4 混进核心的「插件」

**（a）语言服务 = 补全 + 文档，是一个完整功能，被硬编码进核心**

- `lang/complete.rkt`、`lang/docs.rkt`、`lang/source.rkt`、`lang/ident.rkt`：纯逻辑，本身很干净。
- `lang/doc-runner.rkt`、`lang/doc-worker.rkt`：异步文档查询 place。
- `core/actions/lang.rkt`：把上面接到 app（`app-complete-*` / `app-show-docs!`）。
- `ui/mode.rkt` 里的 `complete` / `docs` 结构体：**功能状态寄生在核心模态文件里**。
- `app/render.rkt` 里的 `app-complete-panes` / `app-docs-panes`：**功能浮层画在核心渲染里**。
- `config/keys.rkt` 里的 `complete-keys` / `docs-keys`：**功能键表写在核心键位里**。
- `backend/tui.rkt` 注册 `app-lang-source`：**功能异步源接在后端**。

在 Emacs 里，对应的是 `completion-at-point-functions` + `eldoc` + 一个补全 UI 包（company/corfu）。
现在等于把 company 的内部结构塞进了 `keyboard.c` 和 `xdisp.c`。

**（b）文件树 / 文档列表 = 内置包（dired / ibuffer）**

- `ui/tree.rkt` + `ui/buffers.rkt`：面板 view-model。
- `core/actions/core.rkt` / `tree.rkt`：面板动作。
- `config/keys.rkt` 的 `tree-keys` / `bufs-keys`：面板键表。
- `app/app.rkt` 的 `app-init` 直接建 `*tree*` / `*buffers*` 两个内部文档。

这些放在 `ui/`/`core/` 会被误当成平台。应迁到 `builtin/`（内置包），只依赖平台的「面板注册 + 键表 + 动作」扩展点。

**（c）单个插件自己的配置散落在核心 config**

- `config/syntax.rkt`（`keyword-list` / `racket-exts` / `racket-file?`）是 **syntax 插件专属配置**，却放在核心 `config/`。
- `base/brackets.rkt`（配对/嵌套深度算法，173 行）只被 bracket 插件使用，却放在核心 `base/`。
- `config/theme/slots.rkt` 把插件色板（`bracket`/`word`/`keyword`）和核心 face 混在同一张清单里。

### 2.5 插件层 —— 已成型

**属性插件（font-lock 类）**：`plugin/attr/`

- `api.rkt`：`plugin = (name open change)` 纯函数协议（好）。
- `manager.rkt`：版本 token、增量、结果缓存、版本闸门、face 合并（好）。
- `runner.rkt` / `runner-place.rkt` / `worker.rkt` / `machine.rkt` / `shadow.rkt`：同步 + place 两套执行器，影子增量（好，偏重）。
- `brackets.rkt` / `words.rkt` / `syntax.rkt`：三个内置插件实现。
- `registry.rkt`：**写死 catalog**，启用集来自 `config/plugins.rkt`。

**输入插件（electric-pair 类）**：`plugin/input/`

- `api.rkt`：`on-text` / `on-backspace`，第一个插手的赢（好）。
- `auto-pair.rkt`：唯一插件。
- `registry.rkt`：**写死 catalog**。

**接缝**：`plugin/seam.rkt`（core ↔ manager），只认 document 版本 + path。

---

## 3. 耦合点清单：核心和插件到底在哪混着

按严重程度排序：

1. **`command/registry.rkt` 是最大的混合枢纽**
   - `cmd-insert`：调 `input-plugins-text!`（输入插件）+ 编辑后 `plugin-note-change!`（属性插件）+ `complete-refresh!`（语言服务）。
   - `cmd-backspace`：调 `input-plugins-backspace!` + `plugin-note-change!` + 补全刷新。
   - `edit!`：每次编辑都 `plugin-note-change!`。
   - `cmd-complete-accept`：接受补全后 `plugin-note-change!`。
   - 注册了 `show-docs` / `complete` / `complete-move` / `complete-accept` / `complete-cancel` 这些**功能命令**。
   - `define-command` 是私有宏，**外部插件无法注册命令**。

2. **`ui/mode.rkt` 把功能模态当核心模态**
   - 定义 `complete` / `docs` 结构体，和 `prompt` / `prefix` 平级。
   - `mode-bottom-vid` / `mode-focus-vid` / `mode-tables` 都 `complete?` / `docs?` 分支。
   - 平台模式集合是**封闭的**，插件加不了新模态。

3. **`app/render.rkt` 把功能浮层当核心装饰**
   - `app-complete-panes` / `app-docs-panes` 硬编码。
   - `app-overlay-panes = bars + complete + docs`，没有 provider 列表。
   - `require "../lang/docs.rkt"`，核心渲染直接依赖功能模块。

4. **`config/keys.rkt` 把功能键位当核心键位**
   - `complete-keys` / `docs-keys`。
   - `edit-keys` 绑 `tab`→`complete`、`C-n`→`complete`；`focus-keys` 绑 `d`→`show-docs`。
   - 键表只在装配时构造，**插件无法往已有 keymap 增删绑定**。

5. **`backend/tui.rkt` 把功能异步源接在后端**
   - 同时注册 `app-plugin-source`（属性插件）和 `app-lang-source`（文档）。
   - 每帧 `app-plugin-tick!` + `app-complete-tick!` 两条独立轮询。

6. **`app/app.rkt` 事件后固定调功能 tick**
   - `app-handle-input` 末尾 `app-plugin-tick!` + `app-complete-tick!`。
   - re-export `app-complete-tick!` / `app-lang-source`（把功能 API 混进 app 门面）。

7. **`core/actions/lang.rkt` 挂在核心动作聚合里**
   - `core/actions.rkt` 把它和 core/file/focus/tree 并列，注释也当成一个核心域。

8. **插件注册写死**
   - `plugin/attr/registry.rkt` / `plugin/input/registry.rkt` 的 catalog 是硬编码 list。
   - 没有加载/发现/自动加载机制；第三方插件必须改核心文件。

9. **face 槽位清单集中且混杂**
   - `config/theme/slots.rkt` 同时声明核心 face 和插件色板 kind；
   - 插件无法自己声明 face/palette。

10. **异步执行器两套并存**
    - `plugin/attr/runner-place.rkt` 和 `lang/doc-runner.rkt` 是两套几乎一样的 place+async-channel+signal 机制。

---

## 4. 目标架构（Emacs 类比）

### 4.1 目录提案

```
core/                          # 不变：编辑器引擎
lab/
  platform/                    # 核心平台（命令循环 / keymap / mode / hook / overlay / job / face）
    command.rkt                # 命令注册表 + interactive 概念（公开 register!）
    keymap.rkt                 # command-table（公开 add-binding! / 全局 & mode keymap）
    mode.rkt                   # 通用 mode 注册 + 内置 prompt/prefix
    hooks.rkt                  # 具名 hook 点（post-command / after-edit / document-opened …）
    overlay.rkt                # overlay provider 注册（取代硬编码 app-overlay-panes）
    job.rkt                    # 统一异步执行器（place/异步 channel/signal）
    face.rkt input.rkt layout/ wrap.rkt path.rkt slot.rkt
  app/                         # 装配 + 事件入口 + modeline/status
    app.rkt render.rkt state.rkt panes.rkt paths.rkt edit-panes.rkt
  backend/tui.rkt
  builtin/                     # 内置包：只用 platform 扩展点，不碰核心内部
    edit/                      # 基本编辑命令（insert/backspace/save/quit/split/focus/modal）
    files/                     # 文件树面板 + 动作（原 ui/tree + actions/tree + tree-keys）
    buffers/                   # 文档列表面板 + 动作（原 ui/buffers + bufs-keys）
    complete/                  # 补全包（lang/complete + 模态 + keymap + overlay + provider）
    docs/                      # 文档包（lang/docs + doc-runner + 命令 + 浮层）
    highlight/                 # 原 plugin/attr：brackets/words/syntax + manager/runner
    autopair/                  # 原 plugin/input：auto-pair
  config/                      # 用户配置：keymap 覆盖、启用插件、主题、init
init.rkt                       # 像 ~/.emacs：把内置包和用户包装进 platform
```

### 4.2 扩展点对照表

| Emacs 扩展点 | lab 现有 | lab 目标 |
|---|---|---|
| `interactive` + `defun` 注册命令 | `define-command`（私有） | `platform/command` 公开 `command-register!` |
| `global-map` / `*-mode-map` | `config/keys.rkt` 静态表 | `platform/keymap` 注册 + 运行时 `keymap-add!` |
| minor mode / `define-minor-mode` | `ui/mode.rkt` 封闭 union | `platform/mode` 注册表 + `mode-tables` 扩展 |
| `add-hook` | 只有 `document-closed` 一个钩子 | 具名 hook 点集合（见 4.3） |
| `font-lock-keywords` | `plugin = (open change)`（好） | 保留，注册改为 `register-attr-plugin!` |
| `completion-at-point-functions` | `app-complete-refine!` 写死 | completion provider 注册 + buffer 级挂载 |
| `eldoc-documentation-functions` | `app-show-docs!` 写死 | doc provider 注册 |
| `post-self-insert-hook` | `input-plugin` 写死在 cmd-insert | 保留协议，派发改为 hook |
| `display-buffer` / 面板 | 树 / 列表写死在 app-init | 面板注册（left panel kinds） |
| `defface` | 主题槽位集中声明 | 插件可声明 face/palette kind |
| async process / timers | 两套 runner | `platform/job` 统一 |

### 4.3 建议的 hook 点

- `post-command`（每个命令后，补全刷新、mode 检查用）
- `after-edit`（文本变更后，通知属性插件 / 触发补全过滤）
- `before-edit` / `after-edit`（取代 `plugin-note-change!` 硬调）
- `document-opened` / `document-closed`（已有 closed）
- `focus-changed`
- `mode-entered` / `mode-exited`
- `render-overlays`（provider 收集，取代 `app-overlay-panes` 硬编码）

---

## 5. 改造路线（按优先级）

**P0 — 把语言服务拆成插件（收益最大）**

1. `complete` / `docs` 结构体从 `ui/mode.rkt` 移到 `builtin/complete` / `builtin/docs`。
2. `platform/mode` 加通用 mode 注册，`mode-tables` 改为查注册表；补全/文档注册进来。
3. `platform/completion` 加 provider 注册；`cmd-insert` 只发 `after-edit` 事件，补全包自己监听。
4. `platform/overlay` 加 provider 注册；`app-complete-panes` / `app-docs-panes` 移出 `app/render.rkt`。
5. `config/keys.rkt` 的 `complete-keys` / `docs-keys` 移到各自包；核心 `edit-keys` 不再直接绑功能命令（或由包在装配时绑定）。
6. `backend` 只连一条统一的 `job-source`，不再单独连 `app-lang-source`。

**P1 — 平台扩展点公开化**

7. `command-register!` 公开；`command/registry.rkt` 只保留核心命令，其余由包注册。
8. `keymap-add!` / mode keymap 公开，支持运行时增删。
9. hook 机制扩到 4.3 的点；`plugin-note-change!` / `complete-refresh!` 改为 hook 订阅。
10. `overlay provider` / `panel provider` 注册。

**P2 — 内置包搬家 + 插件加载**

11. `ui/tree.rkt` + `core/actions/tree.rkt` → `builtin/files`；`ui/buffers.rkt` + bufs 动作 → `builtin/buffers`。
12. `config/syntax.rkt` → `builtin/highlight`；`base/brackets.rkt` → `builtin/highlight`（或文本工具库）。
13. attr/input registry 改为「注册 + 目录发现」，支持用户插件目录 / init 文件。
14. face 槽位：包声明自己的 face/palette，主题只填色。

**P3 — 统一异步**

15. `plugin/attr/runner-place.rkt` 与 `lang/doc-runner.rkt` 合并到 `platform/job`。

---

## 6. 附：当前模块依赖现状（简化）

```
core/  (引擎)  ←── lab/base, lab/ui, lab/core, lab/app, lab/backend
                     │
   app/app.rkt ──────┼── require ──> command(registry,dispatch) ──> plugin/input, plugin/seam, core/actions(含 lang)
                     │                                   │
                     ├── require ──> plugin/attr/manager, registry, runner
                     ├── require ──> plugin/seam ──> core/state(钩子)
                     └── require ──> core/actions(agg) ──> actions/lang ──> lang/*

   backend/tui.rkt ── require ──> app/app, plugin/seam, plugin/attr/*, app/render, config/theme
                                  + app-lang-source(功能)

   command/registry.rkt ── require ──> plugin/input/api+registry, plugin/seam, core/actions
```

关键不当依赖（应消除）：

- `app/render.rkt` → `lang/docs.rkt`
- `backend/tui.rkt` → 语言服务异步源
- `command/registry.rkt` → `plugin/input/*` 与 `plugin/seam`
- `core/actions/lang.rkt` 挂在核心动作聚合
- `ui/mode.rkt` 认识补全/文档
