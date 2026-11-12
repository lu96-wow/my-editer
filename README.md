# edit

终端编辑器。当前实现分成两部分：

| 目录 | 内容 |
|---|---|
| `core/` | 文本引擎 + 渲染值：buffer / view / document / history；track / change / slot / face port；screen / panel / piece |
| `edit-tui/` | TUI 应用：纯 State + action、editor 操作面与扩展点、布局 / 资源 / 命令 / 投影、插件与 host |
| `history/` | 历史实现（`edit` / `edit4` …），只作参考，运行时不依赖 |
| `core-test/`、`edit-tui/test/` | 回归测试 |

`edit-tui/` 现在是重建后的实现；旧 `edit-tui` 已由它替换。

## 先看哪里

- `core/README.md`：core 的设计决策、分层、写入口
- `edit-tui/README.md`：TUI 目录、分层、数据流、API、键位
- `edit-tui/editor/state.rkt`：`app-state = editor-core + editor-session`
- `edit-tui/editor/host-api.rkt`：宿主装配面（插件只应 require `editor/api.rkt`）
- `edit-tui/edit.rkt`：TUI 装配 + 事件循环
- `edit-tui/test/layers.rkt`：分层约束的可执行版本

## 测试

```sh
bash edit-tui/test/run.sh            # 全部 edit-tui 测试
racket edit-tui/test/layers.rkt      # 分层 / 依赖方向
```

也可以直接跑单个领域测试，例如：

```sh
racket edit-tui/test/layout.rkt
racket edit-tui/test/hooks.rkt
racket edit-tui/test/filetree.rkt
```

## 运行

```sh
racket edit-tui/edit.rkt
```

## 约定

- `core/` 的 buffer / view 只由 `edit-tui/editor/engine/store.rkt` 持有；
- 用户文档文本编辑只经 `editor/ops/raw.rkt` / `editor/ops/surface.rkt`；
- State 不存 core 句柄、线程、cache 或 inbox；
- 命令只返回 `(values state actions)`，action 由 `edit-tui/edit.rkt` 解释；
- 渲染是纯投影：`layout -> core panel -> bytes`，尺寸写回只经 `panels-sync!`；
- 插件状态是纯值，按 plugin id 命名空间存在 `editor-core`，只有 plugin runtime 按 owner 写回；
- 插件只 require `edit-tui/editor/api.rkt` 与 feature 的 `api.rkt`，跨插件只经 action 或对方 `api.rkt`。

## 迁移期依赖

`edit-tui` 仍保留少量从旧实现迁回的支撑模块，集中放在 `edit-tui/compat/`：

- `edit-tui/compat/lang/racket/`：Racket 语言能力（着色 / 补全 / 文档 / 缩进）；
- `edit-tui/compat/source/`：源码扫描；
- `edit-tui/compat/face/`：face 值；
- `edit-tui/compat/render/`：core piece -> tui bytes；
- `edit-tui/compat/theme/`：默认主题。

宿主入口只使用 `compat/render/core.rkt` 和 `compat/theme/default.rkt`；后续可以逐步迁进新树并删除 `compat/`。
