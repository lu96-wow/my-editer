# edit

终端编辑器。当前实现分成两个自包含部分：

| 目录 | 内容 |
|---|---|
| `core/` | 文本引擎 + 渲染值：buffer / view / document / history；track / change / slot / face port；screen / panel / piece |
| `edit-tui/` | TUI 宿主：纯 State + action、分层骨架、布局 / 资源 / 命令 / 投影、插件与 boot |
| `history/` | 历史实现（`edit` / `edit4` …），只作参考，运行时不依赖 |
| `core-test/`、`edit-tui/test/` | 回归测试 |

## 先看哪里

- `core/README.md`：core 的设计决策、分层、写入口
- `edit-tui/README.md`：TUI 目录、分层、数据流、API、demo
- `edit-tui/core/skeleton.rkt`：插件唯一能 require 的骨架入口
- `edit-tui/boot/`：action 解释、同步、渲染、事件循环
- `edit-tui/test/layers.rkt`：分层约束的可执行版本
- `edit-tui/test/api-boundary.rkt`：API 边界检查

## 测试

```sh
bash edit-tui/test/run.sh            # 全部 edit-tui 测试
racket edit-tui/test/layers.rkt      # 分层 / 依赖方向
racket edit-tui/test/api-boundary.rkt
```

也可以直接跑单个领域测试，例如：

```sh
racket edit-tui/test/layout.rkt
racket edit-tui/test/resource.rkt
racket edit-tui/test/input.rkt
```

## demo

```sh
racket edit-tui/demo/interactive.rkt  # 文件树 + 编辑 + 输入栏 + placement
racket edit-tui/demo/layout.rkt       # 80x24 布局渲染
racket edit-tui/demo/three-panels.rkt # 只用 core 的三 panel 示例
```

## 约定

- `core/` 的 buffer / view 只由 `edit-tui/core/engine/store.rkt` 持有和写；
- State 不存 core 句柄、线程、cache 或 inbox；
- 命令只返回 `(values state actions)`，action 由 `edit-tui/boot/actions.rkt` 解释；
- 渲染是纯投影：`layout -> core panel -> bytes`，尺寸写回只经 `panels-sync!`；
- 所有显示都是 document；颜色 / 样式只在 `edit-tui/config/theme/`；
- 插件只 require `edit-tui/core/skeleton.rkt` 和 app 基础值，跨插件只经对方 `api.rkt`。
