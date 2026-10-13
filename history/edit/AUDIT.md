# edit → edit-rebuild 行为审计（能否完整、更清晰地表达）

目标：把 `edit/` 里所有「隐式靠组合/焦点/注册顺序」的操作状态，检查能否用新模型
（`key` / `scope` / `route` / `effect` / `dispatch`）**显式声明**，并列出需要的扩展。
结论：**全部可表达**；需要 3 个扩展（已实现）：`focus-id`、生命周期事件 `emit`、
命令路由 `execute`。没有任何行为需要保留“脆弱的组合”。

---

## 0. 新模型提供的表达力

| 概念 | 旧 `edit/` | 新模型 |
|---|---|---|
| 键表生效 | 焦点硬编码的栈（float → 焦点面 → 焦点文档 → 全局） | `route.scope`（数据） |
| 查找 | 单命中，first wins | 命中列表按 `priority`；`policy 'stop/'continue` |
| 命令目标 | 隐含 `session-focus-vid` | `(addressed target cmd)` |
| 跨窗 | hook 手工转发 | 多路由 / `(broadcast targets cmd)` |
| 事件替换 | 做不到 | `(forward input/cmd/event)` |
| 模式 | 可变 box（`active`/`phase`） | context 的 `modes`（纯值） |
| 命令处理 | opaque handler 链（LIFO） | command 路由（priority） |
| 生命周期 | opaque hook 链（注册顺序） | `emit` + reaction 路由（priority） |
| 前缀 | 特例分支 | `route.prefix` |

---

## 1. 输入绑定

### 1.1 全局键（`core/command/keys.rkt` 的 `global-keys`）

| 旧绑定 | 新表达 |
|---|---|
| `C-q` → cmd-quit | `(route* (key 'q 'ctrl) (cmd-quit))` ✅ |
| `C-d` → cmd-close | `(route* (key 'd 'ctrl) (cmd-close))` ✅ |
| `C-b` → cmd-toggle slot-side | `(route* (key 'b 'ctrl) (cmd-toggle 'side))` ✅ |
| resize → cmd-resize | `(route* (resize-binding) resize-spec)` ✅（载荷 spec） |
| 鼠标 press/scroll | `(route* (mouse 'press 'left) mouse-press-spec)` ✅ |

作用域：`(scope-always)`。优先级：低于面板/文档键（显式给 10）。

### 1.2 编辑文档键（`tables.rkt`）

| 旧绑定组 | 新表达 |
|---|---|
| text/enter/backspace/delete/方向/home/end/C-a/C-c/C-x/C-v/C-z/C-y | `(route* binding cmd #:when (scope-focus-kind 'editor))` ✅ |
| `M-/`→cmd-complete，`M-d`→cmd-docs-show | 同上 ✅ |
| `M-方向`→cmd-focus | 同上 ✅ |
| `C-p` 前缀（方向 + d） | `(route* (key 'p 'ctrl) (begin-prefix 'C-p))` + 子路由 `#:prefix 'C-p` ✅ |
| `C-o` 前缀（resize） | 同上 ✅ |
| `C-s` 前缀（split） | 同上 ✅ |

**旧“注册顺序覆盖”**（`base-keys = merge(edit-keys, global-keys)`，global 覆盖 edit）
→ 显式 `priority`。✅

**旧每文档键表**（`session-set-doc-keymap`）→ 文档打开时把该文档的路由加进会话路由表，
scope 用 `(scope-focus vid)`；或给文档一个 `mode`。✅（当前默认所有文档同一套，等价。）

### 1.3 面板键（tree / buffers / log / prompt）

| 旧 | 新 |
|---|---|
| tree-keys（焦点在树时） | `#:when (scope-focus-id 'tree)` ✅ |
| buffers-keys | `#:when (scope-focus-id 'buffers)` ✅ |
| log-keys | `#:when (scope-focus-id 'log)` ✅ |
| input-keys（prompt；text/enter/escape） | `#:when (scope-focus-id 'input)`，text 用 `text-spec` ✅ |

说明：旧模型“焦点面键表”是按 vid 取的；新模型需要**面身份** → 已加 `context.focus-id`。✅

### 1.4 浮窗补全键（`completion` 的 `complete-keys`）

| 旧 | 新 |
|---|---|
| down/up/left/right/tab/enter/escape | `#:when (scope-mode= 'menu 'open)`，`priority` 高于文档/全局 ✅ |

**旧是隐式“float 永远在栈顶”**；新是显式 scope + priority。✅

### 1.5 Tab 换焦点（已删）

新表达：`(focus-to 'docs)` / panel-swap 路由，`#:when (scope-visible 'docs)`。✅

---

## 2. 命令 / 处理器

| 旧 | 新 |
|---|---|
| `step-base` 基础命令 | `host.run-command`（原语） ✅ |
| document handler（save/open） | command 路由 `(route* (cmd-save) …)` ✅ |
| tree / buffers / log / completion / docs handler | command 路由 ✅ |
| lifecycle 抢先处理 `cmd-quit` | 更高 `priority` 的 command 路由 ✅ |
| handler 链 LIFO | 显式 `priority` ✅ |
| handler 返回 `session\|#f` | 宿主 result `'handled/'pass/effect` ✅ |

已实现 `execute`：命令先进 command 路由，无命中落宿主原语。✅

---

## 3. 生命周期 hook

| 旧 hook | 新表达 |
|---|---|
| `before-render`（completion poll/resync、docs tick、doc-job poll） | `emit 'before-render`，reaction 按 `priority`（旧顺序脆弱，现显式） ✅ |
| `after-edit` / `after-insert` | `emit` + reaction ✅ |
| `after-nav` | `emit` + reaction ✅ |
| `focus-changed` | `emit` + reaction；docs-cancel **限定** `(scope-focus-kind 'editor)`（修掉“进文档就自杀”） ✅ |
| `document-closed` | `emit` + reaction ✅ |
| `log-appended` → 弹日志 | `emit 'log-appended` + reaction，`#:when (not (scope-mode= 'prompt 'active))` ✅（旧是 handler 里硬编码判断） |
| `prompt-closed` → 换回状态栏 | `emit 'prompt-closed` + reaction ✅ |
| `complete-selection` → 查文档 | `emit 'complete-selection` + reaction ✅ |
| `docs-state` → 补全标志 | `emit 'docs-state` + reaction ✅ |
| `docs-scroll` / `docs-hscroll` / `docs-focus` | **不再用 hook**：改成 route（`addressed 'docs …` / `set-mode`） ✅ |

已实现 `emit`：事件 tag 命中路由，**全部命中按 priority 跑**（纯通知语义）。✅

---

## 4. 焦点 / 面板 / 显隐

| 旧 | 新 |
|---|---|
| `focus`（target + 历史）、`focus-push/restore` | 宿主状态；`run-focus` / `(focus-to t)` ✅ |
| 粘性 `edit-vid`（焦点落 dock 不更新） | 宿主 `run-focus` 内部实现 ✅（引擎不关心） |
| `region-select` / 同区互斥 / 显隐 | 宿主命令 + `context.visible` ✅ |
| `panel-swap` / `bottom-pop` / `panel-fit` / `region-fit` | 宿主命令 ✅ |
| `init-region-visibility` | 宿主装配 ✅ |

---

## 5. 模式 / 输入状态

| 旧 | 新 |
|---|---|
| completion `active` box（'complete/'docs） | `modes 'interaction` ✅ |
| prefix（input-state） | `context.prefix` + `route.prefix` ✅ |
| prompt（input-state） | 宿主状态 + `(scope-focus-id 'input)` ✅ |
| docs `phase` / `win` | 宿主异步状态；**“谁接键”部分** → `modes` ✅ |

---

## 6. 留在宿主层（本就不该进键路由）

这些不是“脆弱的组合”，而是引擎职责，保持宿主/host：

- 异步传输 + 版本闸门（runner / `session-await`）；
- 文本编辑原语、undo/redo、选区、复制粘贴；
- 文件 I/O、目录树状态机；
- 布局几何、渲染、主题；
- `before-render` 里驱动异步 poll（由事件 `before-render` 的 reaction 触发）。

---

## 7. 结论与需要的扩展

**结论：原行为 100% 可用新模型表达，且更清晰**——所有隐式状态都变成 `scope`/`modes`/
`priority`/`effect` 的显式声明。需要的扩展（已全部实现并通过测试）：

1. `context.focus-id`（面身份，用于面板键 scope）。
2. `event` + `emit`（生命周期通知 → reaction 路由）。
3. `execute`（命令 → command 路由，宿主原语兜底）。

**没有发现必须保留的旧机制**。唯一需要“习惯性约定”的两点：
- 同名同 scope 的键冲突由 `priority` 决定（旧是注册顺序）；
- 命令路由的动作若是同一条命令会自递归（约定：动作用效果或原语）。
