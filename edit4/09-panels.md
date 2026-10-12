# edit4 · 09 面板 / 区域 / 命令序列：与 edit3 的对照

> 把 edit3 的 status / tree / buffers / log 面板、区域（region）、浮窗、以及
> 「正在输入的命令序列」显示，逐项对照到 edit4 的骨架上，并列出还缺什么。

---

## 1. 面板清单

| 面板 | edit3 | edit4 | 状态 |
|---|---|---|---|
| `*status*` 状态栏 | 命令序列 / name+脏+行列 | 命令序列 / name(相对路径)+脏+行列 | ✅ 已同步 |
| `*tree*` 文件树 | enter/导航/新建/删除/hidden/reload/着色 | enter/parent/child/new/delete/reload/hidden/着色 | ✅ 已同步 |
| `*buffers*` 文档管理 | 行模型/fold/enter/new-view/close-view/close-doc/着色 | 同左 | ✅ 已同步 |
| `*input*` 输入行 | prompt kind | prompt kind（P2） | ✅ 已同步 |
| `*log*` 日志 | log 面板 + region | log 面板 + region | ✅ 已同步 |

面板都遵循同一骨架：**模型在 `content/`、投影在 `view/`、命令在 `content/*-cmds.rkt`**，
选择行就是面板文档的游标（不另设）。

具体落点：

```
content/
  buffers.rkt        行模型（buffer-rows）
  buffers-cmds.rkt   enter/fold/new-view/close-view/close-doc
  region.rkt         面板槽：显隐 / 切换 / 聚焦
                   （日志行存在 content.log，无单独模型模块）
view/
  buffers.rkt        文档管理投影（▾/▸/●/· + 着色）
  status.rkt         状态栏（含命令序列）
  tree.rkt           文件树投影
  log.rkt            日志投影
```

---

## 2. 区域（region）

edit3：`region(id side size members anchor)`，成员互斥显示；支持
show/hide（布局手术）、activate/cycle（换成员）、focus。

edit4：`region(side size members active anchor wid)`——支持
show/hide（布局手术：`insert-side` / `insert-adjacent` / `remove-leaf`）、activate/cycle、focus。

- 侧栏 `sidebar`：`left 28 (*tree* *buffers*)` anchor `root`，默认显示；C-b 显/隐，M-b 循环，M-t 回 tree。
- 日志区 `log`：`bottom 6 (*log*)` anchor `main`，**默认隐藏**；C-l 显/隐。
- 命令：`region-toggle` / `region-cycle` / `region-activate` / `region-focus`（`content/region.rkt`）。

缺：`(region id)` 作用域（edit3 的 Tab 循环用）。

---

## 3. 命令序列显示

edit3：`feature 'keys`，`op-runner` 每次按键 push `binding-label`，进入前缀则保留，
完成/未命中即清；状态栏优先显示它。

edit4：`World.keys`（`listof string`）+ `core/dispatch.rkt` 维护；`view/status.rkt` 显示
`"C-n …"`。规则与 edit3 一致：**进入前缀时累积，跑完非前缀命令或未命中即清**。
（键表数据本身带 `binding-label`。）

---

## 4. 还缺什么（按骨架落点）

| 缺口 | edit3 落点 | edit4 应落在 |
|---|---|---|
| **placing**（多窗打开时选目标） | placing 状态机 | `World` 一个模式字段 + prompt 类似流程（工程量大） |
| **边框开关** `C-t border-toggle` | 每窗口 border | `content` 每窗 border 标注 + `view/border` 读取 |
| **异步插件内容**（completion/docs） | plugins | 基础设施已就位（见下），只差把两个插件搬过来 |

**优先级建议**：边框开关 `C-t` → placing → completion / docs。

### 插件（L5 + 边界已落地）

`plugin.rkt` 契约已补齐到 edit3 的能力槽：
`name / commands / scopes / keymap / panels / regions / decor / prompt-kinds / hooks / services /
 doc-key-matchers / boot / on-open`；`install` fold 进 Environment。详见 `10-plugins.md`。

- **高亮**（`brackets` 深度底色 / `words` 当前词 / `bracket-match` 光标配对）是普通 decor 函数
  （`decor/*.rkt`），由插件包声明；
- **`auto-pair`** 是命令 + 键表覆盖（`plugins/auto-pair.rkt`），后装覆盖 `(text) editor` 同 slot；
- **hooks**：`World.signals` + `core/hook.rkt` 的 `reaction`/`run-hooks`；命令用 `emit!` 发点
  （`after-edit`/`after-insert`/`after-nav`/`focus-changed`/`before-render`/`document-opened`/`job`…）；
- **jobs/services**：`World.jobs` 账本 + `core/job.rkt`；runtime 每帧派发到 worker 池，结果以
  `job-event` 回注，`emit 'job` 给插件；
- **mode**：`core/mode.rkt` matcher → 打开文档时挂 `content.doc-keys`；`dispatch` 先试文档表；
- **插件状态**：`World.store`（`core/store.rkt`，命名空间隔离）；**boot / on-open** 装配末尾 / 开文档时跑。

内置插件在 `plugins/`，`config/plugins.rkt` 只给名字，`plugins/catalog.rkt` 解析成实现。
`demo`（契约演示）与 `async-demo`（service + job 钩子）证明所有槽可用。

还差的是把 **completion / docs** 搬过来（它们要用上面全部基础设施）。

已对齐 edit3 的键：`(region id)` 作用域（`Tab` 循环侧栏）、新建 `C-n f` / `C-n C-n f`（`prefix-new` 切换）、
去掉多出的 `C-w`（关文档只走 buffers `Del`）。

### 浮窗（已同步）

浮窗是第三种显示位置（不进平铺树，几何由 anchor 决定，画在最上）：
`World.floats` 是 `(listof float)`，顺序 = z；浮窗 id 用**负数**分配，与平铺 id（非负）隔离。

- 命令（`content/float.rkt`）：`float-open` / `float-toggle` / `float-close` / `float-raise` / `float-cycle`；
- 声明（`config/floats.rkt`）：`(name (rel h v dx dy) (w h))`；
- 键：`M-j` 开日志、`M-k` 开树、`M-g` 开关日志；float 作用域 `C-j` 提升 / `Tab` 切换 / `Esc`·`C-d` 关闭；
- 同一 vid 可多位置显示（侧栏的树 + 浮起来的树）；点击浮窗正文也置光标。

### 焦点：导航跟着资源走（不做「focus 具名」）

焦点就是**窗口 id**。「聚焦某个具名东西」= **reveal（使其可见 + 聚焦其窗口）**，
由资源的子系统拥有，而不是给 focus 加一层名字：

- 面板（region 成员）→ `region-activate` + `region-focus`；
- 文档 → `lifecycle` 的 `show-doc!` / `show-view!`；
- 编辑器 → `content/focus.rkt` 的 `focus-editor`（M-e）。

理由：中心化的 `focus <name>` 会与 region / show-doc! 重复「可见性」逻辑；按 vid 查窗口
还是多义的（同一 vid 可在多窗口/浮窗）。core 的 `focus` 现在只接受 `next/prev`、方向、
**合法 id**；其它目标直接让位（不再把焦点设成垃圾值）。浮窗的 reveal = `float-open`（已在则提到最上）。
（方向焦点仍是 `focus` 的能力，但按 edit3 不再绑 `M-方向`。）

---

## 5. 与设计骨架的一致性

- 三个面板都遵守 **project 纯 / commit 集中**：投影只读 World，写回只在 `commit-panels!`。
- 区域是 `content` 的一个**类型化切片**（`content-regions`），命令做布局手术（insert/remove）+ 换 vid。
- 命令序列是 `World` 的一等字段（像 `prefix`），由 `dispatch` 维护，投影只读。
- 没有新增「面板注册表」之类标签层：面板就是 `World -> 投影` 的函数（见 07）。
