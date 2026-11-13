# edit-tui

这是按“core 纯数据 → editor 操作面 + 扩展点 → plugins → host”模型重建的第一阶段。

目标不是复制旧 `edit-tui`，而是先立住 **操作面 / 裸 API / 扩展点 / 插件状态** 这四条边界，
继续把 workspace / analysis / 多进程等能力接进来。

---

## 当前实现范围

已经完成：

- `core/`：复用 repo 的纯 core（document / view / panel / rect / render 值）。
- `editor/engine/`：core buffer / view 的唯一可变拥有者；user / ui / derived 文档与 view 分开存储；按 read / user-write / ui-write / derived-write / lifecycle 拆分能力。
- `engine-doc-kind`：用户文档 `'user`、UI 投影文档 `'ui`、插件派生文档 `'derived` 分开；插件默认查询 `editor-user-doc-ids`，derived 用 `editor-derived-*`。
- 插件 sync / overlay / hook / timer / job / command 抛异常时由 runtime 捕获并 flash，不打断整帧。
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
- `plugins/completion/`：本地候选 / debounce / overlay 菜单 / 接受；候选包含 prefix 本身，但只有存在其他候选时才显示 popup；workspace 提供跨 buffer 的 analysis / require 导出，缺省时退回当前 buffer + open-text 解析。
- `plugins/docs/`：docs 面板 / 本地预览 / 异步库文档 / C-x d；本地定义优先查 workspace，面板隐藏时 M-d 与 docs sync 走统一开关，不提交解析 job。
- `editor/points.rkt`：插入点表（name / kind / phases / context），make-hook 校验 operation/phase。
- `editor/hooks.rkt`：typed hook 扩展点 + 有序 pipeline。
- `editor/contributions.rkt`：非 hook 扩展点的统一 registry（sync / overlay / timer / job-service / job-result）。
- `editor/plugin.rkt`：插件描述 + 字段聚合；`editor/plugin-runtime.rkt`：registry 执行器。
- `editor/plugin.rkt`：最小插件值（id / state / hooks / commands）。
- `plugins/pair/`：括号自动配对。
- `plugins/indent/`：Enter 换行按当前行前导空白对齐。
- `plugins/racket-color/`：Racket 基础语法着色（每帧 sync + version 缓存）。
- `plugins/layout/`：通过 `commands` 贡献 split / focus / close 键位。
- `plugins/filetree/`：sidebar 文件树、目录展开 / 折叠、隐藏文件切换、guarded Enter / C-r / C-h、C-f s 递归查找；生产路径异步扫描。
- `plugins/resources/`：resources 面板、buffer / view 行、dirty 标记、Enter 聚焦。
- `plugins/bilingual/`：源 user doc ↔ derived mirror；行级 token 双语映射；源变化投影镜像，镜像编辑反译回源；M-l 打开 / 聚焦 / 关闭 pair；镜像无 resource / history。
- 打开文件：resource 去重 + placement（方向键 / Enter / Esc / 鼠标）。
- C-s / C-q：save-path / save-confirm / quit-confirm 输入栏流程。
- `host/source.rkt`：把打开中的 editor resource 同步进 source-store；同一 path 上 buffer > disk；未打开/关闭文件由语言层按需读磁盘。
- `host/workspace.rkt`：消费 source-store 的权威 snapshot，派生语言 workspace；insert / delete / paste / kill-line / undo / redo 的 changes hook 都走 `workspace-apply-changes` 增量；新打开文件 / save-as / 没有 changes 的整篇写回在 async 模式下提交 `workspace-analysis` job，按 `(doc-id, version)` 校验安装。
- `editor/plugin.rkt` 的 `run-plugin-syncs`：按插件顺序执行每帧同步。
- `guarded-command`：插件命令不适用时自动回落到下一张表。
- `core/layout/` / `core/panel/` / `core/projection/` / `core/focus/`：纯布局 / panel / 投影 / 焦点。
- `edit.rkt`：可运行入口；装配在 `app/`，事件 / 渲染 / action 已拆开。
- 启动时只创建空 editor buffer，不自动创建默认 scratch resource。
- `test/`：hooks / ops / plugins / layout / mouse / commands / host 回归。

还没有：

- C-x o completion / docs 焦点切换
- 多进程
- filetree 文件系统自动刷新 / 拖拽

这一阶段先把编辑器最核心的“插入 / 删除”路径跑通，并证明：

> 插件只通过扩展点参与编辑，不直接摸 engine。

---

## 目录

```text
edit-tui/
  edit.rkt            可运行入口 / 终端生命周期
  app/
    bootstrap.rkt     engine / 初始文档 / 初始布局 / 插件装配
    layout.rkt        具体 panel kind 的初始布局
    actions.rkt       action 解释
    frame.rkt         status / 插件 sync / overlay / render
    event.rkt         tui event -> state / 主循环
  core/
    api.rkt            纯值 / 纯算法面（当前复用 repo core）
    command/           key token + command table（纯）
    layout/            split tree / solve / 结构操作 / config
    panel/             layout panel 资源
    projection/        layout -> core panel / 命中
    focus/             方向焦点导航
    face/              face / style 纯值 + 分层合成

  lang/
    README.md          多语言能力层说明
    racket/            Racket 词法 / 着色 / 补全 / 文档 / 缩进
    source/            解析来源快照 / 缓冲区与磁盘优先级

  config/
    layout/default.rkt 各 kind 的默认布局规则
    theme/default.rkt  默认主题数据（纯，不安装）

  editor/
    engine/
      store.rkt        engine 内部实现：user/ui/derived doc + view + cache + derived-meta
      read.rkt         只读能力：document / view / point / face
      user-write.rkt   用户文档写能力：view-action 解释（kind-aware）
      ui-write.rkt     UI 内容写 + 通用 face / cursor
      derived-write.rkt derived 内容投影写 + CAS
      lifecycle.rkt    engine / buffer / view / derived buffer 创建与删除
      projection-write.rkt UI / derived 共享投影内核
      apply.rkt        view-action 内部解释器
      api.rkt          宿主用的全量兼容聚合面
    ops/raw.rkt        裸操作：不触发 hook；含程序化区间替换
    ops/surface.rkt    编辑操作面：validate -> transform -> raw -> derive -> observe；replace-lines 只写 user doc
    derived.rkt        derived view 投影写 / 查询
    layout.rkt         通用布局操作面：split / close / focus + layout hooks
    resource.rkt       已打开文档：path / view / mode / command-stack / saved-version
    mode.rkt           .rkt / #lang racket -> racket，否则 text

    job.rkt            job-result-event / job 账本 State
    timer.rkt          timer-event / schedule / cancel / editor timer runtime
    overlay.rkt        插件浮层描述
    points.rkt         插入点表 / kind / phase / context 校验
    hooks.rkt          typed hook 扩展点 / 有序 pipeline
    contributions.rkt  非 hook contribution registry
    plugin.rkt         插件描述 / 字段 -> contribution
    plugin-runtime.rkt contribution registry 执行器 + command registry -> table
    state.rkt          纯值：editor-core + editor-session + app-state；state-* helper
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
    bilingual/model.rkt
    bilingual/translate.rkt
    bilingual/action.rkt
    bilingual/api.rkt
    bilingual/plugin.rkt
    completion/plugin.rkt
    docs/api.rkt
    docs/plugin.rkt

  features/
    input/             单行输入栏
    placement/         打开文件后的目标 editor 选择
    mouse/             鼠标 press/move/release、拖选、seam drag
    sidebar/           sidebar tab 切换 / 显隐
    find/              当前 buffer 查找 / 前后匹配项

  host/
    docs.rkt           completion -> docs 的跨插件 action 解释
    bilingual.rkt      双语 pair：derived mirror 创建 / bind / 清理 / 源行替换
    derived-buffer.rkt 动态 derived doc + view 生命周期
    layout.rkt         host 侧 detach / attach-as-tab
    event.rkt          tui raw -> host 事件
    render/core.rkt    core piece -> tui bytes
    render/theme.rkt   style -> tui 样式安装
    keymap.rkt         命令值 + 分 scope 的 host 内置表
    input/scope.rkt    focus / key-owner -> command scope
    input/dispatch.rkt pending 多键序列 + 命令查找 / 执行
    open.rkt / close.rkt / prompt.rkt   文件打开 / 关闭 / save quit IO
    filetree-io.rkt    filetree 创建 / 删除 / 重命名 / 查找 IO
    jobs.rkt           worker runtime
    timers.rkt         timer runtime
    source.rkt         buffer / disk 来源权威索引同步
    workspace.rkt      权威 snapshot -> 语言 workspace 同步

  test/
    hooks.rkt
    ops.rkt
    plugins.rkt
    ownership.rkt      插件状态 owner 写回
    state-split.rkt    core / session 更新互不污染
    resource-path.rkt  workspace root 内相对 / root 外绝对
    ui-incremental.rkt UI view face-only / 文本最小 diff
    panel-resize.rkt   fixed seam 拖动 / hide-show min clamp
    filetree-io.rkt    C-f 创建 / 删除文件、目录
    find.rkt           find 命令 / 前后移动
    buffer-keymap.rkt  键表跟随 resource / active view
    workspace.rkt      跨 buffer completion / docs
    workspace-async.rkt 全量 workspace analysis 异步
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

host 按当前 focus / key-owner 得到有序 scope，例如：

```text
editor:     (completion?) mode? editor resource-stack global
filetree:   filetree global
resources:  resources global
```

editor 的 `resource-stack` 存在 resource 上；同一个 panel 换 active view 时，
键表跟着对应的 core buffer / resource 走。每个 scope 先查插件 contribution，
再查该 scope 的 host 内置表；unbound 才落到下一个 scope。leaf 保存 ordered
`(owner . command)`，执行后按 owner 写回 `ps'`。

同一 key 有多条命令时，guard 不成立会继续试下一条 / 下一张表。
前缀只有在“至少一个后续命令当前可执行”时才遮蔽后面的表；否则继续回落，
避免所有 guard 都失败的前缀永久挡住 host 的同键命令。
`plugins/layout` 贡献全局 `C-w` / `C-x` / `C-d`（`C-w d` close panel）；filetree / resources 命令放在
自己的局部 scope。completion 打开时通过 `#:key-owner` 把 completion scope 叠在
focus scope 上面。

插件用 `#:view-scopes` 声明 `view-id -> scope`；`app/bootstrap.rkt` 聚合为
`editor-core.view-scopes`，`host/input/scope.rkt` 只读 state，不再硬编码具体
view id。

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
不导出 `state-set-plugin-state`，也不导出 resource 变更函数。
跨插件请求走 action（例如 completion 发 `show-docs-action`，docs owner 更新自己）。

插件初始状态来自：

```racket
(make-plugin #:id 'pair #:state #t #:hooks ...)
```

---

## 运行

```sh
racket edit-tui/edit.rkt
```

键：

```text
直接打字       插入
Enter          换行 + 当前行对齐
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
C-w d          关闭当前 editor panel
C-d            同上（兼容）
               最后一个 editor 只清空 views，保留 panel slot
C-s            保存 / save-as / 确认
C-q            退出（dirty -> 确认 / save-as）
C-o            手动打开补全
Up / Down      移动候选
Tab            下一个候选
Enter          接受候选（菜单关闭时仍是普通换行）
Esc / C-g      关闭补全
M-d            查看光标处标识符文档
M-l            双语：打开 / 聚焦 / 关闭当前 buffer 的 mirror
C-x d          显 / 隐 docs panel
C-b            显 / 隐 sidebar
C-x b          切换 sidebar tab（filetree / resources）
C-x n / C-x p  下一个 / 上一个 editor tab
C-x k          关闭当前 buffer（dirty -> 确认）
C-x f          查找当前 buffer
C-left         上一个匹配项（filetree 查找也适用）
C-right        下一个匹配项（filetree 查找也适用）
C-x ←          聚焦 sidebar
Enter          文件树：打开文件；编辑器：换行
C-r            文件树刷新（不重跑上次查找）
C-h            文件树：显 / 隐 dotfile
C-f s          文件树：一次性递归查找；展开匹配路径并在树中定位
               C-left / C-right 在匹配项间移动；Esc 只清除查找会话
C-f n          文件树：新建文件
C-f C-f n      文件树：新建目录
C-f r          文件树：重命名
C-f d          文件树：删除文件 / 目录
C-f l          文件树：显式刷新（C-r 兼容保留）
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
bash edit-tui/test/run.sh
```

单独跑：

```sh
racket edit-tui/test/engine-kinds.rkt
racket edit-tui/test/replace-lines.rkt
racket edit-tui/test/bilingual.rkt
racket edit-tui/test/hooks.rkt
racket edit-tui/test/ops.rkt
racket edit-tui/test/plugins.rkt
racket edit-tui/test/layout.rkt
racket edit-tui/test/mouse.rkt
racket edit-tui/test/commands.rkt
racket edit-tui/test/filetree.rkt
racket edit-tui/test/filetree-expand.rkt
racket edit-tui/test/placement.rkt
racket edit-tui/test/resources-panel.rkt
racket edit-tui/test/save-quit.rkt
racket edit-tui/test/tabs.rkt
racket edit-tui/test/color-incremental.rkt
racket edit-tui/test/job-async.rkt
racket edit-tui/test/color-word.rkt
racket edit-tui/test/timer.rkt
racket edit-tui/test/completion-docs.rkt
racket edit-tui/test/workspace.rkt
racket edit-tui/test/workspace-async.rkt
racket edit-tui/test/sidebar.rkt
racket edit-tui/test/host.rkt
racket edit-tui/test/host-event.rkt
racket edit-tui/test/ownership.rkt
racket edit-tui/test/state-split.rkt
racket edit-tui/test/resource-path.rkt
racket edit-tui/test/ui-incremental.rkt
racket edit-tui/test/panel-resize.rkt
racket edit-tui/test/filetree-io.rkt
racket edit-tui/test/buffer-keymap.rkt
racket edit-tui/test/find.rkt
racket edit-tui/test/layers.rkt
```

---

## 设计规则

1. `core/` 不放 hook、不放插件、不放 IO。
1b. `editor/layout.rkt` 只做通用布局操作；具体 editor/status/sidebar/docs 装配在 `app/layout.rkt`。
1c. 插件 API 不导出 host 编排函数；host-api 才导出 plugin runner / open / prompt。
2. 只有 `editor/ops/raw.rkt` 能写 engine。
3. 所有用户可见编辑走 `editor/ops/surface.rkt`。
4. 插件只 require `editor/api.rkt` + feature 的 `api.rkt` + `core/command` 的纯键表构造器 + `core/face/api.rkt` + `lang/racket/api.rkt`。不 require editor 内部 / host / repo core 实现。
5. 插件状态是纯值，按 plugin id 命名空间存在 editor-core；只有 plugin runtime 按 owner 写回。
5b. engine 的 document 分 `'user` / `'ui` / `'derived`；用户文档流程只看 user doc，derived 由 owner 插件投影 / 协调。
     user doc 有 history/resource；ui 是 host 投影；derived 是 plugin-owned、无 resource / 无 history 的派生文本。
5c. 插件回调异常不允许打断事件循环：runtime 捕获、flash，并保留该插件旧状态。
5d. 插件命令在 command-table 里是显式 `plugin-command`；host 遗留 raw procedure 只属于 input / placement。
5e. view-id -> command scope 由插件 `#:view-scopes` 声明，随 editor-core 保存。
5f. app-state = editor-core + editor-session；editor 操作只改 core，host 会话只改 session。
5g. prefix 查找要 guard-aware：没有可执行后继时不遮蔽后面的表。
5h. Session 分正交轴：modal = input/placement；pointer = drag/select-drag；
    轴内互斥，轴间独立（find / pending / jobs 可同时存在）。
    input-state 是持久 seed：modal 退出后保留，下一次 open 复用。
5i. Engine 按能力分模块：read / user-write / ui-write / derived-write / lifecycle；
    raw 只用 user-write，surface 只用 read，投影内核只由 ui-write / derived-write 使用，
    layout / host open / close 只用 read + lifecycle。
5j. Engine 分开存储 user-docs / ui-docs / derived-docs 与对应 views；
    derived 带 owner / source-doc-id / edit-policy；split view 跟随 source view 的 kind；
    不为插件增加运行时权限守卫。
5k. source-store 是 host 维护的打开 buffer override 索引：同一 path 上 buffer > disk；
    未打开/关闭文件按需读磁盘，不缓存 disk snapshot；不进 State，也不暴露给插件。
5l. workspace 是 host 维护的语言分析纯值缓存：不进 State、不属于 engine；
    它消费 source-store 的权威 snapshot，插件只读 `editor-workspace`。
    所有用户文本变更（insert / delete / paste / kill-line / undo / redo）
    都走 changes hook + workspace-apply-changes；
    新打开文件 / save-as / 没有 changes 的整篇写回在 async 模式下走
    workspace-analysis job。
6. hook 不放进 state，hook 属于 editor 实例的不可变 registry。
7. layout / render 保持纯；它们以后接 provider，而不是任意 hook。
8. 异步 / 多进程只通过 job request/result + 版本校验，不跨进程传 lambda。

---

## 与旧实现的差异

已经恢复的旧行为：

- filetree 行文本：根显示绝对路径，子项只显示名字；**2 空格缩进**区分层次；
- status bar / resources 的路径：workspace root 内显示相对路径，root 外显示绝对路径；
- 打开文件去重 / 已打开 panel 聚焦 / detached 进 placement；
- placement：方向键换目标、Enter 放入、Esc 取消、鼠标点 editor 放入；
- pair / indent 按 buffer mode 生效（.rkt / #lang racket）；
- resources 面板（buffer / view 行、dirty、Enter 聚焦；workspace root 内显示相对路径）；
- C-s / C-q 的 save-path / save-confirm / quit-confirm 输入栏；
- 鼠标文本拖选（press 落 caret，move 扩展，release 结束）；
- UI view 增量：selection 只改 face 行；文本变化做最小区间替换；
- sidebar fixed 边界可拖；C-b hide/show 恢复尺寸并 clamp 到 min（sidebar min-w 8）；
- filetree C-f n / C-f C-f n / C-f d / C-f r：输入名字 / 确认删除 / 重命名，host 执行文件 IO；
- filetree C-f s：一次性递归查找；不覆盖文件树，而是展开匹配路径的祖先目录并把光标移到对应行；
- filetree C-left / C-right：在本次查找的匹配项间移动并展开定位；之后的展开 / 折叠 / 刷新不会被查找重跑覆盖；
- filetree C-f l 显式刷新；C-r 兼容保留；
- resource 持有自己的 command-stack：同一 panel 切 active view 会切换键表；
- find：C-x f 输入 query，C-left / C-right 前后移动并选中当前匹配；
- editor tab 切换 / close buffer；
- color 增量：`'changes` + `color-edit*` 只重扫脏行；所有用户文本操作（含 undo / redo）都产生 changes，只有首次打开 / 外部整篇写回走 sync 全量；
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
- bilingual：源 user doc ↔ derived mirror，行级双向映射；镜像无 resource / history，源为权威；
- completion：debounce / 本地候选 / overlay / 接受 / docs 联动；
- docs：本地预览 + 异步库文档 + C-x d / M-d；
- 关闭 panel 只摘 panel，view / resource 保留；
- 不再使用 `▸/▾` 或目录 `/` 后缀来区分类型；
- face：`filetree-root` / `filetree-dir` / `filetree-open` / `filetree-file`；
- root 也可以 Enter 展开 / 折叠；
- 打开过的文件用 `filetree-open` face；
- C-h 显示 / 隐藏 dotfile；
- C-r 重扫；
- Racket Enter 只复制当前行前导空白，不做语法级额外缩进；非 Racket 文本只插普通换行。

还没有恢复的旧行为：


---

## 语言 / 渲染 / 主题层

`compat/` 已删除，支撑模块按职责进入新树：

- `lang/racket/`：Racket 词法 / 着色 / 补全 / 文档 / 缩进；
- `lang/source/`：解析来源快照；
- `core/face/`：face / style 纯值；
- `host/render/core.rkt`：`core piece -> tui bytes`；
- `host/render/theme.rkt`：`style -> tui` 样式安装；
- `config/theme/default.rkt`：默认主题数据（纯）。

宿主入口 `edit.rkt` 只 require `host/render/theme.rkt` 与 `config/theme/default.rkt`，
并显式调用 `install-theme!`。

---

## 下一步

1. filetree 拖拽 / 文件系统自动刷新。
2. C-x o completion / docs 焦点切换。
3. bilingual side-by-side split / 多翻译表 / 结构化数据源。
