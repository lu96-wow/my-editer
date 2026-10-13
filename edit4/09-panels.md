# edit4 · 09 面板 / 区域 / 命令序列：与 edit3 的对照

> 把 edit3 的 status / tree / buffers / log 面板、区域（region）、浮窗、以及
> 「正在输入的命令序列」显示，逐项对照到 edit4 的骨架上，并列出还缺什么。

---

## 1. 面板清单

| 面板 | edit3 | edit4 | 状态 |
|---|---|---|---|
| `*status*` 状态栏 | 命令序列 / name+脏+行列 | 命令序列 / name(相对路径)+脏+行列 | ✅ 已同步 |
| `*tree*` 文件树 | enter/导航/新建/删除/hidden/reload/着色 | enter/parent/child/new/delete/reload/hidden/着色 | ✅ 已同步 |
| `*buffers*` 文档管理 | 行模型/fold/enter/new-view/close-view/close-doc/着色 | 行模型/fold/enter/`C-n` 新视图/`C-d` 关视图或关文档/缩进+着色 | ✅ 已同步 |
| `*input*` 输入行 | prompt kind | prompt kind（P2） | ✅ 已同步 |
| `*log*` 日志 | log 面板 + region | log 面板 + region | ✅ 已同步 |

面板都遵循同一骨架：**模型在 `content/`、投影在 `view/`、命令在 `content/*-cmds.rkt`**，
选择行就是面板文档的游标（不另设）。

具体落点：

```
content/
  buffers.rkt        行模型（buffer-rows）
  buffers-cmds.rkt   enter/fold/new-view/buffers-close（C-d 视图/文档二选一）
  region.rkt         面板槽：显隐 / 切换 / 聚焦
                   （日志行存在 content.log，无单独模型模块）
view/
  buffers.rkt        文档管理投影（缩进 + 着色，不加符号）
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

区域**由 `config/layout.rkt` 声明**（纯数据：`(id side size (member ...) active anchor shown?)`），
`boot` 按声明生成底盘（显隐都走 `region-show`，与运行时同一套手术）。改布局 = 改数据：
想 `tree` 到顶部，把 `sidebar` 的 `side` 改 `top`、`size` 改为高度（tree+buffers 一起上顶部）；
只把 tree 单独放顶部，则拆成 `tree` / `buffers` 两条区域。

区域相关键（C-b / C-l / M-b / M-t / Tab）也在 `config/layout.rkt` 的 `region-keys` 里（纯数据：
`(key-pattern scope command-data ...)`，scope 可用 `(region ID)`），**不用改 `content/` 的代码**；
`(region ID)` 作用域由 `content/scopes.rkt` 按区域声明自动生成。所以拆/改名区域时，
只改 `region-specs` + `region-keys` 两处即可。

- 侧栏 `sidebar`：`left <按屏宽算> (*tree* *buffers*)` anchor `root`，默认显示；宽度启动时由 `config/sidebar.rkt` 按屏宽算一次（比例 + 上下限）；隐藏时记住当前（拖过的）宽度，显示回来照旧；C-b 显/隐，M-b 循环，M-t 回 tree。
- 日志区 `log`：`bottom 6 (*log*)` anchor `main`，**默认隐藏**；C-l 显/隐。
- 命令：`region-toggle` / `region-cycle` / `region-activate` / `region-focus`（`content/region.rkt`）。

缺：完整 `(region id)` 作用域（现由区域声明自动生成；编辑区 Tab 循环未加）。

---

## 3. 命令序列显示

edit3：`feature 'keys`，`op-runner` 每次按键 push `binding-label`，进入前缀则保留，
完成/未命中即清；状态栏优先显示它。

edit4：`World.keys`（`listof string`）+ `core/dispatch.rkt` 维护；`view/status.rkt` 显示
`"C-n …"`。规则与 edit3 一致：**进入前缀时累积，跑完非前缀命令或未命中即清**。
（键表数据本身带 `binding-label`。）

---

## 4. 放置选择（placing）—— 已落

打开文件时的目标窗选择：`content/placing.rkt`。

- 规则：**0 个编辑器窗 → 新开；恰好 1 个 → 直放；≥2 个 → 进 placing 让用户选**；
- 状态放 `content.placing`（与 `prompt` 同构）：`vid` 待放置、`prev-focus` 进入前焦点；
- 键（`placing` 作用域）：`Tab` / `M-n` / `M-p` 循环焦点，`Enter` 确认，`Esc` 取消（只清 placing + 回焦）；
  鼠标点编辑器窗 = 切换目标焦点（再 `Enter` 确认）；点面板 / 浮窗则只消费、**不改任何面板状态**；
- `editor` 作用域在 placing 时让位（编辑键不误触）；状态栏显示“选择目标窗口 …”。
- 打开流程（`runtime.rkt` 的 `open-path`）先建/取 doc+view，再 `reveal-or-place-doc!`：
  已显示的文档→聚焦那个窗；否则 `place-vid!`。
- **消费方统一**：文件树 `tree-enter` 与文档管理面板 `buffers-enter` 都经
  `reveal-or-place-doc!` / `reveal-or-place!` 打开（同一条“0 新开 / 1 直放 / ≥2 进 placing”规则），
  不再有面板专用的直放路径。

> `C-t` 边框开关**不做**：edit4 浮窗固定 1 格框，没有每窗边框开关的需求（边框字形在 `view/border.rkt`，几何内缩在 `layout/float.rkt`）。

### 插件（L5 + 边界已全部落地，含 completion / docs）

`plugin.rkt` 契约已补齐到 edit3 的能力槽：
`name / commands / scopes / keymap / panels / regions / decor / prompt-kinds / hooks / services /
 doc-key-matchers / boot / on-open`；`install` fold 进 Environment。详见 `10-plugins.md`。

- **高亮**（`syntax` 关键字/字符串/注释/数字 / `brackets` 深度底色 / `word-color` 同词着色 /
  `words` 当前词 / `bracket-match` 光标配对）是普通 decor 函数（`decor/*.rkt`），由插件包声明；
- **`auto-pair`** 是命令 + 键表覆盖（`plugins/auto-pair.rkt`），后装覆盖 `(text) editor` 同 slot；
- **hooks**：`World.signals` + `core/hook.rkt` 的 `reaction`/`run-hooks`；命令用 `emit!` 发点
  （`after-edit`/`after-insert`/`after-nav`/`focus-changed`/`before-render`/`document-opened`/`job`…）；
- **jobs/services**：`World.jobs` 账本 + `core/job.rkt`；runtime 每帧派发到 worker 池，结果以
  `job-event` 回注，`emit 'job` 给插件；
- **mode**：`core/mode.rkt` matcher → 打开文档时挂 `content.doc-keys`；`dispatch` 先试文档表；
- **插件状态**：`World.store`（`core/store.rkt`，命名空间隔离）；**boot / on-open** 装配末尾 / 开文档时跑。

内置插件在 `plugins/`，`config/plugins.rkt` 只给名字，`plugins/catalog.rkt` 解析成实现。
`demo`（契约演示）与 `async-demo`（service + job 钩子）证明所有槽可用。

- **`completion`**（`plugins/completion.rkt`）：不抢焦点的浮窗菜单；M-/ 开；Up/Down/Tab/Enter/Esc
  用“有菜单则操作菜单、否则回落原行为”的命令接住；打字经 after-insert/after-edit 重筛；
  require 导出用异步 `completion-exports` job，结果由 `job` 钩子回写缓存再开菜单；
  发 `complete-selection` 供 docs 订阅。
- **`docs`**（`plugins/docs.rkt`）：订阅 `complete-selection`（与补全互不 require）；本地定义同步
  显示，标准库/包走异步 `doc` job（`setup/xref` + blueboxes）；M-d 查光标处标识符。
- 纯语言服务在 `plugins/lang/`（source/pool/module-index/local-docs/doc-html/docs，从 edit3 平移）。
- 插件面板需要文档：`view/panel.rkt` 现在是 `(panel name render)`，`boot` 按 Environment 里的
  面板名建文档；浮窗菜单用 `content/float.rkt` 的 `open-overlay`（不抢焦点）。

已对齐 edit3 的键：`(region id)` 作用域（`Tab` 循环侧栏）、新建 `C-n f` / `C-n C-n f`（`prefix-new` 切换）、
去掉多出的 `C-w`（关文档走 buffers `C-d`，脏则询问）。

### 浮窗（已同步）

浮窗是第三种显示位置（不进平铺树，几何由 anchor 决定，画在最上）：
`World.floats` 是 `(listof float)`，顺序 = z；浮窗 id 用**负数**分配，与平铺 id（非负）隔离。

- 命令（`content/float.rkt`）：`float-open` / `float-toggle` / `float-close` / `float-raise` / `float-cycle`；
- 声明（`config/floats.rkt`）：`(name (rel h v dx dy) (w h))`；
- 键：`M-j` 开日志、`M-k` 开树、`M-g` 开关日志；float 作用域 `C-j` 提升 / `Tab` 切换 / `Esc`·`C-d` 关闭；
- 同一 vid 可多位置显示（侧栏的树 + 浮起来的树）；点击浮窗正文也置光标。
- **浮窗有框**：几何归 layout —— `layout/float.rkt` 的 `float-content-rect`（外框四边内缩 1）
  与 `layout/frame.rkt` 的 `frame-float-content-rect`；`view/render.rkt`、`content/pointer.rkt`
  都用**内容矩形**，而 `hit`/移动/拖拽/画框用**外框**。边框字形仍由 `view/border.rkt` 画
  （view 只做 frame→字形，与平铺缝同）。completion/docs 菜单以此为基准。

### 焦点：导航跟着资源走（不做「focus 具名」）

焦点就是**窗口 id**。「聚焦某个具名东西」= **reveal（使其可见 + 聚焦其窗口）**，
由资源的子系统拥有，而不是给 focus 加一层名字：

- 面板（region 成员）→ `region-activate` + `region-focus`；
- 文档 → `placing` 的 `reveal-or-place!` / `reveal-or-place-doc!`（多窗时进 placing）；
- 编辑器 → `content/focus.rkt` 的 `focus-editor`（M-e）。

理由：中心化的 `focus <name>` 会与 region / reveal 重复「可见性」逻辑；按 vid 查窗口
还是多义的（同一 vid 可在多窗口/浮窗）。core 的 `focus` 现在只接受 `next/prev`、方向、
**合法 id**；其它目标直接让位（不再把焦点设成垃圾值）。浮窗的 reveal = `float-open`（已在则提到最上）。
（方向焦点仍是 `focus` 的能力，但按 edit3 不再绑 `M-方向`。）

---

## 5. 与设计骨架的一致性

- 三个面板都遵守 **project 纯 / commit 集中**：投影只读 World，写回只在 `commit-panels!`。
- 区域是 `content` 的一个**类型化切片**（`content-regions`），命令做布局手术（insert/remove）+ 换 vid。
- 命令序列是 `World` 的一等字段（像 `prefix`），由 `dispatch` 维护，投影只读。
- 没有新增「面板注册表」之类标签层：面板就是 `World -> 投影` 的函数（见 07）。
