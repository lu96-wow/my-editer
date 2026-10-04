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
    mode.rkt        输入转移状态（prompt + 续延），不认识 vid/布局
  app/       应用层（唯一状态 + 动作）
    panes.rkt       pane registry：role → vid
    paths.rkt       did ↔ 规范化路径
    state.rkt       app 结构 + 派生量 + layout 缓存
    actions.rkt     唯一改 state/editor 的地方
    commands.rkt    命令表（handler 收 (event app)）
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
| 5 | `app-layout-result` 每事件算多次 | layout 缓存在 `app.layout`，只有改 layout 输入的 setter 失效它（`app-mode-set! / app-left-set! / app-edit-vid-set! / app-size-set!`） |
| 6 | 关文档后手工修 edit-vid/focus/bufs | 收在 `app-close-path!` / `app-show-view!` 等少数动作里 |
| 7 | `mode?` / `mode-tables`(app) 死代码 | 删除 `mode?`；`mode-tables` 真正用在 dispatch |
| 8 | 死 `slot` 结构体（mode 认识容器） | `mode-bottom-vid` / `mode-focus-vid` 直接收 vid |
| 9 | 模块名 `input-doc.rkt` 名不符实 | 改名 `ui/slot.rkt` |

## 关键约定

- **一个事实只存一处**：pane 身份在 `panes`、路径在 `paths`、模态在 `app.mode`、布局在 `app.layout`。
- **改 layout 输入必须走 state.rkt 的 setter**（否则缓存过期）。
- **渲染前必须走 `app-prepare!`**（刷 state 槽位 + 取窗格）；增量后端也不能绕。
- **动作只在 `actions.rkt`**；`commands.rkt` 仅做「事件 → 动作」。
- 模态表在 dispatch 时叠在 did 表之后，优先级最高。

## 跑 / 测

```
racket lab/main.rkt [根目录]
racket lab/smoke.rkt        # base / ui 协议
racket lab/smoke-app.rkt    # 集成（无终端）
```

## 键位

- `Ctrl+←/→/↑/↓` 移焦点；`Ctrl+O` 左栏 ↔ 编辑格；`Ctrl+S` 保存；`Ctrl+Q` 退出
- 文件树：`↑/↓/←/→` 光标移动、`Enter` 打开文件 / 展开折叠目录、`Tab` 切左栏面板、
  `Ctrl+N` 新建文件、`Ctrl+L` 新建目录、`Backspace` 删除（y/n）
- 文档列表：`Tab` 切左栏面板、`Enter` 展开/收起文档行、选 view 行 `Enter` 打开到编辑格
- 输入行：`Enter` 提交、`Esc` 取消；字符 / 退格直接编辑
- 编辑格：常规编辑（方向 / 选择 / 剪贴板 / 撤销）

## 还没动（以后）

- `base/input.rkt` 仍直接依赖 racket-tui 的事件类型（换后端要改这里）。
- `basename` 在 `ui/tree.rkt` 与 `app/actions.rkt` 各一份。
- 绑定词表把可打印字符塌成 `'text`，所以 y/n 仍要回看原始 event（`confirm-text`）。
  要彻底解决需给绑定加「按字符」形态。
- state 行每变一次就整篇 `editor-view-assign!`，可用 `editor-view-change-text` 增量。
- `size-warning` 仍未显示。
- prompt 单槽（要嵌套再改栈）。
