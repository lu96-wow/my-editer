# edit3 —— 重构设计

> 目标：在 edit2 的「State + 4 个纯函数 + CPS 路由 + 事件循环」骨架之上，**从设计层重做
> 布局与指针交互**，让「窗口运行时变化」和「鼠标」成为一等公民，并把浮窗纳入同一套模型。

## 0. 为什么重构（edit2 的病）

edit2 的布局树 `(split axis ((size node) ...))`，`size = 整数 | 'flex`。这个模型对**声明式
初始布局**够用，但：

1. **运行时改尺寸是事后补丁。** 拖动一条缝要：把 flex 物化成整数、按 `int|flex` 分三种
   情况、用 `path`+`index` 找回 split、再写回。规则不对称（flex 侧靠 layout 兜底），
   拖到极端时会把别的窗挤塌。
2. **最小尺寸不是布局的性质。** 只在拖拽代码里 clamp，`layout` 本身不保证；嵌套子树
   没有「随轴累加的最小尺寸」，外层边界会把里层压到 0/1。
3. **几何不带来源。** `placement` 只有窗口，边界要重新遍历树算；鼠标命中一条缝就得
   再推导一遍，容易和渲染帧不一致。
4. **指针状态没有位置。** 拖拽塞在 `feature 'drag` 里，没有类型、没有状态机，press/move/release
   的意图混在重算里。
5. **浮窗进了平铺树。** `float` 被当成 split 的一个 0 尺寸 part，靠 `anchor` 事后摆位；
   层级（z）、移动、缩放都别扭。

结论：**尺寸约束和指针交互必须进模型，不能是补丁。**

## 1. 目标 / 非目标

目标：
- 容器改变（终端 resize）、窗口增删、用户拖拽，三者共用**同一个纯求解器**；结果只是
  tree + size 的函数。
- **最小尺寸是求解器内建约束**：任何输入都不会让窗口 < min（含嵌套）。
- **几何带来源**：一次求解同时产出「窗口矩形」和「可拖手柄」，命中测试吃它，拖动不再重推。
- **指针交互是显式状态机**，与键盘一样是纯 `State + Event -> State + [Effect]`。
- 浮窗与平铺窗同构（都是 window = wid + vid），但**浮窗不进平铺树**，是覆盖层。

非目标：
- 不重写文本引擎：`core/`（`core/editor.rkt` 等）原样复用，edit3 只在协调层。
- 不追求任意树形布局算法，终端里够用即可（行列切分）。

## 2. 核心概念

- **window（窗口）**：身份 `wid` + 显示 `vid`（沿用 edit2 的 wid/vid 分离）。平铺和浮窗
  都是 window；焦点、命中、z 都用 `wid`。
- **tiling tree（平铺容器树）**：`container` 节点，叶子是 `tile`（一个 wid）。
- **float（浮窗）**：有序表，顺序 = z（头在最上）；不进平铺树。
- **geometry（几何）**：某尺寸下求解出来的**值**——窗口 placement + 手柄 handles。
- **interaction（交互）**：`idle | dragging`，dragging 引用一个 handle。

## 3. State 与值类型

```racket
;; ---- 窗口 ----
(struct tile  (wid vid min border) #:transparent)         ; 平铺叶子：窗口 + 最小尺寸 + 边框
(struct float (wid vid anchor size border) #:transparent) ; 浮窗：锚点 + 尺寸 + 边框；z = 在表里的位置

;; ---- 平铺容器树：只有“结构 + 弹性意图”，几何永不存 ----
;; item 不是固定格数，而是求解器的输入：
;;   basis  期望基准尺寸（整数格数；初值 = 平分父容器）
;;   grow   容器有多余空间时的分配权重（0 = 不参与）
;;   shrink 容器空间不足时的收缩权重（0 = 不参与）
;;   min    沿轴硬下限（整数 ≥ 1；浮窗 0）
(struct item   (basis grow shrink min child) #:transparent)
(struct split  (axis items) #:transparent)             ; axis : 'h | 'v
(struct tiling (root) #:transparent)                   ; 根；可为 #f（空）

;; ---- 浮窗锚点 ----
;; rel : wid | 'screen ；h : left|right|center ；v : top|bottom|center ；dx/dy : 偏移
(struct anchor (rel h v dx dy) #:transparent)

;; ---- 唯一状态 ----
(struct state
  (ed      ; core 编辑器句柄（命令式引擎，box 是设计）
   docs    ; did -> doc-meta（预留）
   views   ; vid -> 特性局部状态（预留）
   tiling  ; tiling 树
   floats  ; (listof float)，头在最上
   focus   ; wid（窗口身份）
   drag)   #:transparent)
```

关键：**`basis/grow/shrink/min` 都在 item 上**，所以「容器 resize」「运行时刻改尺寸」
不需要额外机制，求解器直接读它。

## 4. 布局求解器（本设计的核心）

输入：tiling 树 + floats + 屏幕尺寸。输出：geometry（placements + handles）。

### 4.1 一维分配（`solve-axis`）

对 `(split axis items)` 给定沿轴 extent `E`：

```
1. 若 E < Σmin           → 全部取 min（溢出，允许；不压到 min 以下）
2. free = E - Σbasis
3. free > 0 → len_i = basis_i + free * grow_i / Σgrow   （Σgrow=0 时多余留给最后一格）
   free < 0 → len_i = basis_i + free * shrink_i / Σshrink（按收缩权重削减）
   free = 0 → len_i = basis_i
4. len_i < min_i → 抬到 min_i（并从“高于 min 的余量”补回，保证 Σlen = E 当可行）
```

性质：
- **flex 不再是特例**：`grow/shrink` 是权重，0 就是固定面板。所以 `int|flex` 的分支消失了。
- **min 是求解器保证的**：不管 basis 被写成多小/多离谱，结果都 ≥ min；嵌套 split 的 min
  由**沿轴累加**得到（见 4.3），所以外层也压不塌里层。

### 4.2 运行时改尺寸 = 改两个相邻 item 的 basis

拖动 item `i` 与 `i+1` 之间的缝，位移 `Δ`：

```
basis_i   += Δ          （夹到使结果 ≥ min_i）
basis_{i+1} -= Δ        （夹到使结果 ≥ min_{i+1}）
```

因为 `Σbasis` 不变 → `free` 不变 → 第 3 步对**所有** item 的加项不变，于是
`len_i += Δ, len_{i+1} -= Δ`，其它 item **精确不动**。

- 对称、无方向特例、无物化、无路径分支。
- 两个都是面板（`grow=shrink=0`）时同样成立（就是改固定格数）。
- 拖动结束也不需要“整理”，因为改的就是意图。

### 4.3 最小尺寸：**每叶自带**，沿轴累加 + 每条缝 1 格

最小尺寸不是全局常量：它是**叶子（窗口）自己的属性**——「一个窗口最小能多小」取决于
它的内容，而不是一刀切。编辑窗要能看见光标，故取 2×2；面板 / 单行状态条 / 顶部工具
条等只需 1 格。想再细分就再给一类即可。

```
leaf.min            = (cons min-w min-h)      ; tile 自带的硬下限
min-w((tile _ min)) = car(min)
min-w((split 'h is))= Σ min-w(child) + (n-1)  ; n-1 条分隔线
min-w((split 'v is))= max min-w(child)
min-h 对 'v 同理（轴对调）
```

两个好处：
- **贴边不需要特例**：最后一个 item 的终点 = extent，所以底/右贴边的单行面板天然贴着边缘；
  之前看到「状态栏差一行」，是因为叶子被全局 min=2 抬成 2 行、内容又顶对齐，余出的一行
  空在中间，**不是**分隔线把边缘顶开了。
- **顶部将来同理**：1 行的顶部条只要 `leaf.min` 给 1，拖动时也能压到 1 行。

`item.min` 在**创建/分裂时**由子树的 min 填好（`min-size` 读叶子的 `min`）；求解器只用
`item.min`，不每次递归。分隔线占位见 4.6——**min 是内容下限，缝是缝，两者正交**。

### 4.6 分隔线占位（不占内容）

split 有 `n` 个子项 → **预留 `n-1` 格**：内容空间 `= extent - (n-1)`，`solve-axis` 只分内容；
放置时每段后面跟 1 格缝。缝是独立格，所以交点可以取 `┬ ┴ ├ ┤ ┼`，不会覆盖窗内
容。边界 handle 就是这 1 格缝（跨轴方向铺满），命中/拖动都在它上面。

### 4.4 容器 resize

终端尺寸变了：extent 变了 → 重新跑求解。`grow=1` 的编辑窗按权重吸收，`grow=0` 的面板
（侧栏 28、状态栏 2）不动。**没有额外代码路径。**

### 4.5 增删窗口

- 分裂一个 tile：把它替换成 `(split axis (i  i'))`，两个 item 的 `basis = 1`、
  `grow = shrink = 1`（basis 相等 → 任意 extent 都等分）、`min = 各自子树 min`（tile 为 2）。
  谁放前谁放后由命令给。
- 关窗口：从树里摘掉 item；只剩一个 item 的 split 收拢。空树 → `#f`。
- 打开视图：优先填空 tile，否则新建/分裂/让用户选目标（沿用 edit2 的 placing 语义）。

## 5. 几何带来源（命中不重推）

求解器一次产出：

```racket
(struct rect      (x y w h) #:transparent)
(struct placement (wid vid rect z) #:transparent)      ; 窗口
(struct handle    (kind rect z data) #:transparent)      ; 可拖手柄（z 用于命中优先级）
;; kind = 'boundary | 'junction | 'float-move | 'float-resize-{nw,ne,sw,se}
;; data = 缝：(axis path index lens mins bases)  |  十字路口：(listof 缝 data)
;;        | 浮窗：(wid edge)
(struct geometry  (placements handles w h) #:transparent)
```

- `layout : tiling floats size -> geometry`（纯）。
- `hit : geometry x y -> (or/c handle placement #f)`（纯，最上层优先）。
- 鼠标 press 直接拿 handle，**不需要再遍历树**。渲染和命中共用同一个 geometry，天然一致。
- **十字路口**（四窗相交）额外生成一个 `'junction` handle（1 格，`hit` 里优先于
  `'boundary`）：它聚合穿过该点的**整条竖缝线 + 整条横缝线**（同列 / 同行的所有缝段）。
  拖动时按轴分组，各自取多段的可移动区间交集，一条 move 同时改两条线 → 四窗一起缩放。
  T 字路口只有三臂，不生成（仍按普通缝拖）。渲染只认 `'boundary`，junction 纯用于命中。

## 6. 指针 / 交互状态机

指针事件是一等数据（沿用 edit2）：

```racket
(struct cursor-event (kind button x y) #:transparent)  ; press | release | move | scroll
```

`state.drag`：

```racket
(struct idle  () #:transparent)
(struct dragging (handle start-x start-y snapshot) #:transparent)
;; snapshot 保存按下时的起点（basis 对 / 浮窗 anchor+size / 光标偏移），
;; move 用「总位移」算，不累积误差；release 回 idle。
```

转移（纯）：

| 事件 | idle | dragging |
|---|---|---|
| `press` | 命中 handle → dragging(handle, 起点, 快照)；否则窗口聚焦/定位光标 | 忽略 |
| `move` | 忽略 | 按 handle.kind 改 tiling.basis / float.anchor/size |
| `release` | 忽略 | → idle |

好处：拖拽意图有类型、可测；不只鼠标——键盘也能造 `dragging`（例如 `C-w` 前缀选边）。

`resize` 手术是独立的纯函数：

```racket
(layout-set-bases tiling path index bi bj) -> tiling   ; 从按下时原 basis + 总位移算（不漂）
(move-float*   float dx dy)                -> float
(resize-float* float edge dx dy rel-rect W H) -> float
```

## 7. 浮窗

- **不进平铺树**：`state.floats` 是有序表，顺序即 z（头最上）。`layout` 先铺平铺，
  再把 floats 按 z 覆盖上去（`panes->composition` 的 deep 已经能做）。
- **窗口同构**：`float` 也是 `(wid vid ...)`，所以焦点、命中、编辑、关闭都和平铺窗共用代码。
- **几何**：`anchor`（贴屏或贴某 wid，`left/right/center` + 偏移）+ `size`。求解时 clamp 进屏，
  `size` 夹到 min（浮窗最小 2×2 之类）。
- **交互**：边框/标题 → 移动（改 anchor 的 dx/dy）；四角/四边 → 缩放（改 size，反向角/边不动）。
  这些都由 `handle` 表达，和平铺缝同一套 press/move/release。
- **层级与焦点**：焦点浮窗提到表头（raise-on-focus 不变量）；新开压表头。
- **声明式**：`config/floats.rkt` 给「名字 → anchor/size」，`float-open NAME` 查表。
- **detach / dock**（可后做）：tile ↔ float 只是 wid+vid 的载体互换，纯手术。

## 8. 纯函数与效果边界（沿用 edit2）

```
layout  : tiling floats size -> geometry      ; 纯
hit     : geometry x y -> handle|placement     ; 纯
step    : routes state event -> state + [effect]
render  : state geometry -> [piece]            ; 纯
jobs    : state -> [job]                       ; 纯
```

可变的只有：终端、worker 池、上一帧缓存。Effect 只承载一次性 IO。

## 9. 模块结构

```
edit3/
  main.rkt                    入口（可带文件参数）
  config/
    theme.rkt                 调色板（face → style 值）
    keys.rkt                  命令表（纯数据：binding + scope + op）
    layout.rkt                区域 / 启用面板 / 边框（纯数据）
    floats.rkt                浮窗声明（名字 → anchor/size）
    app.rkt                   配置入口（聚合）
  core/
    state.rkt                 State + 值类型（rect/anchor/tile/float/item/split/tiling/
                              placement/handle/geometry/idle/dragging/doc-meta/prompt/placing）
    layout.rkt                纯求解器（min-size / solve-axis）+ 几何/命中 + 树手术 + 区域贴边
    resize.rkt                纯 resize 手术（浮窗 move/resize；缝改 basis 在 layout）
    interaction.rkt           指针状态机（press/move/release）
    border.rkt                纯装饰（分隔线含交点 + 浮窗框）
    render.rkt                geometry -> core rectangle/piece
    window.rkt                wid ↔ vid（平铺/浮窗统一）：查询 / 改 vid / 摘窗口
    session.rkt               会话操作（纯）：打开/保存/显示/分裂/关闭/脏判定/区域/输入行/树/浮窗/指针
    job.rkt                   异步工作账本（job / service / jobs / job-finish）
    runtime.rkt               backend 协议 + 事件循环 + 输入/worker 线程（每帧先 refresh-panels!）
    step.rkt                  转移（编辑 / 分裂 / 关窗 / 浮窗 / 面板 / 区域 / 文件 /
                              输入行 / 指针 / 退出）+ op 注册表 + 路由
    panels.rkt                面板 = 文档（状态栏 / 文件树 / 缓冲区 / 输入行 / 日志）
    adapter.rkt               core/editor 边界（唯一 require core/editor）
    theme.rkt                 face → ANSI
    event.rkt effect.rkt fs.rkt
    route.rkt                 CPS 声明式路由（数据表 + 续延）
    op.rkt prompt.rkt         原语 / 输入行 kind 的**注册表**（纯值）
    keymap.rkt                键表组合（纯数据代数）
    command.rkt               binding/entry → route 编译
    mode.rkt                  路径 → document 键表的匹配层
    plugin.rkt                插件契约 + 装配器（把贡献叠加到基础注册表）
    extension.rkt             插件门面（白名单；插件只 require 这个，不碰 step）
    backend/tui.rkt           终端输入解码 / 字节输出
  plugins/
    catalog.rkt               插件目录（名字 → 实现）
    demo.rkt                  示例插件
    auto-pair.rkt             括号自动配对（编辑行为插件）
    completion.rkt            补全菜单
    docs.rkt                  标识符文档弹窗（本地定义 + 标准库 xref/bluebox/HTML）
    lang/source.rkt           #lang / require / 定义 / provide 启发式扫描（纯）
    lang/pool.rkt             require spec → 最终绑定名 + 模块导出（纯）
    lang/module-index.rkt     已安装模块路径索引（require / #lang 补全用）
    lang/local-docs.rkt       缓冲区顶层定义 → 一行摘要（纯）
    lang/docs.rkt             标识符 → 文档（xref / bluebox / HTML）
    lang/doc-html.rkt         HTML 文档页 → markdown
  config/
    plugins.rkt               本次启用哪些插件（只给名字）
  backends / test: edit3-test/core/*.rkt（纯函数 + 装配单测）
```

复用：根目录 `core/`（文本引擎）原样。

## 9.5 插件 / 扩展

一个 **plugin** 是纯数据包，向 edit3 现有的注册表贡献能力；没有新机制，只是把
「基础注册表 + 插件贡献」在 `boot` 时叠一次：

```racket
(struct plugin (name ops prompt-kinds panels regions
                     key-tables doc-key-matchers faces hooks services boot on-open) #:transparent)
```

- 贡献点对齐 edit2 的注册表：`op-register`（原语）、`prompt-kind-register`、
  `panel-register`、区域、`keymap` 条目、`doc-key-matchers`（路径匹配）、`services`（worker）。
- **文档打开时匹配 + 组合**：`open-file*` / `set-focused-path!` 时，把所有
  `doc-key-matchers` 里命中的表（多插件可同时命中）按顺序 `compose-keymaps` 成一张，
  绑到该 document（`bind-doc-keys`）；同名同 scope 的绑定后表覆盖前表。随后跑
  各插件的 `on-open`（`(st did path) -> st`）。`focused-keymap` 返回这张组合表，
  doc 路由在全局路由之前先试它。
- **生命周期钩子（`hooks`）**：`reaction = point + when(st) + priority + proc(st,args)`；
  事件点 `before-render / after-edit / after-insert / after-nav / focus-changed /
  document-opened / document-closed / log-appended / tick`。`core/hook.rkt` 的 `emit`
  按 priority 降序跑命中项；`step`/`runtime` 在各点 emit。
- **face 插件（`faces`）**：`face-plugin = name + applies?(path,text) + scan(path,text,cursor)`；
  `scan` 返回每行一个 face 向量。核心在多插件间按顺序 `face-compose` 叠层，写成引擎
  face 区间（`core/face-plugin.rkt`，整篇重扫；edit/ 的按行增量缓存将来可换）。
  刷新时机：打开文档 / 编辑后 / 移动光标后。示例：`plugins/syntax.rkt`。
- **异步 jobs**：`job = id + kind + payload + tag`。插件用 `job-submit` 把「想发的工作」
  登记进 State（纯）；`jobs : state -> [job]` 从 State 取待办（id 升序）。runtime 持有
  唯一可变状态：输入线程 + worker 线程池（`thread` + channel）；worker 按 `kind` 找
  `service`（`#:services` 贡献，handler 是**纯函数**，不碰 State）并跑，结果以
  `job-event` 回注同一条事件流；`step` 收到后 `job-finish` 把 open→done 并 `emit 'job`，
  插件在 `'job` 钩子里按 `tag` 消费。键盘 / 鼠标 / 并发结果走同一条流。
- 装配器 `install-plugin-*` / `collect-*` / `run-plugin-boots` / `run-plugin-open` 产出本次
  运行的 op / prompt / panel / region / key-table / matcher / hooks / faces，编译成路由后
  **存进 State 的 feature**（`'panels` `'regions` `'doc-key-matchers` `'routes` `'plugins`
  `'hooks` `'faces`）。`step` 从 State 读，不依赖插件实现，所以插件可自由依赖
  `core/extension.rkt` 而不循环。
- `core/extension.rkt` 是**白名单门面**：插件只 require 它，拿到 State 词汇、注册表
  构造、adapter 原语（含 face 写回）、窗口/布局查询、keymap/command/route、face/lex。
- `config/plugins.rkt` 只给名字；`plugins/catalog.rkt` 解析成实现（未知名报错）。

## 10. 进度

- [x] 求解器（item/split/solve-axis/min/geometry/hit）+ 单测。
- [x] 树手术（split/remove）+ 单测。
- [x] 指针状态机（press/move/release）+ 浮窗手术 + 单测。
- [x] 浮窗（anchor/size/z + 移动/缩放 + 声明式 config/floats.rkt）。
- [x] 装配（panels/render/tui/runtime）+ 分隔线与交点字形。
- [x] **命令系统平移**（route/op/prompt/keymap/command/mode + config/keys.rkt）+ 路由化 step。
- [x] **区域（region）**：侧栏成员互斥（树↔缓冲区）、显隐（`C-b` 侧栏 / `C-l` 日志）、
      贴根 / 贴主区两种 anchor；layout 提供 `layout-add-side` / `layout-add-adjacent`。
- [x] **文件打开 / 保存**：`fs.rkt` + `doc-meta`（path/saved）+ `M-s` / 脏文档退出询问 + 落盘 effect。
- [x] **可交互文件树 + 缓冲区面板**：展开/收起、隐藏项、新建文件/目录、删除、重读；
      面板选择 = 文档光标。
- [x] **输入行**：`*input*` 文档就地占状态栏 pane，label 只读，提交按 kind 注册表分派。
- [x] **每窗口独立边框（edit2 的 `C-t` / `border-toggle`）**：`tile`/`float` 带 `border` 字段；
      分隔线只在相邻窗里至少一个有边框时绘制（
      全关则不画、不留字形）；浮窗无边框则不画框。
- [x] **插件层**：`core/plugin.rkt` 契约 + 装配器；`core/extension.rkt` 白名单门面；
      `config/plugins.rkt` + `plugins/catalog.rkt` + 示例 `plugins/demo.rkt`；`boot` 装配
      并存入 State feature；`step` 从 State 读路由。
- [x] **生命周期钩子**：`core/hook.rkt` 的 `reaction` + `emit`；事件点
      `before-render / after-edit / after-insert / after-nav / focus-changed /
      document-opened / document-closed / log-appended`；插件 `#:hooks` 贡献。
- [x] **face 端口 + face 插件协议**：`face-batch!`/`face-range!`/`document-face-at`、
      `core/face.rkt`（`face-stack`/`face-compose`）、`core/face-plugin.rkt`（多插件叠层，
      打开/编辑/移动光标时刷新）、`core/lex.rkt`、`core/kind.rkt`；
      验证插件 `plugins/syntax.rkt`（关键字/字符串/注释/数字）。
- [x] **补全插件**：`plugins/completion.rkt`（**不抢焦点**的浮窗菜单：编辑器保持焦点
      → 边打边筛；`before-render` 每帧随光标落位；`popup-window` 滚动窗口；
      `complete`/`complete-selected` 颜色）。`window.rkt` 加 `open-float-overlay*` 等
      状态级浮窗原语；插件键表排在基础键表之前。
- [x] **高亮对齐 edit/**：`core/face.rkt` 加 `palette-color/palette-bg`，`config/theme.rkt`
      加 `palettes`；`plugins/syntax.rkt` 用调色板；新增 `plugins/words.rkt`（当前词）、
      `plugins/brackets.rkt`（匹配括号）+ `core/bracket.rkt`；face 刷新改由
      `after-edit/insert/nav` 钩子驱动（插件接管的按键也能刷新）。
- [x] **括号深度背景**：`core/bracket-depth.rkt`（移植 edit/highlight/bracket-pair 的全量部分，
      词法跳过字符串 / 注释 / 字符字面量）+ `plugins/brackets.rkt` 叠 `palette-bg 'bracket level`；
      光标配对叠在其上（`'bracket-match` 覆盖深度色）。
- [x] **require 词表**：`plugins/lang/source.rkt`（#lang/require/定义/provide 扫描）+
      `plugins/lang/pool.rkt`（`spec-names` 按 spec 结构算 only-in/except-in/prefix-in/
      rename-in/prefix-rename-in 后的**最终绑定名**，打开的本地文件用当前缓冲区文本）；
      `plugins/completion.rkt` 的候选池加入导入名 + 顶层定义名。
- [x] **auto-pair**：`plugins/auto-pair.rkt`——接管 editor 作用域的 `(text)`，`(`/`{`/`[` 成对插入
      （有选区不配对）、`)`/`}`/`]` 右边已是它则跳过、其它文本原样插入。
- [x] **模块路径补全**：`plugins/lang/module-index.rkt`（collects + 包目录扫描，惰性）+
      `completion.rkt` 的 `module-path-context`（`require`/`#lang` 路径位置）→ 走同一个
      `'completion-exports` worker（payload `(module-paths)`）补已安装模块名。
- [x] **文档弹窗**：`plugins/docs.rkt` 在补全选中项变化时（`emit 'complete-selection`）或 `M-d` 时，
      算「来源模块 + 原名」（`spec-binding-of`）+ 本地定义（`lang/local-docs`）；标准库/已安装包
      走 `#:services 'doc` 异步 worker：`lang/docs.rkt`（`setup/xref` 找定义 tag → `scribble/blueboxes`
      取签名 → 兜底抽 HTML 正文 `lang/doc-html.rkt`）。**同一时刻只允许一个 doc 在途 + 结果缓存**，
      快速切换不堆积；`lang/docs` 内部信号量串行化。选中普通标识符就立即弹（名字/来源先行，
      标准库异步补；“无文档”也弹）；**位置**贴**整个编辑区**（平铺编辑器窗包围盒 `rect-bounds`）
      的上/下边、宽取编辑区宽，输入行靠下时翻到顶（不盖住）。
- [x] **浮窗摆位**：补全菜单在目标编辑窗格内、输入行的上/下侧（不盖住输入行）；文档弹窗贴**整个
      编辑区**（平铺编辑器窗包围盒）的上/下边；焦点离开目标视图自动关（防切文件后的陈旧菜单/文档）。
- [x] **编辑区包围盒 API**：`layout.rkt` 新增 `rect-bounds`（一组矩形 → 包围盒）；
      docs 用它把“所有平铺编辑器窗”框成编辑区（面板/浮窗不计），从而跨分屏贴边。
- [x] **前缀作用域修正**：`editor` 作用域在前缀（`C-s` / `C-n`）激活时让位，修好 `C-s ↑/↓`
      被补全 `(key up/down) editor` 挡住的问题。
- [x] **会话操作暴露给插件**：纯领域原语抽到 `core/session.rkt`（open/save/show/split/close/dirty/
      区域/输入行/树/浮窗/指针）；`step` 只留「键表 + op 解释器 + 路由 + 装配」，从 session 调用；
      `core/extension.rkt` 再导出 session，插件可直接调这些原语（不依赖 step）。
- [x] **异步 jobs**：`core/job.rkt`（`job` / `service` / 账本 / `jobs`）+ runtime 输入线程与
      worker 池（`thread` + channel，结果以 `job-event` 回注）；插件 `#:services` 贡献 worker，
      `'job` 钩子消费结果；示例 `plugins/async-demo.rkt`；补全的模块导出已接 worker。
- [ ] overlay/popup + modes + 自定义路由（文档弹窗等）
