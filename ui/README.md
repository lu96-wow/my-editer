# ui —— racket-tui 前端（core screen → 终端）

把「把 `core` 的 `screen` 画到终端」这件事抽成可复用的一层，避免每个应用各抄一套
screen→ANSI、增量重绘、事件循环、输入翻译。只依赖 `core/api.rkt` + `racket-tui`，
**不认识** editor / default-editor / 任何具体应用。

```
ui/tui.rkt    tui 后端：绘制 + 增量 + 事件循环 + 输入翻译 + 默认样式
```

## 会话契约（应用提供三个纯函数）

| 函数 | 签名 | 说明 |
|---|---|---|
| `project` | `session → screen` | 已是**合成好的整屏**（多窗格先自己 `screen-compose`） |
| `handle` | `session core-event → (values session quit?)` | 唯一输入入口（输入已翻成 core 事件） |
| `resize` | `session rows cols → session` | 终端尺寸（启动 + 每次 resize 都由它接管） |

## API

| 名字 | 签名 | 说明 |
|---|---|---|
| `run-tui` | `(run-tui session #:project #:handle [#:resize] [#:style] [#:rows] [#:cols] [#:alternate-screen?])` | 跑事件循环；返回最终 `session` |
| `screen->bytes` | `(screen->bytes scr [#:style])` | 整屏 → 字节（纯，测试用） |
| `frame->bytes` | `(frame->bytes old new [#:style])` | 两帧之间 → 字节（`old=#f` 或尺寸变 = 整屏；否则 `screen-damage` 增量） |
| `draw-screen!` | `(draw-screen! old new [#:style])` | `frame->bytes` + `put-bytes`，返回 `new` |
| `tui-event->core-events` | `(tui-event->core-events ev)` | tui 事件 → `(listof core-event)` |
| `default-face->style` | `(default-face->style face)` | 默认 face → tui 样式名（可覆盖） |

`#:style : face → (or/c symbol? #f)` —— core 的 face 是不透明语义值，`ui` 只能给一套默认约定；
应用用 `#:style` 覆盖/扩展：

```racket
(run-tui s #:project P #:handle H
         #:style (lambda (f) (or (my-style f) (default-face->style f))))
```

## 已定下的语义（要改就从这里改）

| 输入 | 翻成 | 理由 |
|---|---|---|
| paste（粘贴） | `text-event` | core 没有 paste 类型；「粘贴」就是「插入一段文本」，复用 `edit-insert` |
| 可打印、无 Ctrl/Alt 的键 | `text-event` | 与打字同语义；Shift 不改分派（和 tui `build-input` 一致） |
| 其余键（命名键 / 带 Ctrl/Alt） | `key-event` | 物理键 + 修饰 |
| 鼠标 press | `mouse-press-event`（坐标转 0-based） | tui 是 1-based（SGR），core 要 0-based |
| 鼠标 scroll | `mouse-wheel-event`（坐标转 0-based） | 同上 |
| 鼠标 release / move | **丢弃** | core 无对应；要就自己在应用里处理 tui 事件 |
| resize | **不进 handle**，调 `#:resize` | 尺寸变化只该有一个入口 |
| null / other | 丢弃 | |

## `default-editor` 怎么用（第一个实例）

```racket
;; default-editor/terminal.rkt（整层就这几行）
(run-tui (shell-open path 24 80 #:root root)
         #:project shell->screen
         #:handle  shell-handle
         #:resize  (lambda (s rows cols) (shell-resize s rows cols)))
```

新应用也一样：把「应用状态」当 `session`，写三个纯函数即可。

## 分层

```
core (L0–L5)  <  ui (L6)  <  default-editor (L7)
```

`tools/layers.rkt` 已把 `ui` 记为 L6、`default-editor` 记为 L7，机械校验「不得向上」
（`ui` 只依赖 `core/api.rkt` + 外部 `racket-tui`）。

## 还没做 / 可扩展

- `io/example.rkt` 仍手写了一套绘制（它是「手工组合」的参考示例，没动）。
- 想加 GUI/Web 后端：新增 `ui/gui.rkt` 实现同样的 `screen→渲染`，`project`/`handle` 契约不变。
- 原始 paste 字节、鼠标 release/move 若要暴露，加可选的 `#:paste` / `#:mouse` 钩子即可。
