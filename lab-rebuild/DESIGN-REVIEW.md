# lab-rebuild 设计评审：耦合点 + 优化

> 骨架功能已跑通（树 / 编辑 / 底槽 / 输入转移 / 增删同步）。
> 本文只谈**结构**：先列耦合点，再给优化项（按优先级）。

## 0. 现状分层

```
core/        编辑器平台（无终端、无 app）
  ↑
lab-rebuild/ 
  layout/*     纯几何（split / regions / 方向邻居）
  input.rkt    事件 → 绑定键（依赖 tui 的事件类型）
  input-doc.rkt 底部槽位文档（state / input）
  mode.rkt     输入转移状态（prompt + 续延）
  command.rkt  纯表：binding → handler
  dispatch.rkt did + event → 表/跑 handler（不含 core / 焦点）
  tree.rkt     文件树模型 → document（纯）
  buffers.rkt  文档/视图两级列表 → document（纯）
  app.rkt      ★ 唯一状态源 + 胶水（状态 / 命令 / 动作 / 渲染 / 鼠标 / 输入）
  tui.rkt      racket-tui 后端（增量渲染 + 主循环）
```

**好的部分**（先记着，别动）：geometry / command / tree / buffers / mode 都是纯的、可单测；
`dispatch` 不认识 core 和焦点；`mode` 用闭包续延回传值，干净；`app-prepare!` 把「每帧先刷 state」收敛成一个入口。

问题集中在 **app.rkt 用 24 字段的可变 struct 手工维护一堆不变量**。下面按耦合类型列。

---

## 1. 耦合点清单

### 1.1 状态：`app` 是 god-object
- `(struct app (ed tree tree-vid tree-did bufs-vid bufs-did bufs-model edit-vid
   sidebar-width left focus mode slot cs paths by-path width height prev quit?))`
- 每个 handler 都 `(ctx-state ctx)` 拿整个 app，接口无法收窄；改一个功能要读全 struct。
- `ctx` 的 `editor / width / height` 三个字段**全项目没人用**（只有 `panes` + `state` 用），
  说明「ctx 给几何」这个抽象目前是空的。

### 1.2 pane 身份：vid / did 双份 + 散落硬编码
- `tree-vid tree-did / bufs-vid bufs-did / edit-vid` + `slot` 里两个 vid。
- `app-bufs-exclude` 每次把 slot vid 反查回 did（`editor-view-document-id`）才知道要排除谁。
- `app-pick-edit-vid` 自己遍历 `editor-document-id-list` 再排除一遍。
- **代价**：加一个 pane（比如 help / 输出面板）要同时改 struct、init、exclude、pick、
  layout、mouse、state-line …… 一律漏改。

### 1.3 mode 的双重表达（最该先修的）
- `app.mode` 表示「现在是 prompt」；**同时** `app-set-input-keys!` 改 `cs` 里 input did 挂的表。
  同一个事实存了两遍。
- `dispatch.rkt` 文件里已经预写了接缝 **(b) 模式表**（`dispatch-tables` 多收一个 mode），
  但 app 没接，反而绕开它去改 command-set。
- 连带：`mode-tables` / `mode?` 在 app 里是**死代码**（只有 smoke 还测）。
- 退出模态时 `commit / answer / cancel` **三处**都要记得 `app-set-input-keys! a #t`，
  加第四种退出方式就会漏。

### 1.4 命令表 / 事件
- 全局默认是「编辑」，只读面板靠 **did 表覆盖**（tree-keys / bufs-keys 内嵌 readonly-keys）。
  「默认行为 + 覆盖」是隐含约定，不在类型里。
- 绑定词表把可打印字符**全塌成 `'text`**；所以 `y/n` 这种按字符的命令只能回看原始事件
  （`confirm-text` 里 `key-event?` + `key-event-key`），**绕过 dispatch**。凡是要 vim 键、y/n
  的模式都会重复这个绕法。

### 1.5 布局耦合 & 重算
- `app-layout-result` 一个事件里可能被算两次：`app-ctx`（→`app-focus-panes`）一次、
  `app-prepare!` 一次；鼠标路径 `app-handle-mouse` 再一次。
- `main-w` / `main-h` 自己算一遍尺寸，`compute-regions` 又算一遍；statusbar 高 `1`
  在 `main-h` 和 `#:statusbar-height 1` 两处硬编码。
- `bottom-vid` 依赖 `mode` ⇒ **layout 依赖 mode**；`app-focus-panes` 过滤 bottom，
  `app-handle-mouse` 又单独判断 `(slot-state-vid ...)` —— 「底部槽位」的知识有两份。
- `size-warning` 已经产出，但没人显示（状态栏可挂）。

### 1.6 文档生命周期 / 路径表
- `app-paths` + `app-by-path` 两个 hash，**手工双写**（open 写两处，close 删两处）。
- core 的结构操作返回**新 ed**（`editor-add-* / editor-close-*`），就地操作改 box
  （`editor-view-*!`）。两种风格并存，app 必须记得哪些要 `set-app-ed!`。
- `editor-close-document` 之后要修 `edit-vid / focus / bufs`，目前只在 `app-close-path!`
  里做了一次；将来加「关闭缓冲区」命令就会复制这段不变量。
- `app-pick-edit-vid` 依赖 `editor-document-id-list` 的**创建顺序**（未文档化的隐式约定）。

### 1.7 刷新散落
- `app-tree-refresh!` 在 activate/expand/collapse/open/new/delete 里各调一次；
  `app-bufs-refresh!` 在 init/show-view/toggle-left/close/bufs-activate 里各调一次。
  是「手动失效」，不是「按需派生」。

### 1.8 渲染 / face
- face 符号定义散在 `tree.rkt` / `buffers.rkt` / `input-doc.rkt`，
  颜色 `case` 集中在 `tui.rkt`。**加一个 face 要动两处以上**，且没有唯一清单。
- state 文本每变一次（光标移动）就 `editor-view-assign!` **整篇 document**，
  而 core 其实有 `editor-view-change-text` 可做增量（见 §2 P2）。

### 1.9 后端耦合
- `input.rkt` 直接 `(require tui)`，把 app 层绑死在 racket-tui 的事件类型上
  （SKELETON 说这是有意选择，但要记成耦合：换后端 = 改 input.rkt）。

### 1.10 命名 / 杂物
- 模块名 `input-doc.rkt` 现在装的是 **state + input** 两份文档，名不符实。
- `basename` 在 `app.rkt` 和 `tree.rkt` 各有一份。
- `app.rkt` 里曾出现重复的 section header（已清）。

---

## 2. 优化建议（按优先级）

### P0 —— 不动行为、收益最大

1. **把 mode 接进 dispatch（用现成的 (b) 接缝）**
   - `dispatch-tables`: `global + did表 + (mode-tables mode edit-table confirm-table)`；
     或者 dispatch 收一个 `mode` 维度。
   - 删掉 `app-set-input-keys!` / `app-input-did` 和三处退出时的还原。
   - 结果：模态只存在于 `app.mode` 一处；加新模态不用改命令集。
2. **删死代码**：`ctx` 的 editor/width/height、`mode?`、app 侧的 `mode-tables`、重复 header。
3. **pane registry**：用 `role → vid` 的小结构/hash 替掉 `tree-vid/tree-did/bufs-vid/…`，
   did 现推。`app-bufs-exclude` / `app-pick-edit-vid` 改成遍历 registry。
4. **每帧只算一次 layout**：在 `app-prepare!` 里算，缓存进 app（resize / mode / left /
   edit-vid 变化时失效），`ctx` 直接带这个结果；`app-handle-mouse` 复用。

### P1 —— 结构收敛

5. **`paths.rkt`**：封装 `did ↔ path`，open/close 走它，杜绝双 hash 手工同步。
6. **生命周期包装**：`app-close-view!` / `app-close-document!` 统一维护
   `edit-vid / focus / bufs`；`app-close-path!` 变成它的调用者。
7. **`faces.rkt`**：face 符号 + 颜色的单一来源，tui 只查表。
8. **拆 `app.rkt`**（~490 行，现在什么都装）：
   `state.rkt`（struct + 不变量）、`actions.rkt`（打开/关闭/保存/树/缓冲）、
   `commands.rkt`（各表）、`render.rkt`（state-line + prepare）、`app.rkt`（init + 输入）。

### P2 —— 顺手 / 以后

9. **绑定词表支持按字符命令**：给一个 `(key #\y)` 之类的 char 绑定，或让 `'text` 携带字符，
   这样 `y/n` 不必再偷看原始 event。
10. **state 行用 `editor-view-change-text` 增量更新**，别整篇 re-assign。
11. **`size-warning` 挂到 state 行**（空间不足提示）。
12. **prompt 栈化**（SKELETON 已列在「还没定」）——等真需要嵌套再动。

---

## 3. 一个目标骨架（示意）

```
lab-rebuild/
  state.rkt      app 结构 + pane registry + 不变量（不碰命令）
  paths.rkt      did ↔ path
  actions.rkt    唯一改 state 的入口（打开/关闭/焦点/树/缓冲）
  commands.rkt   纯 command-table（含 mode 表）
  dispatch.rkt   global + did + mode  → 跑 handler
  render.rkt     state-line + 每帧 layout（一次）
  app.rkt        init + handle-input（薄壳）
```

原则三条：
- **一个事实只存一处**（mode、路径、pane 身份、layout）。
- **不变量用包装函数守**（关文档 / 切焦点 / 改路径）。
- **纯的继续纯**（layout / tree / buffers / command / mode 不动）。

## 4. 如果只做一件事

选 **P0-1：把 mode 接进 dispatch**。
它是唯一「同一状态存两份 + 三处手工还原」的地方，dispatch.rkt 的设计注释早就为它留了接缝，
单点改动就能消掉一类未来的 bug。
