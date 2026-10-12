# edit3 抽象模型（重构前拆解）

> 面向重构：先**忽略 Racket 代码形状**，把 edit3 重新描述成一台机器 + 若干纯投影，
> 然后标出边界/限制与耦合点，最后给出目标抽象模型与优化顺序。
> 细节以代码为准；本文件只保留「原理模型」。

---

## 0. 一句话原理

edit3 是一台**以单一不可变 State 为真值的纯事件状态机**，外面套三条纯投影流水线：

```
reduce : State × Event        → State × [Effect]      （逻辑，纯）
project: State × Size         → View(几何 / 面板 / face)（投影，纯）
jobs   : State                → [Job]                  （后台意图，纯）
```

+ 一层薄的**可变 runtime**（事件通道、worker 线程、唯一解释 Effect 的地方），
+ 一个**外部命令式文本引擎**（文本/游标/face 的真身，用 handle 引用）。

一句话：**State 决定一切，事件驱动，几何与显示都是 State 的投影，副作用被推到边缘。**

---

## 1. 功能原理模型

### 1.1 三个数据流

| 流 | 输入 | 输出 | 是否纯 | 备注 |
|---|---|---|---|---|
| 逻辑 | State + Event | State′ + Effects | 纯 | `step` |
| 显示 | State + Size | 屏幕 patch | 纯（除文本引擎写回） | `layout`→`render` |
| 异步 | State | [Job] | 纯 | `jobs`；结果变成 Event 回流 |

### 1.2 事件是一等数据

`Event = key | text | cursor | resize | job | tick`。键盘、鼠标、终端 resize、
后台结果、定时**走同一条流**。所有「路由/守卫」都编译成 `State × Event → Bool`，
唯一入口是 `route-input`。异步没有特权通道。

### 1.3 Effect 与 Job 分工

- **Effect**：一次性 IO（打开/保存/退出/日志），只在 runtime 边缘 `perform!`。
- **Job**：可等待的后台计算。`step` 只登记意图；runtime 派给 worker；结果以
  `job-event` 回注；`step` 收尾并 `emit 'job`，插件在钩子里消费。
- **service**（job 的实现）必须是**纯函数**，不得碰 State / 文本引擎。

### 1.4 投影原则

- **几何** = `layout(tiling, floats, size)`，带来源（placement + handle），
  `hit` 是纯查表，渲染与命中共用同一份。
- **面板** = 把 State 投影成文本 + face，写回一个普通 document。
- **face** = 对文档文本做扫描，写成引擎的 face 区间。
- **一切皆 document**：面板的「选择/光标」就是普通视图游标，没有第二套游标。

---

## 2. 抽象状态

### 2.1 实体

| 抽象 | 含义 | 代码落点 |
|---|---|---|
| `Doc` | 一段文本 + 版本 | core 引擎（外部盒），State 只留 handle |
| `doc-meta` | 路径 + 存档时的 handle | `state.docs : did → doc-meta` |
| `View` | 一个游标/滚动/face 绑定到某 Doc | core 引擎 |
| `Window` | `(wid, vid)`，vid=#f 表示空窗 | tiling 叶子 / float |
| `Tiling` | 二叉/多叉 guillotine 切分树 | `state.tiling` |
| `Float` | `(wid, vid, anchor, size, border)`，有序 | `state.floats`（表头=最上） |
| `Focus` | 一个 wid | `state.focus` |
| `Drag` | `idle | dragging(handle, start, snapshot)` | `state.drag` |
| `Feature` | 插件/框架局部状态，一个 hash | `state.views`（其实是 feature 存储） |
| `Registry` | ops/prompts/panels/regions/routes/hooks/faces/services | 存在 Feature 里 |

### 2.2 三条同构关系（关键简化）

1. **Window ↔ View**：窗口显示视图，平铺窗与浮窗同构（都是 `wid+vid`）。
2. **Panel ↔ Document**：面板就是文档，选择就是游标。
3. **Layout item ↔ 求解器输入**：每段不是固定格数，而是 `basis/grow/shrink/min`。

### 2.3 State 值语义的边界

State 是**值**（不可变、可比较），但其中 `ed` 是**命令式引擎的盒**：
- State 比较/相等**不覆盖文本**；
- 「脏」用 **handle 身份**判断（`doc-meta.saved` vs `document-handle`）；
- 这是刻意的：文本不进值语义，避免 O(doc) 拷贝。

---

## 3. 逻辑分层

从底到上；每层给「局部骨架」与「向外暴露的组合点」。

### L0 · 值与基础设施（纯）

- `state`（所有值类型）、`event`、`effect`、`face`（分层 face 值）、
  `lex/kind/bracket/bracket-depth`（**Racket 专用支撑算法**）、`fs`（IO 原语）。
- 骨架：无状态；纯函数 + 透明 struct。
- 组合点：被所有上层 require。
- ⚠️ 分类问题：`lex/kind/bracket*` 是「编辑器域支撑」，不是「通用 UI/协调」。

### L1 · 文本引擎适配（命令式边界）

- `adapter`：把 State 的视图/窗口操作翻译成 core 引擎调用（插入、游标、face、渲染 patch）。
- 骨架：`render-layout` / `insert!` / `set-point!` / `face-batch!` / `layout->rectangles`。
- 组合点：L2 几何（内容矩形）、L3 渲染、L4 会话。

### L2 · 几何（纯）

- `layout`（求解器 + placement + handle + junction）、`resize`（浮窗手术）、`border`（装饰）。
- 骨架：
  - `solve-axis`：basis/grow/shrink/min → 长度，**min 是地基不变量**。
  - `layout`：tiling → placements；reserves `n−1` 分隔格；再解 floats（anchor→rect，z=顺序）。
  - `hit`：placement/handle 按 z 取最上，同 z 手柄优先，junction 优先于 boundary。
- 组合点：输出 `geometry`，被渲染、命中、拖拽共用。

### L3 · 交互（纯状态机）

- `interaction`：`press/move/release`；拖拽用**按下时快照 + 总位移**（不漂）。
- 覆盖三类 handle：`boundary`、`junction`（拖两条线）、`float-move/float-resize`。
- 组合点：改 `state.tiling.basis` 或 `state.floats`；由 L5 的 op `pointer*` 调用。

### L4 · 会话与领域（核心逻辑集中区）

- `window`：浮窗原语（open/raise/focus/close、wid↔vid）。
- `session`（≈990 行，**事实上的领域大杂烩**）：打开/保存/分裂/关闭/区域/输入行/树/
  缓冲区/浮窗/指针入口。
- `panels`：面板注册表 + 每帧投影；`prompt`：输入行语义注册表；
  `job`：异步账本；`hook`：生命周期钩子。
- 骨架：
  - 会话操作 = `State → (State, [Effect])`。
  - 面板 = `State × vid → (text, faces)`，写回 document。
- 组合点：被 L5 的 op 解释器调用；被插件的会话操作面（经门面）调用。

### L5 · 路由与命令（数据驱动）

- `keymap`（表代数）、`command`（binding→route 编译）、`op`（tag→handler 注册表）、
  `route`（CPS 声明式路由）、`mode`（路径 matcher → 文档键表）。
- 骨架：
  - 键表是数据 `(binding scope op...)`；
  - 路由三层：全局 → 面板（树/缓冲区）→ 文档（focused-keymap）；
  - `run-ops` = 前缀/放置状态机 + 顺序解释 op 序列。
- 组合点：`scope-of`（**硬编码作用域表**）、op 注册表、doc-key matchers。

### L6 · 装配（组合根）

- `plugin` 契约（纯数据包）+ 装配器（`install-plugin-*` / `collect-*` / `run-plugin-boots`）。
- 骨架：插件贡献 → 叠加到基础注册表 → 编译路由 → **存进 State 的 feature**。
- 组合点：`boot`（写底盘 + 跑 boot 钩子）；`main`（解析 catalog，组装根）。
- 依赖规则：插件只 require `extension`（白名单门面），core 不反向依赖插件。

### L7 · 运行时与后端（唯一可变处）

- `runtime`：每帧 `layout→render→draw→dispatch jobs→step→perform`；事件通道；worker 池。
- `backend/tui`：终端 IO；`theme`：face → ANSI 字节。
- 骨架：唯一持有可变状态（通道、已派发 id 集、worker 线程）。
- 组合点：`perform!`（Effect 解释）、`run-service`（Job 解释）。

### 插件侧

- `plugins/*`：只依赖 `extension`；贡献 ops/panels/regions/keys/matchers/hooks/faces/services。
- `plugins/lang/*`：**纯库，不是插件**（无 `plugin` 值），被插件当工具用。

---

## 4. 四条流水线（组合时序）

### 4.1 输入

```
backend 事件 ──输入线程──▶ 事件通道 ──▶ step:
   resize? → 忽略体
   job?    → job-finish + emit 'job
   其它    → 取 routes → layout(size) → ctx(size,g) → route-input
             → 命中的 op 序列 → run-ops → 会话操作 → (State', Effects)
             → focus 变则 emit 'focus-changed
```

### 4.2 渲染

```
refresh-panels!（State→State，但**写回引擎**）
 → emit 'before-render（插件 reposition 浮窗）
 → layout（第二次）
 → render: content-placements(内缩) + border-runs(缝/框) + focus vid
 → adapter → core 引擎 patch → backend draw
```

### 4.3 异步

```
step 里 job-submit（登记）→ runtime jobs 取待办（去重派发）
 → worker 跑 service（纯）→ job-event 回注 → step: job-finish + emit 'job
 → 插件 'job 钩子消费（按 tag）
```

### 4.4 face

```
after-edit / after-insert / after-nav（core 预装钩子）
 → 焦点文档 → face-plugins scan（整篇）→ face-compose 分层 → 写回引擎
```

---

## 5. 边界与限制（现状）

### 5.1 结构性边界

1. **State 值语义不含文本**；脏判定靠 handle 身份；引擎是盒。
2. **service 必须纯**，不得碰 State/引擎；否则破坏模型。
3. **插件运行在主线程**；只有 service 在 worker。
4. **无 job 取消 / 优先级**；`'job-done` 表默认不回收（靠插件自己 `job-forget`）。
5. **插件无沙箱**：门面虽白名单，但仍导出会写引擎的会话操作。

### 5.2 布局/窗口边界

6. **布局是 guillotine**：只能整行/整列切分，不能 L 形/任意贴边。
7. **分隔缝是独立 1 格**，不占内容；min 是硬不变量。
8. **浮窗整块都是 move handle**：鼠标点在浮窗上只聚焦/拖动，**不能定位光标**。
9. **浮窗不能锚到浮窗**：`rel` 只在平铺窗里解析，否则退化为整屏。
10. **浮窗无裁剪概念**：内容按矩形渲染，越界靠 clamp；无遮挡剔除。

### 5.3 逻辑边界

11. **`scope-of` 作用域表硬编码**在 step；加新作用域要改核心。
12. **`boot` 硬编码底盘**（sidebar 28 | editor flex | status）与默认面板集；不声明式。
13. **面板强制整篇重建**：文本变了就 `assign!` 整个文档；face 每帧重设。
14. **face 每次编辑整篇重扫**（无按行增量缓存）。
15. **`feature` 命名空间共享**：框架键与插件键同处一个 hash，靠 symbol 约定，易撞。
16. **doc-key matcher / 绑定**深嵌在会话里。

### 5.4 性能边界

17. **每事件两次 `layout`**（runtime 渲染一次、step 路由一次）。
18. **每帧 `refresh-panels!` 全量**（O(面板文本)），且鼠标移动也跑。
19. **`border-runs` / `junction-handles` 按屏幕格扫描**（O(area)）。
20. **face 整篇重扫**（O(doc)），大文件显著。
21. **面板/face 刷新无条件**，即使不可见。

---

## 6. 耦合点清单（重构靶子）

| 级别 | 耦合点 | 说明 | 方向 |
|---|---|---|---|
| 高 | 纯投影**暗写引擎** | `refresh-panels!`/`refresh-doc-faces!` 名义 State→State，实则 `assign!/set-point!/face-batch!` | 拆出 commit 阶段 |
| 高 | `session.rkt` 大杂烩 | 文件/窗口/树/区域/输入行/浮窗/指针全在一起 | 按领域拆 |
| 高 | `feature` 单命名空间 | 框架与插件状态混放 | 命名空间 + 类型化访问 |
| 高 | `step` 认识底盘 + scope | `boot` 与 `scope-of` 在核心里 | 装配外置 + 作用域注册 |
| 中 | 两次 layout | 渲染与路由各算一次 | 一次 layout 进 Ctx |
| 中 | 插件直接写引擎 | 经会话操作改文本 | 命令提交面（只读 State） |
| 中 | `config/app` 聚合 + 插件直连 `config/syntax` | 配置层次含混 | config 只做数据，键/主题分家 |
| 低 | `lex/kind/bracket` 在 core | 编辑器域支撑混进通用核 | 归位「内置功能包」 |
| 低 | `plugins/lang/*` 命名 | 纯库挂 plugins/ | 移到 `support/` |

---

## 7. 目标抽象模型（简化 / 受限）

### 7.1 分层重构后的形态

```
Environment（装配期 immutable，运行期只读）
  = 注册表(op/prompt/panel/region/keys/matchers/hooks/faces/services)
    + 底盘声明(chassis) + 主题 + 配置

World（= 现 State 的纯逻辑部分）
  = windows(tree + overlays) + docs/view-refs + focus + drag
    + features(namespaced) + jobs-ledger

TextStore（外部、版本化、命令式）
  = did → (text, version) ; vid → (doc, point, scroll, faces)

Commit（唯一写引擎的地方）
  = apply(World′, View′) → TextStore′ + screen patch
```

### 7.2 每帧单管道

```
Ctx   = derive(World, Size)              // geometry + hit，算一次
Event
World′ = reduce(Env, Ctx, World, Event)  // 纯；产出 Effects/Jobs
View′  = project(Env, World′)            // 纯：几何 + 面板 + face（可缓存）
patch  = commit(TextStore, World′, View′)// 唯一副作用
```

### 7.3 约束（把自由度收小，换清晰）

1. **投影纯 + commit 集中**：`project` 不得碰引擎；所有写文本/face 只在 `commit`。
2. **一次 layout**：`Ctx` 贯穿渲染与路由，消除重复求解。
3. **Environment 与 World 分离**：注册表不进 `World.features`；插件状态按 `(plugin,key)` 命名空间。
4. **插件只读 World + 提交命令**：插件不直接写引擎；需要副作用就产出 Effect/Command。
5. **声明式底盘**：侧栏/状态栏/默认面板由 `chassis` 数据描述，`boot` 只解释。
6. **作用域注册**：`scope` 由环境提供 `symbol → State×Event→Bool`，核心不认识具体值。
7. **可缓存投影**：`geometry` 按 `(tiling,floats,size)` 缓存；面板按文本版本缓存；
   face 按 `(did,version)` 做**按行增量**。

### 7.4 需要先定的决策

- 文本引擎是否纳入 `World` 的版本体系（推荐：独立 `TextStore` + version，不并入值）。
- `Feature` 是否强类型（推荐：`(namespace . key)` + 访问器）。
- 插件写引擎的权限边界（推荐：只读 + Command；特殊需求走受控 API）。
- 面板投影是「拉」还是「推」（推荐：拉 + 版本缓存）。

---

## 8. 性能优化清单（对应边界 17–21）

1. **layout 一次**：runtime 算 `Ctx.geometry`，`step` 复用。
2. **junction/border 从 handle 直接生成**：免 O(area) 扫格（已部分如此，仍可再省）。
3. **face 按行增量**：移植 line-scan 思路（`(did, line-version)` 缓存）。
4. **面板按版本 diff**：文本未变不 assign；仅可见面板投影。
5. **刷新门槛**：鼠标 move / 无关事件不触发全量面板刷新。
6. **job 表回收**：done 表 TTL 或按消费者取用即删。
7. **缓存键**：completion/docs 的导出缓存加容量/失效策略。

---

## 9. 建议的重构顺序

1. **拆 `session.rkt`** → `documents / windows / regions / prompts / panels-ops / pointer / files`。
2. **分离 Environment 与 World**：注册表/路由移出 `features`，`features` 改名分命名空间。
3. **引入 `commit` 阶段**：把面板/face 的引擎写回从 `project` 里拿出来。
4. **一次 layout + Ctx 贯穿**。
5. **声明式底盘 + scope 注册**，`boot` 降级为解释器（继续外置 catalog）。
6. **face 增量 + 面板 diff** 做性能。
7. **归位 `lex/kind/bracket` 与 `plugins/lang`**，收敛 core 语义。

> 每一步都可单测；不改变对外行为，只改变内部形状。
