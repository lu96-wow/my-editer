# lab 架构

`lab/` 是 lab-rebuild 的重构版：功能不变，把 app 层从「24 字段 god-object + 手工不变量」
拆成 **base / ui / app / backend** 四层，耦合点各自收口。

```
        core/  （编辑器平台，无终端）
          ↑
lab/
  base/      可复用、无 app 依赖
    input.rkt       事件 → 绑定键（依赖 racket-tui 的事件类型）
    command.rkt     纯表：binding → handler + command-set
    dispatch.rkt    did + extra(模态) + event → 跑 handler（不认识 core / 焦点）
    layout/         area / split / main（纯几何）
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
    app.rkt         装配 init + 事件入口（薄壳）
  backend/
    tui.rkt         racket-tui：screen patch → ANSI；读事件
  main.rkt
  smoke.rkt / smoke-app.rkt
```

依赖方向是 DAG：`base → (tui)`、`ui → core`、`app → ui + base + core`、`backend → app`。

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

## 关键约定

- **一个事实只存一处**：pane 身份在 `panes`、路径在 `paths`、模态在 `app.mode`、布局在 `app.layout`。
- **改 layout 输入必须走 state.rkt 的 setter**（否则缓存过期）。
- **渲染前必须走 `app-prepare!`**（刷 state 槽位 + 取窗格）；增量后端也不能绕。
- **动作只在 `actions.rkt`**；`commands.rkt` 只做「功能 → 命令」转发；`keys/` 只做「binding → 命令」。
- 模态表在 dispatch 时叠在 did 表之后，优先级最高。
- **前缀键**：`mode` 的第三种状态 `prefix`（记 label + tables）。下一键只查这些表（不回落 normal）；
  处理完**若还是同一个前缀就退出**，否则（处理器又进了新前缀 / 开了 prompt）就保留 → **支持任意层级嵌套**。
  `app-prefix-begin! a label (list table ...)` 可挂任意命令表；底部显示 `[label-]`。

## 跑 / 测

```
racket lab/main.rkt [根目录]
racket lab/smoke.rkt        # base / ui 协议
racket lab/smoke-app.rkt    # 集成（无终端）
```

## 键位

- 焦点移动：`C-p` 前缀 + `←/→/↑/↓`（`C-p` = 控制字节 0x10，方向键无修饰，任何终端都送得到）
- `Ctrl+O` 左栏 ↔ 编辑格；`Ctrl+S` 保存；`Ctrl+Q` 退出
- 编辑区分屏：`Ctrl+K` 水平（上下）分隔、`Ctrl+L` 垂直（左右）分隔、`Ctrl+D` 关焦点所在编辑窗格（剩下自动补满）
- 编辑格：`Ctrl+A` 全选；常规编辑（方向 / Shift+方向选择 / 剪贴板 / 撤销）
- 文件树：`↑/↓/←/→` 光标移动、`Enter` 打开文件 / 展开折叠目录、`Tab` 切左栏面板、
  `Ctrl+N` 新建文件、`Ctrl+L` 新建目录、`Backspace` 删除（y/n）
- 文档列表：`Tab` 切左栏面板、`Enter` 展开/收起文档行、选 view 行 `Enter` 打开到编辑格、
  `Ctrl+N` 给当前行的文档新建 view、`Backspace` 在 view 行只关 view（文档保留，即使最后一个 view）；
  在 doc 行关文档（连带它所有 view）
- 输入行：`Enter` 提交、`Esc` 取消；字符 / 退格直接编辑

## 还没动（以后）

- `base/input.rkt` 仍直接依赖 racket-tui 的事件类型（换后端要改这里）。
- `basename` 在 `ui/tree.rkt` 与 `app/actions.rkt` 各一份。
- 绑定词表把可打印字符塌成 `'text`，所以 y/n 仍要回看原始 event（`cmd-answer`）。
  要彻底解决需给绑定加「按字符」形态。
- state 行每变一次就整篇 `editor-view-assign!`，可用 `editor-view-change-text` 增量。
- `size-warning` 仍未显示。
- prompt 单槽（要嵌套再改栈）。
