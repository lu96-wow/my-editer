# 编辑器核心架构

一个纯函数式的编辑器核心。整个系统的设计哲学是：

> **数据 → lambda → 数据**：每个模块都是「输入数据 → 纯函数变换 → 输出新数据」，
> 不修改输入、无全局可变状态。所有结构都是 `#:transparent` 的持久化结构。

「持久化」= **叶共享**（文本字符串、区间表在编辑后可被旧快照共享）＋
**骨架是「按行索引的平数组」**，每次编辑 O(#行) 重建。设计目标 ≤ ~20 万行。

core 里唯一的动态参数是测试开关 `properties-debug?`（只影响诊断，不改语义）；
守卫绕行走显式入口 `buffer-splice-trusted`，不用参数（§8.4）。

core 只提供**底层数据原子 + 它们的原语变换**，不提供任何「组合层」：
多窗口、布局、命令、插件、后端、组装根都不在 core 里，由使用方自行拼装。

## 0. 目录结构

```
edit/
├── core/                 # 编辑器核心（纯函数、持久化、后端无关、只含原子）
│   ├── api.rkt           #   对外唯一入口：显式白名单转发（零逻辑）
│   ├── text/             #   文本层（无光标）：point content properties marker overlay buffer patch edit
│   └── view/             #   视口层（后端无关）：width render window view screen project events document
├── history.rkt           # 消费层：撤销/重放账本（不 require document；归属见 §8.5）
├── editing.rkt           # 消费层：编辑组合示例（编辑 → 记账 → 撤销/重做 ＋ 多视图同步 ＋ 增量范围）
├── attributes.rkt        # 消费层：属性示例（写/读/清、只读约束、程序修改 trusted 入口、patch）
├── main.rkt              # 消费层：完整示范（布局 / 输入路由 / 拼屏 / 键盘命令 + racket-tui 前端）
├── io/tui.rkt            # racket-tui ↔ core 的两个连接点（全项目唯一 require racket-tui 的地方）
└── tools/reconcile.rkt   # 文档 ↔ 可达面对账（§8.8）；racket tools/reconcile.rkt
```

`core/` 之外的这几个文件是**消费层**：组装与策略，不在 core 的边界内，也不经 `api` 门面。
`editing.rkt` / `attributes.rkt` 是**只含必要调用**的聚焦示例，`main.rkt` 是完整示范。

依赖方向：`text ← view`；`api` 在最外层，只 `require` 它们并转发，不实现任何东西。

**对外只暴露 `core/api.rkt`**：使用方一律 `(require "core/api.rkt")`，不要直接
`require core/text/*` 或 `core/view/*`。

## 1. 分层与职责边界

```
┌──────────────────────────────────────────────────────────────┐
│ core/api.rkt      对外门面：显式白名单转发（零逻辑，213 个名字） │
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
  → document-edit（唯一编辑入口：用视图光标驱动 buffer-* 的显式位置原语）
  → buffer-* → 新 buffer + edit-desc
  → 入口把 desc + 逆 + 编辑前光标打包成 edit-change 交回使用方
    （撤销 / 语言层由使用方决定；多视图 rebase 已在入口内完成）
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

## 3. 唯一跨层契约：`edit-desc` 与 `edit-change`

```racket
(struct edit-desc (s-line s-col e-line e-col new-text))  ; 全操作前坐标
;; 删除 [s-line,s-col)..[e-line,e-col)，插入 new-text（可含 \n）
```

一次编辑 = **一个 splice**（替换区间）。content 产生它，marker/properties/overlay 各自用同一个
**位置映射函数** `edit-desc-map-position` 调整。所有编辑（插入/删除/换行/合并/粘贴/剪切）
都只是 splice 的特例。

- `edit-desc-map-position` / `edit-desc-after-position`：把位置映射过编辑。
- `edit-desc-inverse d old-text`：纯 desc 代数求逆（edit-desc 不含旧文本，故逆必须由
  编辑前的内容导出）。
- `buffer-*` 编辑原语统一返回 `(values 新buffer edit-desc)`；无操作 / 被 read-only 拒时
  `desc = #f`，原 buffer 原样返回。
- **`edit-change`** 是「一次编辑的完整材料」，由**持光标**的层产出（buffer 层没有光标）：

```racket
(struct edit-change (desc inv pre-point) #:transparent)
;; desc      : edit-desc  这次编辑（操作前坐标）—— 重放用它
;; inv       : edit-desc  逆（操作后坐标，由**编辑前**的 buffer 导出）—— 撤销用它
;; pre-point : point      编辑视图在编辑前的光标 —— 撤销后回到这里
```

- `document-edit` 返回 `(values 新值 (or/c #f edit-change))`；导航/状态原语直接返回单值。
  编辑在每层的形状（§8.6）：

```racket
(buffer-splice  b s-line s-col e-line e-col text) → (values buffer   edit-desc)
(document-edit  doc i edit-fn)                    → (values document (or/c #f edit-change))
```

**撤销**：`buffer-edit-desc-inverse`（b 须是 desc 生效前的 buffer）取回被删文本、求出逆编辑，
再用 `document-apply-descs-trusted` 落回；**重放**走同一入口、传 `replay-descs`。
**账本不在 core**（§8.5）：core 只给这组可逆编辑代数，「记几步、怎么分组」是消费层策略
（`history.rkt`，与 `main.rkt` 并列，不在 `core/` 下）。

## 4. 命名规范

| 前缀/后缀 | 含义 | 例子 |
|---|---|---|
| `make-*` | 空构造器（表/状态/默认实例） | make-content, make-marker-table, make-overlay-table, make-properties, make-screen |
| `*-open` / `*-of-*` | 从数据构造 | buffer-open, window-open, content-of-string, content-of-lines, document-of-buffer |
| `*->*` | 投影/换算 | content->string, index->column, window-point->screen, window->screen, screen->text |
| `*-ref` / `*-count` / `*-line-count` | 访问/计数 | buffer-line-ref, marker-table-count |
| `*-get` / `*-at` | 查询 | properties-get, properties-at, overlay-table-at |
| `*-set-*` | 字段更新（返回新结构） | window-set-top, window-set-size |
| `add` / `remove` / `delete` | `add` 建实体；`remove` 移除实体或键；`delete` 专指**文本删除操作**（delete 键语义） | marker-table-add / overlay-table-add；marker-table-remove / buffer-remove-property；buffer-delete / content-delete |
| `*-many` / `*-batch` | 批量形态 | properties-put-many, buffer-apply-edit-batch |
| `*-trusted` | 跳过守卫/校验的**显式**入口（不留全局开关） | buffer-splice-trusted, buffer-apply-edit-trusted |
| 方向/位置名词 | 光标单步移动（名字与键名同形） | window-left, window-right, window-up, window-down, window-home, window-end |
| 动词-名词 | 变换 | buffer-insert-char, properties-put, window-scroll |
| `*-apply-edit` | 解释 edit-desc | properties-apply-edit, marker-table-apply-edit, buffer-apply-edit |
| `*-check` / `*?` | 断言 / 谓词 | content-check, properties-check, restrict-read-only?, buffer-content-same? |

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
- 垂直夹紧 `top ∈ [0, 行数-height]`（`window-clamp-view`）

## 6. 关键不变量

| 层 | 不变量 |
|---|---|
| content | lines 非空；gap-line ∈ [0,n)；gap-col ≤ 行长 |
| properties | 行内区间升序、不重叠；相邻且 (presentation, restrict) 都相同已合并；两槽都空的区间不保留 |
| marker/overlay | overlay 的 start/end id 可查；start ≤ end |
| window | **水平滚动的每个入口**（`window-set-left` / `window-hscroll` / `window-ensure-point` / `window-clamp-view`）都把 `left-col` 吸附为字符起点列（`snap-left-col`：只吸附、**不夹到行尾**——滚过短行尾部是合法状态）；`window-ensure-point` 在视口内不重吸附 |
| view | vrow 序列长度 = height；越界行用 line=-1 占位 |
| document | 任一 document 内，所有视图的 buffer 都 `eq?` 同一个（不分叉） |

## 7. 后端无关

core 不含任何后端，也不含多窗口组合。`events`（类型化事件）、`screen`、`window->screen`、
`render`、`width`、`view` 全部后端无关。GUI/Web/TUI 后端只需两件事：

1. 把 `screen` 画出来；
2. 把原始输入翻译成类型化事件（text/key/mouse/resize/quit，参考 racket/gui 的 key-event%/mouse-event% 模型）。

## 8. 设计决策（机制边界）

### 8.1 属性三分

三类性质不同的东西在结构上分开：

| 类别 | 载体 | core 是否解释 | 开放性 |
|---|---|---|---|
| 表现 presentation | 开放 plist（`face` 等） | **否**（只搬运） | 任意键，永不过滤 |
| 约束 restrict | **typed struct** | **是**（编辑守卫等） | 封闭；加约束 = 加字段（编译期可见） |
| 归属 owner | `patch` 的 `key` | 否（只做清旧写新） | 任意键 |

```racket
;; 区间：一个 span 同时携带两个槽，沿用同一套区间机制（split/shift/merge/apply-edit 各只有一份）
(struct span (start end presentation restrict) #:transparent)
(struct restrict (read-only?) #:transparent)   ; 加约束 = 加字段
(struct overlay (id start-id end-id presentation priority evaporate?) #:transparent)
```

两槽的**读**共用一份段分解（`properties-slot-runs`）：`properties-runs`（表现层）/
`properties-restrict-runs`（约束层，buffer 层导出为 `buffer-restrict-runs`，用于**枚举**
只读区间——逐点问 `buffer-read-only-at?` 是 O(列数)，这是 O(段数)）。

### 8.2 传播规则（写在一处）

插入时的继承规则（唯一实现在 `inherit-presentation`）：

- `presentation`：**继承左邻**。
- `restrict`：**不继承**（硬边界）。
- 左邻带 `restrict` ⇒ `presentation` 也**不继承**（「约束变化处就是字段边界」）。

### 8.3 `document`：容器机制（两条固定的 rebase 模式）

- **机制（core 拥有）**：单一事实源（任一 document 内所有视图的 `buffer` `eq?` 同一个）
  ＋ 编辑**漏斗**（所有编辑经 `document-edit`）＋ 每视图的 rebase **模式**（两档）：
  - `'free`：光标随文本映射、视口不动（正确性下限）。
  - `'follow`：光标 + 视口锚点复制自编辑视图，**随后按自己的几何 `window-ensure-point`**。
- **视图管理**：`document-add-view` 直接收尺寸（`height width [point] #:sync`），不再要求
  消费方先造一个「会被丢弃 buffer 的 window」；`document-update-view` 更新第 i 视图后
  **自动同步 follow 视图**（几何变更不动锚点、同步无害；导航变更正是 follow 语义）。
  `document-sync-followers` 是内部镜像原语，一般不必直接调。
- 正在被编辑的那个视图：光标推进到插入后 + `ensure-point`。
- **第三种策略**：编辑前用 `document-window` 拿到旧 window（不可变快照），编辑后用
  `document-update-view` 任意调整即可——不需要把策略做成函数塞进 core。

### 8.4 守卫抑制：去全局状态（显式 trusted 入口）

`read-only` 守卫由 `buffer-edit-at` 内的 `guard?` 参数控制（默认 #t）；**唯一**绕行入口是
`buffer-splice-trusted`（传 #f）。没有 `inhibit-read-only` 参数、没有 `with-read-only-inhibited`
宏——程序要编辑 read-only 内容写成零宽 splice：

```racket
(buffer-splice-trusted b 0 2 0 2 "X")
```

### 8.5 撤销 / 重放（账本在消费层）

- **core 给的机制**：`edit-desc-inverse`（纯代数）、`buffer-edit-desc-inverse`（用编辑前的
  buffer 取回被删文本）、`buffer-apply-edit(-trusted)`、`document-apply-descs-trusted`
  （批量落回，跳过守卫；可选 `pre-point` 把光标放回并 `ensure-point`）。
- **`edit-change` 由 document 产出**：只有持光标的层能填 `pre-point`。求逆用**编辑前**
  的 buffer（desc 不含旧文本，用后态 buffer 求逆会静默写坏历史，只在删除路径爆）。
- **账本 `history.rkt`（消费层）**：`step` = `(replay-descs undo-descs point)`，
  `history` = `(undo redo)`。`history-record` 收 `edit-change`；撤销/重放各把对应的 desc 组
  交给 `document-apply-descs-trusted`。

**合并规则（结构判定，无时钟、无状态）**：新 desc 能否并进栈顶那一步——

| 段 | 条件（`pl` = 栈顶最后一条 desc，`d` = 新 desc） |
|---|---|
| 打字连续段 | 两条都是「单字符、非换行」纯插入，且 `d.s == edit-desc-after-position(pl)` |
| 退格连续段 | 两条都是「单字符、非换行」纯删除，且 `d.e == pl.s`（向左推进） |
| 前向删除段 | 同上，且 `d.s == pl.s`（同点继续删） |
| **不合并** | 换行插入、多字符插入（粘贴）、跨行删除（行合并）、替换、其它一切 |

合并时保留**较早**的 `point`（撤销回到整段之前）。

**撤销/重放走 trusted**：记录在案的编辑当年都过了守卫（`desc #f` 不入栈），不该被**事后**
加的约束挡住。被恢复的文本**不带**它被删时的 restrict/表现（区间随删除塌缩）。
`modified?` 是**约定**（编辑置位、`patch` 不置位），不是机制。

### 8.6 编辑动作的规范函数（`edit-*`）

把常用编辑变成**可传的值**（buffer.rkt），消费者不必再写 buffer 级 λ：

```racket
(edit-char ch) (edit-insert s) (edit-newline) (edit-backspace) (edit-delete)
(edit-splice s-line s-col e-line e-col new-text)   ; 通用逃生门
```

- `edit-char ch` / `edit-insert s` 是构造器（返回新闭包）；`edit-newline` / `edit-backspace` /
  `edit-delete` 形状本来就一致，就是那几个原语本身。
- 自定义 λ 依然合法（`document-edit` 收的仍是函数）。
- 配套读入口 `document->string` / `document->lines`。
- 保留 `buffer-insert-*` 等显式坐标原语（「文档原子」层的**调用形式**）；`document-edit` 是
  唯一的编辑入口——不再有 `window-insert-*` / `document-insert-*` 这类掩盖通用入口的便捷包装。

### 8.7 增量信息归操作，不归文档（无 `dirty` 槽）

「这次改了哪几行」随**操作返回**（`edit-desc` / `edit-change`），不存进 buffer：

- `edits-span descs` → 一组（应用顺序的）desc 影响到的**行区间并集**（新坐标系），
  空 → `(values #f #f)`。单次编辑传一条 desc，整步撤销/重放传整组。
- `buffer-tick` 只回答「有没有变」（编辑/属性/patch 都涨）；`buffer-modified?` 是
  「有没有未保存改动」的长期事实。两者都保留。

### 8.8 API 可达面：显式白名单

`core/api.rkt` 用**显式白名单**（不是 `except-out all-from-out`）：新增内部函数不会自动泄漏。
白名单与 MANUAL 的「消费者 API」栏目一一对应，可用 `tools/reconcile.rkt` 对账（当前 0 漂移）。

## 9. API 契约与违约行为

违约分两类，判据是「最近合法解释」是否存在：

- **没有唯一合法解释 → 报错**（抛 `exn:fail?`）：编辑区间反向（`s > e`）、属性/约束区间为空或
  反向、视图索引越界、`window-set-mode` 未知 mode、marker/overlay 位置不在 buffer 内、overlay
  区间反向、patch 行范围越界（过期 patch）、`buffer-apply-edit-batch` 的编辑重叠。
- **有唯一合法解释 → 夹紧**：越界行列、属性端点超出行长、视口 `top`/`left` 越界
  （经 `document` 的路径自动夹，`window-clamp-view` 供直接摆 window 的消费方手动夹）。

校验加在**唯一漏斗**上（`content-splice`、`row-modify`、`document-view-ref`），不逐原语重复。
夹紧后的结果（含 `edit-desc` 里的坐标）反映**夹紧后**的值——想确认发生了什么，看返回的 `desc`。

**core 不解释的东西**（立场，消费方自行处理）：tab/Ambiguous 宽度（core 记 1 列，终端画 8，
要对齐就自己先展开成空格）；`modified?` 的保存点回退；命令/键位/主题/布局；撤销账本。
