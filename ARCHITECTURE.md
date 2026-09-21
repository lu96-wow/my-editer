# ARCHITECTURE —— 分层、组合与契约

纯函数式、持久化、后端无关的编辑器核心。所有值是**不可变数据**，所有操作是
**`data -> lambda -> data`** 的纯函数；没有隐藏状态，没有副作用。

---

## 0. 目录 = 依赖层

目录不再按「文本 / 视图」这种主题切，而是按**依赖层（stratum）**切：
**依赖只许向下**——一个模块只能 `require` 同层或更低层的模块，永不向上。
这样从路径就能读出「我在哪一层、我能依赖谁」。

```
core/
├── atom/                      # 原子：不可再分的值 + 代数（只互相依赖）
│   ├── point.rkt              #   位置 (line,col) + 比较 + clamp
│   ├── selection.rkt          #   选区 (anchor,head) + 端点映射
│   ├── lines.rkt              #   string->lines（换行归一的唯一约定）
│   ├── edit.rkt               #   edit-desc + 位置代数 + edit-change
│   ├── content.rkt            #   行向量文本存储 + content-apply
│   ├── width.rkt              #   显示宽度（wcwidth 语义）
│   └── event.rkt              #   类型化输入事件
├── unit/                      # 单元：由原子组合出的「单维结构」
│   ├── attrs.rkt              #   行内属性区间（通用 key→hash，随编辑移动）
│   ├── screen.rkt             #   run 行帧（width）
│   └── history.rkt            #   账本：edit-change 序列
├── doc/                       # 文档：把单元装配成一个可编辑值
│   ├── buffer.rkt             #   content ⊕ attrs（+tick）
│   └── batch.rkt              #   [edit-desc] → buffer（原子批量施加）
├── viewport/                  # 视口：把文档投影成画面
│   ├── window.rkt             #   buffer ⊕ point ⊕ 滚动/尺寸
│   ├── render.rkt             #   buffer 行 × line-face-provider → glyph
│   ├── layout.rkt             #   window → vrow / 光标映射 / ensure / 视觉移动
│   ├── project.rkt            #   window → screen
│   └── rebase.rkt             #   window × edit → window（free / follow）
├── platform/                  # 平台：多文档 × 多视口 + 三种面
│   ├── state.rkt              #   editor/view/buffer-entry 数据 + 查找 + 不变量（内部）
│   ├── write.rkt              #   无策略写原语（内部）
│   ├── neutral.rkt            #   中性面：读 / 构造 / 投影（公开）
│   ├── reaction.rkt           #   显示语义：clamp / map / leader（内部）
│   ├── program.rkt            #   程序面（公开）
│   └── command.rkt            #   用户面（公开）
├── api.rkt                    # 低层公开面：白名单转发（零逻辑）
└── editor.rkt                 # 最终组合入口
```

依赖方向：

```
atom  ←  unit  ←  doc  ←  viewport  ←  platform
api        ←  atom, unit, doc, viewport          # api 只转发低层，不依赖 platform
editor.rkt ←  api, platform(neutral, program, command)
```

`platform/state.rkt`、`platform/write.rkt`、`platform/reaction.rkt` 是**内部**，不进入口。
同层内允许相互依赖（如 `project → layout`、`program → neutral`），
但必须无环；`tools/layers.rkt` 机械校验「不得向上」。

---

## 1. 五层各是什么

### atom —— 原子
不可再分的值，以及只依赖同层原子的代数。`point` 是唯一位置表示；`selection` 是选区
（`anchor`/`head`，空选区即光标）；`edit-desc` 是唯一跨层变更契约；`content` 是行向量
文本存储；`width` / `event` 是值。`lines.rkt` 固定「字符串 ↔ 行序列」的唯一
约定，供存储与代数共用。

### unit —— 单元
每种「单维结构」= 一种标注/索引 + 它自己的 `apply-edit`：
- `attrs`：行内属性区间（通用 key→hash）；core 只解释保留 key `read-only`。
- `screen`：后端无关的输出帧（run 序列）。
- `history`：`edit-change` 的账本（撤销/重放）。

### doc —— 文档
把 unit 装配成**一个可编辑值**：`buffer` = 文本 ⊕ 属性（+ `tick`）。
**文档不存 face**（派生 face 是投影参数，见 §5、§9）。
`buffer-apply-edit` 是唯一传播点，把同一条生效 `edit-desc` 依次喂给各层，保证坐标一致。
`batch` 处理「一串 desc」。

### viewport —— 视口
把文档投影成画面：`window` 持有文档引用与光标/滚动；`render` 把一行合成 glyph；
`layout` 生成 vrow 并做光标/鼠标映射、滚动、ensure、视觉移动；`project` 出 `screen`；
`rebase` 是编辑后 view 的重新基准（free 映射 / follow 镜像）。

### platform —— 平台
`state` 是 `[buffer-entry] × [view] × focus`（`view` = id × window × sync，buffer 在 window 里）；
`write` 是无策略写原语，维持不变量；`neutral` 只读投影；`reaction` 是唯一的显示语义；
`program` / `command` 是两个操作面。

---

## 2. 核心结构如何组合成 editor.rkt

```
atom        point · selection · edit-desc · content · width · event
             │
unit        attrs = 行 × rspan(hash)                      screen = runs(文档) ⊕ cursors/selections(视图 overlay)
            history      = [edit-change]
             │
doc         buffer  = content ⊕ attrs ⊕ tick
            batch   = buffer × [edit-desc] → buffer × applied × inverses
             │
viewport    window  = buffer ⊕ point ⊕ (mode, top, left, height, width)
            render  = buffer × line × line-face-provider → glyphs   （派生 face 在此注入）
            layout  = window × render → vrows / 映射 / ensure / 视觉移动
            project = window × layout → screen
            rebase  = window × edit-desc → window              （free / follow）
             │
platform    state   = [buffer-entry] × [view] × focus   （view = id × window × sync；window 含 buffer）
            write   : state × … → state                        （无策略写原语）
            reaction= state × edit → state                     （clamp / map / leader）
            neutral = state → 读 / 构造 / 投影
            program = state × edit-desc → (values state report)（程序面）
            command = state × op      → (values state report)（用户面）
             │
editor.rkt  = api（低层公开面）+ neutral + program + command
```

一条命令的返回是 `(values editor (or/c #f change-report))`；`change-report` 携带
影响行区间与**施加顺序**的生效 `edit-desc`。两条数据流：

- **内容流**：`op`（`buffer point → edit-desc`）→ `buffer-apply-edit` → 新 buffer。
- **渲染流**：`buffer → render → run → window->screen → screen`（后端画）。

**`screen` 有两条独立通道**（这是刻意的分离）：
- **文档文本** `row-runs`：来自 buffer 的文本 + 投影 `line-face-provider` 给出的 face。
- **视图 overlay** `cursors` / `selections`：来自 window 的选区（光标点 = 每个选区的 head；
  选中区 = 每个非空选区的 `[anchor,head)` 按 vrow 切段）。

两者不混：文本/标注是**文档**状态（存 buffer、随文本移动、可编辑）；光标/选区是**视图**状态
（存 window、临时）。`face` 一律是**语义 hash**，core **不给颜色**，前端把语义映射成样式。

---

## 3. 一个编辑原语 + 显式策略

一切操作先问：**改哪个对象（view）？编辑上下文是什么？用什么策略？**

编辑只有**一个原语**（在 `platform/program.rkt`）：

```
editor-command        : 给 op，算 desc 再施加
editor-command-batch  : 给 descs 直接施加
```

策略全是**正交的显式参数**（不是函数身份）：

| 参数 | 取值 |
|---|---|
| `#:view` | 目标 view（默认焦点） |
| `#:selection` | 编辑上下文（默认该 view 的选区集） |
| `#:trusted?` | 是否跳过 read-only 守卫（默认 `#f` = 守） |
| `#:reaction` | `none` / `map` / `leader`（本 view 怎么反应；其余同文档 view 按 sync） |
| `#:record?` | 是否记一步账本 |
| `#:pre-point` | 撤销回落的编辑前光标 |

`editor-edit-at` / `editor-edit-at-batch` / `editor-view-edit` / `editor-edit` 都是它的
**薄封装**（只固定策略取值），所以不存在「两个面各自实现一遍」。

- **程序默认**：`editor-edit-at` → `#:reaction 'none`（只换 buffer 值，视图字面不动）。
- **用户默认**：`editor-edit` → `#:reaction 'leader` + `#:record? #t`。
- **裸写 / 同步**：视图写入是 `editor-view-put-window`（裸写，不镜像）；同步是显式
  `editor-view-follow`。用户导航 = 两者的组合（`editor-view-move`，不对外）。
- **中性面**：读、解析、投影、构造（`editor-buffer->string` 等）。

---

## 4. 显示语义（内容变更后视图怎么反应）

`platform/reaction.rkt` 是唯一的显示语义层，全部是 `editor -> editor`：

| 策略 | 行为 | 谁用 |
|---|---|---|
| `none` | 字面不动，只把光标/视口夹回合法域 | 程序默认 |
| `map` | 每个同 buffer view 各自把光标映射过这次编辑（不滚屏） | `editor-edit-at` 显式地图 |
| `leader` | 指定 view 推进到插入后 + ensure；其余 free 映射 / follow 镜像 | 用户编辑 |

契约：同步**只在同一 buffer 的 view 之间**发生；`leader` 必须**先 ensure 定稿**，
`follow` 再复制。

---

## 5. 位置契约

**`point` 是唯一的位置表示**（`line`, `col`，0-based，`col` 是**字符索引**）。

**选区（selection）是 view 层的光标模型**：`selection = (anchor head)`，空选区就是普通光标；
一个 view 持有一组选区（`window` 的 `selections` + `primary-index`），这就是多光标。
光标/选区是 **view 状态**，不进 buffer（buffer 无光标）。

**选择/导航是算子，不是容器操作**（Unix 式接口）：
- 值级原子（低层）：`point-left/right/home/end : buffer point -> point`，
  `point-up/down : window point -> point`。
- editor 级算子（应用用）：`editor-point-left/right/home/end : editor bid point -> point`，
  `editor-point-up/down : editor vid point -> point`；buffer/window 由 bid/vid 解析，应用不见底层值。
- 选区变换是纯原子：`selection-map-head/anchor/both`（对端点施 `point→point`）。
- 集合级正交组合：`window-map-selections`（全部）/ `window-map-primary`（仅 primary）；
  `window-primary` 直接给 primary **选区值**（不再靠位置比较），`window-primary-index` 给下标。
- 编辑入口 `editor-edit` 也遵循同一形态：`op : editor bid selection → edit-desc` 是策略（editor 级），
  core 负责循环/落点/账本；buffer 级 `buffer-op-*` 是更低层的动作。

多光标编辑 = 对每个选区施加同一 op 得到一组**同坐标系、不重叠**的 `edit-desc`，
交给 `buffer-apply-edit-batch` **一次原子施加、一步撤销**（`editor-edit` 就是这么做的）。
若 op 会**超出选区**（如 backspace 删光标前一字符、delete 删后一字符），相邻选区可能产出
重叠的 desc；`editor-edit` 会先把冲突的选区**合并成包络并重算 op**，保证交给 batch 的 desc 两两不相交。
方向键对每个选区各走一步（`window-map-points`）后再去重/合并。
Shift 扩选 = `editor-map-primary` + `selection-map-head`；移动全部 = `editor-map-selections` +
`selection-map-both`；加光标 = 点运动算位置后 `editor-add-selection`。

| 名字 | 契约 |
|---|---|
| `point` | 位置 `(line col)`；要位置收 point，给位置返回 point |
| `point-clamp` | 把位置夹到合法域（越界有唯一合法解释） |
| `buffer-clamp-point` | 只按 buffer（不依赖视图）夹紧 |
| `edit-desc-map-position` | 编辑前位置 → 编辑后位置（`#f` = 落在被删区间） |

三套列不许混：`point.col` 是字符索引，`window.left-col` / vrow 是显示列，
偏移是 `content->string` 坐标。换算只经 `index->column` / `column->index`。

---

## 6. `buffer-tick`（变化计数 / 版本戳）

`buffer-tick` 是单调计数，回答「有没有变」：文本编辑、写属性 **都涨**。
多线程 / 乐观并发合并时拿它当**版本戳**。注意 tick 也随标注涨——要判断「**文本本身**
是否同一」用 `buffer-content-eq?`。「有没有未保存改动」不属于 core：它取决于外部事件
（存盘），由调用方自己持有。

---

## 7. 撤销 / 重放

- 一步自含正反两向：`step` = `(replay-descs undo-descs pre-point)`，账本 = `(undo redo)`。
- 逆必须由**编辑前**的 `buffer` 导出（`buffer-edit-desc-inverse`）；用编辑后的 buffer
  求逆会静默写坏历史。
- 合并规则是**结构判定**（打字连续段 / 退格段 / 前向删除段），无时钟无状态。
- 撤销/重放走 **trusted**：当年过了守卫（被拒的 `desc` 不入栈），不该被事后属性挡住。

---

## 8. 守卫抑制：显式 trusted 入口

`read-only` 守卫默认开；绕行**只**有显式入口 `buffer-apply-edit-trusted` 与
`editor-edit-at` 的 `#:trusted?`。没有全局开关、没有 `inhibit` 参数。

---

## 9. 增量信息归操作，不归文档

「这次改了哪几行」随操作返回（`edit-desc` / `change-report`），不存进 `buffer`：
`edits-span` 给出应用顺序的一组 desc 影响的行区间并集；`change-report` 是命令的第二个返回值。

**作者态 vs 派生态（face）：** 文档只存**文本 + 属性**（`content` + `attrs`；`read-only` 是 core
保留并解释的 key，其余对 core 不透明），它们随编辑移动。**派生 face**（content 的纯函数，如语法高亮）**不进文档**，
而是作为投影参数：viewport 机制用 `line-face-provider : buffer × line → runs`，
editor 门面用 `face-provider : editor bid line → runs`（内部适配成前者），在
`window->screen` / `editor->screen` 时现算。

这条边界消除了「重算」：派生量不存 → 不会过期 → 不需要失效，也不需要 `change-report`
驱动标注。（异步/外部标注如 LSP 诊断不是 content 的纯函数，归各自的缓存，不由投影现算。）

---

## 10. API 可达面：显式白名单

- 消费者白名单 = **`core/editor.rkt`**（低层公开面 + editor 平台）。
- 内部机制可达但不进白名单：`platform/state.rkt`、`platform/write.rkt`、
  `platform/reaction.rkt`、各层内部模块。
- 带不变量的值（`buffer` / `window` / `screen`）只透出谓词、读口与具名构造入口
  （`buffer-open` / `window-open` / `screen-empty` / `screen-compose`），**不透出 struct
  构造器**，避免从外部绕过规范化。
- `tools/reconcile.rkt` 对账文档表格名字与白名单；`tools/layers.rkt` 强制「依赖不向上」。

---

## 11. 违约行为

违约分两类，判据是「最近合法解释」是否存在：

- **有唯一合法解释 → 夹紧/归一**（越界位置夹到合法域；见 `point-clamp`）。
- **没有合法解释 → 报错**（反向编辑区间、跨行属性区间、未知 `sync`）。
