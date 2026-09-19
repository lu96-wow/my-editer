# 编辑器核心架构

一个纯函数式的编辑器核心。整个系统的设计哲学是：

> **数据 → lambda → 数据**：每个模块都是「输入数据 → 纯函数变换 → 输出新数据」，
> 不修改输入、无全局可变状态。所有结构都是 `#:transparent` 的持久化结构。

「持久化」在这里要精确理解：**叶共享**（文本字符串、区间表在编辑后可被旧快照共享）＋
**骨架是「按行索引的平数组」，每次编辑 O(#行) 重建**。设计目标 ≤ ~20 万行（见 §8.6）。

core 里唯一的动态参数是测试开关 `properties-debug?`（只影响诊断，不改语义）；
守卫绕行走显式入口 `buffer-splice-trusted`，不用参数（见 §8.8）。

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
├── core/                 # 编辑器核心（纯函数、持久化、后端无关、只含原子）
│   ├── api.rkt           #   对外唯一入口：门面，转发 text/view 全部公开 API（零逻辑）
│   ├── text/             #   文本层（无光标）：文档 = 文本 + 属性 + 标记 + 装饰
│   │                     #     point content properties marker overlay buffer patch edit
│   └── view/             #   视口层（后端无关）：宽度/渲染/窗口/视觉行/屏幕/事件/多视图容器
│                         #     width render window view screen project events document
├── history.rkt           # 消费层：撤销/重放账本（不 require document；归属见 §9.4）
├── editing.rkt           # 消费层：**编辑的组合示例**（编辑 → 记账 → 撤销/重做 ＋ 多视图同步）
├── attributes.rkt        # 消费层：**属性示例**（写/读/清、只读约束、程序修改 trusted 入口、patch）
├── main.rkt              # 消费层：完整示范（布局 / 输入路由 / 拼屏 / 键盘命令 + racket-tui 前端）
└── tools/reconcile.rkt   # 文档 ↔ 可达面对账（§10.3 C/E）；racket tools/reconcile.rkt
```

`core/` 之外的这几个文件是**消费层**：组装与策略，不在 core 的边界内，也不经 `api` 门面。
它们是「core 只给机制」这句话的示范：`editing.rkt` / `attributes.rkt` 是**只含必要调用**的
聚焦示例（18 / 20 个 core 名字），`main.rkt` 是完整示范（60 个）。

> **2026-09-19**：`skeleton.rkt` 与 `document-layer.rkt` 已删除，由 `editing.rkt`（编辑组合）
> 与 `attributes.rkt`（属性）取代。§11 / §12 正文里引用它们的地方是**当时的取证记录**，
> 保留原样（行号属于那两个文件）；当前示例以 `editing.rkt` / `attributes.rkt` / `main.rkt` 为准。

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
│ core/view/*.rkt   视口（后端无关）：几何/渲染/屏幕/事件/多视图容器 │
│   width  render  window  view  screen  project  events document │
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
| buffer | 把上面各层装配成「文档」（无光标）；编辑原语显式位置；`tick`/`modified?` | 显示、输入、光标 |
| patch | 补丁（delta）：按 key 清旧写新 | 谁在消费 |
| edit | 批量编辑应用：`buffer-apply-edit-batch` / `edits-map-position` / `edits-span` | 单条编辑语义 |
| width | 字符 ↔ 显示列（wcwidth 语义，确定性 Unicode 表） | 终端/GUI |
| render | 一行 → glyph（语义 face） | 布局、屏幕、宽字符列 |
| window | 视口：buffer 引用 + point + 滚动/尺寸 + 光标导航/编辑 | 其他窗口、几何位置 |
| view | 单窗口 vrow 布局 + 光标/鼠标映射 + 滚动（clip/wrap） | 具体后端、多窗口 |
| screen | 屏幕帧（run 序列）+ diff + 拼屏原语 | 具体后端 |
| project | 单窗口可见区 → screen（`window->screen`） | 具体后端、多窗口 |
| events | 类型化输入事件（text/key/mouse/resize/quit，参考 racket/gui） | 具体后端 |
| document | 多视图容器：单一事实源 + 编辑漏斗 + 每视图 rebase 模式（`'free`/`'follow`） | 具体布局、窗口个数、命令 |
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
（新坐标系），再用 `buffer-apply-edit` 应用；**重放**（撤销后再做一遍）走
`buffer-apply-edit-trusted`（§9.6：记录在案的编辑当年都过了守卫，不该被**事后**加的约束
挡住）。纯 desc 代数在 `edit-desc-inverse`。
edit-desc 不含旧文本，故逆必须由编辑前的内容导出——编辑时压栈、撤销时应用。
**账本不在 core**（§9.4）：core 只给这组可逆编辑代数，「记几步、怎么分组」是消费层策略
（`history.rkt`，与 `main.rkt` 并列，不在 `core/` 下）。

`edit-desc` 是唯一跨层契约：一次编辑 = 删除 `[s..e)` + 插入 `new-text`，坐标全在**操作前**。
`edit-change`（`desc inv pre-point`）是「一次编辑的完整材料」，由**持光标**的层产出
（§9.3 / §12.5）。

> **2026-09-19**：本节原有 `dirty-desc` / `dirty-of` 一段（`buffer` 的「最近一次改动行范围」
> 槽 + per-operation 语义）。**该槽已删除**——增量信息一律归操作、不归文档，见 §12.6。

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
| `*-trusted` | 跳过守卫/校验的**显式**入口（不留全局开关） | buffer-splice-trusted, buffer-apply-edit-trusted |
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
- 左边界吸附：`window-set-left` / `window-hscroll` / `window-ensure-point` / `window-clamp-view` 都把 `left-col` 吸附到字符起点（`snap-left-col`：只吸附、不夹到行尾），左边界不出现「空格+字符」浮动；`window-ensure-point` 在视口内移动**不**因换行重吸附（避免上下移动时窗口左右平移）
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
| view | vrow 序列长度 = height；越界行用 line=-1 占位；**水平滚动的每个入口**（`window-set-left` / `window-hscroll` / `window-ensure-point` / `window-clamp-view`）都把 `left-col` 吸附为字符起点列（`snap-left-col`：只吸附、**不夹到行尾**——滚过短行尾部是合法状态）；`window-ensure-point` 在视口内不重吸附 |

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

### 8.5 `document`：容器机制（含两条固定的 rebase 模式）

> **2026-09-18 修正（撤回原主张）**：本节原来主张「删掉 `view.sync` 与 `'free|'follow`
> 枚举、core 零策略」。复查后**撤回**——`document` 的职责是「N 个视图共享 1 个 buffer 且
> 始终一致」；**定义「每个视图被别处编辑后怎么重新基准」是这个容器的语义**，不是像配色
> 那样的任意策略。它与 core 里既有的 `window.mode ∈ {'clip,'wrap}`（同样是枚举 + `case`
> + 未知值报错）是同一性质。自动执行还让不变量**被强制**，而不是靠消费方记得调用。
> 另：「枚举封死扩展性」也不成立——消费方编辑前用 `document-window` 拿到旧 window
> （不可变快照）+ 编辑返回的 `desc`，编辑后用 `document-update-view` 可表达任意第三种策略。

- **机制（core 拥有）**：单一事实源（任一 document 内所有视图的 `buffer` `eq?` 同一个）
  ＋ 编辑**漏斗**（所有编辑经 `document-edit`）＋ 每视图的 rebase **模式**（两档）：
  - `'free`：光标随文本映射、视口不动（正确性下限）。
  - `'follow`：光标 + 视口锚点复制自编辑视图，**随后按自己的几何 `window-ensure-point`**。
  ＋ **镜像原语** `document-sync-followers`（消费方在导航等路径上复用）。
- **已修（实测 bug）**：原 `rebase-follow` 只复制编辑视图的 `point`/`top-line`/`top-seg`，
  **等于假设两个视图几何相同**——编辑视图高 10、follow 视图高 3 时，follow 的光标落在第 9 行
  而它自己的可见区只有 0..2（实测越界）。修法是镜像后追加 `window-ensure-point`：
  几何相同时行为**逐字不变**（编辑视图的 point 本来就在其几何内可见），不同时自动退化为
  「跟着光标，视口自己夹紧」；mode 不同的情形也一并修好。
- **`view` 一词负重**（`view.rkt` 是视口层模块；document 的 `view` = window + rebase 模式）：
  文档里说清即可。

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

**已实施（第 2b 步）**：`buffer-edit-at` 多了内部参数 `guard?`（默认 #t）；
`buffer-splice-trusted` 传 #f。参数与宏已删除。

### 8.7 分步实施

| 步 | 内容 | 验证 |
|---|---|---|
| 0 | ✅ 本节（设计定稿写进文档）。**无代码** | 文档自洽 |
| 1 | ✅ `overlay` 拿真字段：`priority`/`evaporate?` 进 struct；`key.rkt` 去掉这两项 | 全绿 ＋ overlay 层叠/蒸发行为不变 |
| 2a | ✅ `properties` 两槽化（`span` = presentation + restrict）；`properties-put` 只写表现；新增 `buffer-put-restrict` / `buffer-read-only-at?` / `make-restrict`；编辑守卫改读 typed 槽；传播规则显式化；**删除 `text/key.rkt`**；`render` 不再过滤；`main.rkt` 改用新入口 | 全绿 ＋ 复现「face 纯净、run 不断裂、硬边界语义不变」 |
| 2b | ✅ 删 `inhibit-read-only` + `with-read-only-inhibited`，加 `buffer-splice-trusted`（§8.8）；MANUAL §7.5 与 api 头注释紧跟改 | 全绿 ＋ 可信入口能编辑 read-only |
| 3 | 命名与 MANUAL §5 / §7.5 收尾 | 全绿 |
| 4 | ✅ **保留** `view.sync`（容器语义，类比 `window.mode`）；**修 `rebase-follow` 的几何耦合**（镜像后 `window-ensure-point`）；§8.5 撤回原主张并留修正记录 | 全绿 ＋ 等几何行为不变 ＋ 不等几何光标可见 |
| 5 | 文档定稿：§8.2 的三分表并入 §1；删掉 §8 的「状态」注记，把本节内容并入 §0/§1/§5 | 文档与代码一致 |

> 第 5 步之后，删掉本节的「状态」注记，并把本节内容并入 §0/§1/§5。

## 9. 目标设计：撤销 / 重放

> **状态**：**已实施**（第 0–4 步全部完成，见 §9.9）。core 部分（`buffer-apply-edit-trusted`、
> 逆编辑的用法）已并入 §3/§4；本节留下的是**消费层**设计：归属判据、合并规则、边界。
>
> 与 §8 的关系：本节沿用 §8 的机制/策略判据（§9.4 就是它的应用），不改 §8 的任何结论。

### 9.1 现状与缺口

**撤销原语已经齐了**（§3 末）：`edit-desc-inverse`（纯代数）、`buffer-edit-desc-inverse`
（用编辑前的 buffer 取回被删文本）、`buffer-apply-edit`（应用单条 desc）。缺的是三样：

- **没有账本**：`buffer` / `document` / 组装层都没有「编辑过什么」的记录；
- **没有分组**：一次按键 = 一条 desc，而真编辑器要的是「一个 undo 单元」（连续打字算一步）；
- **没有绑定**：没有 Ctrl+Z / Ctrl+Y。

即：**难的机制（逆编辑代数 + desc 式无快照）已经完成**，缺口是记账。这决定了本节的性质——
它是一节**消费层**设计，core 只加一个函数（§9.6）。

### 9.2 一步必须自含正反两向

硬约束（§8.6）：撤销必须是 desc 式，快照式每步留 8MB×3。于是「一步」必须自己装下两个方向：

```racket
;; 字段名自带方向与次序：两个列表存的是**相反次序**，而单元素 step（绝大多数）看不出
;; 差别 —— 所以不许用中性名字（曾用 `descs`/`invs`；改名理由见下）
(struct step (replay-descs undo-descs point) #:transparent)
;; replay-descs : (listof edit-desc)  重放：正序依次 apply（desc 自带 new-text，不需旧文本）
;; undo-descs   : (listof edit-desc)  撤销：正序依次 apply（与 replay-descs 相反次序）
;; point        : point               该步开始前 active 视图的光标（撤销后回到这里）
```

- **为什么要两个方向都存**：desc 不含旧文本，所以逆只能由「编辑前的 buffer」导出（§3）；
  而撤销到底再重放需要正向。两者合起来才闭合，且都是 desc 大小——**不是快照**。
- **为什么字段名带方向**：`undo-descs` 存成撤销应用顺序，撤销就是把列表从头 `for/fold` 一遍；
  合并时 `cons` 进 `undo-descs` 是 O(1)。`replay-descs` 是前向顺序（重放一遍），合并时
  `append`，代价 O(段长)，而段长由人手打字决定（§9.5）。
  **中性名字是陷阱**：两者次序相反，而单元素 step 看不出差别，弄反的后果又不可预测
  （实测：打字段的逆升序施加直接抛异常；删除段的逆升序施加**恰好得到正确答案**）——
  所以不靠"写错了会炸"兜底，靠名字说清。
- 内存账：一步 ≈ 若干 desc ＋ 被删文本（删除整篇时 `undo-descs` 持有全文）。总量 O(累计编辑量)，
  不是 O(步数 × 文档)。**不做深度上限**（§9.8）。

### 9.3 记录：逆在编辑时捕获

组装层的编辑漏斗 `on-edit` 是唯一记录点，它天然持有「编辑前的 buffer」与「编辑前的光标」：

```racket
(define (on-edit a do-edit)
  (define b0 (document-buffer (app-doc a)))          ; 编辑前 buffer：不可变引用，不复制
  (define-values (doc* desc) (do-edit (app-doc a) (app-active a)))
  (cond
    [(not desc) (struct-copy app a [doc doc*])]      ; no-op / 被 read-only 拒 → 不入栈
    [else (struct-copy app a [doc doc*]
            [hist (history-record (app-hist a) desc
                                  (buffer-edit-desc-inverse b0 desc)      ; 逆在编辑时算
                                  (window-point (active-window a)))])]))
```

**⚠ 这里有一个会静默出错的地方（实测）**：逆必须从**编辑前**的 buffer 导出。desc 不含旧文本，
逆里的文本是从 `b` 的 `[s..e)` 读出来的——编辑之后那里已经是新内容：

```
删 "abcdef" 的 'b'：desc = (0,1)-(0,2) ""
  用编辑前 buffer 求逆 → 插回 "b" → 撤销得 "abcdef"  ✓
  用编辑后 buffer 求逆 → 插回 "c" → 撤销得 "accdef"  ✗ 不报任何错
纯插入时两态求出的逆恰好相同（实测 equal?=#t）→ 打字路径完全看不出这个错，只在删除路径爆
```

所以 `buffer-edit-desc-inverse` 那句「b 须是 desc 生效前的 buffer」是**约定级**防护，没有机制
拦你——这正是 §9.4 缝 1 的触发条件被收紧的原因。

> **§11 之后（2026-09-18）**：这段的 `b0` / 求逆已由 `document-edit-reversible` 一句替代——
> 消费者不再自己调 `buffer-edit-desc-inverse`，这个坑不再可达（见 §11.2 ③）。
> **2026-09-19 再修订**：那个"第二个入口"已并入 `document-edit` 的返回值（`edit-change`）；
> 防护本身不变（求逆仍由 document 用**编辑前**的 buffer 做），见 §12.5。

**core 零改动**：逆代数、`document-edit`（把一条 desc 当一次编辑落回视图）、
`document-update-view` / `document-sync-followers`（收尾光标）全是现成公开 API。
若 history 真是容器语义，core 里应该缺一块——它不缺，这是 §9.4 判据的实测依据。

### 9.4 归属：账本**不进** `document`

**结论**：文本变更走 `document`（撤销/重放都是 `document-edit`——只有 document 能把一次
变化 rebase 到所有视图）；**栈、分组、"记不记" 留在组装层**（`history.rkt`，与 `main.rkt`
并列，不是 core）。

判据（逐条都是可反驳的，不是偏好）：

1. **不是容器自洽条件**。§8.5 把 `view.sync` 判给 document，判据是「没有 rebase 的 document
   **非法**」。而没有 history 的 document **完全合法**：它的不变量只有「所有视图共享同一
   buffer」＋「光标可解释」。history 是**派生结构**，不参与容器自洽。
2. **撤销的单位是"用户意图"，只有动作层知道**。document 只看得见单条 splice；
   「回车还要带自动缩进」「粘贴是一个单元」这类边界在动作层。§9.5 的连续段启发式本身就是
   对用户意图的**近似**；留在外层，将来能升级成批量记一步（§9.8 缝 2），进了容器就不能。
3. **"记不记 / 怎么并" 是 per-call 策略，容器没有承载位**。`view.sync` 是挂在 `view` 对象上的
   **数据**，容器解释它很自然；「这次编辑要不要进历史」挂在**调用**上，不挂在任何对象上。
   进容器就只剩两条路：给 `document-edit` 加 flag（§8.8 已否），或加第二个入口。
   放在外层，"记不记" 就是**调不调 `on-edit`**——策略免费表达。
   > **2026-09-19 补第三条**：单入口 + **总是捕获**——因为实际消费者全部都要捕获（见 §12.5）。
   > 本条的判据（策略不挂对象、挂调用）不受影响。
4. **改动面**。容器方案要动 `struct document` 字段、每个构造点、不变量文档、MANUAL §3.1/§6.5
   表；外层方案是**纯加法**。
5. **防忘记不成立**。容器方案唯一的收益是"不可能忘记记录"，但这里的暴露面只有
   `on-edit` 一个（对比 §8.5 那次：rebase 是每个消费方都要记得调的）。且 document 现有的
   不变量本身就是**约定级**的（`struct-out document` 公开），并非强制。

**两条缝（加法，不是"留坑"）**：

- **缝 1**（**2026-09-18 已下沉；2026-09-19 改形状，见 §12.5**）：出现**除本节示范（`main.rkt`）之外任何**要历史的消费者
  → 把"捕获"下沉成 document 的第二个显式入口 `document-edit-reversible` →
  `(values doc desc inv pre-point)`（flag-free，形状同 `buffer-splice-trusted` 之于
  `buffer-splice`）。**栈仍在外面**。触发它的正是 §11 的 `skeleton.rkt`（第二个消费​者）。
  > **2026-09-19**：形状改为**唯一入口的返回值**——`document-edit` → `(values doc (or/c #f edit-change))`，
  > `document-edit-reversible` 已删。判据（捕获必须在 document）不变；§12.5 还补了第 3 条路
  > （单入口 + 总是捕获），因为"无 undo 的消费者"实际是 0 个。
  > 触发线为什么收得这么紧：§9.3 那个坑是**静默**的（用后态 buffer 求逆不报错，只在删除
  > 路径写坏历史）。所以不是等第二个消费者，是**不等**——等到了就做（见 §11.2 ③）。
- **缝 2**：出现**多 splice 的单步动作** → 需要 `document-edit-batch`（原子落回视图、只
  rebase 一遍）；但**记录仍在外面**（动作层自己持有那几条 desc/inv，压成一步）。

### 9.5 合并规则：结构判定（无时钟、无状态）

| 段 | 条件（`pl` = 栈顶那一步最后一条 desc，`d` = 新 desc） |
|---|---|
| 打字连续段 | 两条都是「单字符、非换行」纯插入，且 `d.s == edit-desc-after-position(pl)` |
| 退格连续段 | 两条都是「单字符、非换行」纯删除，且 `d.e == pl.s`（向左推进） |
| 前向删除段 | 同上，且 `d.s == pl.s`（同点继续删） |
| **不合并** | 换行插入、多字符插入（粘贴）、跨行删除（行合并）、替换、其它一切 |

坐标可比性（易错点）：`d` 在新坐标系、`pl` 在旧坐标系，但删除只移动**起点左侧**的坐标，
而上述比较全发生在 `pl.s` 及其左侧——数字可直接比。

合并时保留**较早**的 `point`（撤销回到整段之前）——即 Emacs amalgamation 的语义。

**明确否决**：时间窗合并（要传时钟、破坏纯函数、不可测；Emacs 本身就是按「连续同类命令」
合并的，本规则是它的纯函数版）；`hist-seal` 之类的"打断"状态（要加字段，且代价只是
「移开光标又回到紧邻处再打字会并进上一段」——那段文本本就连续，并成一步反而合理）。

### 9.6 应用：撤销 / 重放

```racket
;; 依次应用一组 desc（撤销传 step-undo-descs、重放传 step-replay-descs）——2026-09-19 起是
;; document 的一个入口（§12.5）；旧的消费者样板（for/fold + 丢 `_` + 单独收光标）已消失：
(document-apply-descs-trusted doc i descs [pre-point]) → document
```

- **撤销**：传 `step-undo-descs` 与 `step-point`（该入口把光标放回那里并 `ensure-point`）。
- **重放**：传 `step-replay-descs`，**不给** `pre-point`；光标由 desc 天然落到「插入之后」，
  与原操作一致，不需要额外状态。
- **撤销后光标为什么存而不用推**：纯删除的逆其 `edit-desc-after-position` 只剩删除起点，
  对前向删除会差一个字符；存「该步之前的光标」则退格/前向删除/替换/整段打字全部与 Emacs 一致。
- **free 视图光标自动还原**（实测）：位置映射可逆，free 视图的光标随逆编辑映射回原位；
  落在被删区间内的光标已在删除时被吸附，偏移无法还原（§9.7）。
- **撤销作用在当前 active 视图**；两视图共享同一 buffer，文本状态一致。

**core 唯一新增**：`buffer-apply-edit-trusted`（与 `buffer-apply-edit` 同形，走
`buffer-splice-trusted`）。**决定：撤销/重放走 trusted**，理由：

1. 记录在案的编辑在当年都过了守卫（`desc #f` 不入栈）→ trusted 撤销**不可能**破坏编辑时
   就存在的约束，只会越过**事后**加的约束。
2. 撤销是「历史重放」，正属于 §8.8 说的「程序编辑走显式入口」那一类。
3. 带守卫的版本会让撤销**静默失灵**（实测：给刚输入的字符事后加 read-only → 守卫版返回
   `desc #f`、文本不动），此时栈不能弹（弹了栈就在说谎）、不弹就把用户卡住——两种都不成立。
4. 后果已知并且自洽：被恢复的文本**不带**它被删时的 restrict/表现（区间随删除塌缩），
   注解由插件按 `tick` 重推（patch 模型）。

### 9.7 边界与不变量

**会恢复**：文本；`tick`（触发重渲染）；所有视图的位置（free 视图光标、marker/overlay/
properties 的**位置映射结果**）。

**不会恢复（明确接受）**：
- 属性 / `restrict` / marker / overlay 的**状态本身**：随编辑映射，不重建。
- 被删区间**内部**的偏移：删除时已被吸附（实测：光标在被删区内 → 撤销后停在区间起点）。
- 编辑之后插件加的注解：不还原，由插件按内容变化重推。
- `modified?`：任何 splice 都置 #t，撤销回原文也不清（沿用 §8.6「`modified?` 是约定」）。

**不变量**：栈 LIFO ⇒ 撤销第 k 步时缓冲区恰好是第 k 步的前态，故 `step.point` 一定合法、
无需夹紧。**前提约定**：所有 splice 都必须经 `on-edit` 记录（当前只有它一个 splice 入口）。

### 9.8 明确不做

1. 快照式 undo（§8.6 已定案 desc 式）。
2. 时钟 / 时间窗合并（§9.5）。
3. `hist-seal` 之类的打断状态、begin/end 事务（§9.5）。
4. 把账本放进 `document`（§9.4）。
5. 深度上限 `hist-max-depth`（要加是 3 行策略；当前不必）。
6. 属性 / 约束 / marker / overlay 的快照恢复（§9.7）。
7. 多 splice 单步（§9.4 缝 2：`replay-descs`/`undo-descs` 内部已是列表，加法不改结构）。
8. `modified?` 的保存点回退。
9. Ctrl+Shift+Z（TUI 的 `#:ctrl` 分不出 ctrl+shift 字母；用 Ctrl+Z / Ctrl+Y）。
10. 改 `document` / `buffer` 结构（core 只加 §9.6 那一个函数）。
11. 在 MANUAL 里为消费层模块开章节（MANUAL 是 **core** 手册；`history.rkt` 与 `main.rkt`
    同属消费层，其说明在 §9 与两个文件的头注释里）。

### 9.9 分步实施

| 步 | 内容 | 验证 |
|---|---|---|
| 0 | ✅ 本节（设计定稿）。**无代码** | 文档自洽 |
| 1 | ✅ core：`buffer-apply-edit-trusted`（§9.6） | 全绿 ＋ 对照测试（守卫版拒绝 / trusted 版通过） |
| 2 | ✅ 新 `history.rkt`（消费层）：`step`/`history` ＋ `make-history` / `history-record` / `history-pop-undo` / `history-pop-redo` / `history-can-undo?` / `history-can-redo?` / `history-undo-depth` / `history-redo-depth` | `module+ test` 纯数据：三种合并与各自的不合并情形、redo 清空、point 保留、空栈 no-op |
| 3 | ✅ `main.rkt` 接线：`app` 加 `hist`、`on-edit` 记录、`apply-descs`/`on-undo`/`on-redo`、Ctrl+Z / Ctrl+Y、状态行与启动提示 | 全绿 ＋ 端到端：打字→一次撤销→重放、follow 同步、空栈 no-op、被拒编辑不入栈、撤销后新编辑清空 redo |
| 4 | ✅ 文档收尾：§3 撤销段与 §4 命名（core 侧）随实现更新；§0 注明根目录是消费层；把「文档表格提到的标识符 ↔ 模块真实导出」再对账一遍 | 对账无漂移 |

**实施期修正（都记在这里，避免以后翻 git）**：

- **后续加固（2026-09-18，做完 API 易用性评估后）**：① `step` 的字段 `descs`/`invs` 改名为
  `replay-descs`/`undo-descs`——两个列表次序**相反**而单元素 step 看不出差别，中性名字是隐性
  陷阱（实测弄反的后果不可预测：打字段的逆升序施加抛异常、删除段的逆升序施加恰好正确）；
  ② §9.3 补「逆必须从编辑前 buffer 导出」的**静默坑**记录（实测）；③ §9.4 缝 1 的触发条件从
  「第二个消费者」收紧为「示范之外任何消费者」。三项都**不改语义、不扩 API 面**。
- `char-delete?` 一开始把 `e-col = s-col+1` 写成 `s-col = e-col+1`，症状是**前向删除连续段
  不合并**（退格段也一样），被测试当场抓住。
- `history-pop-undo` / `history-pop-redo` 不能写成 `(if test (values #f h) (define st …) …)`
  ——`if` 只收 2~3 个子式、没有定义上下文，改 `cond`（与 §8「踩坑记录」同类）。
- §9.3 的代码块一度写成 `(active-view a)`（实现是 `(app-active a)`），对账时才发现。

**对账（第 4 步的执行记录，做法同 §8 第 3 步那次）**：`namespace-mapped-symbols` 取
「require 过项目**全部 20 个模块**后可见的符号」（减去只 require `racket/base` 的基线，得 336 个），
再正则扫两份 `.md` **表格行第一格**里首个反引号 token，比对它是否在这个集合里。
结论：**无真实漂移**——`buffer-apply-edit-trusted` 与 §9 的消费层名字（`history-record`、
`make-history`、`history-pop-undo`…）全部命中。被列出但已确认非绑定的只有两类：§4 命名表的
模式行（`make-*`、`*-open`、`*-trusted` 等 10 个）与 MANUAL §2 术语表的术语（`cursor`、`face`）。

> 两个方法要点，留给下次：① 扫描必须取**第一格**（行内其它反引号多是概念词、字段名、
> 局部变量，如 `cursor`、`left-col`、`pl`——用「行内首个反引号」会误报一堆）；
> ② 比对集合要把 `history.rkt` / `main.rkt` 也算进去，否则消费层的名字会误报。

## 10. API 易用性：契约清单、规则与改法

> **状态**：设计**定稿**，分 6 步实施（见 §10.6）。§10.1 的每条都实测过（脚本见
> `/tmp`，另有一份子代理的扩展审计，**复核边界**见 §10.1 末）。

### 10.1 问题：契约重、组合难

**① 可达面与文档不一致**（`api_surface.rkt` / `api_reachable.rkt`）：

| 度量 | 数字 |
|---|---|
| `core/api.rkt`（唯一入口）消费面 | **208 个名字** |
| 全项目可见符号并集 | 336（差额 = 模块内部 + `except-out` 挡掉的） |
| MANUAL 表格里 130 个名字 | **api 可达 76 ／ 只能从模块内部拿 52 ／ 术语 2** |

那 52 个（`content-splice`、`properties-put`、`properties-runs`、`marker-table-*`、
`overlay-table-*`、`layout-*`、`wrap-segments`、`vrow`、`glyph`、`render-line`…）就排在
MANUAL §5.2–§6.2 的"详细签名"表里 —— 读者会以为能用。**这是"契约重"的一半来源。**

**② 静默错 / 崩溃**（`verify_audit.rkt` / `clamp_probe.rkt`，逐条实测）：

| 契约（调用方必须满足） | 违约后果（实测） | 现状 |
|---|---|---|
| `buffer-splice` 要 `s ≤ e` | **静默复制文本**：`"abcdef"` 上 `(0,3)-(0,1)` → `"abcbcdef"` | 无校验 |
| 属性/约束区间要 `start < end` | **静默不保护**（写只读区"以为锁了没锁"），但 `modified?`/tick 照样置位 | 无校验 |
| `buffer-apply-edit(-trusted)` 的 desc 要与 b 同代 | 静默多删：`"acdef"` 上再应用 `(0,1)-(0,2)""` → `"adef"` | 无校验 |
| `buffer-edit-desc-inverse` 的 b 要**编辑前** | 静默插错旧文本（§9.3 已记） | 无校验 |
| `document-update-view`/`set-view-sync` 索引越界 | **静默 no-op**，而 `document-window` 是 list-ref 抛 —— 同类操作两副面孔 | 无校验 |
| 视口 `top`/`left` 必须仍在合法域 | **`top` 越界**：wrap → `window->screen` **抛 vector-ref**；clip → **静默全空白**。实测在 document 双视图上复现：free 视图 `top=15` + wrap、另一视图删 19 行 → 崩 | `set-point`/`set-buffer` 夹紧，`set-top`/`set-left` 漏了 |
| marker/overlay 位置要在 buffer 内；overlay `start ≤ end` | 越界 marker 永不修正、overlay 永不显示 | 无校验 |
| `patch` 的 `[first-line,last-line]` 要在行范围内 | 被静默夹到**别的行**去清旧写新 | 静默夹紧 |
| tab/Ambiguous 宽度 | core 记 1 列、终端画 8 → run 列/光标/折行/鼠标命中全错位 | 立场未声明 |

**③ 文档与代码不一致**（读码 + 实测；**本次已修**，见 §10.6 第 4/5 步）：
- ARCHITECTURE §6 说「clip 滚动时 `left-col` 吸附为字符起点列」——实际只有
  `window-ensure-point` 的**跟随路径**吸附（`view.rkt:278` 右界那条）；`window-hscroll` /
  `window-set-left` **都不吸附** → 宽字符被整字丢弃、行首留一格空白。
- §8.5 说 mode「枚举 + case + 未知值报错」——`window-scroll-visual`（`view.rkt:192`）**静默当 wrap**。

> **复核边界**（诚实标注）：② 表里前 6 行与 ③ 两条是**我实测/读码复核**过的；子代理那份
> 扩展审计还报了 ~20 条（`screen-compose` 块重叠、`dirty`/`modified?` 语义、`window-open`
> 之外的位置合法性等），**我只复核了头几条**，其余按"待复核"处理——本次改法只覆盖已复核的。

### 10.2 五条规则

| 规则 | 内容 |
|---|---|
| **R1** | 违约分两类：**没有唯一合法解释 → 报错**（`s>e`、区间反向、索引越界、过期 patch）；**有唯一合法解释 → 夹紧**（越界行列、`top`/`left` 越界）。判据是"最近合法解释"是否存在，与"哪种更省事"无关 |
| **R2** | 校验加在**唯一漏斗**上（`content-splice`、`row-modify`、`document-view-ref`），不逐原语重复 |
| **R3** | **保留形状差异**：编辑=双值（吐 desc）、非编辑=单值 —— 差异编码机制差异（改共享文本 vs 改一个视图几何）。缺的不是统一，是 **desc 形状的入口** |
| **R4** | 可达面显式（`api.rkt` 显式白名单），文档与可达面**一一对应** |
| **R5** | core 不解释的东西（tab 宽度等）→ MANUAL 明写**立场** + 消费方该怎么做 |

### 10.3 改法

**A. 必需契约不可违约（R1/R2）**

| # | 改动 | 单点 | 依据 |
|---|---|---|---|
| A1 | 夹紧端点（越界行列）后校验 `s ≤ e`，否则 `error` | `content-splice` | ② 行 1；同时顺带修掉 raw `vector-ref` 抛错 |
| A2 | `start < end` 否则 `error`；区间端点**夹到行长** | `row-modify` + buffer 写入口 | ② 行 2（清除用 `(make-restrict)` 表达，空区间无合法解释） |
| A3 | 视图索引越界统一 `error`（同一消息） | `document-view-ref`（其余走它） | ② 行 5 |
| A4 | `window-set-mode` 未知值立即 `error`（与 `view.rkt` 的延迟报错共用同一检查） | `window-set-mode` | ③ 第 2 条 |
| A5 | marker/overlay 位置须在 buffer 内、overlay `start ≤ end`，否则 `error` | `buffer-make-marker` / `buffer-make-overlay` | ② 行 7 |
| A6 | `patch` 行范围越界 `error`（"过期就丢弃"仍是消费方责任） | `buffer-apply-patches` | ② 行 8 |

**B. 补形状缺口（R3）**：`document-apply-edit` ＋ `document-apply-edit-trusted`
（desc 形状入口，与 `buffer-apply-edit(-trusted)` 一对）——消掉 §9.6 那个丢掉两个参数的 lambda。

**C. 可达面显式化（R4）**：`api.rkt` 从 `except-out all-from-out`（fail-open）改**显式白名单**
（即清单第 5 项）。收益：① 内部函数不再默认泄漏；② 可达集合显式 → 文档可**自动对账**；
③ 消掉 MANUAL 那 52 个名字的混乱（拆"消费者 API / 模块内部"）。

**D. 一致性补完（R1 夹紧侧）**

| # | 改动 | 依据 |
|---|---|---|
| D1 | `window-clamp-view`（**mode-aware**：clip 按行数、wrap 按折行段数夹 `top`；`left-col` 吸附到字符起点）＋ 在 `set-top`/`set-left`/`set-size`/`set-mode`/`set-buffer` 与 `document` 对**非编辑视图**的 rebase 里调用 | ② 行 6 的崩溃/空白；`free` 视图"视口钉住"的语义修正为"**钉住，但必须仍在合法域内**"（`rebase-free` 只改 point，正是漏洞来源） |
| D2 | `window-hscroll`/`window-set-left` 吸附到字符起点（与 ensure-point 右界吸附一致） | ③ 第 1 条 |
| — | 修正 §6 / §8.5 的表述 | ③ 两条 |

> 注意：`left-col` 大于本行宽度**不是** bug（那是"滚到右边"的正常状态，短行显示空）；真 bug 是
> "落在宽字符右半"（画出半格空白）。

**E. 文档（R5 + 归档）**：MANUAL 加**立场声明**（tab/Ambiguous core 记 1 列、消费方自行展开；
`modified?` 谁置位谁不置；`dirty` per-operation）＋**任务索引**（"我要做 X → 用这些"）＋撤销指路；
本节归档全部契约清单与取舍；对账脚本入库。

### 10.4 破坏性评估：返回值形状统一 → **不做**

把所有权变换都改成 `(values X #f)`：收益是能写通用分派表（省掉示范里两个 wrapper ≈ 6 行）；
代价是 40+ 签名 + 全部测试 + 全部文档表格，且每个简单调用点变吵（`(define-values (w _) …)`）。
**决定性理由**：形状差异编码机制差异，且误用是 **arity 错（loud）**，与本次要修的静默错性质不同。
**重估判据**：出现"把操作当数据"的消费者（宏录制、命令面板、可撤销的批量动作表）时再做。

### 10.5 明确不做

1. 统一返回值形状（§10.4）。
2. 给 buffer 加"desc 代"计数（要动 core 结构，违 §9.8 第 10 条）→ ② 行 3 归入文档 + §9.7 前提约定。
3. core 解释 tab/Ambiguous（是立场，R5）。
4. 把命令/键位/账本搬进 core（§1.2 / §9.4）。
5. 为单一消费方造框架。

### 10.6 分步实施

| 步 | 内容 | 验证 |
|---|---|---|
| 0 | ✅ 本节（设计定稿） | 文档自洽 |
| 1 | ✅ A 组（A1–A6）＋ 顺带把 §8.5/§10.3 D3 的「未知 mode」也 case 化（同一处编辑，不再分两步） | 全绿 ＋ 回归：曾经的静默行为现在**报错**（每条一个用例） |
| 2 | ✅ D1：`window-clamp-view`（mode-aware）＋ 接入 `document` 的三个视图入口 | 全绿 ＋ **复现回归**：删短内容/视口越界后不空白、不崩 |
| 3 | ✅ B 组 `document-apply-edit(-trusted)` ＋ 换掉 §9.6 的 lambda | 全绿 ＋ 撤销/重放仍精确 |
| 4 | ✅ D2 吸附（`snap-left-col`：只吸附、不夹行尾）＋ §6/§5 表述改准 | 全绿 ＋ 宽字符视口回归 |
| 5 | ✅ C/E：api 白名单 ＋ MANUAL 分栏/任务索引/立场声明 ＋ `tools/reconcile.rkt` 入库 | 对账无漂移（退出码 0） |

**结果（2026-09-18）**：测试 **488 → 534**（最后一条是 `tools/reconcile.rkt` 作为
`raco test .` 的检查跑：漂移即测试失败——安静、无需额外 CI）；
`core/api.rkt` 从 208 个名字变成**显式白名单 211 个**
（+5 新入口：`buffer-apply-edit-trusted` 是 §9 的、`document-apply-edit(-trusted)`、`window-clamp-view`；
−2 内部助手 `check-mode` / `snap-left-col` 明确挡在外面——这正是白名单相对 fail-open 的差价）；
白名单与「可达面」经脚本**逐名核对一致**（幂等自检：再跑一次生成器，差异为空）。
对账脚本入库后可直接当检查跑（`racket tools/reconcile.rkt`）：目前 **0 漂移**，
MANUAL 表格 136 个名字里 78 可达 / 52 模块内部（已在 §5/§6 标注）/ 6 概念词。保护力也当场兑现：
本次新增的两个内部助手（`check-mode`、`snap-left-col`）**没有**出现在消费者面上——换成
fail-open 就会自动泄漏。

**实施期踩坑**：

- `snap-column-forward` 顺带**夹到行尾**，用在水平滚动上会把「滚过短行尾部」这个合法状态也
  吃掉（`set-left 3` 在单字符行上变成 1）→ 抽出 `snap-left-col`：只在行宽内吸附、越界原样保留。
- `buffer-put-properties-many` 里重排 segs 用了 `cddddr`（应为 `cdddr`）——segs 是
  `line start end prop val` 五元，多丢一个就把 `prop` 也丢了。
- 测试里连踩两次「双值函数当单值用」（`document-apply-edit`）；这恰好**正面证明**了
  §10.4 的判断：形状误用是 arity 错（loud），不是静默错。

## 11. 用起来别扭的 API：第二个消费者（骨架）暴露的四条

> **状态**：设计定稿，分 4 步实施（见 §11.4）。证据来自 `skeleton.rkt` —— §10 之后加入的
> **第二个消费者**（不接前端，只拼装），所以这里的判断第一次有了「不止一个消费方」的依据。
> **全部是加法**：不动既有签名，也不动 §10.4 的决定。

### 11.1 证据

| # | 别扭 | 证据 | 为什么算问题 |
|---|---|---|---|
| ① | `window-open` 要一个**占位 buffer**（`document-add-view` 随即把它丢掉） | `skeleton.rkt:53,58`；core 自己的测试为此封了个具名 workaround `(define (blank-w) (window-open (buffer-open "") 10 40))` | 「为了被丢弃而存在」的实参 |
| ② | 「改一个视图 → 对齐 follow」每次自己拼 | **2 消费者 4 处**：`main.rkt:166`（导航）/`:201`（撤销收光标）、`skeleton.rkt:84`/`:100` | 这是**容器不变量**（视图间一致性），该由容器的事务性入口承担 |
| ③ | 账本只给「取出 step」；**捕获逆**要消费者自己写 | 捕获那段在 `main.rkt:179` 与 `skeleton.rkt:77` **逐字重复**；§9.3 的坑是**静默**的 | §9.4 缝 1 的触发条件（"除示范之外任何要历史的消费者"）**已满足** |
| ④ | 左右是 `window-left/-right`，上下却要写 `(window-visual-move w ∓1)` | `skeleton.rkt` 键位表 | §4 约定「名字与键名同形」对上下不成立 |
| ④b | 没有 `screen` 的朴素文本投影 | `skeleton.rkt` 自己写了 10 行 `screen->text` | 与 `screen-diff-rows` 同类（后端辅助/诊断），测试与无前端驱动反复需要 |

### 11.2 目标态（四处新增）

```racket
;; ① 空构造器（§4 的 make-* 家族：make-content / make-marker-table / make-screen）
(define (make-window [height 24] [width 80]) (window-open (buffer-open "") height width))

;; ② 改第 i 个视图并**保持 follow 一致**（= 老的两步一次做完）
;;    语义平行于 document-edit：这次变化由视图 i 发起，follow 视图必须跟它一致。
(define (document-update-view-synced doc i f)
  (document-sync-followers (document-update-view doc i f) i))

;; ③ 编辑入口直接给出「新 document + 一次编辑的完整材料」。**不记任何历史**——栈仍在消费层。
;;    2026-09-19：原为第二个入口 document-edit-reversible；现并入唯一入口的返回值（§12.5）
(document-edit doc i edit-fn) → (values doc (or/c #f edit-change))

;; ④ 方向名词一族（上下是**视觉行** = window-visual-move ∓1，不是 buffer 行）
(define (window-up w)   (window-visual-move w -1))
(define (window-down w) (window-visual-move w +1))

;; ④b 朴素投影（与 screen-diff-rows 同类）：按 run-col 定位、缺口补空格、宽字符按显示宽度占位
(screen->text s) → string
```

**为什么这样定形**：

- ① 用 `make-*` 而不是给 `window-open` 加可选参数——可选参数在 Racket 只能**尾随**，`b` 在最前面
  → 省不掉 `(buffer-open "")`；而 `make-*` 是既有约定。
- ② 单独入口而不是改 `document-update-view`——**`resize-app` 需要「改视图但不镜像」**
  （改尺寸不该重新镜像，`main.rkt:120-125`）；也不是 keyword flag（§8.8 判据）。
- ③ 只做**捕获**，不做入栈判断（那是消费层的）；不做 batch 形态（§9.4 缝 2）。
  它买到的：`buffer-edit-desc-inverse` 从消费者里归零 → §9.3 的静默坑**不可达**。
- ④b 只做朴素文本（不画光标、不加颜色）——颜色/ANSI 是后端的事。

### 11.3 明确不做

1. 不改 `document-update-view` / `window-open` 的既有语义（理由见 §11.2）。
2. 不加 `document-set-point-synced`（"设光标 + ensure + sync" 里那个 λ 只剩 1 行；
   **触发条件**：第三个消费者也写它）。
   > **2026-09-19：触发条件已满足**（`document-layer.rkt` 是第三个），但解法不是加这个方法——
   > 它被折进了落回入口的 `pre-point` 参数（§12.5），三处 λ 一并消失。
3. 不给 ② 加 keyword flag（§8.8）。
4. `screen->text` 不做 ANSI / 颜色 / 光标 / 超宽截断。
5. 不碰 §10.4 的决定；不把命令/键位/账本搬进 core。

### 11.4 分步实施

| 步 | 内容 | 验证 |
|---|---|---|
| 0 | ✅ 本节（设计定稿） | 文档自洽 |
| 1 | ✅ ① `make-window`；`blank-w` workaround 删掉（改用 `(make-window 10 40)`） | 全绿 ＋ 消费者改用 |
| 2 | ✅ ② `document-update-view-synced` ＋ 两个消费者 4 处改用 | 全绿 ＋ `'follow` 回归仍过 |
| 3 | ✅ ③ `document-edit-reversible` ＋ 两个消费者改用（**2026-09-19 已并入 `document-edit` 的返回值，见 §12.5**） | 全绿 ＋ **消费者里 `buffer-edit-desc-inverse` 归零** ＋ 撤销仍精确 |
| 4 | ✅ ④ `window-up`/`-down` ＋ `screen->text` ＋ 骨架/示范改用；白名单与 MANUAL 同步 | 全绿 ＋ 对账 0 漂移 |

**结果（2026-09-18）**：测试 **552 → 563**；白名单 **211 → 217**（+6：`make-window`、
`document-update-view-synced`、`document-edit-reversible`、`window-up`、`window-down`、`screen->text`）。
骨架用到的 core 名字 **52/211 → 51/217（24%）**——净减 1，但构成变了：
`document-update-view` + `document-sync-followers` 合成一个、`document-insert-*` 换成 buffer 级
edit-fn、`run-col`/`run-text` 由 `screen->text` 取代。**消费者里 `buffer-edit-desc-inverse` 归零**
——§9.3 那个静默坑不再可达。

**实施期踩坑（有信息量的一条，它正是 §12 的动机）**：

- `on-edit` 原来转的是**整次 document 编辑**（消费者协议 `do-edit : doc → i → …`），而
  `document-edit-reversible` 要的是 `document-edit` 的 **buffer 级 edit-fn**。第一次改写漏了这层
  差异 → 两个消费者一起 arity 错。最终**改调用点**（把 `buffer-insert-string` / `buffer-newline`…
  直接当 edit-fn），于是 `on-edit` 反而更短、也不需要适配层。
  顺带说明一件事：**`document-edit` 的 `(buffer, line, col)` 就是"编辑"在 core 里的规范形状**；
  消费层用 `document-insert-*` 虽顺手，却正好挡住了可逆入口。**这条痛点由 §12 治**（把"编辑"
  补成可传的规范函数，消费者不必再写 buffer 级 λ）。

## 12. 让编辑路径不再下探 `buffer-*`：动作的规范函数

> **状态**：设计定稿，分 4 步实施（§12.4）。
> **问题（读代码得出，不靠文档）**：写一台带撤销的编辑器，生产代码里必须同时出现
> `document-*`、`window-*`、`buffer-*`、`history-*`/`step-*` **四套前缀**；其中只有
> **"编辑"** 那一条是设计造出来的：可逆入口（§11 ③）要求 edit-fn 是 buffer 级，
> 而 `document-insert-*` 那套便利包装拿不到 `inv` ⇒ **顺手的层不可记账，可记账的层不顺手**。
> 几何（window）、属性（buffer）、账本（history）那三条是真实分工，不在本节范围。

### 12.1 目标态（加法，5 + 2 个）

```racket
;; ① 编辑动作的"规范函数"（buffer.rkt，紧挨原语）：把常用编辑变成可传的值
(define (edit-insert s)    (lambda (b l c) (buffer-insert-string b l c s)))
(define (edit-newline)     buffer-newline)      ; 形状本来就一致，就是它
(define (edit-backspace)   buffer-backspace)
(define (edit-delete)      buffer-delete)
(define (edit-splice s-line s-col e-line e-col new-text)   ; 通用逃生门
  (lambda (b _l _c) (buffer-splice b s-line s-col e-line e-col new-text)))

;; ② 文档的读入口（补全"读也在 document 层"）
(document->string doc) → string
(document->lines doc)  → (listof string)
```

**消费者代码的前后**：

```racket
前  (on-edit a (lambda (b l c) (buffer-insert-string b l c (text-event-text ev))))
后  (on-edit a (edit-insert (text-event-text ev)))
前  [(enter) (on-edit a buffer-newline)]       后  [(enter) (on-edit a (edit-newline))]
前  (document-of-buffer (buffer-open text))    后  (document-open text)
前  (buffer->string (document-buffer doc))     后  (document->string doc)
```

### 12.2 为什么是"构造器"而不是 `edit-op` 结构体 + core 里 `case`

| | 构造器（本节） | 结构体 + 解释 |
|---|---|---|
| document 入口数 | **不变**（仍是 `document-edit` / `-reversible`）｜**2026-09-19 修订：入口数 9 → 3**，见 §12.5 | +1，还要决定是否配 `-reversible` 孪生 |
| 扩展性 | 不关闭：自定义 λ 依然合法 | 封闭词表，加一种编辑 = 加分支 |
| core 里的重复 | 无（就是给已有原语起名） | 把同一份编辑词表**再枚举一遍** |
| 将来"动作即数据" | 可叠加：一行 `op->edit-fn` 就能接上 | 就是它 |

**命名**：`edit-*`（与 `edit-desc` 同族——一个描述一次编辑，一个就是那次编辑）；不用 `*-op`
（后缀会读成数据，而它们是函数）。

### 12.3 边界与明确不做

1. ~~**不动** `document-edit` / `document-edit-reversible` 的签名（仍收 edit-fn；`edit-*` 只是
   规范填充物，消费者随时可传自己的 λ）。~~ → **2026-09-19 修订**：参数形状（仍收 edit-fn）不变，
   但**返回值**改为 `(values doc (or/c #f edit-change))`，`-reversible` 删除（§12.5）。
2. **不把账本收进 document**（§9.4 归属不变）；`history-*`/`step-*` 仍在消费层。
3. **不做** `edit-op` 结构体 / core 里的 `case` 解释（留作宏录制/命令面板出现时的加分项）。
4. **不给 document 造几何入口**（`document-left` 之类）——视图几何属 window。
5. **不删** `document-buffer` / `buffer-*`：`buffer-*` 只从**编辑路径**消失；属性/只读
   （`buffer-put-properties-many` / `buffer-put-restrict`）、建文档前的 setup 仍在 buffer 层，
   这是合理的层次分工（§10.1）。
6. 不加 `document-line-count` 之类（`document->lines` 够；要就自己数）。

### 12.4 分步实施

| 步 | 内容 | 验证 |
|---|---|---|
| 0 | ✅ 本节（设计定稿） | 文档自洽 |
| 1 | ✅ ① `edit-*` 家族 ＋ 测试（与手写 λ 逐字等价） | 全绿 |
| 2 | ✅ ② `document->string` / `document->lines` ＋ 测试 | 全绿 |
| 3 | ✅ 两个消费者改用（`edit-*` / `document-open` / `document->string`） | 全绿 ＋ **`grep buffer- skeleton.rkt` = 空**（连测试都没有） |
| 4 | ✅ 白名单（217 → 224）、MANUAL 行、本节状态、对账 | 对账 0 漂移 |

**结果（2026-09-18）**：测试 **563 → 586**；白名单 **217 → 224**（+7：5 个 `edit-*` ＋
`document->string` / `document->lines`）。`skeleton.rkt` 用到的 core 名字 **51/217 → 50/224（22%）**，
而**编辑路径上 `buffer-*` 归零**（机器可测：`grep buffer- skeleton.rkt` 为空）。
`main.rkt` 里残留的 `buffer-*` 只剩**属性/约束域**：`highlight` / `mark-prompt`（建文档前往 buffer
写 face 与 read-only）、以及测试里的 `buffer-read-only-at?` / `buffer-get-property`。
**这正是"分工 vs 缺陷"的判据**：编辑（含记账）不该下探 → 已归零；属性/只读本属 buffer 层 → 保留。

**踩坑**：新测试里两次把双值函数塞进单值位置（`(buffer->string (run-op …))`）→ 又是那个 arity 错。
`edit-*` 的返回是"函数"，调用时要 `((edit-insert "XY") b l c)` 或先绑成变量——这也是它不关扩展性的代价。

### 12.5 编辑路径统一（2026-09-19）：把"可撤销"从入口的选择降为返回值的处理

> **取代关系**：本节取代 §11.2 ③ 的 `document-edit-reversible` 形状、§12.2 表格「document 入口数
> 不变」、§12.3 第 1 条「不动 `document-edit` / `-reversible` 的签名」、§9.6 的 `apply-descs` 样板。
> **§9.4 的归属判据不变**（捕获必须在 document——只有它同时持有「编辑前的 buffer」与「视图光标」）；
> 变的是它的**形状**：从"第二个显式入口"改成"唯一入口的返回值"。

**问题（代码取证，不靠文档）**：以 undo/redo 为边界，编辑的使用逻辑分了叉：

1. **入口按"要不要撤销"二选一**（`document-edit` 2 值 vs `document-edit-reversible` 4 值），
   而便捷包装 `document-insert-*` 只覆盖**没人用**的那一支。生产代码（排除 `module+ test`）：
   `document-edit`（非 reversible）**0 次**、`document-insert-*` **0 次**、`window-insert-*` **0 次**；
   实际全走 `document-edit-reversible`(4) + `document-apply-edit-trusted`(4) + `edit-*`(8)。
2. **no-op 用 `desc = #f` 与真 desc 同槽位**（同一值域既当数据又当控制流）。
3. **光标三个权威来源**（编辑 = core 的 after-position / 撤销 = 账本 point / 导航 = window 原语）；
   撤销要**借用导航入口** `document-update-view-synced` 去恢复编辑状态。
4. **`(values doc desc)` 同形状两处含义相反**：编辑时是新事实（要入账），落回时是回声
   （`content-splice` 归一后的入参）——4 个调用点 100% 写 `_`。
5. **undo 显式 point vs redo 靠推导**（"最后一条 desc 的 after-position"），不对称且无签名/断言保护。
6. **终局样板三处逐字重复**（记账 / 落回 / 收光标），见 §9.6 与 §11.2 ③ 的旧代码。

**目标态**：

```racket
;; 编辑动作：唯一的编辑词表（buffer.rkt §12；新增 edit-char）
(edit-char ch) (edit-insert s) (edit-newline) (edit-backspace) (edit-delete)
(edit-splice s-line s-col e-line e-col new-text)

;; 一次编辑的完整材料（buffer.rkt，紧挨 buffer-edit-desc-inverse）
(struct edit-change (desc inv pre-point) #:transparent)

;; 入口：三层同形，差别只有「光标从哪来」
(buffer-splice  b s-line s-col e-line e-col text) → (values buffer   edit-desc)
(window-edit    w edit-fn)                        → (values window   (or/c #f edit-change))
(document-edit  doc i edit-fn)                    → (values document (or/c #f edit-change))

;; 落回：施加「已记录」的 desc
(document-apply-edit          doc i desc)                     ; 单条，过守卫（程序编辑）
(document-apply-descs-trusted doc i descs [pre-point])        ; 批量，跳过守卫（撤销/重放）
```

document.rkt 内部拆成 **`edit-and-rebase`（私有机制）** + 三个入口：rebase 是机制，
change 是「编辑入口」的职责——落回路径没有新事实要捕捉，也就不该为它多算一次逆。

**规则**：
- R1 **`#f` 的位置上移**：从「desc 这个值的失败标记」变成「整个 change 槽为空」。
- R2 **求逆零成本**：生产代码每次编辑**已经**在调 reversible（4/4 调用点），统一不新增开销。
- R3 **落回永远 trusted、编辑永远 guarded**（记录在案的编辑当年都过了守卫）。
- R4 **光标覆盖只属于落回**（`pre-point` 参数），不在 `document-edit` 上。
- R5 **redo 的光标仍由推导给出**（`pre-point` 缺省）；触发线见「明确不做 3」。

**归属判据**：

| 新东西 | 归属 | 判据 |
|---|---|---|
| `edit-change` | text 层（`buffer.rkt`） | 纯 text 层数据：`edit-desc` ×2 + `point`，零 view 依赖 |
| 产出 `edit-change` | window / document | **只有持光标的层**能填 `pre-point`（buffer 层不产出它） |
| `document-apply-descs-trusted` | document | 组合里没有消费者知识；且只有 document 能 rebase 所有视图 |
| `window-edit` 导出 | window | window 自洽需要它（否则单窗口模式连 splice 都做不了） |
| `history-record h ch` | 消费层 | 记不记 / 怎么并 / 栈，core 里不出现 undo 概念 |

**与 §9.4 第 3 条的关系**：那里说「记不记是 per-call 策略，进容器只剩两条路：加 flag（§8.8 已否）
或加第二个入口」。本次找到**第三条**：**单入口 + 总是捕获**——因为实际消费者**全部**都要捕获
（reversible 占 4/4），而"无 undo 的消费者"在生产代码里是 **0**。所以不为它优化：
`(values doc (or/c #f edit-change))` 里那个 `#f` 槽就是它的位置，`_` 就是它的代价。

**明确不做**：

1. **不引入 `edit-op` 结构体**（§12.2 的判决不变）：`edit-fn` 保持 λ。
   触发线：出现需要「比较 / 命名 / 序列化编辑」的消费者（命令面板、宏录制）。
2. **不给 `document-edit` 加 `#:point`**：光标覆盖只属于落回动作。
3. **不把 after-point 存进 `step`**：它是 `edit-desc-after-position` 的导出值（第二事实源）。
   触发线：出现「一步内 desc 排布不是单一方向」的消费者（`step-merge?` 只并同类段，当前恒成立）。
4. **core 里不出现 undo / redo 词**：落回入口叫 `-apply-descs-`（机制中性），不叫 `document-undo`。
5. **不动属性 / restrict 路径**（`buffer-put-*` 与编辑无关）。
6. **不动 `core/text/edit.rkt` 的 batch**（0 消费者，但已是白名单里的机制层；是 §9.4 缝 2 的
   独立目标态）。
7. **保留 `buffer-insert-*` 等显式坐标原语**（与 §12.3 第 5 条一致）：它们是「文档原子」层的
   **调用形式**，与 `edit-*`（动作的**值**）分工不同，且不在 undo 边界上——为词表整齐而删掉
   会把「对裸 buffer 做退格」逼成 `((edit-backspace) b l c)`。**只删同层隐藏了通用入口的那些**
   （`window-insert-*` 隐藏 `window-edit`、`document-insert-*` 隐藏 `document-edit`）。

**分步实施**（每步独立可测，且恰好落在目标态上）：

| 步 | 内容 | 验证 |
|---|---|---|
| 1 | ✅ text 层：`edit-change` ＋ `edit-char`（纯加法，不改签名） | `raco test core/text/buffer.rkt` 绿（102） |
| 2 | ✅ **一次原子改**：`window-edit` 导出并返回 change、删 5 个 `window-insert-*`；`document-edit` 返回 change、删 `-reversible` / `-trusted` / 5 个 `-insert-*`、加 `document-apply-descs-trusted`；`history-record` 收 change；三个消费者（main / skeleton / document-layer）迁到新形状 | 各文件全绿 |
| 3 | ✅ 白名单 ＋ MANUAL 表格对账 | `racket tools/reconcile.rkt` 0 漂移 |
| 4 | ✅ api 头注 / `skeleton.rkt` 头注 / 本节 | 全绿 |

**结果（2026-09-19）**：白名单 **224 → 221**（删 12、加 9）；`document` 层编辑面 **9 → 3**
（`document-edit` / `document-apply-edit` / `document-apply-descs-trusted`），`window` 层 **5 → 1**
（`window-edit`）；3 处逐字重复的样板 → 每个消费者的 undo / redo 各 2 行、**完全对称**；
`skeleton.rkt` 用到 core **48/221（22%）**。**撤销/重放不再借用导航入口**，`desc`/`inv` 的交换
从"静默写坏历史"变成编译错（`history-record` 收 struct）。

### 12.6 增量信息归操作，不归文档（`dirty` 槽的删除，2026-09-19）

> **取代**：§3 结尾那段 `dirty-desc` / per-operation 语义的描述（已就地标注）、§9.7 的
> 「会恢复：… `dirty` …」、§9.6 第 4 条的「注解按 `dirty`/tick 重推」、MANUAL 立场表的
> 「`dirty` 是 per-operation」、以及更早那批修复里的第 3 项（把 `dirty` 从"累加"改成
> per-operation）——**那一项修的是「累加语义错了」，但没有问「这个槽该不该存在」**。

**核心冲突**：`dirty` 想回答「刚刚变了哪些文本行」，却把答案**存在文档状态里**；而编辑路径
（§12.5）已经把「操作产生的信息」统一成"**随操作返回**"。同一个信息出现两个来源：

| 问题 | 存在状态里（`dirty` 槽） | 随操作返回（`edit-desc` / `edit-change`） |
|---|---|---|
| 单次编辑 | ✅ | ✅ |
| **一组编辑**（落回一整步 desc） | ❌ 只剩最后一条 | ✅ 并集（`edits-span`） |
| 不碰文本的改动（写属性 / patch） | ⚠️ 语义上不属于"文本行"，所以 `buffer-put-property` 干脆不写它 | ❌ 也不返回（独立缺口，见下） |
| 没人读时 | 💀 白占字段 | 无成本 |

**为什么不能改成"累加 + 读完清"**（这是关键，别重开）：
1. 累加本身**可行**：旧区间经 `edit-desc-map-position` 映射过新编辑再并集，O(1)。
2. **"清"不可行**：buffer 不可变，"读过了"是副作用，"清"要产出新 buffer；而 buffer 在
   document 里被**多个视图共享**——任一视图清掉，别的视图就看不到了。**"读过即清"是一个
   跨视图的共享状态问题，在 document 世界无处安放。**
3. 不清就退化成"从加载到现在的累计脏区" → 渲染时等于全量，**增量意义消失**。

→ 累加路线死在"清"的归属上，不是死在难度上。

**判据（为什么删）**：问「这个信息的存在期有多长」——
- `dirty` 的有效期 = **到下一次操作为止** → 它是"上一次事务的日志"，不是文档的不变量。
- 文档状态（`buffer` 字段）只装不变量与长期事实：文本、属性、marker/overlay、`tick`、
  `modified?`。其中 `tick` 单调、无归属问题 ✅；`dirty` 两样都不满足 ✗。
- 再看它想装的两半，各自都有更强的载体：**「有没有变」→ `buffer-tick`**（编辑/属性/patch
  都算，`dirty` 不算）；**「变了哪些文本行」→ `edit-change` 的 desc**（一组也能算，`dirty` 不能）。
  **`dirty` 是这两者的交集，而在两个方向上都比对方弱。**

**已删**：`dirty-desc`（struct + 4 访问器）、`buffer` 的 `dirty` 字段、`buffer-dirty`、
`dirty-of`、`buffer-mark-dirty`、`buffer-mark-dirty-all`（白名单 −9，221 → 212）；
`buffer-edit-at` 少两次 `content-line-count`。新增 `edits-span`（`core/text/edit.rkt`，与
`edits-map-position` 同族）：**一串（应用顺序的）desc → 行区间并集**，空 → `(values #f #f)`
（与 `window-point->screen` 的"没有"同形）。**单次编辑也用它**：一条 desc 的区间就是这次改动。

**"`buffer-mark-dirty` 的插件声明能力"不损失**：插件写标注也走 `buffer-put-property` /
`buffer-apply-patches`，**都返回新 buffer**；消费层的重渲染本来就是"拿到新值就渲染"
（`io/tui.rkt` 的 `tui-run` 每帧无条件 render）→ 不需要"状态里记一笔"。

**明确不做**：
1. **不给属性路径补"属性脏行"**（`buffer-put-property` 返回新 buffer 但不报告脏行）。
   触发线：出现"按属性行做增量重绘"的消费者（当前 **0**）。
2. **不删 `buffer-tick` / `buffer-modified?`**：前者语义正确（单调、累加）且是"变了没"的
   唯一答案，后者是"有没有未保存改动"的长期事实。
3. **保留 `buffer-mark-dirty` 的替代品？不需要**：若将来真有"外部副作用改了共享可变状态"
   的插件——本项目全不可变，不存在。

**验证**：`raco test .` 全绿（buffer.rkt 95 / edit.rkt 19）；`tools/reconcile.rkt` 0 漂移；
全仓库 `grep dirty` 只剩**历史记录**处（§10 的审计回顾、§11 的计划表）——它们描述当时，
不描述现状。
