# edit-tui-rebuild

重建中的编辑器骨架。设计、状态清点、目标分层见 [`DESIGN.md`](DESIGN.md)。

## 进度

| 块 | 内容 | 状态 |
|---|---|---|
| 1 | `base/` 词汇 + `model/` 状态切片 + 纯测试 | ✅ |
| 2 | `env/` 注册表（role / mode / scope / command） | ✅ |
| 3 | `dispatch/` 规则管线 + 键盘/鼠标统一 | ✅ |
| 4 | `effects/` engine 适配 + 文件 IO（spawn/timer 留给 runtime） | ✅ |
| 5 | `projection/` geometry / render / status | 待做 |
| 6 | `bootstrap/` + runtime | 待做 |

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
  engine.rkt      core buffer/view 的唯一拥有者 + 只读 engine-view
  interpreter.rkt effect -> transition（引擎写 / open / save / 文件 IO / quit）
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
- `spawn` / `timer` / `emit` 是 Runtime effect，解释器显式报错，等 runtime 块接线。

## 测试

```
racket edit-tui-rebuild/test/base-model.rkt
racket edit-tui-rebuild/test/env.rkt
racket edit-tui-rebuild/test/dispatch.rkt
racket edit-tui-rebuild/test/effects.rkt
edit-tui-rebuild/test/run.sh
```
