# edit4 · 08 资源管理模型（设计稿）

> 范围：把 edit3 的「文件树 + 文件 IO + 文档/视图生命周期」迁到 edit4。
> 核心不是某个功能，而是一套**资源管理模型**：资源怎么表示、谁拥有、何时释放、
> 怎么和外部（文件/目录）保持一致、IO 怎么放到边缘。
> 本文只设计，不写实现。

---

## 0. 一个判据先立住：权威在内存，还是在外部

所有资源分两类，规则不同：

| 类型 | 权威 | 例子 | 不一致时叫 | 动词 |
|---|---|---|---|---|
| **工作副本** working copy | 内存 | document | **脏**（dirty） | persist（save） |
| **派生缓存** derived cache | 外部 | tree（目录）、face、exports | **过期**（stale） | refresh（重读） |

- 工作副本：内存是真相，外部只是存储 → 脏 = `saved-handle ≠ current-handle`；释放前要防丢。
- 派生缓存：外部是真相，内存只是快照 → 过期 = 缓存键/源变了；只读、不 persist。

这条判据决定一个资源是「脏」还是「过期」，是 `save` 还是 `refresh`——后面所有动作由它推出。

---

## 1. 资源清单与归属

| 资源 | 身份 | 内存表示 | 外部来源 | 归属 | 权威 |
|---|---|---|---|---|---|
| document | `did` | engine document | 文件? | `content.ed` + `content.docs` | 内存 |
| view | `vid` | engine view（point/scroll） | — | `content.ed` + `content.bindings` | 内存 |
| window↔view 绑定 | layout id | `content.bindings : id→vid` | — | `content` | 内存 |
| panel | `name→vid` | engine document（不可编辑） | — | `content.panels` | 派生（投影） |
| directory tree | `root` | `content.tree` | 目录 | `content` | 外部 |
| face | `(did,handle,cursor)` | runtime 缓存 | document | runtime | 派生 |
| job（异步，P3） | `id` | pending/done | service | World 的切片 | 派生 |

归属沿用现有分层：可变状态进 `content`（World 的切片）；派生缓存进 runtime；只读配置进 Environment。

---

## 2. 生命周期动词（统一语义，**不做通用类型**）

每个资源用同一套动词描述，但**状态类型各自具体**，不建通用 `resource` 结构：

- **acquire**：从源装载/新建，得到句柄（doc/view）。
- **release**：释放句柄，并清掉所有引用（绑定/视图）。
- **persist**：写回源（只有工作副本有）。
- **refresh**：重读源（只有派生缓存有）。
- **derive**：纯投影出显示/下一层缓存。

> 反模式：把 doc / tree / job 塞进一个 `resource(id, kind, state, …)` 的万能表。
> 状态类型不同、生命周期不同，硬统一只会多一层解释器。共享的是**词汇和规则**，不是类型。

---

## 3. 文档资源（工作副本）

身份三层：`did`（文档）→ `vid`（视图）→ window id（布局叶子）。

- **acquire**
  - new：`content-add-doc! c text name #f`。
  - open：先 `content-doc-by-path c path` **复用**（一个路径只有一个 doc）；没有才读文件 → acquire。
  - 视图：`content-add-view! c did`；窗口绑定：`content-bind c id vid`。
- **persist**：`save` 写文件 + `doc-save-mark!`（saved ← 当前 handle）。
- **release**（三步，从外到内）
  - 关窗口：只 `content-unbind`（view 保留，可再显示——buffers 需要）。
  - 关视图：解绑 + `content-remove-vid`（释放 engine view）。
  - 关文档：释放其全部视图 + 解绑所有窗口 + 删元数据；焦点回退。
  - dirty 保护：release 脏文档前 → prompt（P2，见 §6）。
- **一致性**：同一 doc 的所有视图共享 engine 文本；脏永远由 handle 比较，不 diff 文本。

现状差距：`content-close-doc!`/`content-remove-vid` 已有；缺 `content-doc-by-path` 与「open 复用」。
`runtime` 目前每次 `open` 都新建 doc——迁移时改为「复用或新建」。

---

## 4. 文件树资源（派生缓存）

树是**目录的缓存**，不是文档。状态全部在 `content.tree`：

```racket
(struct tree (root expanded children show-hidden?) #:transparent)
;; root         : 绝对路径
;; expanded     : dir -> #t
;; children     : dir -> (listof (cons path dir?))   目录快照
;; show-hidden? : 是否显示 . 开头项
```

- **纯操作**（`content/tree.rkt`，无 IO）：
  `tree-toggle-dir / tree-expand-dir / tree-parent-dir / tree-refresh / tree-toggle-hidden / tree-rows`
- **IO**：`tree-ensure`（读缺失/展开目录）。只在 **boot / reload 时**跑，不在每帧投影里。
- **交互命令**（`content/tree-cmds.rkt`，只产 effect / 改 content）：
  `enter`（文件→open，目录→toggle）、`new-file`/`new-dir`/`delete`（prompt→effect）、
  `reload`、`toggle-hidden`、`move-parent`/`move-child`（面板光标行导航）。
- **投影**（`view/tree.rkt`，纯）：`tree-rows` + 「已打开文件」着色 + 目录尾 `/`。
- **与文档资源的关系**：`enter` 文件走 §3 的 acquire（复用）；`open-paths` 给树着色；
  `tree-relative-path` 给状态栏/树显示相对路径。

「选择行」不另设游标：树面板就是一个 document，`view-line` 即当前行（edit3 的既定做法）。

---

## 5. IO 边界

**一切 IO 是数据（effect），runtime 在唯一边缘解释。命令/Prompt 只产出 effect。**

effect 集合（在现有基础上补齐）：

```racket
(struct quit-effect ())          (struct log-effect (msg))
(struct open-file (path))        (struct save-file (path text))
(struct make-file (path))        (struct make-dir (path))     (struct delete-path (path))
(struct reload-tree ())          ;; 清缓存 + 重读根/展开目录
```

解释规则（runtime）：

| effect | 解释 | 产出新 World? |
|---|---|---|
| `open-file` | 复用同路径 doc，否则读文件并 acquire；绑定焦点窗 | 是 |
| `save-file` | 写文件（错误 → log） | 否 |
| `make-file`/`make-dir`/`delete-path` | 改文件系统（错误 → log） | 否 |
| `reload-tree` | `tree-refresh` + `tree-ensure` | 是 |
| `log` / `quit` | 打印 / 关闭 | 否 |

- **为什么 effect 是「资源请求」而不是裸 `read/write`**：`open-file` 语义清楚（装载并显示），
  与 `save-file`/`reload-tree` 对称；边缘顺带做 acquire/refresh 这些领域动作。
  （备选是 `read-file`/`write-file` 裸 IO，把 acquire 也放边缘；收益不明显，反而多一步，暂不采纳。）
- **错误**：IO 异常一律转成 `(log …)`，绝不把异常抛进 `step`（step 只有 World 与 effect）。
- **可测**：effect 是数据，脚本化后端/测试可断言 effect 序列，不真碰盘（或只在边缘碰）。

---

## 6. Prompt（P2 才需要，但模型先定）

需要 prompt 的场景：`new-file`/`new-dir`/`delete` 的参数与确认、关脏文档、退出。

- 输入行就是 `*input*` 面板文档；「答案」从该视图 `view-line` 取（一切皆 document）。
- 状态放 `content` 的一个切片（类比 core 的 `prefix`，但属于内容域）：

```racket
(struct prompt (wid label kind data prev-focus) #:transparent)
;; kind : new-file | new-dir | delete | close-doc | quit
```

- `kind → handler` 是**数据注册表**（Environment）：`handler : prompt → (values world effects)`。
  handler 只产出 effect（make/delete/save/close），不做 IO。
- 打开 prompt：把状态栏窗的 vid 临时指向 `*input*`；取消/提交后换回。

本轮 P1 不依赖 prompt：`enter`/`toggle`/`reload`/`toggle-hidden` 都不需要。

---

## 7. 异步（P3 留位，本轮不做）

重 IO（模块导出、标准库文档）应走 job/service：

- `job(id, kind, payload, tag)`；`service = kind → (payload → result)`。
- 记账（pending/done）放 World 的切片；worker 结果以 `job-event` **合流进事件源**，
  回到 `dispatch`，由按 kind 注册的 result handler 应用成新 World。
- runtime 需要一个「后端事件 ⊕ job 结果」的统一事件源（edit3 用 channel + 输入线程）。
- 文件树的目录读 **先同步在边缘**；将来把 `reload-tree`/`read-dir` 换成 job 即可，接口不变。

---

## 8. 模块与文件划分

```
content/
  fs.rkt          文件系统原语（+ make-file / make-dir / delete）
  model.rkt       content 值 + doc/view/binding/panel/tree 访问器 + close
  tree.rkt        tree 状态 + 纯操作 + tree-ensure + rows
  tree-cmds.rkt   文件树交互命令（enter/new/delete/reload/hidden/nav）
  prompt.rkt      输入行状态 + kind 注册表（P2）
  edit.rkt files.rkt commands.rkt   编辑 / 文件 / 装配（沿用）
view/
  tree.rkt        文件树投影（rows → text+faces）（沿用）
core/
  effect.rkt      effect ADT（+ make/delete）
runtime.rkt       解释 effect；刷 tree；（P3）合流 job
```

---

## 9. 迁移分期

- **P1（无 prompt，本轮）** ✅ 已落地
  1. `fs.rkt` 补 `make-file`/`make-dir`/`delete`。
  2. `tree.rkt` 补 `show-hidden?` 与纯操作 `toggle-dir`/`expand-dir`/`parent-dir`/`refresh`/`toggle-hidden`。
  3. `model.rkt` 补 `content-doc-by-path`/`content-doc-paths`/`content-show`/`content-editor-window`；
     `runtime` 的 `open-file` 改为「复用同路径 doc 或新建」，并落到**编辑器窗口**（不是面板窗）。
  4. `tree-cmds.rkt`：`enter`（open/toggle）、`reload`、`toggle-hidden`、`parent`/`child`。
  5. `view/tree.rkt`：目录尾 `/` + 已打开着色 + hidden。
  6. `scopes.rkt`：`editor` / `(panel "*tree*")` 作用域；键表按作用域拆分。
  → 结果：文件树可展开/导航/开文件/刷新；同路径文件只开一个 doc。
  （`fs` 的 make/delete 已就位，命令与 effect 留到 P2 配 prompt。）
- **P2（prompt）**：输入行 + `new-file/new-dir/delete/close-doc/quit`。
- **P3（异步）**：job/service + 事件合流；重 IO 上移到 worker。

---

## 10. 反模式（与 07 组合原则一致）

- **不建通用 `resource` 类型/注册表**：状态类型各自具体，只共享动词与规则。
- **不在投影里做 IO**（`view/tree.rkt` 只读 `content.tree`）。
- **不让命令做 IO**（命令只产出 effect，IO 在 runtime）。
- **不把缓存/脏做成标签**：handle 就是版本号，直接比较（`saved-handle`、`tree-children` 缓存键）。
- **不为一次性动作加抽象层**：够用就停（见 07）。

---

## 11. 需要拍板的点

1. **effect 粒度**：采纳「资源请求」（`open-file`/`save-file`/`make-file`…），还是裸 `read-file`/`write-file`？
   （本文建议前者：语义清晰、与现有代码一致。）
2. **prompt 状态归属**：放 `content` 切片（本文建议，内容域），还是 World 一等字段（像 `prefix`）？
3. **P3 是否现在就定事件合流**：还是等真正需要异步（docs/completion）时再设计 runtime？
4. **tree 目录读是否要异步**：先同步（P1），还是一开始就 job？
