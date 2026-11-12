# edit-tui-rebuild

这是按“core 纯数据 → editor 操作面 + 扩展点 → plugins → host”模型重建的第一阶段。

目标不是复制旧 `edit-tui`，而是先立住 **操作面 / 裸 API / 扩展点 / 插件状态** 这四条边界，
继续把 workspace / analysis / 多进程等能力接进来。

---

## 当前实现范围

已经完成：

- `core/`：复用 repo 的纯 core（document / view / panel / rect / render 值）。
- `editor/engine/`：core buffer / view 的唯一可变拥有者。
- `editor/ops/raw.rkt`：裸操作，不跑扩展点。
- `editor/ops/surface.rkt`：编辑操作面，负责 before / after hooks、plugin-state 线程化。
- `editor/layout.rkt`：布局操作面（split / close / focus / mouse）+ layout 扩展点。
- `editor/resource.rkt` / `editor/mode.rkt`：已打开文档 / path / mode / opened 集合。
- `features/placement/`：打开文件后的目标 editor 选择。
- `features/input/`：输入栏状态 / 编辑接口。
- `host/open.rkt` / `host/prompt.rkt` / `host/close.rkt`：打开 / 保存退出 / 关闭 buffer。
- `editor/job.rkt` / `host/jobs.rkt`：异步 job 账本 + worker runtime。
- `editor/timer.rkt`：timer runtime + `timer-event` + 插件 `#:handle-timer`。
- `editor/overlay.rkt`：插件浮层描述，host 转 core panel。
- `plugins/completion/`：本地候选 / debounce / overlay 菜单 / 接受。
- `plugins/docs/`：docs 面板 / 本地预览 / 异步库文档 / C-x d。
- `editor/points.rkt`：插入点表（name / kind / phases / context），make-hook 校验 operation/phase。
- `editor/hooks.rkt`：typed hook 扩展点 + 有序 pipeline。
- `editor/contributions.rkt`：非 hook 扩展点的统一 registry（sync / overlay / timer / job-service / job-result）。
- `editor/plugin.rkt`：插件描述 + 字段聚合；`editor/plugin-runtime.rkt`：registry 执行器。
- `editor/plugin.rkt`：最小插件值（id / state / hooks / commands）。
- `plugins/pair/`：括号自动配对。
- `plugins/indent/`：Enter 换行缩进（最小版）。
- `plugins/racket-color/`：Racket 基础语法着色（每帧 sync + version 缓存）。
- `plugins/layout/`：通过 `commands` 贡献 split / focus / close 键位。
- `plugins/filetree/`：sidebar 文件树、目录展开 / 折叠、隐藏文件切换、guarded Enter / C-r / C-h；生产路径异步扫描。
- `plugins/resources/`：resources 面板、buffer / view 行、dirty 标记、Enter 聚焦。
- 打开文件：resource 去重 + placement（方向键 / Enter / Esc / 鼠标）。
- C-s / C-q：save-path / save-confirm / quit-confirm 输入栏流程。
- `editor/plugin.rkt` 的 `run-plugin-syncs`：按插件顺序执行每帧同步。
- `guarded-command`：插件命令不适用时自动回落到下一张表。
- `core/layout/` / `core/panel/` / `core/projection/` / `core/focus/`：纯布局 / panel / 投影 / 焦点。
- `host/final.rkt`：sidebar + 多 editor panel + status 的可运行 TUI。
- `test/`：hooks / ops / plugins / layout / mouse / commands / host 回归。

还没有：

- completion 的 workspace / analysis 完整候选
- docs 的跨 buffer workspace 本地定义
- C-x o completion/docs 焦点切换
- 多进程
- 插件 services
- 完整的 keymap 配置 / 插件命令贡献

这一阶段先把编辑器最核心的“插入 / 删除”路径跑通，并证明：

> 插件只通过扩展点参与编辑，不直接摸 engine。

---

## 目录

```text
edit-tui-rebuild/
  core/
    api.rkt            纯值 / 纯算法面（当前复用 repo core）
    command/           key token + command table（纯）
    layout/            split tree / solve / 结构操作 / config
    panel/             layout panel 资源
    projection/        layout -> core panel / 命中
    focus/             方向焦点导航

  editor/
    engine/            core buffer / view 的唯一拥有者
    ops/raw.rkt        裸操作：不触发 hook
    ops/surface.rkt    编辑操作面：validate -> transform -> raw -> derive -> observe
    layout.rkt         布局操作面：split / close / focus + layout hooks
    resource.rkt       已打开文档：path / view / mode / saved-version
    mode.rkt           .rkt / #lang racket -> racket，否则 text

    job.rkt            job-result-event / job 账本 State
    timer.rkt          timer-event / schedule / cancel / editor timer runtime
    overlay.rkt        插件浮层描述
    points.rkt         插入点表 / kind / phase / context 校验
    hooks.rkt          typed hook 扩展点 / 有序 pipeline
    contributions.rkt  非 hook contribution registry
    plugin.rkt         插件描述 / 字段 -> contribution
    plugin-runtime.rkt contribution registry 执行器 + command registry -> table
    state.rkt          纯值：editor-core + editor-session + app-state
    context.rkt        editor = engine + hook registry + plugins
    api.rkt            插件唯一能 require 的 editor 面
    host-api.rkt       宿主装配面（额外暴露 engine 生命周期 / 渲染）
    action.rkt         quit / flash 等 action 数据

  plugins/
    pair/plugin.rkt
    indent/plugin.rkt
    racket-color/plugin.rkt
    layout/plugin.rkt
    filetree/plugin.rkt
    resources/plugin.rkt
    completion/plugin.rkt
    docs/api.rkt
    docs/plugin.rkt

  features/
    input/             单行输入栏
    placement/         打开文件后的目标 editor 选择

  host/
    final.rkt          可运行 TUI / 事件循环
    docs.rkt           completion -> docs 的跨插件 action 解释
    event.rkt          tui raw -> host 事件
    keymap.rkt         命令值 + 默认键位
    jobs.rkt           worker runtime
    timers.rkt         timer runtime

  test/
    hooks.rkt
    ops.rkt
    plugins.rkt
    ownership.rkt      插件状态 owner 写回
    state-split.rkt    core / session 更新互不污染
    resource-path.rkt  workspace root 内相对 / root 外绝对
    ui-incremental.rkt UI view face-only / 文本最小 diff
    host.rkt
    layers.rkt
    run.sh
```

---

## 两条操作 API

### 1. 裸 API：`editor/ops/raw.rkt`

```racket
(raw-insert! engine view-id text)
(raw-backspace! engine view-id)
(raw-delete! engine view-id)
(raw-move! engine view-id dir)
(raw-undo! engine view-id)
```

特点：

- 不跑 hook；
- 只由 `editor/ops/surface.rkt` 或 editor 内部使用；
- 不是插件互相调用的通用入口。

### 2. 操作面：`editor/ops/surface.rkt`

```racket
(editor-insert! ed state view-id text)
(editor-delete! ed state view-id kind)
(editor-move! ed state view-id dir)
(editor-undo! ed state view-id)
```

内部顺序：

```text
1. 构造 edit-context
2. validate hooks     （可以否决）
3. transform hooks    （可以改 text / delete-plan / caret-delta）
4. raw 操作
5. derive hooks       （纯派生，不能改文本）
6. observe hooks      （可以返回 action）
7. 把 plugin-state 写回 editor-core（app-state 里保留 session）
```

### 为什么裸 API 不直接给插件

如果插件 A 在 after hook 里用裸 API 插文本，插件 B 的 after hook 不会再被触发，
派生状态可能不一致。当前约定：

- 插件要改文档：通过操作面请求，或者由 host 在操作结束后执行 action；
- 裸 API 只用于当前操作自己的内部原语；
- 以后加事务后，嵌套裸操作会合并进同一个 change 批次，扩展点只在事务边界跑一次。

---

## 扩展点

编辑 operation：

```text
'insert
'delete
'changes    一次 surface 操作产生的 change 批次（着色 / workspace / completion 用）
```

布局 operation：

```text
'layout-split
'layout-close
'layout-focus
```

phase：

```text
'validate   否决 / 权限 / 模式限制
'transform  纯变换（自动配对、缩进）
'derive     纯派生（着色、分析缓存）
'observe    发 action / 调度异步 / flash
```

before 阶段按 `validate -> transform`；
after 阶段按 `derive -> observe`。

hook 签名：

```racket
(hook-fn ctx plugin-state) -> (values ctx' plugin-state' actions allow?)
```

- `ctx` 是 `edit-context`；
- `plugin-state` 只属于这个插件；
- `allow? = #f` 只会中止 before 阶段；
- after 阶段不会因为某个 hook 返回 `#f` 而中断。

顺序：

```text
priority 小者先；同 priority 按注册顺序。
```

hook 没有 plugin discovery / 依赖解析；非 hook 面统一走 contribution registry。

---

## 插件 commands

插件可以提供一张 `command-table`：

```racket
(make-plugin
 #:id 'layout
 #:state #t
 #:commands (keys [(key 'w 'ctrl) (key 'right) split-right-command]))
```

命令值是普通过程，只拿到自己的 plugin-state：

```racket
(lambda (ed state ps) -> (values state' ps' actions))
```

插件 `#:commands` 里的每条 key binding 在构建 editor 时变成一条
`command/<scope>` contribution；默认 scope 是 `'global`：

```text
command/<scope> -> ordered (owner, command-binding)
```

host 从 registry 建纯 `command-table`，leaf 保存 ordered `(owner . command)`
列表；执行后按 owner 写回 `ps'`，插件不能写别的 owner。

查找顺序：

```text
command/global 贡献（priority / 注册顺序）
  > host default-command-table
```

同一 key 有多条命令时，guard 不成立会继续试下一条 / 下一张表。
`plugins/layout` 已经用这个机制贡献了 `C-w` / `C-x` / `C-d`，
host 不再知道 split/focus 的实现。

如果插件命令只想在某个焦点下生效，用 `guarded-command`：

```racket
(make-guarded-command
 #:when (λ (ed state ps) (eq? (editor-focus-view-id state) filetree-vid))
 #:run enter-command)
```

guard 不成立时，host 继续查下一张表，所以 filetree 的 Enter 不会抢 editor 的 Enter。

---

## 插件每帧 sync

插件可以实现：

```racket
#:sync (lambda (ed state ps) -> (values state' ps'))
```

host 在每帧按插件安装顺序执行：

```text
panel 尺寸同步 -> status 内容 -> 插件 sync -> 渲染
```

`racket-color` 是第一个真实用户：按 `(doc-id, version)` 缓存 color-state，
版本没变时只把已有 face track 写给新 view（split 出来的 view 也能拿到颜色）。

sync 顺序 = 插件安装顺序。`filetree` 放在 `racket-color` 前面，保证 UI 内容先写、
派生 face 后写，避免多等一帧。

---

## 插件状态

插件状态是纯值，按 plugin id 分命名空间存在 `editor-core.plugin-states`。
插件回调只拿自己的 `ps`，返回自己的 `ps'`：

```racket
hook        (ctx ps)          -> (values ctx' ps' actions allow?)
sync        (ed state ps)     -> (values state' ps')
timer/job   (ed state ps ev)  -> (values state' ps' actions)
command     (ed state ps)     -> (values state' ps' actions)
```

`editor/plugin-runtime.rkt` 根据 contribution owner 写回；`editor/api.rkt`
不导出 `editor-state-set-plugin-state`，也不导出 resource 变更函数。
跨插件请求走 action（例如 completion 发 `show-docs-action`，docs owner 更新自己）。

插件初始状态来自：

```racket
(make-plugin #:id 'pair #:state #t #:hooks ...)
```

---

## 运行

```sh
racket edit-tui-rebuild/host/final.rkt
```

键：

```text
直接打字       插入
Enter          换行 + 缩进
Tab            插入两个空格
Backspace      删前
Delete         删后
←→↑↓ Home End  移动
Shift+方向     扩选
PageUp/Down    翻页
C-a / C-e      行首 / 行尾
C-f            右移
C-k            删到行尾
C-z / C-y      撤销 / 重做
C-w ←→↑↓       拆分当前 editor
C-x ←→↑↓       焦点在 editor panel 间移动
C-d            关闭当前 editor panel（最后一个不允许）
C-s            保存 / save-as / 确认
C-q            退出（dirty -> 确认 / save-as）
C-o            手动打开补全
Up / Down      移动候选
Tab            下一个候选
Enter          接受候选（菜单关闭时仍是普通换行）
Esc / C-g      关闭补全
M-d            查看光标处标识符文档
C-x d          显 / 隐 docs panel
C-b            显 / 隐 sidebar
C-x b          切换 sidebar tab（filetree / resources）
C-x n / C-x p  下一个 / 上一个 editor tab
C-x k          关闭当前 buffer（dirty -> 确认）
C-x ←          聚焦 sidebar
Enter          文件树：打开文件；编辑器：换行
C-r            文件树刷新
C-h            文件树：显 / 隐 dotfile
鼠标拖接缝     resize
鼠标点 panel   聚焦 + 光标落点
鼠标滚轮       滚指针下 panel
C-q            退出
```

自动配对：

```text
输入 ( [ { "  -> 自动补闭符号，光标停在中间
空配对中间 Backspace / Delete -> 一次删一对
```

---

## 测试

```sh
bash edit-tui-rebuild/test/run.sh
```

单独跑：

```sh
racket edit-tui-rebuild/test/hooks.rkt
racket edit-tui-rebuild/test/ops.rkt
racket edit-tui-rebuild/test/plugins.rkt
racket edit-tui-rebuild/test/layout.rkt
racket edit-tui-rebuild/test/mouse.rkt
racket edit-tui-rebuild/test/commands.rkt
racket edit-tui-rebuild/test/filetree.rkt
racket edit-tui-rebuild/test/filetree-expand.rkt
racket edit-tui-rebuild/test/placement.rkt
racket edit-tui-rebuild/test/resources-panel.rkt
racket edit-tui-rebuild/test/save-quit.rkt
racket edit-tui-rebuild/test/tabs.rkt
racket edit-tui-rebuild/test/color-incremental.rkt
racket edit-tui-rebuild/test/job-async.rkt
racket edit-tui-rebuild/test/color-word.rkt
racket edit-tui-rebuild/test/timer.rkt
racket edit-tui-rebuild/test/completion-docs.rkt
racket edit-tui-rebuild/test/sidebar.rkt
racket edit-tui-rebuild/test/host.rkt
racket edit-tui-rebuild/test/host-event.rkt
racket edit-tui-rebuild/test/ownership.rkt
racket edit-tui-rebuild/test/state-split.rkt
racket edit-tui-rebuild/test/resource-path.rkt
racket edit-tui-rebuild/test/ui-incremental.rkt
racket edit-tui-rebuild/test/layers.rkt
racket edit-tui-rebuild/test/ownership.rkt
```

---

## 设计规则

1. `core/` 不放 hook、不放插件、不放 IO。
1b. `editor/layout.rkt` 只做通用布局操作；具体 editor/status/sidebar/docs 装配在 `host/layout.rkt`。
1c. 插件 API 不导出 host 编排函数；host-api 才导出 plugin runner / open / prompt。
2. 只有 `editor/ops/raw.rkt` 能写 engine。
3. 所有用户可见编辑走 `editor/ops/surface.rkt`。
4. 插件只 require `editor/api.rkt` + feature 的 `api.rkt`；不 require editor 内部 / host。
5. 插件状态是纯值，按 plugin id 命名空间存在 editor-core；只有 plugin runtime 按 owner 写回。
5b. app-state = editor-core + editor-session；editor 操作只改 core，host 会话只改 session。
6. hook 不放进 state，hook 属于 editor 实例的不可变 registry。
7. layout / render 保持纯；它们以后接 provider，而不是任意 hook。
8. 异步 / 多进程只通过 job request/result + 版本校验，不跨进程传 lambda。

---

## 与旧实现的差异

已经恢复的旧行为：

- filetree 行文本：根显示绝对路径，子项只显示名字；**2 空格缩进**区分层次；
- 打开文件去重 / 已打开 panel 聚焦 / detached 进 placement；
- placement：方向键换目标、Enter 放入、Esc 取消、鼠标点 editor 放入；
- pair / indent 按 buffer mode 生效（.rkt / #lang racket）；
- resources 面板（buffer / view 行、dirty、Enter 聚焦；workspace root 内显示相对路径）；
- C-s / C-q 的 save-path / save-confirm / quit-confirm 输入栏；
- 鼠标文本拖选（press 落 caret，move 扩展，release 结束）；
- UI view 增量：selection 只改 face 行；文本变化做最小区间替换；
- editor tab 切换 / close buffer；
- color 增量：`'changes` + `color-edit*` 只重扫脏行，undo/首次打开才全量；
- color 按 resource mode 判断 Racket；word-color 光标 token 抑制；
- filetree 异步目录扫描：sync 提交 job，worker 返回后按 projection tag 校验；
- C-b 显 / 隐 sidebar；
- filetree 支持自定义 `hidden-entry?` 过滤规则；
- timer runtime + 插件 `#:handle-timer`；
- 插入点表 + hook owner / phase 校验；
- 非 hook 扩展面统一 contribution registry；
- job-result 按 kind 派发；同名 job-service 构建时报错；
- 通用 layout ops 与 host 布局装配分离；
- plugin-api / host-api 分层（runner / open / prompt 只在 host-api）。
- completion：debounce / 本地候选 / overlay / 接受 / docs 联动；
- docs：本地预览 + 异步库文档 + C-x d / M-d；
- 关闭 panel 只摘 panel，view / resource 保留；
- 不再使用 `▸/▾` 或目录 `/` 后缀来区分类型；
- face：`filetree-root` / `filetree-dir` / `filetree-open` / `filetree-file`；
- root 也可以 Enter 展开 / 折叠；
- 打开过的文件用 `filetree-open` face；
- C-h 显示 / 隐藏 dotfile；
- C-r 重扫；
- Racket 换行缩进使用旧 `racket-indent-for-newline`，非 Racket 文本只插普通换行。

还没有恢复的旧行为：


---

## 迁移期依赖

为了先验证操作面，当前有两处暂时复用旧 `edit-tui`：

- `editor/engine/` 是从 `edit-tui/core/engine` 复制过来的；
- `host/final.rkt` 暂时 require `edit-tui/render/core.rkt` 和 `edit-tui/config/theme/default.rkt`。

下一步会把 render 也搬进新树，并让 host 不再依赖旧 `edit-tui`。

---

## 下一步

1. completion 接 workspace / analysis，补全跨 buffer 候选。
2. docs 接 workspace 本地定义与 C-x o 焦点切换。
3. 文件系统变化自动刷新。
4. 固定尺寸 / hide-show 的剩余布局细节。
