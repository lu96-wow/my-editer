# 编辑器核心架构

一个纯函数式的编辑器核心。整个系统的设计哲学是：

> **数据 → lambda → 数据**：每个模块都是「输入数据 → 纯函数变换 → 输出新数据」，
> 不修改输入、无全局可变状态。所有结构都是 `#:transparent` 的持久化结构。

核心只提供**底层数据原子 + 它们的原语变换**，不提供任何「组合层」：
多窗口、布局、命令、插件、后端、组装根都不在 core 里，由使用方自行拼装。
core 里的 `window`/`buffer` 是原子，`window->screen`/`screen-compose` 只是把原子投影成
数据的原语，谁去「组合」它们、怎么组合，是使用方的事。

## 0. 目录结构

```
edit/
└── core/                 # 编辑器核心（纯函数、持久化、后端无关、只含原子）
    ├── api.rkt           #   对外唯一入口：门面，转发 text/view 全部公开 API（零逻辑）
    ├── text/             #   文本层（无光标）：文档 = 文本 + 属性 + 标记 + 装饰 + 脏范围
    │                     #     point content key properties marker overlay buffer patch edit
    └── view/             #   视口层（后端无关，单窗口）：宽度/渲染/窗口/视觉行/屏幕/事件
                          #     width render window view screen project events
```

依赖方向：`text ← view`；`api` 在最外层，只 `require` 它们并转发，不实现任何东西。

**对外只暴露 `core/api.rkt`**：使用方一律 `(require "core/api.rkt")`，不要直接
`require core/text/*` 或 `core/view/*`。core 内部各模块按依赖互相 require 属于
实现细节，外部不接触。

## 1. 分层与职责边界

```
┌──────────────────────────────────────────────────────────────┐
│ core/api.rkt      对外门面：require + all-from-out 转发（零逻辑） │
├──────────────────────────────────────────────────────────────┤
│ core/view/*.rkt   视口（后端无关，单窗口）：几何/渲染/屏幕/事件    │
│   width  render  window  view  screen  project  events         │
├──────────────────────────────────────────────────────────────┤
│ core/text/*.rkt   文本层（无光标）：文本/属性/位置/装饰/文档       │
│   point  content  key  properties  marker  overlay  buffer     │
│   patch  edit                                                  │
└──────────────────────────────────────────────────────────────┘
```

**单一职责**：

| 模块 | 唯一职责 | 不知道的事 |
|---|---|---|
| point | (line,col) 位置代数 | 行有多长、有没有文本 |
| content | 文本存储 + 编辑，产出 `edit-desc` | 属性/marker/overlay 的存在 |
| properties | 行内属性区间的读写与随编辑调整 | 文本内容 |
| key | core 解释的属性键（控制键）词表 | 属性的值、文本内容 |
| marker/overlay | 位置/装饰的随编辑调整 | 文本内容 |
| buffer | 把上面各层装配成「文档」（无光标）；编辑原语显式位置；`dirty`/`tick` | 显示、输入、光标 |
| patch | 补丁（delta）：按 key 清旧写新 | 谁在消费 |
| edit | 批量编辑应用：`buffer-apply-edits` / `edits-map-position` | 单条编辑语义 |
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

`dirty-desc`（`first-line last-line old-count new-count`）是新坐标系下的变化行范围，由
`dirty-of` 从 splice 的行范围折算、`merge-dirty` 累加，是上层做**增量推导**的线索。

## 4. 命名规范

| 前缀/后缀 | 含义 | 例子 |
|---|---|---|
| `make-*` | 空构造器（表/状态/默认实例） | make-content, make-marker-table, make-overlay-table, make-properties, make-screen |
| `*-open` / `*-of-*` | 从数据构造 | buffer-open, window-open, content-of-string, content-of-lines |
| `*->*` | 投影/换算 | content->string, index->column, window-point->screen |
| `*-ref` / `*-count` / `*-line-count` | 访问/计数 | buffer-line-ref, marker-table-count |
| `*-get` / `*-at` | 查询 | properties-get, properties-at, overlay-table-at |
| `*-set-*` | 字段更新（返回新结构） | window-set-top, content-set-col |
| 动词-名词 | 变换 | buffer-insert-char, properties-put, window-scroll |
| `*-apply-edit` | 解释 edit-desc | properties-apply-edit, marker-table-apply-edit |
| `*-check` / `*?` | 断言 / 谓词 | content-check, properties-check, window-count |

**约定**：
- 坐标：core 层全 0-based。
- 列有两种：**字符索引**（buffer 的 col）与**显示列**（width 换算后），函数名用 `index`/`column` 区分。
- 所有「更新」函数返回新值，绝不原地修改。

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
- 空 plist 区间不保留；相邻同 plist 合并；行内升序不重叠
- marker 插入类型 before/after 只在插入点生效
- overlay 两端重合时蒸发（evaporate）
- overlay priority：≤0 在 properties 之下，>0 在 properties 之上
- `priority`/`evaporate`/`read-only` 是控制键（词表见 `text/key.rkt`）：投影时被滤掉，不进 face；插入时也不继承（硬边界）

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
| properties | 行内区间升序、不重叠、相邻同 plist 已合并、无空 plist |
| marker/overlay | overlay 的 start/end id 可查；start ≤ end |
| view | vrow 序列长度 = height；越界行用 line=-1 占位；clip 模式滚动时 `left-col` 吸附为字符起点列，视口内不重吸附 |

## 7. 后端无关

core 不含任何后端，也不含多窗口组合。`events`（类型化事件）、`screen`、`window->screen`、
`render`、`width`、`view` 全部后端无关。GUI/Web/TUI 后端只需两件事：

1. 把 `screen` 画出来；
2. 把原始输入翻译成类型化事件（text/key/mouse/resize/quit，参考 racket/gui 的 key-event%/mouse-event% 模型）。
