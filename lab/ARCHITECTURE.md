# lab 架构

`lab/` 是 lab-rebuild 的重构版：功能不变，把 app 层从「24 字段 god-object + 手工不变量」
拆成 **base / plugin / ui / app / backend** 五层，耦合点各自收口。

```
        core/  （编辑器平台，无终端）
          ↑
lab/
  base/      可复用、无 app 依赖
    input.rkt       事件 → 绑定键（依赖 racket-tui 的事件类型）
    command.rkt     纯表：binding → handler + command-set
    dispatch.rkt    did + extra(模态) + event → 跑 handler（不认识 core / 焦点）
    face.rkt        动态 face 值（bracket-depth，#:prefab 可跨进程）
    brackets.rkt    括号配对 + 深度 → 高亮填充（纯，插件的 compute）
    layout/         area / split / main（纯几何）
  plugin/    插件层（不认识 app / 终端）
    api.rkt         插件协议：plugin（name/priority/compute）+ job（#:prefab）
    brackets.rkt    内置插件：括号按深度背景高亮
    registry.rkt    内置插件表（主进程与 worker 共用）
    runner.rkt      执行器接口 + 同步 runner
    runner-place.rkt 后台 place 进程执行器（worker 池，按 did 分派 + 唤醒源）
    worker.rkt      place 入口：维护影子文本，收 open/change/close/job
    manager.rkt     影子同步 + 版本跟踪 + 调度 + 合并 + 写回文档
  ui/        view-model（纯，只依赖 core）
    tree.rkt        文件树模型 → document
    buffers.rkt     文档/视图两级列表 → document
    slot.rkt        底部槽位文档（state / input）
    mode.rkt        输入转移状态（#f | prompt | prefix 前缀键），不认识 vid/布局
  app/       应用层（唯一状态 + 动作）
    panes.rkt       单值 pane registry：role → vid（tree/bufs/state/input）
    edit-panes.rkt  **编辑区分屏模型**：split 树 + active leaf
    paths.rkt       did ↔ 规范化路径
    state.rkt       app 结构 + 派生量 + layout 缓存
    actions.rkt     功能核心：唯一改 state/editor 的地方
    commands.rkt    命令转发：功能 → 命名命令（handler 收 (event app)）
    keys/           默认命令表（纯数据：binding → 命令），按用途分开
      edit.rkt       编辑键
      focus.rkt      C-p 前缀下的焦点移动
      app.rkt        app 级全局键
      readonly.rkt   只读基表
      tree.rkt       文件树
      bufs.rkt       文档 / 视图列表
      modal.rkt      输入 / 确认模态
      main.rkt       汇总 provide
    render.rkt      state 行 + 每帧准备 app-prepare!
    plugins.rkt     app ↔ 插件层接缝：哪些文档跑插件 / 每 tick sync+poll
    app.rkt         装配 init + 事件入口（薄壳）
  backend/
    tui.rkt         racket-tui：screen patch → ANSI（颜色查 theme/）；读事件
  theme/      主题配置（纯数据，不依赖终端）
    theme.rkt       主题机制：face / overlay → 颜色
    dark.rkt        默认深色主题
    light.rkt       浅色主题
    main.rkt        汇总 + current-theme
  main.rkt
  smoke.rkt / smoke-plugin.rkt / smoke-app.rkt
```

依赖方向是 DAG：`base → (tui)`、`ui → core`、`plugin → core + base`、`app → ui + base + plugin + core`、
`backend → app + plugin + theme`、`theme → base/face`。

## 与 lab-rebuild 的耦合点对照

| # | 旧耦合 | 现在 |
|---|--------|------|
| 1 | mode 存两份：`app.mode` + 偷偷改 command-set | `dispatch` 接 **extra-tables**（`mode-tables`），模态只是 dispatch 的一个显式维度；`app-set-input-keys!` 删除 |
| 2 | pane 身份散落（tree-vid/tree-did/…） | `app/panes.rkt` 一处登记 role → vid；did 用 editor 现推 |
| 3 | `app-paths` + `app-by-path` 手工双写 | `app/paths.rkt` 管双向表 + `dids-under`（删目录级联） |
| 4 | `ctx` 的 editor/width/height 是死字段 | 干掉 `ctx`，handler 直接收 `app` |
| 5 | `app-layout-result` 每事件算多次 | layout 缓存在 `app.layout`，只有改 layout 输入的 setter 失效它（`app-mode-set! / app-left-set! / app-edit-open! / app-edit-remove! / app-size-set!`） |
| 6 | 关文档后手工修 edit-vid/focus/bufs | 收在 `app-close-path!` / `app-show-view!` 等少数动作里 |
| 7 | `mode?` / `mode-tables`(app) 死代码 | 删除 `mode?`；`mode-tables` 真正用在 dispatch |
| 8 | 死 `slot` 结构体（mode 认识容器） | `mode-bottom-vid` / `mode-focus-vid` 直接收 vid |
| 9 | 模块名 `input-doc.rkt` 名不符实 | 改名 `ui/slot.rkt` |

## 编辑区分屏

编辑区是**二叉分屏树**（`base/layout` 的 `node/leaf`），app 层用 `app/edit-panes.rkt` 管
`tree + active`：

- `edit-panes-open!`：用新 vid 替换 active leaf（树空则建根 leaf）——打开文件的语义。
- `edit-panes-split!`：在 active leaf 上 `tree-split` 出新窗格（'lr 左右 / 'tb 上下），active 转新窗格。
- `edit-panes-remove!`：删若干 vid，active 被删就回落到第一个剩余 leaf。

**不变式：一个 view 只能占一个编辑 leaf**。把已经在别的窗格显示的 view 再显示到某窗格时，
`app-show-view!` / `app-show-document!` 会**新建一个同文档的 view**，绝不复用 —— 否则两个
窗格共享同一个 view（光标 / 滚动 / 尺寸耦合），而且 `tree-remove` 按 vid 删会把两块一起删掉。
（删除任意窗格 + 重排：`tree-remove` 只删那个 leaf、兄弟顶替，`compute-layout` 重新铺满。）
- `app-layout-result` 直接把 `tree` 交给 `compute-layout`；多窗格时**一次铺出多个 rectangle**。

命令：`Ctrl+K` 水平（上下）分隔、`Ctrl+L` 垂直（左右）分隔、`Ctrl+D` 关**焦点所在**的编辑窗格。
拆分时新窗格显示**同一文档的新 view**（独立光标 / 滚动）；关窗格**不关 view**（view 仍在文档列表里）。

active 跟随焦点：任何事件后如果焦点落在某个编辑 leaf，就把它设为 active（app-handle-input 末尾同步）。
所以「打开文件 / 拆分 / 关窗格」都作用于**当前焦点**那块，而不是最后拆分的那块；关完剩下的由
`compute-layout` 重新铺满。

分隔线渲染：`compute-layout` 的 `bars`（1 格宽/高）作为**装饰图层**交给 core 的
`editor-render-layout*!` / `editor-render-layout-patch`（可选 `decorations` 参数）合成进 screen，
`│`（lr）/ `─`（tb），所以**增量 patch 也是一致的**。装饰由 `app/render.rkt` 的
`app-bar-panes` 从布局算出（face `bar`）。

## 命令的三层

```
功能核心  actions.rkt    唯一改 state / editor；一个能力一个函数
   ↓
命令转发  commands.rkt   把能力包成统一命令 (event app) -> any
   ↓
默认命令表 keys/*.rkt    binding → 命令；纯数据，不 require core/actions/state
```

- `actions.rkt` 不理解按键 / 事件，也不认识命令表：只暴露「动作」。
- `commands.rkt` 是唯一的转发点：所有 handler 形状统一 `(event app)`，参数化的用工厂
  （`cmd-nav` / `cmd-insert-string` / `cmd-prefix`）。命令表只认这里的名字。
- `keys/` 每张表独立成文件，`keys/main.rkt` 汇总；装配点 `app.rkt` 只 require 汇总。
  `C-p` 前缀表（`focus.rkt`）被 `app.rkt` 的 `cmd-prefix` 引用，键表之间可以组合。

## 主题

颜色配置从后端挪到 `theme/`，与终端渲染解耦：

```
theme/theme.rkt   机制：theme 结构（faces / overlays / default-face）+ 查询
theme/dark.rkt    默认深色（原 backend/tui.rkt 里的硬编码配色）
theme/light.rkt   浅色
theme/main.rkt    汇总 + (current-theme) 参数
```

- 颜色值是 #f 或 `(r g b)`，**纯数据**，不认识 ANSI / racket-tui。
- `backend/tui.rkt` 只负责把当前主题的颜色翻成转义序列（`face-colors` / `overlay-colors` →
  `theme-face-colors` / `theme-overlay-colors`）。
- face / overlay 名由各 view-model 定义（`ui/tree.rkt`、`ui/buffers.rkt`、`ui/slot.rkt`、
  `app/render.rkt`、core 的 `line-number`）；主题把它们映射到颜色。
- 换主题：`(current-theme light-theme)`（`current-theme` 是 parameter）。
- 动态 face：`bracket-depth` 按嵌套深度在 `bracket-colors` 色板上取模取背景色（深度无上限）。

## 插件层

**对 text 无影响的插件**（高亮 / 诊断……）不改文本，可以整个丢到后台进程算。
插件层把这件事收成一个协议：

```
plugin/api.rkt      plugin(name, priority, compute) + job(text, path)
                     compute : job → (listof fill)   —— 纯函数，可跨进程
plugin/shadow.rkt   影子文本：open(text) / apply(edits) / text   —— 增量同步的基础
     ↓
plugin/manager.rkt  每 tick：sync! 派活（发 open/change + submit）/ poll! 收结果 + 写回
     ├─ runner.rkt       同步 runner（测试）
     └─ runner-place.rkt place 后台进程（worker 池 + 唤醒源）
```

**数据流（按版本 token 同步，不整篇搬文本）**：

```
编辑命令 (editor-view-*!)  → 返回 core 的 change
  app-plugin-note-change!  change → (l0 c0 l1 c1 inserted) 存进 manager.pending
app-handle-input / app-prepare!  →  app-plugin-tick!
  manager-sync!  有路径的文档：为当前 document 版本取 token
     token 已在缓存（undo/redo 回到旧版本）→ 什么都不发
     token 新 + 有本 tick 的 diff → runner-change!(did from to edits)
     否则（open/CAS…）            → runner-open!(did token text)
     → 对「该 token 还没算过」的插件 runner-submit!(tag name did token path)
  manager-poll!  收 (tag name fills)，token 仍是当前版本才存/合并写回
```

- **版本 token**：每个 document 值一个编号（主进程弱表 doc→token）。worker / 同步 runner 按
  `(did, token)` 缓存影子，结果也按 token 缓存（每 did 保留最近 `history-bound=64` 个）。
- **undo/redo 完全免费**：旧版本回到 token 时，影子还在、结果还在 → 不重发文本、不重算、
  不写属性。（属性本来就随 document 值存在 box 里，恢复出来就是算好的。）
- **主线程每次编辑只付 O(编辑长度)**：core 的 `change` 只存结构（`before`/`after` 点区间），
  插入文本从新文档读一次（`editor-view-change-text`），发过去的就这五元组。
- **影子文本**（`plugin/shadow.rkt`）在 worker 和同步 runner 各自维护：`vector of lines`，
  `apply` 用同一批 change（同一编辑前坐标系）从右往左 splice。用 core 的 `string->lines` /
  `lines->string`（保尾部空行，`racket/string` 的 split 会吞）。
- **按 did 固定分派**：同一文档的消息都进同一个 worker（它的版本表在那里）；
  超界版本由 manager 发 `drop!` 通知 worker 释放。

**版本闸门（异步安全的核心）**：版本用 **document 值身份 → token**（不是文本哈希）。
core 里文本编辑（`document-edit-tracks`）会 fork 一个**新的 document 值**，而属性编辑
（插件写回 `document-highlight-fill-batch`）就地改 box、值不变。所以：

- 派活时记下当时的 token；结果回来时 token 仍对应当前 document ⇒ 写回安全。
- 不等 ⇒ 丢掉（新版本会在下一次 tick 重新派活）。迟到的结果不会写错文本版本。

**合并**：多个插件的结果按 `priority` 升序拼接（低的先写、高的覆盖），
manager 是真实文件高亮轨的**唯一写者**。

**后台进程（place）**：

```
manager → runner-place → worker place（独立进程）
                              └─ registry 按 name 查同一个 compute
主进程 reader 线程：place 结果 → mailbox(async-channel) + signal(async-channel)
signal 就是 runner 的 source；backend 用 racket-tui 的 on-source 注册它，
于是 read-event 的 sync 会等它 —— 后台结果一到，事件循环醒来、写回、重绘。
```

- `job` / `bracket-depth` 用 `#:prefab`：能跨 place 序列化（普通 struct 也行，prefab 更稳）。
- 后台进程只拿到 `name`，用**同一份 registry** 查 `compute`，保证两边一致。
- 没路径的文档（`*tree*` / `*state*` …）不跑插件（“哪些算真实文件”的策略在 app/plugins.rkt）。
- 关文档时 `manager-forget!` 清状态；在途结果因 did 不在而丢。

## 关键约定

- **一个事实只存一处**：pane 身份在 `panes`、路径在 `paths`、模态在 `app.mode`、布局在 `app.layout`。
- **改 layout 输入必须走 state.rkt 的 setter**（否则缓存过期）。
- **渲染前必须走 `app-prepare!`**（刷 state 槽位 + 取窗格）；增量后端也不能绕。
- **动作只在 `actions.rkt`**；`commands.rkt` 只做「功能 → 命令」转发；`keys/` 只做「binding → 命令」。
- **颜色只在 `theme/`**；后端 / view-model 不写死 RGB。
- **插件不改 text**；装饰只写属性轨，且必须过 `manager` 的版本闸门（不直接调 `document-*`）。
- 模态表在 dispatch 时叠在 did 表之后，优先级最高。
- **前缀键**：`mode` 的第三种状态 `prefix`（记 label + tables）。下一键只查这些表（不回落 normal）；
  处理完**若还是同一个前缀就退出**，否则（处理器又进了新前缀 / 开了 prompt）就保留 → **支持任意层级嵌套**。
  `app-prefix-begin! a label (list table ...)` 可挂任意命令表；底部显示 `[label-]`。

## 跑 / 测

```
racket lab/main.rkt [根目录]
racket lab/smoke.rkt        # base / ui 协议
racket lab/smoke-plugin.rkt # 插件层（含后台 place runner）
racket lab/smoke-app.rkt    # 集成（无终端）
```

## 键位

- 焦点移动：`C-p` 前缀 + `←/→/↑/↓`（`C-p` = 控制字节 0x10，方向键无修饰，任何终端都送得到）
- `Ctrl+O` 左栏 ↔ 编辑格；`Ctrl+S` 保存；`Ctrl+Q` 退出
- 编辑区分屏：`Ctrl+K` 水平（上下）分隔、`Ctrl+L` 垂直（左右）分隔、`Ctrl+D` 关焦点所在编辑窗格（剩下自动补满）
- 编辑格：`Ctrl+A` 全选；常规编辑（方向 / Shift+方向选择 / 剪贴板 / 撤销）；终端括弧粘贴（paste 事件）走富粘贴，多行也成
- 文件树：`↑/↓/←/→` 光标移动、`Enter` 打开文件 / 展开折叠目录、`Tab` 切左栏面板、
  `Ctrl+N` 新建文件、`Ctrl+L` 新建目录、`Backspace` 删除（y/n）
- 文档列表：`Tab` 切左栏面板、`Enter` 展开/收起文档行、选 view 行 `Enter` 打开到编辑格、
  `Ctrl+N` 给当前行的文档新建 view、`Backspace` 在 view 行只关 view（文档保留，即使最后一个 view）；
  在 doc 行关文档（连带它所有 view）
- 输入行：`Enter` 提交、`Esc` 取消；字符 / 退格 / 粘贴直接编辑

## 还没动（以后）

- `base/input.rkt` 仍直接依赖 racket-tui 的事件类型（换后端要改这里）。
- `basename` 在 `ui/tree.rkt` 与 `app/actions.rkt` 各一份。
- 绑定词表把可打印字符塌成 `'text`，所以 y/n 仍要回看原始 event（`cmd-answer`）。
  要彻底解决需给绑定加「按字符」形态。
- state 行每变一次就整篇 `editor-view-assign!`，可用 `editor-view-change-text` 增量。
- `size-warning` 仍未显示。
- prompt 单槽（要嵌套再改栈）。
