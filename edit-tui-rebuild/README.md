# edit-tui-rebuild

重建中的编辑器骨架。设计、状态清点、目标分层见 [`DESIGN.md`](DESIGN.md)。

## 进度

| 块 | 内容 | 状态 |
|---|---|---|
| 1 | `base/` 词汇 + `model/` 状态切片 + 纯测试 | ✅ |
| 2 | `env/` 注册表（role / mode / scope / command） | ✅ |
| 3 | `dispatch/` 规则管线 + 键盘/鼠标统一 | ✅ |
| 4 | `effects/` engine 适配 + 文件 IO（spawn/timer 留给 runtime） | ✅ |
| 5 | `projection/` geometry / render / status | ✅ |
| 6 | `bootstrap/` + runtime | ✅ |

## 块 1：base + model

```
base/
  id.rkt          带 kind 的稳定 id + 纯分配器
  event.rkt       应用事件 ADT（不依赖 tui）
  effect.rkt      效果 ADT（引擎写 / IO / 调度）
  transition.rkt  State + 有序 effects + 组合子
  keymap.rkt      通用 token -> 值 的前缀表（叶子任意值）
  status.rkt      status-part：状态栏可组合段
model/
  layout.rkt      region 布局树（纯几何，不依赖 core）
  workspace.rkt   doc / view / region / layout / focus / overlay
  input.rkt       pending / modes / gesture
  chrome.rkt      message / log
  state.rkt       根 State：window / workspace / input / chrome / runtime / ids
env/
  role.rkt        区域角色 -> splittable? / close-policy / focusable?
  mode.rkt        document 模式 -> keymaps / fallback
  scope.rkt       scope 谓词（state -> bool）
  command.rkt     复用旧 command 结构（run / note / input）
  rule.rkt        scope + keymap 的规则
  doc-type.rkt    路径扩展名 -> mode + per-document keymaps
  environment.rkt role/mode/scope/command/keymap/handler/rules/status 的只读聚合
  defaults.rkt    内置 role / mode
dispatch/
  context.rkt     命令看到的 ctx（env/state/event/subject/engine）
  rules.rkt       有序规则：mode 层 / per-doc 层 / mode 默认 / global
  pipeline.rkt    event -> transition（键盘 / 鼠标 / 内部事件）
effects/
  engine.rkt      core buffer/view 的唯一拥有者 + 只读 engine-view + view 尺寸同步
  interpreter.rkt effect -> transition（引擎写 / open / save / 文件 IO / quit）
projection/
  geometry.rkt    region 树 -> region-panel / 内容区 / 接缝（纯）
  status.rkt      状态栏文本投影（纯）
  render.rkt      state + engine -> panels / chrome / bytes（不输出、不写 core）
bootstrap/
  commands.rkt    默认命令（导航 / 编辑 / split / close / focus / quit）
  defaults.rkt    默认 Environment（命令 + keymap + mode + job-done handler）
runtime/
  tui-adapter.rkt 终端事件 -> base/event
  run.rkt         run-app：事件循环 / effect 解释 / 渲染 / inbox
demo/
  basic.rkt       最小交互 demo
  state.rkt       主编辑区 + 一行 State 观察条
  save.rkt        status/input 共享槽 + y/n/yall/nall 保存确认
  resource.rkt    资源列表面板（buffer）+ 显式 placement
main.rkt          公共面（聚合以上）
```

核心约定：

- State 只存 **id + 元数据**，不存 core 的 buffer / view 句柄；
- 命令返回 `(transition state effects)`，效果按顺序解释；
- 切焦点不再自动清 pending；输入状态独立；
- 区域几何在 layout leaf，区域成员/active 在 region，避免两处真相；
- role/mode/scope/command 都在 Environment 值里，注册是 `environment-add-*`，不是模块级 `set!`；
- 命令 id 作为 keymap 叶子，dispatch 再用 env 查命令实现；
- `env.rules` 是带 scope 的规则层，层序：input modes > per-doc > env.rules > mode > global；
- 状态栏是 `status-part` 列表，不是写死的字符串：`environment.status` 决定用哪些段；
  `default-status-parts` 只有 focus 行列 + path，`full-status-parts` 再加 pending/message；
- 打开文件时按路径匹配 `env.doc-types`，把 mode + keymaps 写进 `doc-meta.keymap-layers`；
  命令派发按 subject view → doc → mode/per-doc layers，不按 layout region；
- dispatch 只接收 subject（view-id / region-id），鼠标 hit-test 留给 projection/geometry；
- 输入栏是 *input* document：prompt 前缀写进 buffer 且 readonly，输入文本就是前缀后的内容；
  提交时读完整 buffer 字符串，交给 `environment.input-commands` 匹配；
- State 不存 core 句柄；engine 是可变边界，命令只通过 engine-view 读；
- `spawn` / `timer` / `emit` 是 Runtime effect，解释器显式报错，等 runtime 块接线；
- 文档版本用 core 的 **opaque document token**：`buffer-version` / `buffer-version=?`，不存文本快照；
  编辑 -> 新 token，undo 回保存点 -> 恢复同一 token（clean），保存时用 token 做异步快照比较；
- 渲染分工：Runtime 先 `engine-sync-views!` 落 viewport，再 `render-frame` 得到 bytes，最后自己 `put-bytes`；
  status/input 是 chrome slot 里的两个 core view（buffer 支撑）；`projection/render` 也保留 projection chrome 兼容路径；
- Runtime 是唯一不纯装配层：`with-tui` / `read-event` / `put-bytes` / inbox / spawn / timer；
  `spawn` / `timer` 的回投事件在“下一个终端事件”到达时排空（与旧骨架一致）。

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
edit-tui-rebuild/test/run.sh
```


## 通用输入栏 API

```racket
(require "edit-tui-rebuild/input.rkt")
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

低层 `chrome-input-show` 不做替换清理；其他逻辑应调用 `input.rkt` 的 `input-show`。

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
| `C-b` / `C-v` | 向右 / 向下切分（same document 多 view） |
| `C-w` | 关闭当前 view |
| `M-w` | 关闭当前 region / panel（按 role 的 close-policy） |
| `C-n` | 新建 document/view（空 editor region 也能接） |
| `C-x C-f` | 打开文件（input document 输入路径） |
| `C-x C-s` | 保存当前 document；无 path 时进入 `Save as:` 输入 |
| `C-x C-k` | 关闭当前 document 的所有 view + document |
| `C-x C-d` | 把当前 view 从 panel 摘出来（保留 view / engine view / document） |
| `C-x C-a` | 把第一个 detached view 挂回当前 region（buffer-list 前的临时入口） |
| `C-x C-o` | 在同一 region 的多个 view 之间循环 active / focus |
| `C-x C-p` | 提交 resource placement 到当前/点击的 panel |
| `C-x C-g` | 取消 placement |
| `M-方向` | region 间焦点移动 |
| 左键点击 | 聚焦 view 并把光标落到点击位置 |
| 左键拖动 | 从按下位置开始拖选 |
| `C-q` | 退出；有 dirty document 时进入保存确认 |
| `y` / `n` / `yall` / `nall` + Enter | 保存确认：当前保存 / 跳过 / 保存剩余 / 跳过剩余 |

## 边界决定：最后一个 editor region

采用 **保留空 region，只清 view**：

- `C-w` close-view：移除当前 view；region 留在布局里；
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
| `C-w` close view | 销毁 view（engine view + view-meta）；document 保留 |
| `C-x C-d` detach view | 从 region 成员表移除；view / engine view / document 全部保留 |
| `M-w` close region/panel | 把 region 内 view 全部 detach，再删除/保留 region；**不销毁 view** |
| `C-x C-k` close document | 销毁该 document 的所有 view + document |

- `workspace.views` 是 view 资源表；detached view 仍在这里；
- `workspace-detached-views` 可列出没有挂到 region 的 view；
- `workspace-attach-view` 强制 view 单成员：挂到目标 region 前先从旧 region 移除；
- 关闭 panel 现在不会销毁 view，所以之后可以从资源列表重新挂回；
- 目前还没有正式 buffer-list 面板，`C-x C-a` 只是“挂回第一个 detached view”的临时入口。

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

- `model/resources.rkt`：`save-confirm` 队列 / 当前 index / 完成后 action；
- `bootstrap/chrome.rkt`：安装共享槽、input show/finish、status buffer 同步；
- `bootstrap/commands.rkt`：`request-quit` / `request-close-file` / input-submit / save-confirm 流程；
- `bootstrap/defaults.rkt`：`input-keys` + `default-input-commands`。


## 资源列表面板

`demo/resource.rkt`：

- `*resources*` 也是 core buffer view，挂在 role `'resource` 的 panel；
- document 行绿色，view 行蓝色：两种资源用颜色区分；
- view 行缩进在 document 下（不显示折叠符号，Tab 直接折叠/展开）：
  - `region:X`
  - `*` = active
  - `[focus]`
  - `[placing]`
- `Enter`：
  - document 行 → 折叠/展开；
  - view 行 → attached 则设为 active + focus；detached 则进入 placement（带选择）；
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
