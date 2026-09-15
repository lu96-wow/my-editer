# 编辑器核心架构

一个纯函数式的编辑器核心。整个系统的设计哲学是：

> **数据 → lambda → 数据**：每个模块都是「输入数据 → 纯函数变换 → 输出新数据」，
> 不修改输入、无全局可变状态。所有结构都是 `#:transparent` 的持久化结构。

## 1. 分层与职责边界

```
┌──────────────────────────────────────────────────────────────┐
│ demo.rkt        入口（手动测试）                              │
├──────────────────────────────────────────────────────────────┤
│ tui.rkt         后端（racket-tui）：screen↔ANSI、raw输入↔事件 │  ← 后端相关
├──────────────────────────────────────────────────────────────┤
│ editor.rkt      应用：命令 + 事件处理                          │
│ events.rkt      中性输入事件 ui-event                          │
├──────────────────────────────────────────────────────────────┤
│ width.rkt       显示宽度（字符↔列换算）                       │  ← 后端无关
│ render.rkt      行渲染：buffer 一行 → glyph（ch+face）        │
│ window.rkt      视图状态（滚动位置、尺寸，不缓存渲染结果）     │
│ view.rkt        布局（clip/wrap）+ 光标/鼠标映射 + 滚动       │
│ screen.rkt      屏幕帧缓冲 run / screen + 行级 diff           │
│ paint.rkt       可见区 → screen                               │
├──────────────────────────────────────────────────────────────┤
│ plugin.rkt      插件组合（buffer→buffer 的纯函数序列）        │
├──────────────────────────────────────────────────────────────┤
│ buffer.rkt      组合根：content + point + 属性/marker/overlay │
│ content.rkt     文本存储 + 编辑原语（产生 edit-desc）         │
│ properties.rkt  文本属性（行内区间）                          │
│ marker.rkt      随编辑移动的位置                              │
│ overlay.rkt     独立装饰层（priority/evaporate）              │
│ cursor.rkt      位置代数 (line, col)                          │
└──────────────────────────────────────────────────────────────┘
```

**单一职责**：

| 模块 | 唯一职责 | 不知道的事 |
|---|---|---|
| cursor | (line,col) 位置代数 | 行有多长、有没有文本 |
| content | 文本存储 + 编辑，产出 `edit-desc` | 属性/marker/overlay 的存在 |
| properties | 行内属性区间的读写与随编辑调整 | 文本内容 |
| marker/overlay | 位置/装饰的随编辑调整 | 文本内容 |
| buffer | 把上面各层装配成「文档」；`dirty`/`tick`/`point` | 显示、输入 |
| plugin | 组合 buffer→buffer 的函数，消费 dirty | 具体插件逻辑 |
| render | 一行 → glyph（语义 face） | 布局、屏幕、宽字符列 |
| width | 字符 ↔ 显示列 | 终端/GUI |
| window | 滚动位置 + 尺寸（纯视图状态） | 文本内容 |
| view | vrow 布局 + 光标/鼠标映射 + 滚动 | 具体后端 |
| screen | 屏幕帧（run 序列）+ diff | 具体后端 |
| paint | 可见区 → screen | 具体后端 |
| editor | 事件 → 命令 | 具体后端 |
| tui | 唯一知道 racket-tui 的层 | 命令语义 |

## 2. 三条数据流

### 编辑流（一次按键）

```
ui-event ──editor-handle──▶ 命令 ──buffer-*──▶ 新 buffer
                                              │
                              plugins 消费 dirty（run-plugins 末尾清空）
```

### 渲染流（每帧）

```
buffer ──render-line──▶ glyph(ch+face)            render.rkt
       ──width──▶ 列坐标                          width.rkt
       ──layout-clip/wrap──▶ vrow(line,列范围)    view.rkt
       ──line-range->runs──▶ run(col,text,face)   view.rkt
       ──paint──▶ screen(行runs+光标)             paint.rkt
       ──screen->bytes-diff──▶ ANSI               tui.rkt
```

### 输入流

```
终端原始输入 ──build-input──▶ ui-event ──editor-handle──▶ 命令
```

## 3. 唯一跨层契约：`edit-desc`

```racket
(struct edit-desc (s-line s-col e-line e-col new-text))  ; 全操作前坐标
;; 删除 [s-line,s-col)..[e-line,e-col)，插入 new-text（可含 \n）
```

一次编辑 = **一个 splice**（替换区间）。content 产生它，marker/props/overlay 各自用同一个
**位置映射函数** `edit-desc-map-position` 调整。所有编辑（插入/删除/换行/合并/粘贴/剪切）
都只是 splice 的特例。

**desc 不再被丢弃**：`buffer-edit` 与所有编辑/导航原语统一返回 `(values new-buffer desc)`
（导航 desc 恒 `#f`，无操作编辑 `#f`）；`editor-edit` / `editor-handle` 同样透传，供上层
（语言层 / 跨 buffer 同步）消费。`buffer.rkt` 已重新导出 `edit-desc`。

`dirty-desc`（`first-line last-line old-count new-count`）是新坐标系下的变化行范围，由
`dirty-of` 从 splice 的行范围折算、`merge-dirty` 累加，是**插件唯一的增量依据**。

## 4. 命名规范

| 前缀/后缀 | 含义 | 例子 |
|---|---|---|
| `make-*` | 构造器（表/状态） | make-marker-table, make-screen, make-editor |
| `*-open` / `*-empty` / `*-of-*` | 构造器 | buffer-open, props-empty, content-of-string |
| `*->*` | 投影/换算 | content->string, index->column, window-point->screen |
| `*-ref` / `*-count` / `*-line-count` | 访问/计数 | buffer-line-ref, marker-table-count |
| `*-get` / `*-at` | 查询 | props-get, props-at, overlay-table-at |
| `*-set-*` | 字段更新（返回新结构） | window-set-top, content-set-col |
| 动词-名词 | 变换 | buffer-insert, props-put, window-scroll |
| `*-apply-edit` | 解释 edit-desc | props-apply-edit, marker-table-apply-edit |
| `*-check` / `*?` | 断言 / 谓词 | content-check, props-check, editor-done? |
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
- 左边界吸附：`left-col` 恒为字符起点列（`snap-column-forward`），左边界不出现「空格+字符」浮动
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
| view | vrow 序列长度 = height；越界行用 line=-1 占位；clip 模式 `left-col` 恒为光标行的字符起点列（`snap-column-forward`） |

## 7. 换后端只换 `tui.rkt`

`events`/`screen`/`editor`/`view`/`paint`/`render`/`width` 全部后端无关。
GUI/Web 后端只需：把 `screen` 画出来 + 把原始输入翻译成 `ui-event`。
