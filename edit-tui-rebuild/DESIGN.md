# edit-tui-rebuild —— 状态机分析与重建设计

本文先给出现有 `edit-tui/app` 的**实际状态机**，再把状态 / 策略 / 效果 / 投影分层，
最后给出重建目标。重建按“层”推进，不按文件搬家。

---

## 0. 一句话概括现有实现

`edit-tui/app` 是一个 **keymap 驱动的 reducer + 效果解释器**：

```
终端事件 / 内部事件
        │
        ▼
   world-step（纯）
        │  world × event -> world + (listof intent)
        ▼
   折叠 update intent，收集 effect intent
        │
        ▼
   loop 解释 effect（edit / select / scroll / spawn / post / invoke / open-doc）
        │
        ▼
   draw-world（world -> panels -> core render -> tui bytes）
```

行为不是写死在流程里，而是通过若干注册表查出来的：

- `role` 注册表：leaf 的 `splittable?` / `close-policy`；
- `doc-kind` 注册表：document 类型 → 默认 keytable；
- `world.layers`：临时拓展层；
- `world.internal`：内部事件处理器；
- `plugin` 注册表：面板贡献 + `on-load`；
- `command/keymap`：token 序列 → command。

这套骨架已经验证了：焦点/鼠标/文档类型/前缀/浮层/插件/状态栏都能用“数据 + 查表”接上。
问题不在“能不能扩展”，而在**状态所有权、注册表生命周期、派发特例、效果语义**。

---

## 1. 逻辑层次（现有代码）

| 层 | 现有文件 | 职责 | 纯? |
|---|---|---|---|
| 终端 IO | `command/tui.rkt`、`app/loop.rkt` | 读事件、解码 token、写字节 | 不纯 |
| 输入词汇 | `command/key.rkt`、`mouse.rkt`、`command.rkt`、`keymap.rkt` | 键/鼠标 token、command、trie、matcher | 纯 |
| 布局几何 | `layout/tree.rkt`、`spec.rkt`、`solve.rkt`、`float.rkt` | 树、尺寸、切分、拖缝、浮窗 | 纯 |
| 应用状态 | `app/world.rkt`、`panel-ref.rkt` | world / ctx / drag / layer / ref | 纯数据 |
| 文档元数据 | `app/doc-kind.rkt`、`app/resource.rkt` | 类型 → 表、每 buffer 覆盖层、路径 | 全局表 / 不纯创建 |
| 策略注册表 | `app/role.rkt`、`app/plugin.rkt`、`app/world.internal` | role / plugin / 内部事件 | 全局可变 |
| 派发 | `app/step.rkt` | 事件分派、活动表、鼠标命中、命令执行 | 纯 |
| 操作原语 | `app/ops.rkt`、`app/base-keys.rkt` | layout/focus/document 命名操作、基础表 | 纯构造器 |
| 投影 | `app/render.rkt`、`app/status.rkt`、`core-render` | world → panels → bytes；状态行文本 | 投影纯，输出不纯 |
| Chrome | `app/slot.rkt`、`app/minibuffer.rkt` | 状态栏/输入栏共享槽、输入会话 | 状态藏在 `world.ext` |
| 外壳 | `app/loop.rkt` | inbox、spawn、首帧、重绘节流 | 不纯 |
| 稳定面 | `app/api/*` | 再导出 | 转发 |

依赖大致是：

```
tui ◀── command/tui
core ◀── layout
core ◀── app ──▶ layout, command, core-render
                 │
                 ├─ world / panel-ref
                 ├─ role / doc-kind / plugin
                 ├─ step / ops / base-keys
                 ├─ render / status / slot / minibuffer
                 └─ loop
```

现有层次的主要错位：

1. `world` 声称是全部逻辑状态，但**文档类型、路径、per-buffer 表、resources、slot、minibuffer、插件状态**分散在
   `world.ext`、全局 weak hash、可变 `resources` 结构里。
2. `role` / `doc-kind` / `plugin` 是**模块级全局注册表**，随 `require` 产生副作用，不能按 app 实例隔离。
3. `step` 同时承担“输入状态机”“活动表解析”“鼠标几何”“命令执行”“文本 fallback”，特殊分支多。
4. `render` 不是纯投影：`panels-sync!` 会写 core view 的 viewport，`status-sync!` 每帧写状态栏 buffer。
5. `intent` 同时表达“改 world”和“做 IO”，但折叠顺序是“先所有 update，再所有 effect”，
   与命令返回顺序不一致。

---

## 2. 现有状态机逐段拆解

### 2.1 事件入口

`world-step` 的分派顺序是写死的：

```
app-event > key-event > mouse-event > resize-event > paste-event > null-event > 忽略
```

这本身没问题，但它把“内部事件”和“终端事件”混在同一入口；`app-event` 又是 shell 注入的，
不是真正的输入设备。重建后建议统一成 `event` ADT，来源只作为标签。

### 2.2 键盘

```
event -> key-token
  ├─ pending 非空且 prefix-keys 命中 -> 执行“前缀编辑命令”
  └─ seq = pending + token
       ├─ 'command -> 清 pending，run-command
       ├─ 'prefix  -> pending = seq，重绘
       └─ 'unbound -> 清 pending；可打印字符 -> 插入；否则 status = unbound
```

`active-keytables` 的层序是：

```
world.layers > per-buffer 层 > doc-kind 默认表 > world.keytable
```

查找语义是“第一个非 unbound 胜出”。这是自然覆盖，但**层本身不是一个数据模型**，
而是 `step` 里的一段 `append`。新增“插件全局层”“前缀层”“输入法层”都要改这里。

### 2.3 鼠标

```
solve layout + floats -> placements / panels / refs / cuts
命中 panel -> hit-ref / doc-point
subject-ref = move/release 时的 drag.subject，否则 hit-ref
  ├─ press 命中缝 -> 进入 seam drag
  ├─ move 且 seam drag -> 改 layout dim
  └─ 否则查 subject 的类型表
       ├─ 命中 command -> run
       ├─ press -> 只聚焦
       ├─ release -> 清 drag
       └─ scroll -> 滚命中 panel
```

“缝优先”“拖动主体决定表”“点击空白不回落 focus 表”都是好决定，但它们是**流程里的 if**，
不是可组合的规则。重建后应把布局 chrome 交互也表达成 scope / gesture，而不是 `step-mouse` 特例。

### 2.4 命令与效果

```
run-command:
  if command 需要 input -> minibuffer-enter + invoke 写 prompt
  else:
    ctx = (world, event, ref, view, panel, doc-point)
    intents = command-run(ctx)
    world' = 折叠所有 update intent
    effects = 过滤所有 effect intent
    若有效果 -> dirty
```

问题：

- `update` 与 `effect` 的顺序被重排；命令无法表达“先 edit 再改 world”或反之。
- `invoke` 是闭包逃生舱，效果不可序列化、不可重放、不可测试。
- `open-doc` 把“造对象”和“装进布局”塞进一个 intent，由 loop 穿 world 解释。
- `spawn` / `post` 把异步结果塞回 inbox，但 inbox 只在下一个终端事件到达时排空（已知暂定）。

### 2.5 重绘

```
loop:
  status-sync!（写状态栏 buffer）
  if force 或 dirty -> draw-world
  mark-clean
  read-event + drain inbox
  world-step*
  run-intents!
```

`draw-world` 里会 `panels-sync!`（写 core viewport）再 `render-display-patch`。
所以“纯投影”实际上带了 core 副作用。首帧、resize、cache 都在 loop 里处理。

---

## 3. 状态清点：哪些东西现在算“状态”

| 当前字段 / 表 | 现在的位置 | 生命周期 | 应该归到 |
|---|---|---|---|
| `area` | `world.area` | 会话 | `state.window` |
| `layout` | `world.layout` | 会话 | `state.workspace.layout` |
| `floats` | `world.floats` | 会话 | `state.workspace.overlays` |
| `focus` | `world.focus`（panel-ref） | 会话 | `state.workspace.focus`（view-id） |
| `keytable` | `world.keytable` | 启动 + 运行期并表 | `env.keymaps.global` + `state.input.layers` |
| `prefix-keys` | `world.prefix-keys` | 启动 | `env.input.prefix-keymap` |
| `layers` | `world.layers` | 运行期 | `state.input.modes` |
| `pending` | `world.pending` | 输入中 | `state.input.pending` |
| `status` | `world.status` | 会话 | `state.chrome.message` |
| `running?` | `world.running?` | 运行时 | `state.runtime.quit?` |
| `dirty?` | `world.dirty?` | 每帧 | 投影修订号（派生，不是领域状态） |
| `drag` | `world.drag` | 手势中 | `state.input.gesture` |
| `internal` | `world.internal` | 启动 | `env.handlers` |
| `slot` | `world.ext` | 启动 + 会话 | `state.workspace.regions` |
| `minibuffer` | `world.ext` | 输入中 | `state.input.prompt` |
| 插件状态 | `world.ext` | 插件生命周期 | `state.plugins[id]`（有类型/命名空间） |
| buffer kind | 全局 weak hash | 文档生命周期 | `state.docs[id].mode` |
| per-buffer 表层 | 全局 weak hash | 文档生命周期 | `state.docs[id].keymap-layers` |
| buffer path | 全局 weak hash | 文档生命周期 | `state.docs[id].path` |
| resources 列表 | 可变 `resources` | 进程 | `state.workspace.docs` |
| core buffer/view | 句柄 | 文档生命周期 | `engine`（纯状态之外，用 id 引用） |
| render cache / inbox | `loop` | 运行时 | `runtime`（shell 私有） |

这张表是重建的核心：**当前所谓 world 只是“界面状态的一部分”，不是全部逻辑状态。**
重建要先把状态归位，再谈派发和渲染。

---

## 4. 现有实现的主要不足

### P0：会阻碍后续扩展

1. **状态所有权分散**
   - `world.ext` 是无类型杂物袋，slot / minibuffer / 插件都往里塞；
   - doc 元数据在全局 weak hash，`resources` 又是另一个可变结构；
   - 同一个“文档”在 layout leaf、buffer、resources、weak hash 里各有一份身份。

2. **注册表是全局可变副作用**
   - `define-role!` / `define-doc-kind!` / `define-plugin!` 写模块级表；
   - 多个 app 实例、测试隔离、插件禁用/重载都很难；
   - `plugins-apply` 在 `run-app` 里隐式执行，装配顺序依赖 `require` 顺序。

3. **效果语义不完整**
   - state intent 与 effect intent 分两段折叠，顺序丢失；
   - `invoke` / `open-doc` 闭包让效果不可记录、不可重放；
   - 没有 effect 结果 / continuation，异步只能靠 `post + task-done`。

4. **投影带副作用**
   - `panels-sync!`、`status-sync!` 写 core；
   - 状态栏为了可滚动，把文本镜像进一个 buffer，再用“焦点在槽时报告第一个 editor”来避免自指；
   - 渲染缓存与 dirty 在 loop 里手工管理。

### P1：造成代码难读 / 难扩展

5. **派发特例**
   - `step-key` 的前缀编辑分支；
   - `step-mouse` 的 seam / subject / fallback 分支；
   - `active-keytables` 的固定层序；
   - 没有 scope / priority / command id 这些可组合概念。

6. **区域模型缺失**
   - 平铺 leaf、float、slot 三套身份/生命周期；
   - 状态栏和输入栏是“一个 leaf + 两个 view + ext 状态”，不是正式的区域；
   - 没有 panel group / dock / region 的概念，插件只能“相对锚点切一刀”。

7. **chrome 与文档耦合**
   - 输入栏靠一个特殊 doc-kind + 特殊 buffer 实现；
   - 状态栏靠特殊 buffer + 每帧同步；
   - 输入会话、prompt、焦点恢复散在 `ext` / buffer / slot 里。

### P2：目标功能缺口

- 文档生命周期：close / save / revert / dirty / find-open；
- 多 view 显示同一 document；
- 区域分组 / dock / 显隐 / 尺寸策略；
- which-key、前缀超时、命令面板；
- 插件启用/禁用/重载、per-plugin 状态命名空间；
- 异步 job / timer / 取消；
- 配置层（主题、键位、布局）；
- 事件日志 / 确定性重放。

---

## 5. 重建目标模型

### 5.1 四个顶层概念

```
Environment   装配期只读：roles / modes / scopes / commands / keymaps / plugins / handlers
State         运行期纯数据：workspace / input / chrome / runtime
Engine        可变文档引擎：core buffer/view 的拥有者；State 只存 id
Runtime       壳：事件源、效果解释器、渲染输出、cache、inbox、线程
```

关系：

```
                 Environment（只读）
                        │
 event ──▶ dispatch(env, state, engine-view, event) ──▶ Transition
                                                        │
                                          ┌─────────────┴─────────────┐
                                          ▼                           ▼
                                       State'                     [Effect]
                                                                      │
                                                            Runtime 解释
                                                      （engine / io / async）
```

`engine-view` 是**只读快照/查询接口**（文本、光标、选区、路径等）；写操作全部走 effect。
这样 reducer 可以在 headless 下用假 engine 重放，State 不依赖 core 的可变对象。

### 5.2 State 切片

```racket
(struct state (window workspace input chrome runtime))
```

- `window`：`area`、终端尺寸、DPR 等会话信息。
- `workspace`：
  - `docs : doc-id -> doc-meta`（path / mode / dirty? / saved-version）
  - `views : view-id -> view-meta`（doc-id / options / kind）
  - `regions : region-id -> region`（members / active / side / size / visible / focus-policy）
  - `layout : tree<region-id>`（复用 layout 的树/尺寸算法，叶子引用 region-id）
  - `overlays : (listof overlay)`
  - `focus : view-id | #f`
  - `focus-stack : (listof view-id)`
- `input`：
  - `pending : (listof token)`
  - `modes : (listof mode)`（拓展层/临时模态）
  - `gesture : idle | (gesture kind owner data)`
  - `prompt : #f | (prompt kind text on-submit source)`（minibuffer）
- `chrome`：
  - `message : string`
  - `log : (listof string)`（可选）
- `runtime`：
  - `quit?`
  - `revision`（用于渲染失效，不参与领域逻辑）

约定：

- 领域状态里**只放 id、元数据、逻辑值**，不放 core 的 buffer/view 句柄；
- 不设 `ext` 杂物袋；插件状态进 `state.plugins[plugin-id]` 或带命名空间的 `store`；
- 派生值（panels、refs、status line、display panels、hit map）不进 State，按需计算/缓存。

### 5.3 Transition 与 Effect

命令返回**一个 Transition**，而不是“state intent + effect intent”两套：

```racket
(struct transition (state effects))
```

- `state`：命令已经做完的纯变换；
- `effects`：按顺序解释的副作用；
- 组合子：`transition-bind` / `transition-all` / `transition-map`；
- 效果类型：

```racket
;; engine（写文档引擎）
(struct edit-effect   (view-id op))
(struct select-effect (view-id selections))
(struct scroll-effect (view-id delta))
(struct open-doc-effect (spec k))       ; k : doc-id view-id -> Transition
(struct close-doc-effect (doc-id))
(struct save-doc-effect (doc-id k))

;; IO / async
(struct read-file-effect (path k))
(struct write-file-effect (path text k))
(struct spawn-effect (job-id thunk))
(struct timer-effect (delay event))
(struct emit-effect (event))            ; 内部事件回投

;; runtime
(struct quit-effect ())
```

效果解释器在 Runtime 边缘；它可以把结果变成**新的 event** 再喂回 `dispatch`，
而不是直接改 State。这样异步/IO 和同步输入走同一条路径。

### 5.4 Environment

```racket
(struct environment
  (roles        ; role-id -> role-behavior
   modes        ; mode-id -> mode（默认 keymap / 输入策略 / 钩子）
   scopes       ; scope-id -> (state -> bool)
   commands     ; command-id -> command-spec（run/note/input）
   keymaps      ; named keymap
   handlers     ; event-kind -> handler
   plugins))    ; plugin-id -> plugin-contribution
```

- 由 `bootstrap/defaults` 和插件声明**显式构造**，不是模块级 `set!`；
- `run-app` 接收 `environment`，测试可以传一个最小 env；
- 插件 = 贡献数据（modes/keymaps/commands/regions/hooks），应用是一次纯 fold；
- `engine` 与 `runtime` 也是 `run-app` 的参数（或默认实现），便于替换。

### 5.5 Dispatch 作为数据

派发不再写死“键盘一套、鼠标一套”：

```
dispatch(env, state, engine-view, event)
  -> 1. 由 event 求 subject（focus / 命中 view / gesture owner）
     2. 求上下文（mode、region、scope 值）
     3. 取候选规则（有序：prompt > gesture > prefix > overlay > mode > doc > global）
     4. 第一条“scope 成立 + keymap 命中”的规则执行 command
     5. 无命中 -> fallback（可配置：插入文本 / 提示 / no-op）
```

规则可以是：

```racket
(rule scope-id keymap priority)
```

- `prefix` 是 Input 状态，不是特殊分支；
- 前缀编辑（退格/取消）是 prefix scope 下的普通命令；
- 布局拖缝是一个 gesture scope，不是 `step-mouse` 的 `if`；
- 鼠标和键盘共用 command / transition / effect。

### 5.6 区域（region）与 chrome

把“平铺 leaf / float / slot”收敛成 **region**：

```racket
(struct region (id members active side size visible? focus-policy))
;; members : (listof member)
;; member  : (view member-id) | (chrome member-id)
```

- 编辑区：`members = (list editor-view ...)`，可切成员；
- 状态栏/输入栏：一个 region，`members = status/input`，`active` 决定显示；
- 面板组/dock：显式的 region 组合，不再靠 `panel-spec` 临时切一刀；
- `layout` 的叶子引用 `region-id`，`focus` 指向 `view-id`；
- float 是 `overlays` 层的 region，不占焦点；
- 状态栏是**投影**，不是每帧写 buffer；输入栏是 `input.prompt` 的投影。

这样 `slot.rkt` / `minibuffer.rkt` 的特殊状态就消失，变成：
`state.input.prompt` + `state.workspace.regions` + 投影函数。

---

## 6. 目标目录（建议）

```
edit-tui-rebuild/
├── base/
│   ├── id.rkt            doc-id / view-id / region-id / job-id
│   ├── event.rkt         event ADT
│   ├── effect.rkt        effect ADT
│   ├── transition.rkt    Transition + 组合子
│   └── keymap.rkt        通用 token -> 值 的前缀表
├── model/
│   ├── state.rkt         root state
│   ├── workspace.rkt     docs / views / regions / layout / focus / overlays
│   ├── input.rkt         pending / modes / gesture / prompt
│   └── chrome.rkt        message / log
├── env/
│   ├── environment.rkt   env 聚合
│   ├── role.rkt          region/leaf 行为（splittable? / close-policy / focusable?）
│   ├── mode.rkt          document mode（原 doc-kind）
│   ├── scope.rkt         scope 谓词
│   ├── command.rkt       复用旧 command 结构（run / note / input）
│   └── defaults.rkt      内置 role / mode
├── dispatch/
│   ├── context.rkt       subject 解析 / engine query 视图
│   ├── keyboard.rkt
│   ├── mouse.rkt
│   └── pipeline.rkt      规则排序 / prefix / fallback
├── ops/
│   ├── layout.rkt
│   ├── region.rkt
│   ├── focus.rkt
│   ├── document.rkt
│   └── input.rkt
├── effects/
│   ├── engine.rkt        core 适配（唯一持有 buffer/view 句柄）
│   ├── io.rkt            file / job / timer
│   └── interpreter.rkt   effect -> event / state
├── projection/
│   ├── geometry.rkt      layout -> panels / hit
│   ├── render.rkt        state + engine -> tui bytes
│   └── status.rkt        status line 投影
├── bootstrap/
│   ├── defaults.rkt      默认 roles / modes / commands / keymaps
│   ├── plugins.rkt       插件贡献应用
│   └── app.rkt           run-app 装配
└── main.rkt
```

依赖方向：

```
base ◀── model ◀── env ◀── dispatch ◀── ops
                 │            │
                 └── projection ◀── effects ◀── bootstrap
```

- `model` 不 require core / tui；
- `dispatch` 只依赖 `env` / `model` / `base`；
- `effects/engine` 是唯一碰 core buffer/view 的模块；
- `projection` 只读 state + engine-view，不写 core；
- `bootstrap` 是唯一装配层，允许不纯。

---

## 7. 目标功能（按优先级）

### MVP（先恢复现有能力）

- 文档：open / close / path / mode / dirty；
- 视图：一个 document 可有多个 view，view 可被替换而不丢身份；
- 布局：split / close / move / resize / hide / show；
- 焦点：view-id、焦点栈、面板间移动；
- 输入：pending、prefix、默认文本插入、未命中提示；
- 命令：命名命令、按 mode/scope 解析、鼠标/键盘统一；
- Chrome：状态栏投影、minibuffer（string 输入）；
- 效果：edit / select / scroll / open-doc / quit；
- 投影：焦点边框、浮窗、overlay selection；
- 插件：声明式贡献（mode/keymap/command/region/hook）；
- 测试：headless dispatch + transition，不启动终端。

### 第二阶段

- 区域组 / dock / 显隐 / 固定尺寸；
- which-key / 前缀超时；
- 输入类型：string / key / key-seq / number / choice；
- 命令面板 / 帮助；
- 文件读写、保存、revert、find-open；
- 异步 job / timer / 取消；
- 插件启用/禁用/重载 + per-plugin store；
- 配置层（主题/键位/布局）。

### 第三阶段

- 多焦点 / 多窗口；
- 装饰器（status/decorations 注册器）；
- 事件日志 / 确定性重放 / 快照测试；
- 性能：增量投影、按区域失效。

---

## 8. 重建顺序（一块一块来）

1. **词汇与状态**
   - `base/id`、`base/event`、`base/effect`、`base/transition`
   - `model/state` + workspace/input/chrome 切片
   - 先不接 core，用假 doc/view 写纯测试。

2. **Environment**
   - role / mode / scope / command / keymap 注册表
   - 构造一个最小 env；插件贡献先做成纯 fold。

3. **Dispatch**
   - 规则排序、subject 解析、prefix、fallback
   - 键盘/鼠标共用；gesture 作为 scope。

4. **Effects + Engine**
   - core 适配层（唯一持有 buffer/view）
   - open/close/save + edit/select/scroll
   - 效果解释器把 IO 结果转成 event。

5. **Projection**
   - geometry（layout → panels / hit）
   - status line 投影
   - render（纯投影 + 输出在 runtime）。

6. **Bootstrap + Runtime**
   - `run-app`：env/state/engine/runtime 装配
   - 首帧、resize、inbox、dirty/revision。

7. **Port demos**
   - temp 23–34 逐个迁移，作为回归用例。
   - 最后再决定是否保留旧 `edit-tui/app`。

---

## 9. 验收标准

- `dispatch` / `transition` 可 headless 重放，不 require tui；
- State 中无 core 句柄、无全局 weak hash、无 `ext` 杂物袋；
- 多个 app 实例可并存，注册表互不污染；
- 键盘/鼠标走同一条“规则 → command → transition”；
- 投影不写 core；输出只在 runtime；
- 新区域 / 新模式 / 新命令 / 新插件只加数据或注册项，不改 dispatch / runtime；
- 现有 demo 的行为（split、focus、拖缝、doc-kind、overlay、status/minibuffer、plugin）全部可复现。

---

## 10. 待确认的中心决策

**State 里是否保留 core 的 buffer/view 句柄？**

- 方案 A（薄重建）：保留句柄，只整理切片 / 注册表 / 派发。
  快，但 State 仍不是真正可序列化，headless replay 依赖同一个 engine。
- 方案 B（深重建）：State 只存 id，`effects/engine` 持有句柄，reducer 接收只读 engine-view。
  纯度高，插件/测试/多实例友好，但需要先写 core 适配层。

本设计默认推荐 **B**；如果优先快速恢复功能，可先用 A 落地，再把 engine 边界抽出来。
