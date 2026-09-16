# 编辑器核心架构

一个纯函数式的编辑器核心。整个系统的设计哲学是：

> **数据 → lambda → 数据**：每个模块都是「输入数据 → 纯函数变换 → 输出新数据」，
> 不修改输入、无全局可变状态。所有结构都是 `#:transparent` 的持久化结构。

## 0. 目录结构

```
edit/
├── core/                 # 机制（不变式，只定契约）
│   ├── text/             #   文本层：cursor content properties marker overlay buffer patch
│   └── view/             #   视口（后端无关）：width render window view frame screen paint events
│                         #   frame = 窗口集合 + linked 同步（无布局，无边框）
├── framework/            # 框架（只定 slot 类型 + 组合器 + 机械循环）
│   ├── slots.rkt         #   slot 类型 + 组合器（layout/compose/commands/run-plugins）
│   ├── plugin-dag.rkt    #   插件 DAG 调度（依赖分层 + future 并行 + sync/async）
│   └── stateful.rkt      #   有状态插件（fold + view，edit-desc 流，不可丢状态）
│   └── framework.rkt     #   config + framework-handle/render/status/run
├── reference/            # 参考实现（用户 copy/替换，非默认）
│   ├── layout-tree.rkt   #   树布局（含 | - 分隔槽）
│   ├── compose-line.rkt  #   边框拼帧
│   ├── commands.rkt      #   默认两层命令
│   └── input-tui.rkt     #   tui 的 raw→事件 解码
├── ui/                   # 后端
│   └── tui/              #   终端后端（未来 gui/ web/）
│       └── tui.rkt
├── demo.rkt              # 组装根：把 slot 填进 config + 跑起来
└── ARCHITECTURE.md
```

依赖方向：`core ← framework ← reference ← ui`；`demo` 在最外层，依赖所有。

**没有「editor」这一层**：`framework` 只提供框架（契约 + slot 类型 + 机械循环）；真正的 editor（例如 demo 里 `run-tui (buffer-open sample) cfg`）由使用者用 core / framework / reference / ui 的接口自行拼装。

## 1. 分层与职责边界

```
┌──────────────────────────────────────────────────────────────┐
│ demo.rkt             组装根：把 slot 填进 config + 跑起来      │
├──────────────────────────────────────────────────────────────┤
│ ui/tui/tui.rkt       后端（racket-tui）：screen↔ANSI、read/output │ ← 后端相关
├──────────────────────────────────────────────────────────────┤
│ reference/*          参考实现：树布局 / 边框 / 命令 / 输入解码  │
├──────────────────────────────────────────────────────────────┤
│ framework/framework  框架：config + framework-handle/render/run   │
│ framework/slots      slot 类型 + 组合器                        │
├──────────────────────────────────────────────────────────────┤
│ core/view/*.rkt      视口（后端无关）：几何/渲染/屏幕/事件     │
│   width  render  window  view  frame  screen  paint  events   │
├──────────────────────────────────────────────────────────────┤
│ core/text/*.rkt      文本层（无光标）：文本/属性/位置/装饰       │
│   cursor  content  properties  marker  overlay  buffer  patch      │
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
| slots | slot 类型定义 + 组合器（layout/compose/commands/run-plugins） | 具体策略 |
| plugin-dag | 插件 DAG 调度：依赖分层 + future 并行 + sync/async（唯一知道线程处） | 具体插件/依赖 |
| framework | 框架：config + 机械分派 + 机械循环（framework-handle/render/run） | 具体命令/布局/边框 |
| reference | 参考实现：树布局 / 边框 / 两层命令 / 输入解码 | — |
| render | 一行 → glyph（语义 face） | 布局、屏幕、宽字符列 |
| width | 字符 ↔ 显示列 | 终端/GUI |
| window | 视口：buffer 引用 + point + 滚动/尺寸 + 光标导航/编辑 | 属性/marker/overlay 细节 |
| view | vrow 布局 + 光标/鼠标映射 + 滚动 | 具体后端 |
| frame | 窗口集合 + 焦点 + linked-buffer 同步 + 逐窗口渲染（机制，布局无关） | 布局几何、keymap |
| screen | 屏幕帧（run 序列）+ diff + 拼帧原语 | 具体后端 |
| paint | 可见区 → screen | 具体后端 |
| events | 类型化输入事件（text/key/mouse/resize/quit，参考 racket/gui） | 具体后端 |
| tui | 唯一知道 racket-tui 的层 | 命令语义 |

## 2. 三条数据流

### 编辑流（一次按键）

```
事件(text/key) ──framework-handle──▶ 命令表 ──edit-active──▶ window（用 window-point 驱动 buffer-*）
                                                       │
                    buffer-* → 新 buffer + edit-desc
                                                       │
               命令作者手动：run-plugins（消费 dirty）→ frame-sync-buffer（linked 同步）
```

### 渲染流（每帧）

```
buffer ──render-line──▶ glyph(ch+face)            core/view/render.rkt
       ──width──▶ 列坐标                          core/view/width.rkt
       ──layout-clip/wrap──▶ vrow(line,列范围)    core/view/view.rkt
       ──paint──▶ screen(行runs+光标)             core/view/paint.rkt
frame ──layout-rects──▶ rects ──frame-pieces──▶ pieces
pieces ──compose──▶ 合成 screen（含边框）         reference/compose-line.rkt
screen ──screen->bytes-diff──▶ ANSI               ui/tui/tui.rkt
```

### 输入流（两层，都可替换）

```
终端原始输入 ──input 解码(raw→事件)──▶ text/key/mouse 事件 ──命令表──▶ 命令
（reference/input-tui.rkt）            （reference/commands.rkt）
```

### 插件 slot（扩展点地图）

插件不是「一个万能 Plugin」，而是每个数据派生位置一个**类型明确的 slot**（纯函数 + 组合器）。

| # | 位置 | 类型 | 增量依据 | 例子 | 现状 |
|---|---|---|---|---|---|
| 1 | 输入 → 命令 | `config frame 事件 → (values frame desc? done?)`（两层命令表） | 事件 | 键位、vim 模式 | `reference/commands.rkt` |
| 2 | 编辑策略 | `window → (values window desc)` | 无（命令直调） | 自动配对、snippet | `window-*` 原语 |
| 3 | buffer 派生 | `buffer → (listof patch)`（补丁 = delta） | `dirty-desc` | 高亮、lint、折叠 | `framework/slots.rkt` 的 `run-plugins` + `plugin-dag.rkt` |
| 4 | buffer 状态派生 | `stateful-plugin (init step view)` | `edit-desc` 流 | LSP、增量索引、符号表 | `framework/stateful.rkt`（fold+view，状态不可丢） |
| 5 | 视口派生 | `window → status-seg` | 每帧重算 | 行列、模式行、minimap | `run-view-plugins` |
| 6 | 布局 | `layout = (rects order split close)` | frame 状态 | 树/tab/网格 | `reference/layout-tree.rkt` |
| 7 | 组合/装饰 | `pieces → screen` | pieces | 边框、标签 | `reference/compose-line.rkt` |
| 8 | 渲染主题 | `face → style-spec` | 无 | 配色主题 | 纯数据，**无默认** |
| 9 | 后端 | `screen → bytes` / `raw → 事件` | — | tui/gui/web | `ui/tui/tui.rkt` + `input-tui.rkt` |
| 10 | 项目/工作区派生 | `workspace → workspace` | `edit-desc` + 来源 | 跨文件同步 | 待建（frame 之上的下一组合根） |

已实现：#1~#8；#9 待建。

**颜色归属**：插件只声明**语义 face**（`'keyword` / `'string` / …）；颜色由**主题**决定。主题是外部传入的纯 hash：`face → (list r g b [attr ...])`（如 `'keyword '(97 175 239)`、`'comment '(128 128 128 dim)`），无默认、无预定义标识；渲染时用 hash 查 face，查不到就纯文本。RGB/属性到 ANSI 真彩色转义的翻译隐藏在后端内部，外部不接触 racket-tui 细节。
待建：#6 项目/工作区层（LSP/跨文件同步），是 frame 之上的下一组合根（不属于本层的多窗口/关联 buffer 已由 frame 实现）。

## 3. 唯一跨层契约：`edit-desc`

```racket
(struct edit-desc (s-line s-col e-line e-col new-text))  ; 全操作前坐标
;; 删除 [s-line,s-col)..[e-line,e-col)，插入 new-text（可含 \n）
```

一次编辑 = **一个 splice**（替换区间）。content 产生它，marker/props/overlay 各自用同一个
**位置映射函数** `edit-desc-map-position` 调整。所有编辑（插入/删除/换行/合并/粘贴/剪切）
都只是 splice 的特例。

**desc 不再被丢弃**：`buffer-splice` / `buffer-insert` / …（显式位置）与 `window-*` 编辑/导航
原语统一返回 `(values new desc)`（导航/无操作 desc 恒 `#f`）；`framework-handle` / `frame-sync-buffer`
同样透传与消费，供上层（语言层 / 跨 buffer 同步）使用。`core/text/buffer.rkt` 已重新导出 `edit-desc`。

`dirty-desc`（`first-line last-line old-count new-count`）是新坐标系下的变化行范围，由
`dirty-of` 从 splice 的行范围折算、`merge-dirty` 累加，是**插件唯一的增量依据**。

## 4. 命名规范

| 前缀/后缀 | 含义 | 例子 |
|---|---|---|
| `make-*` | 构造器（表/状态） | make-marker-table, make-screen, make-config |
| `*-open` / `*-empty` / `*-of-*` | 构造器 | buffer-open, props-empty, content-of-string |
| `*->*` | 投影/换算 | content->string, index->column, window-point->screen |
| `*-ref` / `*-count` / `*-line-count` | 访问/计数 | buffer-line-ref, marker-table-count |
| `*-get` / `*-at` | 查询 | props-get, props-at, overlay-table-at |
| `*-set-*` | 字段更新（返回新结构） | window-set-top, content-set-col |
| 动词-名词 | 变换 | buffer-insert, props-put, window-scroll |
| `*-apply-edit` | 解释 edit-desc | props-apply-edit, marker-table-apply-edit |
| `*-check` / `*?` | 断言 / 谓词 | content-check, props-check, frame-window-count |
| `!` | 副作用（仅 tui 层，继承自 racket-tui） | put-at!, style-define! |
| `run-*` / `with-*` | 组合器 | run-plugins, run-plugins-init, run-tui |

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
| frame | 共享 buffer（eq?）的窗口在编辑后一起换新 buffer，point 按 edit-desc 映射；窗口至少 1 个 |
| view | vrow 序列长度 = height；越界行用 line=-1 占位；clip 模式滚动时 `left-col` 吸附为字符起点列，视口内不重吸附 |

## 7. 换后端只换 `ui/tui/tui.rkt`

`core/view/events`（类型化事件）、`screen`、`framework`、`core/view/view`、`paint`、`render`、`width` 全部后端无关。
GUI/Web 后端只需：把 `screen` 画出来 + 把原始输入翻译成类型化事件（text/key/mouse/resize/quit，参考 racket/gui 的 key-event%/mouse-event% 模型）。
