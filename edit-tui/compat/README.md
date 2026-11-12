# compat —— 迁移期兼容层

这里放从旧 `edit-tui` 迁回、但还没有完全融入新架构的模块。

| 目录 | 内容 | 当前使用者 |
|---|---|---|
| `lang/racket/` | Racket 词法 / 着色 / 补全 / 文档 / 缩进 | `plugins/indent`、`plugins/racket-color`、`plugins/completion`、`plugins/docs` |
| `source/` | 源码扫描 / 解析来源 | `compat/lang/racket/parse/` |
| `face/` | face 值 + 分层合成 | `compat/render/core.rkt`、`plugins/racket-color` |
| `render/` | core piece -> tui bytes、theme 安装 | 顶层 `edit.rkt` |
| `theme/` | 默认主题安装 | 顶层 `edit.rkt` |

约定：

- 新代码不要继续依赖 `compat/`；
- 新架构的纯值放 `core/`，宿主装配放 `app/` / `host/`；
- 后续把 `render/core.rkt`、`theme`、`face` 逐步迁进新树后，再删除对应 compat 模块。
