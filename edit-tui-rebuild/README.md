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
model/
  layout.rkt      region 布局树（纯几何，不依赖 core）
  workspace.rkt   doc / view / region / layout / focus / overlay
  input.rkt       pending / modes / gesture / prompt
  chrome.rkt      message / log
  state.rkt       根 State：window / workspace / input / chrome / runtime / ids
env/
  role.rkt        区域角色 -> splittable? / close-policy / focusable?
  mode.rkt        document 模式 -> keymaps / fallback
  scope.rkt       scope 谓词（state -> bool）
  command.rkt     复用旧 command 结构（run / note / input）
  environment.rkt role/mode/scope/command/keymap/handler 的只读聚合
  defaults.rkt    内置 role / mode
dispatch/
  context.rkt     命令看到的 ctx（env/state/event/subject/engine）
  rules.rkt       有序规则：mode 层 / per-doc 层 / mode 默认 / global
  pipeline.rkt    event -> transition（键盘 / 鼠标 / prompt / 内部事件）
effects/
  engine.rkt      core buffer/view 的唯一拥有者 + 只读 engine-view + view 尺寸同步
  interpreter.rkt effect -> transition（引擎写 / open / save / 文件 IO / quit）
projection/
  geometry.rkt    region 树 -> region-panel / 内容区 / 接缝（纯）
  status.rkt      状态栏 / prompt 文本投影（纯）
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
main.rkt          公共面（聚合以上）
```

核心约定：

- State 只存 **id + 元数据**，不存 core 的 buffer / view 句柄；
- 命令返回 `(transition state effects)`，效果按顺序解释；
- 切焦点不再自动清 pending；输入状态独立；
- 区域几何在 layout leaf，区域成员/active 在 region，避免两处真相；
- role/mode/scope/command 都在 Environment 值里，注册是 `environment-add-*`，不是模块级 `set!`；
- 命令 id 作为 keymap 叶子，dispatch 再用 env 查命令实现；
- dispatch 只接收 subject（view-id / region-id），鼠标 hit-test 留给 projection/geometry；
- prompt 的文本编辑目前是最小实现（append / backspace），后续块再泛化输入类型；
- State 不存 core 句柄；engine 是可变边界，命令只通过 engine-view 读；
- `spawn` / `timer` / `emit` 是 Runtime effect，解释器显式报错，等 runtime 块接线；
- 文档版本用 core 的 **opaque document token**：`buffer-version` / `buffer-version=?`，不存文本快照；
  编辑 -> 新 token，undo 回保存点 -> 恢复同一 token（clean），保存时用 token 做异步快照比较；
- 渲染分工：Runtime 先 `engine-sync-views!` 落 viewport，再 `render-frame` 得到 bytes，最后自己 `put-bytes`；
  chrome region（状态栏/输入栏）不是 core view，由 `projection/render` 按差异画文本；
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
edit-tui-rebuild/test/run.sh
```


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
| `M-方向` | region 间焦点移动 |
| 左键点击 | 聚焦 view 并把光标落到点击位置 |
| 左键拖动 | 从按下位置开始拖选 |
| `C-q` | 退出 |

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
