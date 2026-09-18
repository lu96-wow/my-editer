# 编辑器核心架构

一个纯函数式的编辑器核心。整个系统的设计哲学是：

> **数据 → lambda → 数据**：每个模块都是「输入数据 → 纯函数变换 → 输出新数据」，
> 不修改输入、无全局可变状态。所有结构都是 `#:transparent` 的持久化结构。

「持久化」在这里要精确理解：**叶共享**（文本字符串、区间表在编辑后可被旧快照共享）＋
**骨架是「按行索引的平数组」，每次编辑 O(#行) 重建**。设计目标 ≤ ~20 万行（见 §8.6）。

核心只提供**底层数据原子 + 它们的原语变换**，不提供任何「组合层」：
多窗口、布局、命令、插件、后端、组装根都不在 core 里，由使用方自行拼装。
core 里的 `window`/`buffer` 是原子，`window->screen`/`screen-compose` 只是把原子投影成
数据的原语，谁去「组合」它们、怎么组合，是使用方的事。

> `document` 的定位是这条边界目前最含糊的地方——它既是组装根又住在 core 里，还没有被
> 列入 §1 模块表。结论见 §8.5：**留在 core 的是机制**（单一事实源 + 编辑漏斗 + 镜像原语），
> 曾写在其内部的同步策略移出。

## 0. 目录结构

```
edit/
└── core/                 # 编辑器核心（纯函数、持久化、后端无关、只含原子）
    ├── api.rkt           #   对外唯一入口：门面，转发 text/view 全部公开 API（零逻辑）
    ├── text/             #   文本层（无光标）：文档 = 文本 + 属性 + 标记 + 装饰 + 脏范围
    │                     #     point content properties marker overlay buffer patch edit
    └── view/             #   视口层（后端无关，单窗口）：宽度/渲染/窗口/视觉行/屏幕/事件
                          #     width render window view screen project events
```

依赖方向：`text ← view`；`api` 在最外层，只 `require` 它们并转发，不实现任何东西。

**对外只暴露 `core/api.rkt`**：使用方一律 `(require "core/api.rkt")`，不要直接
`require core/text/*` 或 `core/view/*`。core 内部各模块按依赖互相 require 属于
实现细节，外部不接触。

## 1. 分层与职责边界

> 下表是各模块的**当前**职责。core 的**机制边界**（core 解释什么、不解释什么，
> 以及 `document` 的归属）见 §8（目标设计）。

```
┌──────────────────────────────────────────────────────────────┐
│ core/api.rkt      对外门面：require + all-from-out 转发（零逻辑） │
├──────────────────────────────────────────────────────────────┤
│ core/view/*.rkt   视口（后端无关，单窗口）：几何/渲染/屏幕/事件    │
│   width  render  window  view  screen  project  events         │
├──────────────────────────────────────────────────────────────┤
│ core/text/*.rkt   文本层（无光标）：文本/属性/位置/装饰/文档       │
│   point  content  properties  marker  overlay  buffer  patch  │
│   edit                                                         │
└──────────────────────────────────────────────────────────────┘
```

**单一职责**：

| 模块 | 唯一职责 | 不知道的事 |
|---|---|---|
| point | (line,col) 位置代数 | 行有多长、有没有文本 |
| content | 文本存储 + 编辑，产出 `edit-desc` | 属性/marker/overlay 的存在 |
| properties | 行内属性区间（两槽：presentation + restrict）的读写与随编辑调整 | 文本内容、具体的键值含义 |
| marker/overlay | 位置/装饰的随编辑调整 | 文本内容 |
| buffer | 把上面各层装配成「文档」（无光标）；编辑原语显式位置；`dirty`/`tick` | 显示、输入、光标 |
| patch | 补丁（delta）：按 key 清旧写新 | 谁在消费 |
| edit | 批量编辑应用：`buffer-apply-edit-batch` / `edits-map-position` | 单条编辑语义 |
| width | 字符 ↔ 显示列（wcwidth 语义，确定性 Unicode 表） | 终端/GUI |
| render | 一行 → glyph（语义 face） | 布局、屏幕、宽字符列 |
| window | 视口：buffer 引用 + point + 滚动/尺寸 + 光标导航/编辑 | 其他窗口、几何位置 |
| view | 单窗口 vrow 布局 + 光标/鼠标映射 + 滚动（clip/wrap） | 具体后端、多窗口 |
| screen | 屏幕帧（run 序列）+ diff + 拼屏原语 | 具体后端 |
| project | 单窗口可见区 → screen（`window->screen`） | 具体后端、多窗口 |
| events | 类型化输入事件（text/key/mouse/resize/quit，参考 racket/gui） | 具体后端 |
| api | 门面：把上面所有公开 API 转发出去 | 任何实现 |

## 2. 两条数据流

### 编辑流（一次按键）

```
事件(text/key) 由使用方翻译（events.rkt 只定义类型）
  → window-* 原语（用 window-point 驱动 buffer-* 的显式位置原语）
  → buffer-* → 新 buffer + edit-desc
  → desc 透传给使用方（多窗口同步 / 撤销 / 语言层，由使用方自行决定）
```

### 渲染流（单窗口）

```
buffer ──render-line──▶ glyph(ch+face)            core/view/render.rkt
       ──width──▶ 列坐标                          core/view/width.rkt
       ──layout-clip/wrap──▶ vrow(line,列范围)    core/view/view.rkt
       ──window->screen──▶ screen(行runs+光标)      core/view/project.rkt
```

多窗口 / 状态行等「拼一块大屏」的需求，使用方用 `screen-compose` 自己拼——
core 只给原语，不预设「怎么组织窗口」。

`screen` 与 `events` 就是 core 与后端的边界：后端负责把 `screen` 画出来、把原始
输入翻译成类型化事件；core 内部全部后端无关。

## 3. 唯一跨层契约：`edit-desc`

```racket
(struct edit-desc (s-line s-col e-line e-col new-text))  ; 全操作前坐标
;; 删除 [s-line,s-col)..[e-line,e-col)，插入 new-text（可含 \n）
```

一次编辑 = **一个 splice**（替换区间）。content 产生它，marker/properties/overlay 各自用同一个
**位置映射函数** `edit-desc-map-position` 调整。所有编辑（插入/删除/换行/合并/粘贴/剪切）
都只是 splice 的特例。

**desc 不再被丢弃**：`buffer-splice` / `buffer-insert-char` / …（显式位置）与 `window-*` 编辑/导航
原语统一返回 `(values new desc)`（导航/无操作 desc 恒 `#f`），供上层（多窗口同步 /
撤销 / 语言层）使用。`buffer.rkt` 已重新导出 `edit-desc`（`api.rkt` 里以
`content.rkt` 为唯一来源去重）。

**撤销**：`buffer-edit-desc-inverse` 用「编辑前的 buffer」取回被删文本、求出逆编辑
（新坐标系），再用 `buffer-apply-edit` 应用；纯 desc 代数在 `edit-desc-inverse`。
edit-desc 不含旧文本，故逆必须由编辑前的内容导出——编辑时压栈、撤销时应用。

`dirty-desc`（`first-line last-line old-count new-count`）是**最近一次改动的行范围**
（新坐标系），由 `dirty-of` 从 splice 折算，是上层做**增量推导**的线索。语义是
per-operation：每次改动整体覆盖，消费方「改一次、读一次」；要跨改动累积由消费方自己
累积（它本就是改动的发起者）——core 不做会随行数漂移的累加。

## 4. 命名规范

| 前缀/后缀 | 含义 | 例子 |
|---|---|---|
| `make-*` | 空构造器（表/状态/默认实例） | make-content, make-marker-table, make-overlay-table, make-properties, make-screen |
| `*-open` / `*-of-*` | 从数据构造 | buffer-open, window-open, content-of-string, content-of-lines |
| `*->*` | 投影/换算 | content->string, index->column, window-point->screen |
| `*-ref` / `*-count` / `*-line-count` | 访问/计数 | buffer-line-ref, marker-table-count |
| `*-get` / `*-at` | 查询 | properties-get, properties-at, overlay-table-at |
| `*-set-*` | 字段更新（返回新结构） | window-set-top, window-set-size |
| `add` / `remove` / `delete` | `add` 建实体；`remove` 移除实体或键；`delete` 专指**文本删除操作**（delete 键语义） | marker-table-add / overlay-table-add；marker-table-remove / buffer-remove-property；buffer-delete / content-delete |
| `*-many` / `*-batch` | 批量形态 | properties-put-many, buffer-apply-edit-batch |
| 方向/位置名词 | 光标单步移动（名字与键名同形） | window-left, window-right, window-home, window-end |
| 动词-名词 | 变换 | buffer-insert-char, properties-put, window-scroll |
| `*-apply-edit` | 解释 edit-desc | properties-apply-edit, marker-table-apply-edit |
| `*-check` / `*?` | 断言 / 谓词 | content-check, properties-check, window-count |

**约定**：
- 坐标：core 层全 0-based。
- 列有两种：**字符索引**（buffer 的 col）与**显示列**（width 换算后），函数名用 `index`/`column` 区分。
- 所有「更新」函数返回新值，绝不原地修改。
- 位置比较只有一份实现：`pos<?` / `pos=?`（point.rkt）；`point<?` / `point=?` 是它的 point 版包装。**各层不要各写一份。**

## 5. 边界情况清单

### 文本 / 编辑
- 首行行首 backspace、末行行尾 delete → 无操作（desc=#f）
- goto/列 越界 → 夹紧到合法行列
- 空 buffer（至少一行）、空行（wrap 模式占一行）
- 属性插入时「继承左邻」（区间扩张），删除使区间变空则删区间

### 宽字符（width.rkt）
- 宽字符 width=2；组合/零宽 width=0；Ambiguous 按 1
- 宽字符**绝不显示半个**：跨视口左右边界的整字丢弃，左右边界同一规则（`line-range->runs`）
- 左边界吸附：滚动时 `left-col` 吸附到字符起点（`snap-column-forward`），左边界不出现「空格+字符」浮动；视口内移动**不**因换行重吸附（避免上下移动时窗口左右平移）
- 光标跟随保证光标字符完整落在视口内（含右边界），光标不会落在被丢弃的字符上
- 宽字符跨折行边界 → 整字移下一段
- 单字符宽度 > 折行宽度 → 独占一段（保证进度）
- 鼠标命中宽字符右半格 → 命中同一字符
- 光标不落在组合字符前（column->index 跳过 0 宽）

### 属性 / 装饰
- marker 插入类型 before/after 只在插入点生效
- 区间带**两个槽**：`presentation`（开放 plist，core 不解释）+ `restrict`（typed 约束，core 解释）
- 相邻区间合并 / 编辑调整 / 插入继承：两槽一起判定；两槽都空的区间不保留
- 插入继承规则：`presentation` 继承左邻；`restrict` 不继承；左邻带 `restrict` ⇒ 表现也不继承（硬边界）
- overlay 的 `priority`/`evaporate?` 是 **struct 字段**（不是 plist 键）：两端重合时蒸发；priority ≤0 在 presentation 之下、>0 在之上

### 渲染 / 屏幕
- face 分段：同 face 相邻列合并成 run
- `screen-diff-rows` 只挑变化行（增量绘制的依据）

### 滚动 / 光标跟随
- 光标移出窗口边界 → 窗口跟随；水平滚动按行宽限位
- 上下键按**视觉行**移动（`window-visual-move`）：wrap 跨折行段、clip 按 buffer 行，统一保持「视觉列」
- 视觉列夹紧到更短的行尾时，停在段内最后一个字符，不溢出到下一视觉行
- 垂直夹紧 `top ∈ [0, 行数-height]`
- wrap 模式视觉行滚动跨行；滚到末尾目前不夹紧（已知 TODO）

## 6. 关键不变量

| 层 | 不变量 |
|---|---|
| content | lines 非空；gap-line ∈ [0,n)；gap-col ≤ 行长 |
| properties | 行内区间升序、不重叠；相邻且 (presentation, restrict) 都相同已合并；两槽都空的区间不保留 |
| marker/overlay | overlay 的 start/end id 可查；start ≤ end |
| view | vrow 序列长度 = height；越界行用 line=-1 占位；clip 模式滚动时 `left-col` 吸附为字符起点列，视口内不重吸附 |

## 7. 后端无关

core 不含任何后端，也不含多窗口组合。`events`（类型化事件）、`screen`、`window->screen`、
`render`、`width`、`view` 全部后端无关。GUI/Web/TUI 后端只需两件事：

1. 把 `screen` 画出来；
2. 把原始输入翻译成类型化事件（text/key/mouse/resize/quit，参考 racket/gui 的 key-event%/mouse-event% 模型）。

## 8. 目标设计：机制的边界

> **状态**：设计**定稿**，分 5 步实施（见 §8.7）。本节描述**目标态**；§0–§7 描述**当前态**，
> 第 5 步之后两者合一（本节的第 0 步就是本节自身，无代码改动）。
>
> 与已完成工作的关系：本设计与「控制键投影」「撤销原语」「dirty 语义」三项**叠加**。
> 其中第 1 项建的 `text/key.rkt` 会在第 2 步被**删除**——它是对「表示错误」的缓解，
> 目标设计让它不需要存在。

### 8.1 问题

core 声称「只给机制（原子 + 变换），不给策略」。后端 / 主题 / 命令 / 键位这四块确实做到了，
**属性与行为**这块没有：机制是按**具体键名**和**具体规则**写死的。

- 按**键名**写死：`read-only`（编辑守卫 + 属性继承的硬边界）、`priority`、`evaporate`
  （后两者是 `overlay` 的 plist 伪字段——用 hash 当结构体，无类型、无校验）。
- 按**规则**写死：「插入继承左邻」的传播策略、`priority ≤ 0 / > 0` 的层叠规则。
- **住错层**：`document.rkt` 是组装根（`buffer` + 一组视图 + `sync = 'free | 'follow` 策略），
  却住在「只含原子、不含组合层」的 core 里，而且 §0/§1 的模块表**根本没列它**。

后果不是洁癖：每加一个 core 要解释的属性，就要在属性继承、渲染投影、键词表三处各写一遍
「这个键是特殊的」；按本文档理解 core 边界的人会据此做错决定。

### 8.2 属性三分

现状把三类性质不同的东西塞进同一个 `plist`，于是只能靠键名把它们切开。
目标态把它**在结构上**分开：

| 类别 | 载体 | core 是否解释 | 开放性 |
|---|---|---|---|
| 表现 presentation | 开放 plist（`face` 等） | **否**（只搬运） | 任意键，永不过滤 |
| 约束 restrict | **typed struct** | **是**（编辑守卫等） | 封闭；加约束 = 加字段（编译期可见） |
| 归属 owner | `patch` 的 `key` | 否（只做清旧写新） | 任意键 |

### 8.3 结构

```racket
;; 区间：一个 span 同时携带两个槽，沿用同一套区间机制
;; （split / shift / merge / apply-edit 各只有一份，不复制）
(struct span (start end presentation restrict) #:transparent)
;;   presentation : immutable hash   表现层（开放；core 不解释、永不过滤）
;;   restrict     : restrict         约束层（typed；core 解释）

(struct restrict (read-only?) #:transparent)   ; 加约束 = 加字段，编译期可见

;; overlay 的行为属性变成真字段，不再藏在 plist 里
(struct overlay (id start-id end-id presentation priority evaporate?) #:transparent)
```

`restrict` **不是**新开一层区间机制，而是同一个 `span` 的第二个槽——这正是
「提升 `read-only` 会复制整套区间机制」这一顾虑的解法。

### 8.4 传播规则（显式两槽，写在一处）

插入时的继承规则从「查键名」改为「两槽各自的规则」：

- `presentation`：**继承左邻**（现行为）。
- `restrict`：**不继承**（硬边界）。
- 左邻带 `restrict` ⇒ `presentation` 也**不继承**（「约束变化处就是字段边界」——
  这就是现在 `inherit-plist` 里那个键名检查的**语义**，只是不再查名字）。

> **Seam（设计的一部分）**：若将来某个约束**不该**截断表现继承，规则改为「该约束自己声明
> 是否成边界」。当前只有 `read-only` 一种，不实现。

### 8.5 `document`：纯机制，零策略

- **机制（core 拥有）**：单一事实源（任一 document 内所有视图的 `buffer` `eq?` 同一个）
  ＋ 编辑**漏斗**（所有编辑经 `document-edit`）＋ 正确性下限 rebase（＝ 现在的 `'free`：
  光标随文本映射、视口不动）＋ **镜像原语** `document-sync-followers`。
- **策略（使用方拥有）**：**何时**镜像、镜像谁给谁。core **不放任何策略**——删掉
  `view.sync` 与 `'free | 'follow` 枚举（枚举就是写死的策略；`view` 结构只为携带 `sync`
  而存在，随之折叠回 `window`）。
- 不变量（单一事实源）只由漏斗保证；视图状态调整发生在不变量成立**之后**，消费方用已导出的
  `document-window` / `document-update-view` / `document-sync-followers` 就能表达任意策略
  （导航路径本来就这么做）。
- **明确否决「策略注入」**（把 rebase 做成函数放进 `view`）：那只是把写死的策略换成可替换的
  策略，而这里根本不该有策略；且代价是 `document` 不再是纯数据。

### 8.6 明确不做（设计的一部分）

- 不为 `presentation` 造 per-key 粘性框架（只有一种传播规则；两槽结构就是扩展点）。
- 不给 `overlay` 加 `restrict`（覆盖层约束没有用例）。
- 不动存储模型：**叶持久化**（文本字符串、区间表在编辑后可被旧快照共享）＋
  **骨架按行索引的平数组**（每次编辑 O(#行) 重建）。设计目标 ≤ ~20 万行。
  这是已定案的模型，本设计不改它。
- 不动 `edit-desc`（唯一跨层契约不变）。
- `modified?` 保留为**约定**（编辑置位、`patch` 不置位），不假装是机制。

### 8.8 守卫抑制：去全局状态（决定 A）

**问题**：`inhibit-read-only` 是 `make-parameter`（buffer.rkt），而两份文档都声称「无全局可变状态」。
它让**同一个编辑函数的语义取决于隐式动态上下文**：

```racket
(buffer-insert-char rb 0 2 #\X)                      ; 拒绝（read-only）
(parameterize ([inhibit-read-only #t])
  (buffer-insert-char rb 0 2 #\X))                   ; 允许
```

同一个调用行为不同，差别不在参数里 —— 这是 ambient state，不是「数据 → lambda → 数据」。

**决定（A）：把「可信编辑」变成显式入口**

- 新增 `buffer-splice-trusted`：与 `buffer-splice` 同形，但**跳过守卫**。
- 删除参数 `inhibit-read-only` 与宏 `with-read-only-inhibited`。
- 程序编辑 read-only 内容一律走它；要「在 read-only 里插一个字符」写成零宽 splice：
  `(buffer-splice-trusted b 0 2 0 2 "X")`。
- `properties-debug?` 是**测试开关**，保留；并在文档里明确它是 core 仅有的动态参数，
  且只影响诊断、不改变语义。

**为什么不是「给每个原语加 `#:trusted?`」**：那是把同一个开关复制到 6 个原语上，噪声大于收益；
「程序编辑」本身就是 splice 语义，一个入口足够。

**与第 2 步的关系**：第 2 步把守卫改为读 typed `restrict` 槽时，`buffer-splice-trusted`
就是那个「跳过该检查」的入口（不再查任何参数）。

### 8.7 分步实施

| 步 | 内容 | 验证 |
|---|---|---|
| 0 | ✅ 本节（设计定稿写进文档）。**无代码** | 文档自洽 |
| 1 | ✅ `overlay` 拿真字段：`priority`/`evaporate?` 进 struct；`key.rkt` 去掉这两项 | 全绿 ＋ overlay 层叠/蒸发行为不变 |
| 2a | ✅ `properties` 两槽化（`span` = presentation + restrict）；`properties-put` 只写表现；新增 `buffer-put-restrict` / `buffer-read-only-at?` / `make-restrict`；编辑守卫改读 typed 槽；传播规则显式化；**删除 `text/key.rkt`**；`render` 不再过滤；`main.rkt` 改用新入口 | 全绿 ＋ 复现「face 纯净、run 不断裂、硬边界语义不变」 |
| 2b | 删 `inhibit-read-only` + `with-read-only-inhibited`，加 `buffer-splice-trusted`（§8.8）；MANUAL §7.5 紧跟改 | 全绿 ＋ 可信入口能编辑 read-only |
| 3 | 命名与 MANUAL §5 / §7.5 收尾 | 全绿 |
| 4 | 删 `view.sync` 与枚举；`view` 折叠回 `window`；core 只留漏斗 ＋ 默认 rebase ＋ 镜像原语；`main.rkt` 在 `on-edit` 显式镜像 | 全绿 ＋ 两个策略行为不变 |
| 5 | 文档定稿：§0/§1 模块表补 `document`，§8.2 的三分表并入 §1 | 文档与代码一致 |

> 第 5 步之后，删掉本节的「状态」注记，并把本节内容并入 §0/§1/§5。
