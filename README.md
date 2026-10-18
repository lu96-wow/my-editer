# edit

终端编辑器。当前实现分成两个自包含部分：

| 目录 | 内容 |
|---|---|
| `core/` | 文本引擎 + 渲染值：buffer / view / document / history；track / change / slot / face port；screen / piece |
| `edit-tui/` | TUI 宿主：分层架构、状态机、effect / hook / plugin、增量 face decor、补全 / 文档 |
| `history/` | 历史实现（`edit` / `edit4` …），只作参考，运行时不依赖 |
| `core-test/`、`edit-tui/test/` | 回归测试 |

> 旧 `edit-tui` 已删除；其中仍然需要的 face / command / core-render / theme
> 已迁入 `edit-tui/`，现在 `edit-tui/` 不依赖同级的旧目录。

## 先看哪里

- `core/README.md`：core 的设计决策、分层、写入口
- `edit-tui/README.md`：目录、分层、数据流、demo
- `edit-tui/ARCHITECTURE.md`：**现在**的层序、副作用白名单、扩展点
- `edit-tui/CONSTRAINTS.md`：特殊约束 / 依赖配合表（改 hook / effect / decor / worker 前看）
- `edit-tui/PLUGINS.md`：高亮 / 补全 / 文档插件
- `edit-tui/INCREMENTAL.md`：增量 face decor 的取舍与实现
- `edit-tui/DESIGN.md`：重建设计的历史记录

## 测试

```sh
racket edit-tui/test/layers.rkt       # 分层 / 副作用 / 线程白名单
racket edit-tui/test/plugins.rkt      # 高亮 / 补全 / 文档
racket edit-tui/test/face-decor.rkt   # 增量 decor / undo / 多光标
racket edit-tui/test/run.sh           # 全部 edit-tui 测试
```

## demo

```sh
racket edit-tui/demo/basic.rkt
racket edit-tui/demo/lab.rkt          # 高亮 + 补全 + 文档
```

## 约定

- core 只由 `edit-tui/effects/engine.rkt` + `effects/paint.rkt` 写；
- State 不存 core 句柄 / 线程 / cache / inbox；
- 投影只读，输出只在 `runtime/run.rkt`；
- 所有显示都是 document；颜色只在 `edit-tui/theme/`；
- 特殊配合点见 `edit-tui/CONSTRAINTS.md`。
