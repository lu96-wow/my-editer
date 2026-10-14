# core —— 设计与分层

## 设计决策

1. **无 did/vid、无中央 `editor`**：`buffer` / `view` 对象本身就是身份；宿主直接持有对象，core 不集中管理多个文档。
2. **操作 = 纯函数 + `compose`/`map`**；状态对象（buffer / view / document / history）可以不纯（functional core / imperative shell）。
3. **多 view 共享一份 document + history**：`buffer` 持 `history`（含当前 document）与 `views`；`view` 指回 `buffer`。
4. **focus 在宿主**：core 不存 focus；渲染时作为参数传入。
5. **history 是纯文档版本栈**：不含 who / selections，撤销不回发起视图。
6. **合并完全显式**：编辑本身不含合并策略；一组操作合成一步用事务（程序）或会话（交互）。
7. **写回只有一条路径**：`buffer` / `view` 的裸 setter 不外露，改状态一律走提交壳。

## 分层

| 层 | 模块 | 性质 |
|---|---|---|
| 值 | `text/base/*`、`view/base/*` | 纯值 |
| 文档 | `text/document.rkt`、`text/command.rkt`、`text/rebase.rkt`、`text/slots*.rkt` | 文本编辑纯，端口 / 槽可含盒 |
| 历史 | `editor/history.rkt` | 纯文档版本栈（record / merge / set-current） |
| 对象 | `editor/state-data.rkt`、`editor/state.rkt` | buffer / view 可变数据；生命周期与访问器（写只经壳） |
| 提交 | `editor/ops.rkt` | 纯算子构造 + 提交壳 + 显式事务（undo-scope） |
| 读 | `editor/query.rkt` | 按对象读 |
| 写回 | `editor/attributes.rkt` | 端口 / 槽写回（就地改盒，不进 history） |
| 渲染 | `editor/render.rkt` | display list → screen（纯投影） |
| 会话 | `editor/session.rkt` | 显式合并的交互封装（镜像导航 / 程序写） |
| 使用层 | `editor.rkt` | 意图名再导出（`rename-out` + 精选） |

## 存在集 vs 可见集（分工）

两个集合职责不同，不可混为一谈：

| | 在哪 | 含义 | 谁维护 |
|---|---|---|---|
| **存在集** | `buffer.views` | 这个文档一共有哪些 view（含未显示的） | core |
| **可见集 / 位置** | 宿主 layout（每个窗口至多挂一个 view） | 现在屏幕上显示哪些 view、在哪 | 宿主 |

一条不变量：**一个 view 至多属于一个窗口**（不会同时出现在两处），所以 viewport 的 w / h 就是它那个窗口的内容尺寸，渲染无歧义。

宿主操作：

| 操作 | 改哪里 |
|---|---|
| 新建 view | `buffer-add-view!` → 挂到窗口 |
| **隐藏** | 只改宿主（从窗口摘掉；view 仍在 `buffer.views`） |
| **显示** | 只改宿主（从 `buffer.views` 挑一个挂回窗口） |
| 销毁 view | 摘窗口 + `buffer-close-view!` |
| 关文档 | `buffer-close!` + 宿主清相关窗口 |

渲染只认可见集（layout 里的 view + 几何），**完全不看 `buffer.views`**。

## 合并与写入口

- 文本提交返回 `#f | (listof change)`（`#f` = 拒绝，`'()` = 无变更）；`buffer-edit!` 每次调用 = 一个新撤销步。
- 合成一步：程序用 `buffer-with-undo-step`，交互用 `session-edit!`（见 `temp/README.md` 与 `temp/COVERAGE.md`）。
