# 编辑器核心架构

一个纯函数式的编辑器核心。整个系统的设计哲学是：

> **数据 → lambda → 数据**：每个模块都是「输入数据 → 纯函数变换 → 输出新数据」，
> 不修改输入、无全局可变状态。所有结构都是 `#:transparent` 的持久化结构。

## 0. 目录结构

```
edit/
├── core/                 # 机制（不变式）
│   ├── doc/              #   文档：cursor content properties marker overlay buffer
│   └── view/             #   视口（后端无关）：width render window view screen paint events
├── plugin/               # 策略 slot（纯函数列表 + 组合器）
│   ├── buffer-plugin.rkt #   buffer→buffer，吃 dirty
│   └── view-plugin.rkt   #   window→status-seg，状态行
├── logic/                # 事件逻辑（组合根）
│   └── event.rkt         #   session 状态 + keymap + 事件处理
├── ui/                   # 后端
│   └── tui/              #   终端后端（未来 gui/ web/）
│       └── tui.rkt
├── demo.rkt              # 入口 + 演示插件
└── ARCHITECTURE.md
```

依赖方向：`core ← plugin ← logic ← ui`（logic 也依赖 core）；`demo` 在最外层，依赖所有。

**没有「editor」这一层**：`logic/event` 只提供事件逻辑（session）；真正的 editor（例如 `ui/tui` 的 `run-tui`）由使用者用 core / plugin / logic / ui 的接口自行拼装。

## 1. 分层与职责边界

```
┌──────────────────────────────────────────────────────────────┐
│ demo.rkt             入口（手动测试）                         │
├──────────────────────────────────────────────────────────────┤
│ ui/tui/tui.rkt       后端（racket-tui）：screen↔ANSI、输入↔事件 │ ← 后端相关
├──────────────────────────────────────────────────────────────┤
│ logic/event.rkt      事件逻辑：session + keymap + 事件处理      │
├──────────────────────────────────────────────────────────────┤
│ plugin/buffer-plugin  buffer 插件（buffer→buffer，吃 dirty）  │
│ plugin/view-plugin    view 插件（window→status-seg，状态行）  │
├──────────────────────────────────────────────────────────────┤
│ core/view/*.rkt      视口（后端无关）：几何/布局/屏幕/事件     │
│   width  render  window  view  screen  paint  events          │
├──────────────────────────────────────────────────────────────┤
│ core/doc/*.rkt       文档（无光标）：文本/属性/位置/装饰       │
│   cursor  content  properties  marker  overlay  buffer        │
└──────────────────────────────────────────────────────────────┘
```

**单一职责**：

| 模块 | 唯一职责 | 不知道的事 |
|---|---|---|
| cursor | (line,col) 位置代数 | 行有多长、有没有文本 |
| content | 文本存储 + 编辑，产出 `edit-desc` | 属性/marker/overlay 的存在 |
| properties | 行内属性区间的读写与随编辑调整 | 文本内容 |
| marker/overlay | 位置/装饰的随编辑调整 | 文本内容 |
| buffer | 把上面各层装配成「文档」（无光标）；编辑原语显式位置；`dirty`/`tick` | 显示、输入、光标 |
| buffer-plugin | buffer 插件：组合 buffer→buffer 的函数，消费 dirty | 具体插件逻辑 |
| view-plugin | view 插件：window→status-seg 的组合（状态行） | 具体插件逻辑 |
| render | 一行 → glyph（语义 face） | 布局、屏幕、宽字符列 |
| width | 字符 ↔ 显示列 | 终端/GUI |
| window | 视口：buffer 引用 + point + 滚动/尺寸 + 光标导航/编辑 | 属性/marker/overlay 细节 |
| view | vrow 布局 + 光标/鼠标映射 + 滚动 | 具体后端 |
| screen | 屏幕帧（run 序列）+ diff | 具体后端 |
| paint | 可见区 → screen | 具体后端 |
| event | 事件层：session 状态 + keymap + 两个插件 slot 的组合 | 具体后端 |
| tui | 唯一知道 racket-tui 的层 | 命令语义 |

## 2. 三条数据流

### 编辑流（一次按键）

```
ui-event ──session-handle──▶ 命令 ──window-*──▶ window（用 window-point 驱动 buffer-* 显式位置）
                                              │
                       buffer-* → 新 buffer + edit-desc
                                              │
                              plugins 消费 dirty（run-plugins 末尾清空）
```

### 渲染流（每帧）

```
buffer ──render-line──▶ glyph(ch+face)            core/view/render.rkt
       ──width──▶ 列坐标                          core/view/width.rkt
       ──layout-clip/wrap──▶ vrow(line,列范围)    core/view/view.rkt
       ──line-range->runs──▶ run(col,text,face)   core/view/view.rkt
       ──paint──▶ screen(行runs+光标)             core/view/paint.rkt
       ──screen->bytes-diff──▶ ANSI               ui/tui/tui.rkt
```

### 输入流

```
终端原始输入 ──build-input──▶ ui-event ──session-handle──▶ 命令
```

### 插件 slot（扩展点地图）

插件不是「一个万能 Plugin」，而是每个数据派生位置一个**类型明确的 slot**（纯函数列表 + 组合器）。

| # | 位置 | 类型 | 增量依据 | 例子 | 现状 |
|---|---|---|---|---|---|
| 1 | 输入 → 命令 | `ui-event → session`（keymap） | 事件 | 键位、vim 模式 | `session-keymap` |
| 2 | 编辑策略 | `window → (values window desc)` | 无（事件直调） | 自动配对、snippet | `window-*` 命令 |
| 3 | buffer 派生 | `buffer → buffer` | `dirty-desc` | 高亮、lint、折叠 | `plugin/buffer-plugin.rkt` |
| 4 | 视口派生 | `window → status-seg` | 每帧重算 | 行列、模式行、minimap | `plugin/view-plugin.rkt` |
| 5 | 渲染主题 | `face → style` | 无 | 配色主题 | `face-theme`（tui） |
| 6 | workspace 派生 | `workspace → workspace` | `edit-desc` + 来源 | 关联 buffer 同步、LSP、多窗口 | 待建 |
| 7 | 后端 | `screen → bytes` / `raw-input → ui-event` | — | tui/gui/web | `ui/tui/tui.rkt` |

已实现：#1 keymap（可 `hash-set` 扩展）、#2 命令、#3 buffer 插件、#4 view 插件、#5 主题表、#7 后端。
待建：#6 workspace 层（多窗口/关联 buffer/LSP），是 core 之上的下一组合根。

## 3. 唯一跨层契约：`edit-desc`

```racket
(struct edit-desc (s-line s-col e-line e-col new-text))  ; 全操作前坐标
;; 删除 [s-line,s-col)..[e-line,e-col)，插入 new-text（可含 \n）
```

一次编辑 = **一个 splice**（替换区间）。content 产生它，marker/props/overlay 各自用同一个
**位置映射函数** `edit-desc-map-position` 调整。所有编辑（插入/删除/换行/合并/粘贴/剪切）
都只是 splice 的特例。

**desc 不再被丢弃**：`buffer-splice` / `buffer-insert` / …（显式位置）与 `window-*` 编辑/导航
原语统一返回 `(values new desc)`（导航/无操作 desc 恒 `#f`）；`session-edit` / `session-handle`
同样透传，供上层（语言层 / 跨 buffer 同步）消费。`core/doc/buffer.rkt` 已重新导出 `edit-desc`。

`dirty-desc`（`first-line last-line old-count new-count`）是新坐标系下的变化行范围，由
`dirty-of` 从 splice 的行范围折算、`merge-dirty` 累加，是**插件唯一的增量依据**。

## 4. 命名规范

| 前缀/后缀 | 含义 | 例子 |
|---|---|---|
| `make-*` | 构造器（表/状态） | make-marker-table, make-screen, make-session |
| `*-open` / `*-empty` / `*-of-*` | 构造器 | buffer-open, props-empty, content-of-string |
| `*->*` | 投影/换算 | content->string, index->column, window-point->screen |
| `*-ref` / `*-count` / `*-line-count` | 访问/计数 | buffer-line-ref, marker-table-count |
| `*-get` / `*-at` | 查询 | props-get, props-at, overlay-table-at |
| `*-set-*` | 字段更新（返回新结构） | window-set-top, content-set-col |
| 动词-名词 | 变换 | buffer-insert, props-put, window-scroll |
| `*-apply-edit` | 解释 edit-desc | props-apply-edit, marker-table-apply-edit |
| `*-check` / `*?` | 断言 / 谓词 | content-check, props-check, session-done? |
| `!` | 副作用（仅 tui 层，继承自 racket-tui） | put-at!, style-define! |
| `run-*` / `with-*` | 组合器 | run-plugins, with-plugins, run-tui |

**约定**：
- 坐标：core 层全 0-based；tui 边界转 1-based（+1）。
- 列有两种：**字符索引**（buffer 的 col）与**显示列**（width 换算后），函数名用 `index`/`column` 区分。
- 所有「更新」函数返回新值，绝不原地修改（唯一例外是 tui 的终端状态）。

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
- overlay priority：≤0 在 props 之下，>0 在 props 之上
- `priority`/`evaporate` 是控制键，不进 face

### 渲染 / 屏幕
- face 分段：同 face 相邻列合并成 run
- resize 尺寸变化 → 全量重画；首帧无 prev → 全量
- 增量只重画变化行（先清行再画），文本变短不残留

### 滚动 / 光标跟随
- 光标移出窗口边界 → 窗口跟随；水平滚动按行宽限位
- 上下键按**视觉行**移动（`window-visual-move`）：wrap 跨折行段、clip 按 buffer 行，统一保持「视觉列」
- 视觉列夹紧到更短的行尾时，停在段内最后一个字符，不溢出到下一视觉行
- 垂直夹紧 `top ∈ [0, 行数-height]`
- 滚动命令（pageup/down/滚轮）**不**触发光标跟随，否则滚动会被拉回
- wrap 模式视觉行滚动跨行；滚到末尾目前不夹紧（已知 TODO）

### 插件
- 初始化全量扫描（`run-plugins-init` 标全量 dirty）；多插件各自全量扫一遍
- dirty 只增不减 → 插件是唯一消费者，`run-plugins` 末尾 `buffer-clean`
- 空插件列表原样返回（eq?）

### 输入 / 后端
- 鼠标坐标 1-based → 0-based（tui 边界 -1）
- 点击窗口外 → 不移动光标
- Ctrl+Q 退出 / Ctrl+W 切换折行
- paste 逐字符插入（已知 TODO：批量插入）

## 6. 关键不变量

| 层 | 不变量 |
|---|---|
| content | lines 非空；gap-line ∈ [0,n)；gap-col ≤ 行长 |
| properties | 行内区间升序、不重叠、相邻同 plist 已合并、无空 plist |
| marker/overlay | overlay 的 start/end id 可查；start ≤ end |
| plugin | 插件跑完后 dirty 必为 #f（被消费） |
| view | vrow 序列长度 = height；越界行用 line=-1 占位；clip 模式滚动时 `left-col` 吸附为字符起点列，视口内不重吸附 |

## 7. 换后端只换 `ui/tui/tui.rkt`

`core/view/events`、`screen`、`logic/event`、`core/view/view`、`paint`、`render`、`width` 全部后端无关。
GUI/Web 后端只需：把 `screen` 画出来 + 把原始输入翻译成 `ui-event`。
