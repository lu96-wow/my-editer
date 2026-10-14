# core 功能示例（拆分版）

每个文件一个主题，都能单独运行：

```sh
cd edit
racket temp/01-objects.rkt
racket temp/02-selection.rkt
...
```

## 文件索引

| 文件 | 主题 | 对应 core 模块 |
|---|---|---|
| `01-objects.rkt` | buffer / view 的创建、共享、关闭 | `editor/state.rkt` |
| `02-selection.rkt` | 选区：值层构造 + 提交到 view + 查询 | `text/base/selection.rkt`、`editor/ops.rkt`、`editor/query.rkt` |
| `03-editing.rkt` | 编辑算子、多光标、只读守卫、并步 | `text/command.rkt`、`editor/ops.rkt` |
| `04-navigation.rkt` | 光标移动、扩选、自定义导航、视口滚动 | `editor/ops.rkt`、`view/base/viewport.rkt` |
| `05-history.rkt` | undo / redo / 并步 / 记步开关 | `editor/history.rkt` |
| `06-attributes.rkt` | face / readonly / 开放槽 的读写 | `editor/attributes.rkt`、`text/slot-dsl.rkt` |
| `07-query.rkt` | 文本、点、选区、坐标换算、视口状态查询 | `editor/query.rkt` |
| `08-render.rkt` | display list → screen（全量 + 增量 + 装饰） | `editor/render.rkt` |
| `09-multiview.rkt` | 一份文档多视图，编辑时兄弟视图重基准 | `editor/ops.rkt`、`text/rebase.rkt` |

## 分层速查

```
值层   text/base/*、view/base/*           纯值，随便构造
文档   text/document.rkt                  文本 + 端口(face/readonly) + 槽
对象   editor/state.rkt                   buffer / view（宿主持有）
算子   editor/ops.rkt                     纯编辑算子 + 提交壳
读     editor/query.rkt
写回   editor/attributes.rkt
渲染   editor/render.rkt                  display list → screen
入口   editor.rkt                         以上全部再导出
```

## 提交的返回值约定（`editor/ops.rkt`）

编辑类提交函数用一个值编码三态，真值 = 已提交，`#f` = 拒绝：

| 返回 | 含义 |
|---|---|
| `#f` | 被只读守卫拒绝，未提交 |
| `'()` | 提交成功但无变更 |
| `(list change)` | 提交成功，含本次变更描述 |

例：`(buffer-edit! b v op)`。需要布尔时用 `(and ret #t)`。
`buffer-replace!` 返回 `void`（可用 `#:changes` 传入变更描述）；`buffer-apply-if-version!` 返回 `applied?`。

## 两个容易踩的点

1. **槽必须在任何 document 创建之前声明**（`document-open` 时会 `freeze-slots!`）。
   所以 `06-attributes.rkt` 里 `define-document-slot` 写在 `make-buffer` 之前。
   又因为注册表是进程级的，**一个进程只能声明一次槽**——所以每个示例用独立进程运行。
2. **`point` 的列是字符索引，不是显示列**（宽字符算 1 个索引、2 个显示列）。
   从屏幕坐标反推点要用 `view-screen-position->point`，别拿终端列号直接造点。
