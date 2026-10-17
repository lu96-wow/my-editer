# edit-tui-rebuild

重建中的编辑器骨架。

- **现在的分层 / 副作用白名单 / 扩展点**：[`ARCHITECTURE.md`](ARCHITECTURE.md)
- **插件怎么写（高亮 / 补全 / 文档 三个例子 + 与上一代的取舍）**：[`PLUGINS.md`](PLUGINS.md)
- **约定 / 不变量**（信号点、什么算编辑、所有显示都是 document、浮层规则）：
  [`ARCHITECTURE.md` §8](ARCHITECTURE.md)
- 为什么这样设计（旧实现的审计与目标模型）：[`DESIGN.md`](DESIGN.md)

所有分层规则由 `test/layers.rkt` 机器检查。

## 进度

| 块 | 内容 | 状态 |
|---|---|---|
| 1 | `base/` 词汇 + `model/` 状态切片 + 纯测试 | ✅ |
| 2 | `env/` 注册表（role / mode / scope / command） | ✅ |
| 3 | `dispatch/` 规则管线 + 键盘/鼠标统一 | ✅ |
| 4 | `effects/` engine 适配 + 文件 IO（spawn/timer 留给 runtime） | ✅ |
| 5 | `projection/` geometry / render / status | ✅ |
| 6 | `bootstrap/` + runtime | ✅ |

## 目录

```
base/          纯词汇（0 依赖）
  id.rkt          带 kind 的稳定 id + 纯分配器
  event.rkt       应用事件 ADT（不依赖 tui）
  effect.rkt      效果 ADT（引擎写 / IO / 调度）
  transition.rkt  State + 有序 effects + 组合子
  keymap.rkt      通用 token -> 值 的前缀表
  status-part.rkt 状态栏段（render 由使用方提供）
  signal.rkt      信号（point + args）与 FIFO 队列
model/         纯状态（只依赖 base）
  state.rkt       根 State：window / workspace / input / chrome / runtime / ids / confirm / store
  workspace.rkt   doc / view / region / layout / focus / overlay / root / placement
  layout.rkt      region 布局树（纯几何）
  input.rkt       pending / modes / gesture
  chrome.rkt      message / log
  workspace.rkt   里含 float（浮层 = 不在 layout 里的 region：id / region / view / anchor）
  save.rkt        保存确认队列（框架级）
env/           纯策略（只依赖 base + model）
  environment.rkt role/mode/scope/command/keymap/handler/rules/status/doc-type/input-command/panel-sync
  role.rkt        区域角色 -> splittable? / close-policy / focusable? / target?
  mode.rkt        document 模式 -> keymaps / fallback
  scope.rkt       scope 谓词
  command.rkt     命令值（复用旧 command 结构）
  rule.rkt        scope + keymap 的规则
  doc-type.rkt    路径 -> mode + per-document keymaps
  input-command.rkt 输入栏字符串匹配
  hook.rkt        钩子（point / when / priority / proc）
  plugin.rkt      插件描述符（plugin / panel-spec）+ 纯装配（plugins-env / plugins-apply）
  defaults.rkt    内置 role / mode
effects/       边界（core 只在这里被拥有）
  engine.rkt      core buffer/view 的唯一可变拥有者
  panel.rkt       面板↔引擎适配：create-view / region-install / install / uninstall / sync-buffer
  interpreter.rkt effect -> transition（文件 IO / 文档开关 / 保存 / 退出）
projection/    纯投影
  geometry.rkt    layout -> region-panel / cut / window-area / region-neighbor
  status.rkt      状态栏文本投影 + 默认段
  render.rkt      state + engine -> panels / chrome / bytes
dispatch/      纯派发
  context.rkt     命令看到的 ctx
  rules.rkt       规则层序（input modes > per-doc > env.rules > mode > global）
  hooks.rkt       排空信号 -> 跑 hook（纯）
  pipeline.rkt    event -> transition
chrome/        框架 chrome
  slot.rkt        安装 status/input 槽（两个 core view）
  input.rkt       输入栏 API（input-show / input-finish / input-cancel …）
bootstrap/     装配
  panel.rkt       panel-spec -> panel-install!（唯一缝）
  commands/
    util.rkt        message / notice / real-view? / fallback-attached-view
    edit.rkt        导航 / 插入 / 删除 / undo / redo / quit
    view.rkt        split / close-view / new-document / detach / attach / cycle
    region.rkt      close-region（按 role 的 close-policy）
    focus.rkt       focus 方向移动 + 鼠标落点/拖选
    document.rkt    open / save / save-as / 保存确认 / 关闭 / 退出
    placement.rkt   把 detached view 放进 panel
    table.rkt       框架命令表
  defaults.rkt    core-env（只有框架）
plugins/       内置插件（每个一个目录）
  builtin.rkt     default-plugins / default-env / editor-plugins / editor-env
  filetree/
    model.rkt       store['filetree]（view / expanded / width）
    scan.rkt        读目录（唯一 IO）
    lines.rkt       纯投影：条��� -> 行
    panel.rkt       写 *filetree* buffer
    commands.rkt    Enter / C-b / C-n f / C-d …
    plugin.rkt      panel-spec + mode + commands + 规则 + install
  highlight/
    lex.rkt         纯词法：文本 -> 每行 face 区间
    plugin.rkt      syntax 高亮插件（只对 .rkt / mode 'racket 生效）
  completion/
    plugin.rkt      C-c / 原地补全（replace-range 会话）
  docs/
    plugin.rkt      C-c h 文档面板（底部固定高度；after-nav 只刷新不关闭）
  resource/
    model.rkt       store['resources]（collapsed / view）
    lines.rkt       纯投影：doc/view -> 行
    panel.rkt       写 *resources* buffer
    commands.rkt    tab / v / n / r / d / c
    plugin.rkt      panel-spec + mode + commands + install
runtime/       壳
  tui-adapter.rkt 终端事件 -> base/event
  run.rkt         run-app：事件循环 / effect 解释 / 渲染 / inbox
demo/           可交互 demo
main.rkt        公共面
```

核心约定：

- State 只存 **id + 元数据**，不存 core 的 buffer / view 句柄；
- 命令返回 `(transition state effects)`，效果按顺序解释；
- 切焦点不自动清 pending；输入状态独立；
- 区域几何在 layout leaf，成员/active 在 region，避免两处真相；
- role/mode/scope/command/plugin 都在 Environment 值里，注册是 `environment-add-*`，不是模块级 `set!`；
- 命令 id 作为 keymap 叶子，dispatch 再用 env 查命令实现；
- 层序：input modes > per-doc > env.rules > mode > global（`dispatch/rules.rkt`）；
- 状态栏是 `status-part` 列表：`default-status-parts` 只有 focus 行列 + path，
  `full-status-parts` 再加 pending/message；
  - path 在 `workspace.root` 下时显示**相对路径**，否则绝对路径；
- 打开文件时按路径匹配 `env.doc-types`，把 mode + keymaps 写进 `doc-meta.keymap-layers`；
- 输入栏是 *input* document：prompt 前缀写进 buffer 且 readonly，提交时读完整字符串，
  交给 `environment.input-commands` 匹配；
- `focus` 是 `view-id | region-id | #f`：有文档时是 view，空窗口（刚拆出来 / 关光 view 的 panel）
  时是 region-id，什么都没有时是 #f；状态栏对后两种退回“第一个 editor view”投影位置；
- `internal?` 文档（状态栏 / 输入栏 / 插件面板）不参与保存确认、不进资源列表、不能当 placement 目标；
- 文档版本用 core 的 opaque token：`buffer-version` / `buffer-version=?`；
- 渲染分工：Runtime 先 `engine-sync-views!` 落 viewport，再 `render-frame` 得到 bytes，最后自己 `put-bytes`；
- `spawn` / `timer` 的回投事件在“下一个终端事件”到达时排空。

## 测试

```
racket edit-tui-rebuild/test/base-model.rkt
racket edit-tui-rebuild/test/env.rkt
racket edit-tui-rebuild/test/dispatch.rkt
racket edit-tui-rebuild/test/effects.rkt
racket edit-tui-rebuild/test/projection.rkt
racket edit-tui-rebuild/test/runtime.rkt
racket edit-tui-rebuild/test/save.rkt
racket edit-tui-rebuild/test/views.rkt
racket edit-tui-rebuild/test/resource-panel.rkt
racket edit-tui-rebuild/test/filetree.rkt
racket edit-tui-rebuild/test/seam.rkt
racket edit-tui-rebuild/test/panel.rkt
racket edit-tui-rebuild/test/plugin.rkt
racket edit-tui-rebuild/test/plugin-detach.rkt
racket edit-tui-rebuild/test/layers.rkt
racket edit-tui-rebuild/test/sidebar.rkt
racket edit-tui-rebuild/test/split.rkt
racket edit-tui-rebuild/test/hooks.rkt
racket edit-tui-rebuild/test/plugins.rkt
racket edit-tui-rebuild/test/float.rkt
edit-tui-rebuild/test/run.sh
```


## 通用输入栏 API

```racket
(require "edit-tui-rebuild/chrome/input.rkt")
```

| API | 作用 |
|---|---|
| `input-show ctx prompt` | 切到 input 栏，写只读 prompt 前缀（ctx 含 env/state/engine） |
| `input-active? state` | 当前是否在 input 栏 |
| `input-read-text state ev` | 完整 buffer 字符串（prompt + 输入） |
| `input-value state ev` | 只取用户输入（自动跳过只读前缀） |
| `input-cancel ctx` | 找当前 input owner 的 cancel，清外部状态后结束 |
| `input-finish state` | 切回 status，恢复进入前焦点 |
| `input-write-prompt state prompt` | 只改 prompt（不切焦点） |
| `input-show-state state prompt` | 低层显示（用于已经 finish 旧 input 的内部流程） |

提交匹配：

```racket
(environment-add-input-command
 env
 (make-input-command
  'my-input
  (input-command-prefix "My prompt: ")
  (λ (ctx value) ...)
  #:cancel (λ (state) state)))   ; 被新 input 替换时清理外部状态
```

输入是 document，没有额外的 prompt 状态机。

**占用规则：新的 input 替换旧的 input。**  
如果当前已经在 input 栏，再调用 `input-show`：

- 用当前 buffer 字符串匹配 `input-command`；
- 调它的 `#:cancel` 清理外部 pending 状态（例如 save-confirm 的 `resources.confirm`）；
- 结束旧 input；
- 写入新 prompt，重新聚焦 input；
- 焦点栈保持平衡（旧 input 先 pop，新 input 再 push）。

低层 `chrome-input-show` 不做替换清理；其他逻辑应调用 `chrome/input.rkt` 的 `input-show`。

## 公共面

```racket
(require "edit-tui-rebuild/main.rkt")
```

聚合了 base / model / env / dispatch / effects / projection / bootstrap / runtime 的公共导出。
需要键/鼠标 token 时再 require `edit-tui/command/key.rkt` / `mouse.rkt`。

## 交互 demo

```bash
racket edit-tui-rebuild/demo/basic.rkt
racket edit-tui-rebuild/demo/state.rkt   # 底部一行直接显示底层 State
racket edit-tui-rebuild/demo/save.rkt    # status/input 共享槽 + 保存确认
racket edit-tui-rebuild/demo/resource.rkt # 资源列表面板 + placement
racket edit-tui-rebuild/demo/filetree.rkt [root] # 文件树面板
racket edit-tui-rebuild/demo/plugin.rkt   # 最小插件（命令 + 键 + store + 状态栏段）
racket edit-tui-rebuild/demo/sidebar.rkt  # 文件树 + 资源列表共用一个面板位置（Tab 切换）
racket edit-tui-rebuild/demo/lab.rkt      # 语法高亮 + C-c / 补全弹窗 + C-c h 文档面板
```

`state.rkt` 的底栏内容：

```
state focus=view:1 pos=1:2 docs=1 views=1 regions=3 pending=- msg=ready
```

操作时可以直接观察 focus / 光标 / docs / views / regions / pending / message 的变化。

默认键位：

| 键 | 作用 |
|---|---|
| `←→↑↓` / `Home` / `End` | 移动 |
| `Enter` / `Backspace` / `Delete` | 编辑 |
| `C-z` / `C-y` | undo / redo |
| `C-b` | 显示 / 隐藏文件树面板 |
| `C-w ←→↑↓` | 左 / 右 / 上 / 下拆出一个**空窗口**（焦点移到空窗口，之后 `C-n` / 打开文件装进去） |
| `C-w C-w` | 关闭当前 view |
| `M-w` | 关闭当前 region / panel（按 role 的 close-policy） |
| `C-n` | 新建 document/view（空 editor region 也能接） |
| `C-x C-f` | 打开文件（input document 输入路径） |
| `C-x C-s` | 保存当前 document；无 path 时进入 `Save as:` 输入 |
| `C-x C-k` | 关闭当前 document 的所有 view + document |
| `C-x C-d` | 把当前 view 从 panel 摘出来（保留 view / engine view / document） |
| `C-x C-a` | 把第一个 detached view 挂回当前 region（buffer-list 前的临时入口） |
| `Tab` / `C-x C-o` | 在同一 region 的多个成员之间切换 active / focus（共用面板位置） |
| `C-x C-p` | 提交 resource placement 到当前/点击的 panel |
| `C-g` / `Esc` | 取消当前 input |
| `C-x C-g` | 取消 placement |
| `M-方向` | region 间焦点移动 |
| 左键点击 | 聚焦 view 并把光标落到点击位置 |
| 左键拖动 | 从按下位置开始拖选 |
| `C-c /` | 补全弹窗：光标前的词 -> 候选浮层；`↑↓` 选，`Enter`/`Tab` 接受，`Esc` 取消（`editor-env`） |
| `C-c h` | 文档面板开关：status 下方固定 8 行，打开时会把焦点 view 夹回窗口，**手动关闭**（`editor-env`） |
| `C-q` | 退出；有 dirty document 时进入保存确认 |
| `y` / `n` / `yall` / `nall` + Enter | 保存确认：当前保存 / 跳过 / 保存剩余 / 跳过剩余 |

## 切分 = 拆出一个空窗口

`C-w ←→↑↓` **不复制 document**，也不给同一 document 再加 view，而是：

```
源 region（成员 / active / 焦点内容都不动）
   ├── 原 region        members = (view ...)   保持原样
   └── 新 region        members = '()          空窗口，role / 边框跟随源 region
```

- 焦点移到新 region（`focus = region-id`）——所以 `C-n` / `C-x C-f` / 文件树 Enter
  会直接装进这个空窗口（`target-region-for-new-view*` 认 region-id）；
- 空窗口也能再拆（`C-w →` 在空窗口上继续拆）；
- 焦点可以在「有文档的 view」和「空 region」之间用 `M-方向` 来回移动；
- 空窗口按 region-id 视为可聚焦（鼠标点它 / `M-方向` 落上去），渲染成带**聚焦边框**的空面板；
- role 不可切分（`'filetree` / `'resource` 这类面板）时拒绝：`split: region not splittable`。

同一 region 里放多个 view 的能力仍然在（`C-n` 会把新 view 挂进当前 region，
placement 也会把 detached view 放进去），用 `Tab` / `C-x C-o` 切换。

`test/split.rkt` 守着这些约定。

## 边界决定：最后一个 editor region

采用 **保留空 region，只清 view**：

- `C-w C-w` close-view：移除当前 view；region 留在布局里；
- `M-w` close-region + role `'editor keep-last`：
  - 同 role 还有别的 region → 删除当前 region；
  - 已经是最后一个 editor region → 关闭其中所有 view，但**保留空 region 占位**。

原因：

1. 不引入“空布局 / 没有任何 panel”的特殊状态；
2. split / open 始终有一个 editor region 可以当锚点；
3. 与 role 的 `keep-last` 语义一致，不需要在 split 时额外补 panel。

代价：最后一个 view 关掉后 `focus = #f`，region 是空占位；`C-n` 会优先找空 editor region 装新 document/view，所以空占位不是死状态。


## view 资源生命周期

区分四件事：

| 操作 | 结果 |
|---|---|
| `C-w C-w` close view | 销毁 view（engine view + view-meta）；document 保留 |
| `C-x C-d` detach view | 从 region 成员表移除；view / engine view / document 全部保留 |
| `M-w` close region/panel | 把 region 内 view 全部 detach，再删除/保留 region；**不销毁 view** |
| `C-x C-k` close document | 销毁该 document 的所有 view + document |

- `workspace.views` 是 view 资源表；detached view 仍在这里；
- `workspace-detached-views` 可列出没有挂到 region 的 view；
- `workspace-attach-view` 强制 view 单成员：挂到目标 region 前先从旧 region 移除；
- 关闭 panel 现在不会销毁 view，所以之后可以从资源列表重新挂回；
- 目前还没有正式 buffer-list 面板，`C-x C-a` 只是“挂回第一个 detached view”的临时入口。

## 状态面板移动

以下 mode 都绑了 `nav-keys` + `pointer-keys`：

- `status`
- `state`
- `input`
- `resources`

状态栏/输入栏的共享槽 role `'slot` 现在是 focusable，所以：

- 鼠标点击状态栏会聚焦并落点；
- 方向键 / Home / End 可在状态栏里移动；
- 焦点在 chrome 上时，状态栏位置/路径仍报告第一个 editor view，避免自指。

## 保存确认 / status+input 共享槽

`demo/save.rkt` 演示：

- status 与 input 都是真正的 core view（buffer 支撑），放在同一个 region；
- 平时 active = status；prompt/保存确认时 active = input；
- 输入结束切回 status，并恢复进入前的焦点；
- `C-q` / `C-x C-k` 遇到 dirty document 时触发全局保存确认：
  - `y` 保存当前；
  - `n` 跳过当前；
  - `yall` 保存剩余全部；
  - `nall` 跳过剩余全部；
  - 非法答案 / 保存失败会重新显示当前确认 prompt；
  - 无 path 的 doc：`y` 进入 `Save as:` 输入；`yall` 会停在该 doc 提示先用 `y` Save as。
  - 输入在 input buffer 里，Enter 提交。
- status/input 的 buffer 文档 mode 是 `'status` / `'input`（state demo 可用 `'state`），
  不参与保存确认。

实现位置：

- `model/save.rkt`：`save-confirm` 队列 / 当前 index / 完成后 action（`state.confirm`）；
- `chrome/slot.rkt`：安装共享槽、input show/finish、status buffer 同步；
- `bootstrap/commands/document.rkt`：`request-quit` / `request-close-file` / input-submit / save-confirm 流程；
- `bootstrap/commands/document.rkt`：`default-input-commands`；`bootstrap/defaults.rkt`：`input-keys`。


## 面板装配原语（`effects/panel.rkt`）

一个 buffer 支撑的面板在四处留痕：

| 位置 | 内容 | 谁负责 |
|---|---|---|
| `engine` | document + view（唯一可变边界） | `panel-create-view!` |
| `workspace` | `doc-meta` / `view-meta` / `region` | `panel-create-view!` + `panel-region-install!` |
| `layout` | 引用 `region-id` 的叶子 | 调用方（装配顺序 / 尺寸是策略） |
| 插件切片 | 自己的 view-id / 展开集合 / 宽度 … | 插件自己（`state.store['resources]` / `store['filetree]`） |

```racket
;; 建 doc + view（不建 region）
(define-values (state' vid) (panel-create-view! engine state #:name "*x*" #:mode 'x))
;; 建 region（role 决定 splittable? / close-policy / focusable?）
(panel-region-install! state' rid #:role 'tool #:members (list (view-member vid)) #:active vid)
;; 单 view 面板 = 上面两个
(define-values (state'' vid) (panel-install! engine state rid #:name … #:mode … #:role …))
;; 卸载：engine 对象 + workspace view/doc + region + layout 叶子（可重复调用）
(panel-uninstall! engine state'' rid)
;; 每帧同步：文本变了才重写 buffer，face 每帧重写，光标夹在文本内
(panel-sync-buffer! engine state vid #:texts texts #:faces faces)
```

`panel-uninstall!` 是 `panel-install!` 的严格反操作：`test/panel.rkt` 断言 docs /
views / regions / layout / engine 全部回到安装前（这也是“面板可拆”的基线）。

### 每帧同步注册表

`run-frame` 不再认识具体面板，只遍历 `environment.panel-syncs`：

```racket
(struct environment (… panel-syncs))   ; (listof (state engine -> any))
(environment-add-panel-sync env f)     ; 追加（执行顺序 = 注册顺序）
```

默认 env 注册了 `sync-resource-panel!` 与 `sync-filetree-panel!`；面板没安装时它们
`view = #f`，直接 no-op。所以“拔掉一个面板”在 runtime 层是零成本。

### 可拆现状（暂定）

已经解耦（逐项落地）：

| 原来 | 现在 |
|---|---|
| 面板装配代码各写一份 | `effects/panel.rkt`（install / uninstall / sync-buffer） |
| `run-frame` 里三行硬调 sync | `environment.panel-syncs`（`panel-spec` 自动挂上） |
| `state.resources.confirm`（框架级） | `state.confirm`（`model/save.rkt`） |
| `state.resources.collapsed` / `.view` | `state.store['resources]` |
| `state.resources.pending`（跨面板） | `workspace.placement`（文件树也发起它） |
| `state.filetree` 整个切片 | `state.store['filetree]` |
| `state.filetree.root` | `workspace.root`（状态栏按它投影相对路径） |
| 3 处 `'(status state input resources filetree)` | `doc-meta.internal?`（创建方声明）+ `role.target?` |
| `default-command-table` 末尾 fold 插件表 | 插件自己贡献 `#:commands` |
| `default-env` 里塞插件 mode / 键 / input-commands | `core-env` + `plugins-env` + 内置插件 |

于是根 State 只剩框架切片：

```racket
(struct state (window workspace input chrome runtime ids confirm store))
```

`test/plugin-detach.rkt` 守着这条线：`core-env` 里没有任何插件痕迹，只用它也能
编辑 / 切分 / 关闭 / 保存确认 / 退出。

仍写死（暂定）：

| 位置 | 内容 | 备注 |
|---|---|---|
| `plugin.rkt` | 没有 `plugin-disable` / `reload` | `environment` 是无来源的纯值，反查需要记 provenance |
| `effects/interpreter.rkt` | effect 解释是封闭 `cond` | 插件只能用内置 effect + `emit-effect` |
| `panel-spec` | 只有 sync，没有 install | 安装需要 region-id + 布局位置，由宿主决定 |

## 插件（`env/plugin.rkt`）

插件是一份**数据**，不是 require 顺序：

```racket
(struct plugin (id env status-parts panels state-init))
(struct panel-spec (id name role mode sync))

(make-plugin
 'demo
 #:env          (make-environment #:commands … #:rules (list (make-rule 'always keys)))
 #:status-parts (list (make-status-part 'demo render))
 #:panels       (list (make-panel-spec 'main #:role 'tool #:mode 'demo #:sync sync-demo!))
 #:state-init   (λ (s) (plugin-state-set s 'demo 0)))
```

| 字段 | 作用 | 语义 |
|---|---|---|
| `id` | `state.store` 的键 | 插件命名空间 |
| `env` | roles / modes / scopes / commands / keymaps / rules / doc-types / handlers / input-commands | **覆盖**（`environment-merge`，后者优先） |
| `status-parts` | 状态栏段 | **追加**（放在现有段之前） |
| `panels` | 自带面板 | 每个 `panel-spec.sync` 自动追加到 `env.panel-syncs` |
| `state-init` | `state -> state` | 初始化自己的 store 槽 |

面板的安装由宿主做（需要 region-id 与布局位置）：

```racket
(panel-spec-install! engine state rid (filetree-panel-spec))  ; → (values state' vid)
(install-filetree-panel! engine state rid root)               ; 便捷版：顺便设 workspace.root
(panel-uninstall! engine state rid)                           ; 反操作（可重复调用）
```

### 全局键用规则，不要覆盖 `keymaps['global]`

`environment-merge` 对 keymaps 也是按名字覆盖，插件写 `'global` 会把框架的全局键表
整个换掉。插件应该贡献规则：

```racket
#:rules (list (make-rule 'always (keys [(key 'b 'ctrl) 'toggle-filetree])))
```

规则层在 mode 之上、`global` 之下（见 `dispatch/rules.rkt`），所以既不丢框架键，
也不影响别的 mode。`test/plugin-detach.rkt` 第 3 条断言 `C-x C-f` 仍是 `open-file`。

### 为什么 `status-parts` 不放在 `env` 里

`environment-merge` 是覆盖语义（a 的 status 被 b 整体替换）。插件通常想
“再加一段”而不是“换掉整条状态栏”，所以把加法语义提到 `plugin` 字段上，避免歧义。
两个语义都有测试（`test/plugin.rkt` 第 2、5 条）。

### 纯装配

```racket
(define-values (env' state') (plugins-apply env state (list p1 p2)))
(plugins-env core-env (default-plugins))   ; 只要 env
```

`plugins-apply` 是纯函数：merge env → 追加状态栏段 → 挂面板 sync → 跑 `state-init`。
副作用（建 engine 对象 / 装面板）不在这里，由 `effects/panel.rkt` 的装配动作做，
插件只声明参数。

### 插件现在能做什么（不改框架任何文件）

- 新命令 + 新键位（`env.commands` + `env.rules` / `env.keymaps`）
- 新 document mode / 按扩展名匹配（`env.modes` + `env.doc-types`）
- 新条件层（`env.rules` + `env.scopes`）
- 状态栏段（`status-parts`）
- 输入栏提交逻辑（`env.input-commands`）
- 内部事件处理（`env.handlers`：`job-done` / `tick`）
- 自己的状态（`state.store` + `plugin-state*`）

内置插件就是这么写的：

- `plugins/filetree/plugin.rkt`：`panel-spec` + mode `'filetree` + `filetree-command-table`
  + `filetree-input-commands` + `C-b` 规则；
- `plugins/resource/plugin.rkt`：`panel-spec` + mode `'resources` + `resource-command-table`。

`demo/plugin.rkt` 是最小的“没有面板”的插件：命令 `demo-hi` + 键 `h` + store 槽 +
状态栏段 `hi×N`，框架侧零改动。

### 还没做（暂定）

- **enable / disable / reload**：`environment` 是无来源的纯值，反查“哪条贡献来自哪个插件”
  需要额外记 provenance；目前只支持“启动时装配一次”。
- **插件自定义 effect**：`effects/interpreter.rkt` 的 `cond` 是封闭的；插件只能用内置 effect +
  `emit-effect`。
- **`panel-spec` 不含 install**：安装需要 region-id 与布局位置（宿主的策略），
  所以只有 `panel-spec-install!` 这个薄封装，没有自动布局。

## 共用面板位置（Tab 切换）

一个 region 可以有多个成员，`active` 决定显示谁——chrome 槽早就是这么做的
（status / input）。同一套机制可以用来把**文件树和资源列表放进同一个面板位置**：

```racket
(define sidebar-rid (region-id 1))

;; 两次 install 传同一个 region-id
(install-filetree-panel! engine state sidebar-rid root)   ; role = 'filetree（第一次决定）
(install-resource-panel! engine state sidebar-rid)        ; 追加成员，active = 资源列表
```

- `panel-region-add!` 是这一步的原语：region 不存在就建，存在就**追加成员**并设为 active；
  role 由第一次安装决定（同一块位置只有一个 role）；
- 布局里只放一个叶子：`(make-leaf sidebar-rid (fixed 30) #:borders '(right))`；
- **Tab**（全局 `switch-member`，也绑在 `C-x C-o`）把 active 挪到下一个成员并聚焦它：

| 情况 | 行为 |
|---|---|
| 焦点在 sidebar（2 个成员） | 切到另一个面板，焦点跟着走 |
| region 只有一个成员（普通 editor） | 提示 `switch: single member` |
| `role.switchable? = #f`（`'slot`） | 提示 `this panel is not switchable` —— 状态栏/输入栏由框架切，不能靠 Tab 手切 |
| 输入栏占用 | 提示 `switch: input active` |

- 被挡住的面板**不重建 buffer**（`panel-visible?` 闸门）：文件树在后台时不再扫盘；
- `C-b`（文件树的显隐）作用在 region 上，所以隐藏的是整个 sidebar。

`demo/sidebar.rkt` 是完整例子，`test/sidebar.rkt` 覆盖上面四条规则。

## 提示消息与未绑定键

### 未绑定键：丢掉前缀，不卡住

前缀 + 未绑定键（例如 `C-x p`）以前会保留 `pending`，于是后续每个键都被当成
`C-x ...` 的延续，整个编辑器“卡住”。现在的规则：

| 情况 | 行为 |
|---|---|
| `C-x`（前缀） | `pending = [C-x]`，状态栏显示 `C-x` |
| `C-x p`（未绑定） | **清空 pending**，状态栏显示 `unbound: C-x p`，**不插入** `p` |
| 单个未绑定键 + `mode.fallback = 'insert'` | 插入字符（行为不变） |
| 单个未绑定键 + 其它 | `unbound: <key>` |

- 报告的是**完整尝试序列**（`C-x p`），不是最后那个键；
- 带前缀时绝不插入字符 —— 否则 `C-x p` 会在文档里留下一个 `p`；
- 前缀编辑（`C-d` 退格 / `C-g` 取消）仍是独立的最高优先层，不受影响。

### 提示消息只活到下一次动作

`chrome.message` 会**在每一次“用户动作”开始时清空**：

| 事件 | 是否清消息 |
|---|---|
| 按键 / 粘贴 | 清 |
| 鼠标按下 / 抬起 | 清 |
| 鼠标移动 / 滚轮 / resize / 内部事件 / tick | 不清（拖动时消息不闪） |

所以 `unbound: …`、`cancelled: …`（取消删除文件）、`switch: single member` 这类提示
在状态栏只停留到你下一次按键 / 点击，不会一直占着状态栏。命令自己要显示的信息
（`saved: …`、`view placed`）在同一个 transition 里重新写入，照常可见。

没有 pending 时状态栏才显示消息；有 pending 时显示键序列（`C-x`）—— 两者不抢位置。

## 资源列表面板

`demo/resource.rkt`：

- `*resources*` 也是 core buffer view，挂在 role `'resource` 的 panel；
- document 行绿色，view 行蓝色：两种资源用颜色区分；
- view 行缩进在 document 下（不显示折叠符号，Tab/Enter 折叠展开）：
  - `←→↑↓ Home End` 可在面板内移动光标；鼠标点击也会聚焦并落点；
  - `region:X`
  - `*` = active
  - `[focus]`
  - `[placing]`
- `Enter`：
  - document 行 → 折叠/展开；
  - view 行 → attached 则设为 active + focus；detached 则进入 placement（带选择）；
- `←→↑↓ Home End` 在资源面板内自由移动；
- `Tab` 也折叠/展开 document；
- `v` 给选中 doc 新建 detached view；
- `n` 新建 scratch doc + detached view；
- `r` 选中 view 进入 placement；
- 然后鼠标或 `M-方向` 把焦点移到目标 panel：
  - 鼠标左键直接点到目标 panel 会提交；
  - 或按 `C-x C-p` 提交到当前焦点 panel；
- 提交会替换目标 panel 的 active view；旧 view 只 **detach**，不销毁；
- `d` detach 选中 view；`c` 销毁选中 view；`Esc` / `C-x C-g` 取消 placement。
- placement 时点击目标 panel 会直接替换该 panel 的 active view；旧 view 被 detach 保留。

API：

```racket
(install-resource-panel! engine state region-id)
(sync-resource-panel! state engine)
(resource-lines state)
(resource-line-at state line)
```

`sync-resource-panel!` 由 runtime 每帧调用；资源面板不参与保存确认。


## 文件树面板

`demo/filetree.rkt [root]`：

- 布局是左侧文件树 + 右侧 editor/status：
  - 文件树占满左侧高度；
  - 文件树上/下/左边框关闭，只保留右侧分隔边；
  - 初始 editor panel 是空占位，打开文件后进入 placement，点击右侧 editor 或 `C-x C-p` 放入。
- `*filetree*` 是 core buffer view；
- 第一行固定是根目录完整路径；
- 目录/文件按 **2 空格/层** 缩进；
- 颜色：
  - 根目录青色；
  - 目录蓝色；
  - 文件灰色；
  - 已打开的 document 绿色。
- `C-b` 显示 / 隐藏文件树面板：
  - 隐藏时记录当前 region 在父轴上的内容尺寸（宽度/高度）；
  - 显示时用该尺寸作为 fixed 恢复，挤出隐藏时让出的空间；
  - 尺寸为 0 / 未记录时使用最小值 20。
- `Enter`：
  - root/dir → 展开/折叠
  - file → 打开：
    - 已有 attached view → 直接聚焦已有 view；
    - 只有 detached view → 进入 placement，用户自己选 panel；
    - 尚未打开 → 进入 placement；没有 editor panel 时自动创建并放入。
- `C-n f` 创建文件；
- `C-n C-n f` 创建文件夹；
- `C-d` 删除文件：先进入 input 栏确认 `y/n`（只删文件，不删目录）；
- 方向键 / Home / End / 鼠标点击都可用。

API：

```racket
(install-filetree-panel! engine state region-id root)
(sync-filetree-panel! state engine)
(filetree-panel-view state)
(filetree-lines state)
(filetree-line-at state line)
```

文件树/资源面板自身 document 不参与保存确认。

## 文件树键

| 键 | 作用 |
|---|---|
| `Enter` | 目录折叠/展开；文件打开 |
| `C-n f` | 创建文件 |
| `C-n C-n f` | 创建文件夹 |
| `C-d` | 删除文件（y/n 确认） |
| `←→↑↓ Home End` | 在文件树内移动 |
| `C-x C-p` | placement 提交到当前/点击 panel |


## 拖动 panel 接缝

鼠标拖动相邻 panel 的共享接缝可以 resize：

- `geometry-solve` 产出 `cut`（axis / offset / path / 两侧 rect 格数）；
- press 命中 cut → `gesture 'seam`；
- move → `tree-resize-seam` 按格数增量改两侧 dim：
  - flex + flex：总权重不变，按新格数比例重分；
  - fixed + fixed：直接改固定值；
  - fixed + flex：固定侧改，flex 侧吸收；
- release → 清 gesture。

接缝是 layout chrome，不进命令表，也不受文档类型影响。
