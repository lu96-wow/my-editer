# lab 组合子基石与重构设计（core 固定）

> 前提：`core/editor.rkt` 及 `core/**` 是**已完成、固定**的编辑器引擎，当黑盒用，不改。
> 本文只讨论 **lab 自己的逻辑**：抽出一组清晰的组合子基石，让功能由组合实现。

---

## 0. 目标与判据

**目标**：不是马上写代码，而是先把 lab 的逻辑抽干净 ——

1. 找出 lab 里**feature-free、可独立、无功能依赖**的 **基石**；
2. 把散落的「机制」提炼成有明确 combine 的 **组合子**；
3. 让每个功能（tree / buffers / complete / docs / indent / autopair / highlight）
   都变成**对组合子的组合**，而不是一堆特判 + require 平台内部。

**判据**（沿用你给的）：

- **基石**：本身不构成功能，独立、无（lab 内）下层依赖 → 值 / 代数 / 原语。
- **组合**：由基石或其它组合拼出来的机制 / 状态 / 功能。

core 视为 lab 之下的固定层，不参与分类。

---

## 1. lab 的职责：四个通道

lab 做的事，本质是把「**事件流 × editor 状态**」映射成「**状态变更 + 每帧画面**」，
并开放扩展点让功能接入。拆成四通道 + 两横切：

| 通道 | 输入 | 输出 | 现有实现 |
|---|---|---|---|
| **输入** | 事件 | 命令执行 | input / keymap / command / dispatch / mode |
| **状态** | 命令 | editor / workspace 变更 | state / panes / edit-panes / paths / slot |
| **输出** | 状态快照 | 每帧 screen | render / overlay / panel / layout |
| **异步** | 纯计算请求 | 结果写回状态 | job /（highlight 自带的 runner） |
| 横切·生命周期 | 事件节点 | 副作用 | hooks |
| 横切·配置 | — | 装配参数 | config/* + package |

**这个「四通道」就是 lab 组合子的骨架**：每个功能只是往若干通道注册"贡献"。
现状的问题不是通道错了，而是**通道的实现与 app 内部耦合、且各注册表各自为政**。

---

## 2. lab 依赖图（实测）

```
【原子层 · 无 lab 依赖】
face   input   keymap   command   job   package   paths   wrap   path
area   panel(registry)   panes(registry)

【结构层 · 只组合原子（部分 require core 值）】
hooks(→state)   slot(→core)   mode(→slot,keymap)   dispatch(→keymap,command,input)
layout/{split,focus,main}(→core.rectangle + area)
overlay(→core.pane + layout + state)
edit-panes(→layout/split)

【总装层 · 组合一切】
state(app) = editor ⊕ panes ⊕ edit-panes ⊕ paths ⊕ panels ⊕ mode ⊕ cs ⊕ 几何 ⊕ hooks ⊕ jobs
app/app    = state ⊕ config ⊕ package ⊕ builtin/edit(动作)
app/render = state ⊕ slot ⊕ overlay ⊕ core.render
backend/tui= core.patch ⊕ theme ⊕ 事件循环

【功能层】
config/{keys,packages,plugins,defaults,theme}
builtin/{edit,tree,buffers,complete,docs,indent,autopair,highlight,lang}
```

关键事实（require 计数）：

- 功能包几乎**只通过 platform 扩展点**接入：`hooks` 21 次、`command` 18、`paths` 18、
  `input` 15、`keymap` 15、`mode` 12、`job` 11、`panel`/`overlay` 9。
  → lab 的**解耦方向是对的**：功能不 require app 内部。
- 但平台把扩展点实现成了**模块级可变全局**，且很多机制 require 了 `state(app)` 具体结构，
  导致「组合子」不纯、不可枚举、不可卸载、测试串味。

---

## 3. 三层分类

### 3.1 原子基石（feature-free，无 lab 依赖）

| 模块 | 值 / 原语 |
|---|---|
| `platform/face.rkt` | `palette-color` / `face-stack` + `face-compose` |
| `platform/input.rkt` | `event->binding`、mods 归一、鼠标坐标 |
| `platform/keymap.rkt` | binding→spec 表 + 可变命名 registry + `command-merge/lookup` |
| `platform/command.rkt` | symbol→handler registry |
| `platform/job.rkt` | 异步 runner（sync / place）|
| `platform/package.rkt` | 配置驱动 dynamic-require |
| `platform/paths.rkt` / `path.rkt` | did↔path / basename |
| `platform/wrap.rkt` | 纯折行 |
| `platform/layout/area.rkt` | 屏幕矩形切分 |
| `platform/panel.rkt` / `panes.rkt` | provider / 单值 pane registry |

**这 12 个是 lab 不可再拆的种子**，核心价值在「值 + combine + registry」。

### 3.2 结构基石（feature-free，但已组合）

| 模块 | 组合了什么 | 为何仍算地基 |
|---|---|---|
| `platform/hooks.rkt` | state（仅存 hook） | 生命周期原语 |
| `platform/slot.rkt` | core.document ⊕ 属性写回 | 底部槽位文档模型 |
| `platform/mode.rkt` | slot ⊕ keymap ⊕ registry | 模态原语 |
| `platform/dispatch.rkt` | keymap ⊕ command ⊕ input | 派发原语 |
| `platform/layout/{split,focus,main}` | area ⊕ core.rectangle | 工作区几何 |
| `platform/edit-panes.rkt` | layout/split 树 | 分屏模型 |
| `platform/overlay.rkt` | registry ⊕ core.pane ⊕ layout | 装饰原语 |
| `config/theme/*` | 纯数据 | 外观槽位 |

### 3.3 组合（机制总装）

| 模块 | 组合出的东西 |
|---|---|
| `platform/state.rkt` | **总组合**：editor ⊕ workspace 全部模型 ⊕ mode ⊕ cs ⊕ 几何 ⊕ 缓存 |
| `app/app.rkt` | 装配 + 事件入口 |
| `app/render.rkt` | state 行 ⊕ 分隔线 ⊕ overlay 汇总 |
| `backend/tui.rkt` | 事件循环 ⊕ core patch ⊕ 主题→ANSI |

### 3.4 功能（builtin）

`edit`（动作 + 命令）、`tree`/`buffers`（面板）、`complete`/`docs`（模态浮层）、
`indent`/`autopair`（覆盖/钩子）、`highlight`（属性插件框架 + 3 插件）、`lang/*`（纯逻辑）。

---

## 4. lab 里已经存在的组合子（现状清点）

lab 其实早就有组合子，只是没被显式化、且各自耦合 app：

| 组合子 | 值 | combine | 污染点（为何还不是干净组合子）|
|---|---|---|---|
| 键表 | `keymap` | `command-merge`（后者覆盖） | registry 模块级全局；顺序 = 注册序 |
| 命令 | `symbol → handler` | 同名覆盖 | registry 不可清空 / 枚举 / 卸载 |
| 派发 | `tables × event → spec` | `dispatch-tables` 拼接 | 需要 did + mode-extra，签名带 app |
| 模态 | `mode-type` | 列表追加 = 优先级 | 单值 union，多职责耦合 |
| 钩子 | `(app . args) → result` | 顺序 reduce / first-wins | stringly-typed，协议在注释 |
| 装饰 | `app → (listof pane)` | 列表 append + deep 合成 | provider 全局、无 priority、无卸载 |
| 面板 | `ctx → (ed . panel)` | 列表 | provider 全局、无 priority |
| 槽位 | `label → document` | — | 与 mode 耦合 |
| 异步 | `runner`（4 函数）| 无 | 两套（platform/job vs highlight/runner）|
| 外观 | `face` | `face-compose` | 已是干净组合子 ✅ |
| 几何 | `area` | `area-split` | 已是干净组合子 ✅ |

**结论**：外观（face）与几何（area）已是好组合子，可作范本。
键表/命令/钩子/装饰/面板/异步需要同样的「值 + combine + 显式优先级 + 可卸载」。

---

## 5. 抽出组合子基石

把 lab 重构成**一个组合子内核 + 四通道 + 注册表**。核心类型：

### 5.1 Contribution：一切扩展点的统一形状

```racket
;; 贡献 = 值 + 元数据。kind 决定它进哪个通道。
(struct contribution (kind name priority value) #:transparent)
;; kind     : 'command | 'binding | 'layer | 'decoration | 'panel
;;          | 'hook | 'prop-plugin | 'job | 'file-source
;; priority : 数字（大者优先 / 后应用），显式取代「注册顺序」
;; value    : 该 kind 的函数（见下）
```

统一注册表（替代所有模块级全局）：

```racket
(register! c)                 ; 按 (kind,name) 唯一
(extensions kind)             ; 按 priority 排序，可枚举
(fold-kind kind init f)       ; 通道的 fold
(unregister! kind name)
(clear! [kind])               ; 测试隔离
```

收益：显式优先级、可枚举（状态栏/调试能列全部）、可卸载、可清空、单一实现。

### 5.2 输入通道：Layer 栈（取代 mode 单值）

```racket
(struct layer (match? tables capture slot focus pop-on priority) …)
;; match?   : Ctx -> bool
;; tables   : Ctx -> (listof keymap)
;; capture  : 'all | 'fallthrough        （取代 exclusive?）
;; slot     : #f | 'state | 'input
;; focus    : #f | 'input
;; pop-on   : 'handled | 'next | never   （取代 transient?）
```

派发 = 在启用的 layer 上按 priority fold 出 tables，再查 binding：

```
spec = lookup(binding(ev),
              concat(base tables, layer tables))   ; 后层覆盖
effect = invoke(spec, ctx, ev)
```

- 前缀 = 一层（capture all, pop-on next）；
- 补全 = 一层（fallthrough, pop-on next/handled）；
- 文档 = 一层（capture all）；
- 多个浮层 / 键序列天然支持；`mode` union 与 `exclusive?/transient?` 消失。

### 5.3 输出通道：Decoration（统一属性 / 浮层 / 槽位）

```racket
(struct decoration (name priority scope render) …)
;; scope : 'document  ; 持久，写回 core 属性轨（异步高亮）
;;       | 'frame     ; 每帧产 pane（菜单 / 浮窗 / 分隔线）
;;       | 'slot      ; 换底部槽位文档（state / input）
;; render : Ctx -> contribution-data
```

每帧：`panes = workspace(ctx) ++ fold(frame-decorations, ctx)`，交给 core 合成。
于是属性插件 / overlay / slot **一套注册与 fold**，不再三套 API。

### 5.4 异步通道：Job（版本闸门内建）

```racket
(struct job (name priority handler runner version current? merge) …)
;; handler  : request -> result                       （纯；可 place 化）
;; runner   : 'sync | (place n)
;; version  : Ctx -> token    发起时抓
;; current? : Ctx token -> bool   结果到达时校验
;; merge    : results -> contribution
```

- `doc-job` = 一个 job（version = document 句柄）；
- highlight 每个插件 = 一个 job（version = token，merge = `face-compose`）；
- 版本闸门从「调用方各自手写 `(cons id doc)`」收敛成 job 字段；
- 删除 `highlight/runner*` 与 `platform/job` 的重复，统一 `submit/poll/source/stop`。

### 5.5 状态通道：Effect + Workspace

命令不直接 mutate app，而是**返回 Effect**，由内核统一施加：

```racket
Effect = (Edit edits) | (Move selections) | (Open path) | (Close did/vid)
       | (Prompt label editable on-commit) | (Focus vid|dir)
       | (Workspace split|swap|resize|show) | (Notify hook . args)
       | (Job-submit job request) | (Quit)
```

Workspace 用**一棵带 role 的窗格树**统一三套模型：

```racket
(struct frame (tree active role-table) …)
;; tree : leaf(vid) | node(dir,size,a,b)
;; role : 'edit | panel(name) | slot(state|input) | popup
```

- `panes` / `panels` / `edit-panes` 合成一棵；
- 布局从树一次算出全部 rectangle + bar；
- setter 自动失效布局缓存 → 删掉 `state.rkt` 顶部那条「必须走某某 setter」的纪律；
- 焦点只有一个（树的 active），`edit-panes-active` 与 `app-focus` 合并。

### 5.6 生命周期：Hook（typed）

```racket
(struct hook-point (name priority) …)
;; handler : Ctx . args -> result
;; 每个 point 在注册时带 contract（参数个数 / 返回协议）
```

`before-*` 的 `#f | '() | changes` 用**显式结果类型**表达，而不是约定。

### 5.7 core 适配层：`lab/editor-api`

core 不动，但 lab **只允许一个模块 require core**：

```racket
;; lab/kernel/editor-api.rkt —— lab 唯一认识 core 的地方
(provide
 editor-state      ; 读：text/point/selection/viewport/attribute（快照）
 edit!             ; 写：edits → changes（走 core text/command）
 move!             ; 选区 / 导航
 open/close        ; view / document
 render            ; core render/layout 的窄封装
 geometry)         ; rectangle / pane / screen 的再导出
```

其余 lab 模块（platform/*、builtin/*）**只 require `editor-api`**，不直接 require core。
这样 core 保持固定，lab 与 core 的耦合被收进一个可测的窄接口。
（现状：platform 有 6+ 处直接 require `core/editor.rkt`。）

### 5.8 Ctx：显式上下文

一切 value 函数收 `Ctx`（只读快照 + 能力），而不是可变的 `app`：

```racket
(struct ctx (editor focus frame mode paths panels registry jobs width height) …)
;; 命令 / decoration / layer / hook / job 都是 Ctx -> … 的纯函数
```

---

## 6. 用组合实现功能

### 6.1 现有功能 → 组合映射

| 功能 | 组合方式（新） |
|---|---|
| `tree` / `buffers` | `register! panel` + `register! hook(document-opened/closed)` + `register! binding` |
| `complete` | `layer`（fallthrough）+ `binding`（往 edit 补 C-n）+ `frame-decoration`（菜单）+ `job`（查文档）+ `hook(after-insert/after-nav/focus-changed)` |
| `docs` | `layer`（capture all）+ `frame-decoration`（浮窗）+ `job` + `hook(job-tick)` |
| `indent` | `command`（覆盖 newline-and-indent），零新机制 |
| `autopair` | `hook(before-insert)`，零新机制 |
| `highlight` | `prop-plugin` × 3 + `job`（版本闸门合成）+ `hook(after-edit/document-closed/before-render)` |
| `edit` | 拆成 **kernel 动作**（open/split/close/prompt/focus，供 API） + **命令绑定**（纯 feature） |

### 6.2 示例：`complete` 作为纯组合

```racket
;; 状态（会话态）
(struct complete (cands idx start vid …) #:transparent)

;; 1) 输入层：不独占，处理一个事件后由打字 refine 决定去留
(register! (contribution 'layer 'complete 50
  (layer complete? (λ (ctx) (list complete-keys)) 'fallthrough 'state #f 'handled)))

;; 2) 触发键：往 edit 表补
(register! (contribution 'binding 'complete 0
  (bindings (hash (key 'n 'ctrl) 'complete))))

;; 3) 命令
(register! (contribution 'command 'complete       0 cmd-complete))
(register! (contribution 'command 'complete-move  0 cmd-complete-move))
(register! (contribution 'command 'complete-accept 0 cmd-complete-accept))
(register! (contribution 'command 'complete-cancel 0 cmd-complete-cancel))

;; 4) 输出：菜单 + 内嵌文档
(register! (contribution 'decoration 'complete 50
  (decoration 'complete 'frame (λ (ctx) (complete-panes ctx)))))

;; 5) 异步：查文档（版本闸门内建）
(register! (contribution 'job 'complete-doc 0
  (job #:handler doc-handler #:runner 'place #:version complete-version …)))

;; 6) 生命周期
(register! (contribution 'hook 'complete-refine 0
  (hook 'after-insert (λ (ctx vid changes) (complete-refine! ctx)))))
```

**没有任何一行 require platform 内部**：只用 contribution / layer / command / decoration / job / hook。
这正是「功能 = 组合」。

### 6.3 示例：highlight 作为组合

```
prop-plugin 'brackets / 'words / 'syntax   → 纯 (open, change)
job × 3（version = token, merge = face-compose）
hook(after-edit) → 记增量到 job
hook(before-render)/job-tick → flush + 写回 decoration(scope document)
```

---

## 7. lab 重构清单（把逻辑抽出）

1. **拆 `builtin/edit.rkt`**：`app-open-path!/split!/prompt!/…` 是 **kernel 动作**（进 `editor-api`/`workspace`），
   其余 `cmd-*`/`define-command` 才是 feature。目前两类混在一个 495 行包里。
2. **收敛 state**：`state.rkt` 只留数据 + 纯访问；布局缓存与「合法 setter」纪律由
   Frame 树 + Effect 施加器接管。
3. **统一注册表**：keymap registry / command / mode-type / overlay / panel / hooks → `contribution`。
4. **统一异步**：`highlight/runner*` 与 `platform/job` 合并为 `job`。
5. **统一装饰**：属性写回 / overlay / slot → `decoration`。
6. **Frame 树**：合并 `panes`+`panels`+`edit-panes`+焦点。
7. **Layer 栈**：`mode` union → `layer` 列表。
8. **`editor-api`**：lab 唯一 require core 的模块。
9. **typed hooks**：钩子点带 contract。

---

## 8. 迁移顺序（每步保持旧 API 可用）

1. 立 `editor-api`（core 适配层），把 `platform/*` 对 core 的直接 require 收进去。—— 纯搬运，零语义变化。
2. 立 `contribution`/`register!`，让 `command`/`keymap`/`panel`/`overlay`/`hooks` 变成薄封装。
3. 立 `layer`，`mode` 改由 layer 表达（prompt/prefix 先做）。
4. 合并异步为 `job`。
5. 合并装饰为 `decoration`。
6. 立 Frame 树，吞掉 `panes`/`edit-panes`/`edit-panes-active`。
7. 拆 `builtin/edit.rkt` 的 kernel 动作与 feature 命令。
8. 功能包逐个改成「注册 contribution」。

---

## 附：判定一个 lab 模块是否合格（自检）

- 它 require 了 `core/**` 吗？→ 只允许 `editor-api`。
- 它 require 了 `app/state` 的具体结构吗？→ 应改为收 `Ctx`。
- 它是全局可变 registry 吗？→ 应改为 `contribution`。
- 它按注册顺序决定优先级吗？→ 应显式 `priority`。
- 它实现了功能吗？→ 是：应能拆成对四通道的贡献；否：可能是基石。
