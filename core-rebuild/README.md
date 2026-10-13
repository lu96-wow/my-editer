# core-rebuild —— 重构中的 core

> 旧 `core/` 原样保留，随时对比、查证。这里是按新架构重写的版本。

## 锁定决策（与旧 core 的差异）

1. **消除 did/vid 与中央 `editor`**：不再有「一个 editor 把互不关联的 document/view 混在一起、用整数 id 指来指去」。
   - did 的替代 = `buffer` 对象本身；vid 的替代 = `view` 对象本身。
   - 宿主直接持有对象；core 不再集中管理多个文档。
2. **操作 = 纯函数 + `compose`/`map`**；状态对象（buffer/view/document/history）**可以不纯**（functional core / imperative shell）。
3. **保留多 view 共享一份 document+history**：`buffer` 持 `history`（含当前 document）与 `views`；`view` 指回 `buffer`。
4. **focus 在宿主**：core 不存 focus；宿主自己决定焦点 view，渲染时作为 focus 传进去。
5. **history 去掉 who/selections**：撤销不再「回到发起视图」。history 退化成**纯文档版本栈**。
   - 并步（merge）决策移到会话层（commit 壳），由「来源切换时 seal」控制。

## 分层

| 层 | 模块 | 性质 |
|---|---|---|
| 值 | `text/base/*`、`view/base/*` | 纯值 |
| 文档 | `text/document.rkt`、`text/command.rkt`、`text/rebase.rkt`、`text/slots*.rkt` | 文本编辑纯，端口/槽可含盒 |
| 历史 | `editor/history.rkt` | 纯文档版本栈 |
| 对象 | `editor/state.rkt`（`buffer`/`view` + 结构手术） | 可变外壳，宿主持有 |
| 算子 | `editor/ops.rkt`（轴算子 + commit 壳） | 纯算子 + 写回 |
| 读 | `editor/query.rkt` | 按对象读 |
| 写回 | `editor/attributes.rkt`（按 buffer）；异步 CAS 在 `ops.rkt` |
| 渲染 | `editor/render.rkt`（display list → screen） | 纯投影 |
| 入口 | `editor.rkt` | 再导出 |

不变（复制自旧 core）：`text/**`、`view/{project,overlay,render,patch}.rkt`、`view/base/*`。
已改：`view/compose.rkt` —— overlay 随 pane 自带的 screen 一起合成，不依赖 active/id（谁画由宿主渲染时决定）。

## 存在集 vs 可见集（分工）

两个集合职责不同，不可混为一谈：

| | 在哪 | 含义 | 谁维护 |
|---|---|---|---|
| **存在集** | `buffer.views` | 这个文档一共有哪些 view（含未显示的） | core |
| **可见集/位置** | 宿主 layout（每个窗口至多挂一个 view） | 现在屏幕上显示哪些 view、在哪 | 宿主 |

一条不变量：**一个 view 至多属于一个窗口**（不会同时出现在两处），所以 viewport 的 w/h 就是它那个窗口的内容尺寸，渲染无歧义。

宿主操作：

| 操作 | 改哪里 |
|---|---|
| 新建 view | `buffer-add-view!` → 挂到窗口 |
| **隐藏** | 只改宿主（从窗口摘掉；view 仍在 `buffer.views`） |
| **显示** | 只改宿主（从 `buffer.views` 挑一个挂回窗口） |
| 销毁 view | 摘窗口 + `buffer-close-view!` |
| 关文档 | `buffer-close!` + 宿主清相关窗口 |

渲染只认可见集（layout 里的 view + 几何），**完全不看 `buffer.views`**。

## 进度

- [x] 目录 + 纯层（text/view）就位
- [x] `editor/history.rkt`：纯文档版本栈（无 who/selections）
- [x] `editor/state.rkt`：buffer/view 对象 + 结构手术
- [x] `editor/ops.rkt`：轴算子 + commit（含并步会话记忆）
- [x] `editor/query.rkt` / `editor/attributes.rkt`
- [x] `editor/render.rkt`：render-display（display list）
- [x] `editor.rkt` 入口
- [ ] 测试对照（旧 core-test）
- [ ] 移植宿主（edit4 adapter）验证
