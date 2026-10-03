# lab 编辑架构设计（v2）

> 建立在 `core/` 之上的**编辑器应用层**。core 是后端无关的内核，lab 提供 app 语义
> （文件路径、焦点、布局、键位）并把后端（TUI / GUI）隔离在外。core 不做任何改动。

---

## 0. 约束与已定决策

1. **多 view 模型**：一个 document 可被多个 view 呈现；一个 view 只属于一个 document。
2. **后端无关**：模型 / 命令层不依赖终端、GUI 或 io；后端只是适配器。
3. **core 不是最终 API**：core 只允许被 `lab/model/` 引用，上层用 lab 门面。
4. **document 与 view 生命周期独立**：关 view 永远不关 document；只有显式关 document 才级联关它的 view。
5. **不包渲染输出**：后端直接消费 core 的 `screen` / `piece`（本就是后端中性 wire format）。
6. **分屏树布局**：布局是一棵树；左侧一个**可隐藏的 file-tree 面板**（为将来「document 文件树」预留）。

---

## 1. 管理粒度：四种角色，按「身份」管理

core 给 `editor` / `document` / `view` 三结构，它们是**角色**而非对等容器；lab 再补一个
**Pane**（布局叶子）。四者职责：

| 角色 | 载体 | 回答的问题 | 数量 | 身份 | 生命周期 |
|---|---|---|---|---|---|
| **内容单元** | core `document` | 编辑的是什么 | N | `did` | 独立 |
| **呈现单元** | core `view` | 从哪个视口/光标看 | M（每 doc 0..M） | `vid` | 依附 document（可先于 document 关闭） |
| **会话根** | lab `session` | 打开集 + 布局 + 焦点 + 项目 | 1 | — | — |
| **布局叶子** | lab `pane` | 屏幕上一格显示什么 | P | `pane-id` | 依附 view / 固定面板 |

关系：

```
session ── editor(core 值) ──┬── documents(did)      ← 独立生命周期
        │                    └── views(vid) ──did──► document
        ├── layout : 分屏树，叶子 = pane
        ├── active : 焦点 pane-id
        └── hidden : 被隐藏的 pane-id 集合（file-tree 开关）

document 1 ── 0..M view          （可 0 view：文档打开但不显示）
pane     :   (view vid) 或 'file-tree
```

**原则：只存 delta。** core 已持有的文本 / 属性 / 撤销 / 选区 / 视口**不复制**；
lab 只存 core 没有的（文件路径、布局、焦点）。读取一律经 core 现读，
**永不缓存 document / view 值**（但可安全持有 `document-entry` / `view` 的 box 引用，身份稳定）。

结论：**管理单位 = `(session, did)` / `(session, vid)` / `(session, pane-id)`；`editor` 是
session 持有的单一事实源，不作为管理对象。**

---

## 2. 分层与依赖方向

```
lab/
├── DESIGN.md
├── protocol.rkt     纯值协议：input（后端→编辑器）+ effect（编辑器→后端）
├── output.rkt       输出：style / span / display 协议 + face→style（core screen→span）
├── model/           唯一接触 core **编辑器数据** 的层；纯函数、无后端
│   ├── layout.rkt       分屏树 + pane 代数 + 命中（纯数据）
│   ├── session.rkt      session 结构 + 打开/关闭 + 焦点 + 尺寸
│   ├── ops.rkt          每文档读（文本/名字/路径）+ 写（编辑/导航/焦点/结构）
│   ├── tree.rkt         两棵树（文件树 / 文档管理树）+ 文件系统（唯一碰盘处）
│   └── render.rkt       pane 树 → core screen（封 core 渲染 + compose）
├── command/         命令层：命令表 + 派发（不 require core）
│   ├── table.rkt        binding / command / context / table（覆盖合并）
│   ├── keys.rkt         默认命令表 + 树命令表
│   └── dispatch.rkt     session × input → session × effects
├── io/tui.rkt       racket-tui 后端（实现 display + 事件→input）
└── main.rkt         组装根（后端无关）+ TUI 入口（module+ main）
```

> 测试替身 `make-headless-display` 在 `lab-test/io/headless.rkt`。

依赖只许向下：

```
io/tui ──► command ──► model ──► core（编辑器数据）
   │            │
   │            └──► output ──► core（纯输出类型 screen / piece）
   └──── input / effect / span / style ────►（纯值协议，人人可引）
```

- `model/` 是唯一 require core **编辑器状态**的层。
- `output.rkt` 是唯一 require core **输出类型**（`screen` / `piece`）的层；后端只认
  `span` / `style`，**不碰 core**（决策 5 的落地方式）。
- `io/` 后端实现 `display` 协议 + 把原生事件译成 `input`，不做任何业务。

---

## 3. 实体契约

### 3.1 `model/layout.rkt` —— 分屏树（纯数据）

```racket
(struct pane  (id content))     ; content = (view-ref vid) | 'file-tree | …
(struct leaf  (pane))
(struct split (dir children sizes))
;; dir     : 'row（左右排）| 'col（上下排）
;; children: (nonempty-listof node)
;; sizes   : (listof size)，与 children 等长
(struct fixed (n))              ; 固定 n 列/行（file-tree 用它）
(struct flex  (weight))         ; 按权重分剩余空间
(struct pane-rect (id x y w h)) ; 求值产物：叶子在屏幕上的格位
```

代数（全部纯函数）：

- `layout-rects root x y w h gap visible?` → `(listof pane-rect)`
  - 跳过 `(visible? id)` 为假的叶子；固定尺寸先预留，剩余按 `flex` 权重分，除不尽的余数给最后一个 flex。
  - 只有 1 个可见子 → 直接占满，不留分隔。
- `layout-ids` / `layout-has-visible?`
- `layout-remove root id`（塌缩空/单子 split）
- `layout-replace root id new-node`
- `layout-split-pane root id dir new-pane`（把一个叶子换成 split）
- `layout-neighbor rects from-id dir`（按几何找相邻 pane，方向键走 pane 用）

### 3.2 `model/session.rkt`

```racket
(struct doc-meta (path saved-doc))         ; per did 的 delta
(struct session
  (editor    ; core editor 值：documents / views / clipboard 的单一事实源
   docs      ; hash did -> doc-meta
   layout    ; 分屏树根（含 file-tree 叶子）
   active    ; 焦点 pane-id / #f
   hidden    ; (setof pane-id)：被隐藏的叶子（file-tree 开关）
   project)) ; 项目根 / #f
```

结构操作（**先算新 editor，再同步 lab 侧**）：

| lab API | core / lab 动作 | 生命周期 |
|---|---|---|
| `session-open text w h name` | `editor-open`；layout = `[file-tree | view 0]` | 建首个 doc + view |
| `session-open-document s text name` | `editor-add-document-view`；往 main 加叶子 | doc 独立 |
| `session-new-view s did` | `editor-add-view`；加叶子，焦点给新 vid | view 依附 did |
| `session-close-view s vid` | `editor-close-view`；删叶子；**不动 document** | — |
| `session-close-document s did` | 先逐个 `close-view`，再 `editor-close-document`；删 doc-meta | 级联 |
| `session-focus s id` | — | — |
| `session-toggle-file-tree s` | 开/关整个侧栏（`sidebar-hidden?`） | — |

焦点回落：关掉 active 后取布局里下一个叶子；无叶子 → `#f`。

### 3.3 `model/ops.rkt` —— 每文档 读 + 写

读：`document-text` `document-name` `document-path`（core 已持有文本/属性/撤销；lab 只多一个 path delta）。
写：`view-insert!/backspace!/delete!/paste!/copy!/cut!/undo!/redo!/select-all!`、
`view-move!/scroll!/page!/goto!`、`focus-neighbor!/cycle!/pane!`、`click!/wheel!`、
`split-active-view!/close-active-view!` —— 全是包 core `editor-view-*!` 的薄封装。
命令层只调这里，**不直接 require core**。

---

## 4. 多 view / 布局不变量（core 留白，lab 负责）

1. **打开已打开的文档** → 新建 view（复用 `did`），不是新 document。
2. **关 view 不关 document**（决策 4）；关 document 才级联其 view。
3. **焦点回落**：active 消失后必须在剩余叶子里选一个，否则 `#f`。
4. **布局随生命周期**：加 view → 加叶子；关 view → 删叶子并塌缩 split；叶子集合 ⊇ 可见 view。
5. **file-tree**：只在布局里占一个固定宽叶子；隐藏 = 进 `hidden`，空间自动还给 flex。
6. **程序态**：整篇赋值走 `editor-view-assign!`（不记步 + 封口）；作者态走
   `editor-view-readonly!` / `highlight!`（不记步）。

---

## 5. IO 抽象层（input / output / 后端）

**目标**：换后端（racket-tui ↔ racket/gui ↔ headless）不改模型与命令。

### 5.1 输入（`lab/protocol.rkt`，纯值）

按 **racket/gui 的事件模型**定型（不按终端）：

| 值 | 含义 |
|---|---|
| `(modifiers control alt shift meta)` | 修饰键 |
| `(key name modifiers)` | 物理键：`name` = char 或命名键 `'left 'enter 'backspace …` |
| `(text string modifiers)` | 已解码文本（IME / 粘贴 / 多字符），与物理键分离 |
| `(mouse kind button row col modifiers)` | `kind` = `'press 'release 'move 'drag` |
| `(wheel direction row col modifiers)` | 滚轮 `'up 'down` |
| `(resize rows cols)` | 尺寸变化 |

坐标一律 **0-based 屏幕格**。像素后端在边界按字体度量换算。

### 5.2 输出（`lab/output.rkt`）

```
core screen / piece ──patch->spans(attr->style)──▶ (listof span) ──display 协议──▶ 后端
```

- `style`：`(fg bg bold? italic? underline? reverse?)`，`fg/bg` 是 RGB 或 `#f`（用后端默认）。
- `span`：`(row col text style)`，`col` 是显示列。
- `display` 协议（后端实现）：
  `init! / exit! / size / clear! / put!(row col text style) / flush!`。
- `present! disp old new attr->style`：算 core `screen-patch` → span，首帧 / 尺寸变则 `clear!`，
  最后 `flush!`；返回 `new` 作下次基线。**增量是默认**。
- core 的 `piece` attr 有两种构造（render 用 list、overlay 用 cons），在 `output.rkt`
  归一为 `(channel . face)`；`output.rkt` 提供 `attr->style`（face → 基础样式，overlay 叠反显 / 蓝底）。

### 5.3 后端（输入映射是关键差异）

| 后端 | display 实现 | 输入来源 | 映射到中性 input |
|---|---|---|---|
| `io/tui.rkt` | tui `format-*` → 终端字节 | `build-input` 的 `#:key / #:text / #:mouse / #:resize` 回调 | 分类交给 `build-input`（可打印键→`#:text`、粘贴→`#:text`、命名键/Ctrl 组合→`#:key`）；`normalize-key` 做 Ctrl+字母大→小写，`normalize-mouse` 做 1-based→0-based、move→`drag`、scroll 的 button → `wheel` |
| `lab-test/io/headless.rkt` | 把 span 记进 box | — | 无头测试 |

> **GUI 后端暂时移除**（代码已删）。接口设计不变：另写一个实现同一 `display` 协议 + 事件翻译的适配器即可，
> 模型/命令/core 一行不改。已知差异（当时实测）：`mouse-event%` **没有 `get-button`/`get-wheel-delta`**；
> GTK 下滚轮是 `key-event%`（`key-code`=wheel-up/down）从 **on-char** 来且无坐标；`canvas%` 的
> `on-event`/`on-char`/`on-size` 是**方法**（不是初始化参数），需匿名子类 `define/override`。

TUI 侧差异全部吸收在 `normalize-key` / `normalize-mouse` 里（Ctrl+字母归一、move→drag、scroll→wheel、1-based→0-based），
并有 `module+ test` 无头单测。**分类不在这里重做**：`build-input` 已经区分「可打印键 vs 命名键 vs
粘贴」，所以 `run-tui!` 直接用它的 `#:key/#:text/#:mouse/#:resize` 回调（不用 `#:any`），
可打印键因此以 `(text "a")` 而非 `(key #\a)` 进入协议——与 `protocol.rkt` 「物理键与文本分离」
的约定一致，派发层也就不再有 `(char? name)+plain-mods?` 这条重复判定。

### 5.4 副作用（`lab/protocol.rkt`，纯值）

`(quit)` / `(io-load path)` / `(io-save path did)`。命令层只返回 effect 列表，
由后端解释执行。

---

## 6. 命令层（P2）

**命令 = 值 + 过程**：`(command name proc)`，`proc : session × ctx × input → (values session (listof effect))`。
`ctx` 是派发上下文（当前行/列）。

**命令表 = `binding → command`**（不可变）：`binding = (name mods)`，`table-merge` 做覆盖（over 优先）。

**两张表**（`command/keys.rkt`）：
- **默认表** `default-table`：通用操作——移动指针 / 扩选 / 翻页 / 基本编辑 / 撤销 / 剪贴板 /
  切换焦点 / 侧栏 / 分屏 / 关视图 / 保存 / 退出。
- **树表** `tree-table`：焦点在树视图上时用（`Enter` / `Backspace` / `C-n` / `C-m` / `C-d`）。

（「每文档命令表」暂不需要：当前没有文档用自定义键位，所以先不引入存储；
真实的「模式」出现时再加一张按 did 查的表即可。）

**派发** `command/dispatch.rkt`：

```
1. resize              → 更新 session 尺寸
2. session-apply-layout! → 把尺寸落到各 view（几何命令 / ensure 要用）
3. 焦点 pane 是树视图 → 树表；否则 → 无表
4. 未命中 → 默认表
5. 仍未命中 → 自插入（text / 无 Ctrl·Alt·Meta 的可打印键）
```

**职责边界**：编辑 / 导航 / 焦点操作在 `model/ops.rkt`（包 core `editor-view-*!`）；
命令层只做「表 + 派发」，**不 require core**。改键位只动表，改语义只动 model/ops。

**默认键位（节选）**：方向 / home / end 移动；`Shift+方向` 扩选；`PgUp/PgDn` 翻页；
`Backspace/Delete/Enter/Tab`；`C-z/C-y` 撤销重做；`C-c/C-v/C-x/C-a`；`M-方向` 切焦点；
`C-o` 循环焦点；`C-b` 文件树；`C-\` 分屏；`C-w` 关视图；`C-s` 保存；`C-q` 退出。
未绑定的可打印键 / `text` → 自插入。

---

## 7. 组装与运行（P3）

`main.rkt` 顶层是组装根（唯一同时认识 model / command / output / protocol 的层），但很薄；
TUI 后端只在 `module+ main` 里接。

```
app = session ⊕ 上一帧 screen ⊕ display ⊕ quit?

app-open  display rows cols [project] #:text #:name → app（screen = #f）
app-draw  app → app'        渲染 + present!（增量）+ 更新基线帧
app-input app input → app'  dispatch → execute-effects → app-draw
```

一条输入的完整数据流：

```
后端原生事件 ──▶ input ──dispatch──▶ (session', effects)
                                   │        │
                          model/core 就地改 box  execute-effects（io-save / io-load / quit）
                                   ▼        ▼
                         session-render → screen ──present!──▶ span ──▶ display ──▶ 终端/画布
```

TUI 入口（`module+ main`）：`make-tui-display` + `run-tui!`（阻塞循环，`loop-input/stop` 由 `app-quit?` 终止）。
换后端 = 另造一个 display + 把原生事件译成 input，组装根与模型/命令不动。

---

## 8. 两棵树（P4）

**两棵树各自是一个 core document**（自托管）——不搞特殊面板：

- 文件树：文本 = 「缩进 + 标记 + 名字」一行一条，颜色来自高亮轨，整篇只读。
- 文档管理树：同样是一个 document，列当前所有文档及其视图。

因为就是 document，它们天然复用 core 的光标 / 滚动 / 选区 / 渲染；但**左侧只有一个侧栏 pane**，
在「文件树 / 文档树」之间切换（`sidebar-kind`），底部是固定 1 行状态栏（pane-id `'status`）。
两棵树的视图都在 editor 里（`tree-vids = [files, documents]`），只是同一时刻只显示其一。

树模型 `model/tree.rkt`：

```
tree  = kind('files|'documents) ⊕ vid ⊕ root(tnode)
tnode = name ⊕ id ⊕ kind('dir|'file|'doc|'view) ⊕ depth ⊕ expanded? ⊕ children
        文件树 id = 路径（children 懒加载，展开时读盘）
        文档树 id = did / vid（children 内存构造）
```

- `tree->document`：把可见行渲染成文本 + 每行 face 高亮 + 整篇只读，`editor-view-assign!` 写回（不记步）。
- 颜色区分类型：`tree-dir`（蓝）/ `tree-file`（灰）/ `tree-open`（绿）/ `tree-doc` / `tree-view-active`（黄）。
- 命令表 `command/keys.rkt`（焦点是树视图时优先于默认表）：
  `Enter` 打开（目录=展开/折叠、文件=打开、文档/视图=聚焦）、`Backspace` 关闭（已打开文件=关文档、视图=关视图）、
  `C-n` 新建文件、`C-m` 新建文件夹、`C-d` 删除（y/n 确认）。
- 建 / 删 / 打开需要输入：`session.prompt` 输入行状态；派发层优先处理 prompt（`text`/可打印键/退格/回车/Esc），
  回车调 `on-confirm`，状态栏显示 `label + text`。
- `trees-refresh`：文件树保留模型（只重画颜色 / 打开标记），文档树按当前 documents 重建（搬运展开状态）；
  派发每步结束后调用，保证树始终最新。
- **默认不打开空文档**：起手用 `session-blank`（只有尺寸、无文档），`trees-init` 只追加两棵树；
  只有从文件树 Enter 打开文件（`io-load`）才产生编辑器文档。两棵树也登记在 `session-docs`（path=#f）。
- **删除级联**：`tree-delete!` 确认后先 `close-docs-under`（关掉路径等于该文件 / 位于该目录下的文档），
  再删盘、`tree-reload!`——不会留下指向不存在路径的幽灵文档。
- **单侧栏切换**：`sidebar-kind` 决定侧栏显示哪棵树；`sidebar-switch!` 在 `files ↔ documents` 间切换
  并把焦点移到它。键位：树里 `Tab`、全局 `C-t`；`C-b` 仍然开关整个侧栏。

### 8.1 鼠标：layout 与 command 的耦合点

点击切焦点是一个纯几何问题 + 一个焦点语义问题，两侧各管一半：

- **layout**：`layout-hit rects row col → pane-rect / #f`——只回答「屏幕 (row,col) 落在哪个 pane」。纯几何，不认识焦点。
- **command / model/ops**：
  - `focus-pane!`：命中 pane → `session-focus`（右键/中键，不落光标）。
  - `click!`：命中 view pane → 聚焦 + 把屏幕坐标换算成 view 内的点（`editor-view-screen-pos->point`）并落光标；
    `Shift+点击` → 原地扩选（两棵树也是 view，所以点树同样能落光标）。
  - `wheel!`：命中 pane → 聚焦 + 滚动。
- **dispatch**：把 `mouse` / `wheel` 输入路由到上面几个函数（在 `session-apply-layout!` 之后，保证 view 尺寸正确）。

于是「layout 不认识焦点，command 不认识像素」——两边都只依赖 `pane-rect`。

> 注：终端里 `Ctrl+M` 与 `Enter` 是同一字节，`C-m` 新建文件夹在 TUI 下可能被 Enter 截走；GUI 可正常区分。

---

## 9. 分阶段

| 阶段 | 内容 | 状态 |
|---|---|---|
| **P0** | 设计定稿 | 完成 |
| **P1** | `model/{layout,session,document,view,render}` | 完成 |
| **P1.5** | IO 抽象：`input` / `output` / `theme` / `effect` + `io/{tui,headless}` | 完成 |
| **P2** | `command/{table,keys,dispatch}` + `model/ops` | 完成 |
| **P3** | `main.rkt`（组装根 + TUI 入口） | 完成 |
| **P4** | 两棵自托管树（文件树 / 文档树）+ fs 操作 + 输入行 + 状态栏 | 完成 |
| **P5** | 打开 / 保存对话框、更多编辑命令、模式命令表（GUI 后端待定） | 下一步 |
