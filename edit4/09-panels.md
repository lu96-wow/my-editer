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
| **浮窗** M-j/M-k/M-g（log/tree/buffers） | floats + `float-open` | `layout/float.rkt` 已有；需 `content` 锚定 + 键表 + 状态栏 |
| **placing**（多窗打开时选目标） | placing 状态机 | `World` 一个模式字段 + prompt 类似流程（工程量大） |
| **边框开关** `C-t border-toggle` | 每窗口 border | `content` 每窗 border 标注 + `view/border` 读取 |
| **`(region id)` 作用域** | Tab 循环成员 | `content/scopes.rkt` 增一个 scope |
| **插件面板**（completion/docs/brackets/auto-pair） | plugins | `plugin` 数据包（L5）——插件机制尚未落地 |

**优先级建议**：浮窗 → `(region id)` 作用域 → placing / 边框 / 插件面板。

### 焦点：导航跟着资源走（不做「focus 具名」）

焦点就是**窗口 id**。「聚焦某个具名东西」= **reveal（使其可见 + 聚焦其窗口）**，
由资源的子系统拥有，而不是给 focus 加一层名字：

- 面板（region 成员）→ `region-activate` + `region-focus`；
- 文档 → `lifecycle` 的 `show-doc!` / `show-view!`；
- 编辑器 → `content/focus.rkt` 的 `focus-editor`（M-e）。

理由：中心化的 `focus <name>` 会与 region / show-doc! 重复「可见性」逻辑；按 vid 查窗口
还是多义的（同一 vid 可在多窗口/浮窗）。core 的 `focus` 现在只接受 `next/prev`、方向、
**合法 id**；其它目标直接让位（不再把焦点设成垃圾值）。

---

## 5. 与设计骨架的一致性

- 三个面板都遵守 **project 纯 / commit 集中**：投影只读 World，写回只在 `commit-panels!`。
- 区域是 `content` 的一个**类型化切片**（`content-regions`），命令做布局手术（insert/remove）+ 换 vid。
- 命令序列是 `World` 的一等字段（像 `prefix`），由 `dispatch` 维护，投影只读。
- 没有新增「面板注册表」之类标签层：面板就是 `World -> 投影` 的函数（见 07）。
