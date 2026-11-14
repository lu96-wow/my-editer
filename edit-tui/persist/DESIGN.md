# 编辑器状态缓存（`.editdata`）设计

状态：完整设计草案。§16 的最小版本已落地（`persist/io.rkt` / `persist/minimal.rkt` / `host/persist.rkt`）。
目标不是把 Racket 对象图直接存盘，而是把**语义状态**序列化成稳定的纯数据，
下次启动时按固定顺序重建 engine / layout / plugin-state。

默认目录：

```text
<workspace-root>/.editdata/
```

---

## 0. 结论：能不能做

**能做。** 但要先承认 edit 的状态不是“一个可序列化的 app-state”：

1. `editor-core` / `editor-session` 是纯值，大部分能直接转成 S-expression；
2. `engine` 才是真正的可变对象图（buffer / view / history / document），里面有
   gensym、box、mutable struct、face 轨、readonly 轨、开放槽；
3. `plugin-states` 是 opaque 值，里面既可能有纯数据，也可能有 procedure
   （如 bilingual 的 `translator`）、timer-id / job-id、引擎版本 token；
4. `editor` 实例上还有 host 缓存（source-store / workspace）、timer / job runtime，
   这些都不是 State，也不应该进缓存。

所以不能做“把 `app-state` 和 `engine` 直接 `serialize`”。正确做法是：

```text
snapshot：engine + state  ->  纯数据（schema 化）
restore ：纯数据          ->  engine + state（按依赖顺序重建）
```

并且把状态分四类：

| 类别 | 例子 | 策略 |
|---|---|---|
| durable | 用户 buffer 文本、打开的 resource、layout、view 光标、filetree 展开、bilingual pair | 存盘并恢复 |
| derivable | 语法着色、workspace analysis、source-store、resources 行、status、UI 文本 | 不存，启动后重算 |
| presentation cache | filetree 上次 rows、docs 面板内容 | 可选存，先显示再刷新 |
| ephemeral | pending 键序列、flash、拖拽、placement、input modal、job ledger、timer、异步请求 | 不存，启动时清空 |

**可以做到“下次打开和关闭时看起来一样”**，前提是接受下面这些**必须丢失**的东西：

- 正在执行的异步 job / timer（关掉时未完成的翻译、补全、workspace 分析不会跨进程继续）；
- 按键前缀、flash、鼠标拖拽、半途的输入栏 / placement；
- 依赖 engine 对象身份的 token（document version、job-id、timer-id）；
- 插件里的 procedure（translator、hook、command table）；
- `screen`（终端尺寸由下一次终端决定，不能让旧尺寸覆盖新终端）。

undo/redo 历史可以恢复，但它不是“免费”的：见 §8。第一版建议先不做，后续按上限做。

---

## 1. 目标 / 非目标

### 目标

- 正常退出后再次启动，恢复：
  - 打开的 resource（路径、名称、mode、dirty 状态）；
  - 所有用户 buffer 文本（包括未保存修改）；
  - 每个 view 的光标 / 选区 / 视口（行列、wrap/clip、行号）；
  - layout 树、split 比例、panel 的 views / active / fixed / hidden / focus；
  - 多编辑区 `areas` / `current-area` / `area-slot`；
  - filetree 的展开集合、dotfile 可见性、当前行、查找 query；
  - docs 面板内容；
  - bilingual pair（源、mirror、翻译器 id/version、mirror 文本与 face）；
  - 可选：find 会话、error log、undo/redo。
- 快照损坏 / 旧版本 / 插件缺失时，**降级启动**，不阻塞编辑器启动。
- 写盘原子化，避免半写文件把上一次好快照覆盖掉。

### 非目标

- 不缓存磁盘文件内容来替代文件系统；`.editdata` 只保存“当前会话”。
- 不做跨进程恢复 job / timer / 线程 / channel。
- 不把编辑器变成“共享项目配置”工具；默认只是本机会话缓存。
- 不保证跨版本、跨插件版本的 opaque 插件 state 100% 兼容；插件 codec 自己负责版本。
- 不做实时协同 / 多实例共享同一 `.editdata`。

---

## 2. 状态清单与可序列化评估

### 2.1 `editor-core`

| 字段 | 当前值 | 可序列化 | 恢复策略 |
|---|---|---|---|
| `workspace-root` | 绝对路径 / `#f` | 是 | 存相对标记；加载时用当前工作目录作为 root |
| `resources` | `resources` struct | 部分 | 存 id / doc-id / path / name / views / mode / saved 信息；`command-stack` 由 mode 重建 |
| `layout` | split tree + panel-map | 是 | 存树 + panel 字段；加载时校验、裁剪、fallback |
| `areas` | area-id -> `editor-area` | 是 | 存 layout + focus；加载时校验 |
| `current-area` | 数字 / `#f` | 是 | 存；不存在则回 1 |
| `area-slot` | parent split-id + side | 是 | 存；父 split 不存在时重新计算 / 禁用多 area |
| `layout-config` | `layout-config` 纯值 | 是，但不应存 | 由 `config/layout/default.rkt` 重建；以后可存 config id |
| `view-scopes` | view-id -> scope | 是，但不应存 | 由插件 `#:view-scopes` 重建 |
| `screen` | rect | 是，但不应存 | 下一次终端 resize 决定 |
| `next-view-id` | int | 是 | 存；同时按所有 doc/view id 的 max+1 校正 |
| `next-panel-id` | int | 是 | 存；同时按数字 panel id max+1 校正 |

### 2.2 `editor-session`

| 字段 | 可序列化 | 策略 |
|---|---|---|
| `pending` / `pending-scope` | 是 | **不存**：半截键序列没有意义 |
| `quit?` | 是 | 不存 |
| `flash` | 是 | 不存 |
| `modal` | 是 | 不存：不恢复 input / placement |
| `input` | 大多可存 | 默认不存 active / seed；避免启动时出现半截 prompt |
| `pointer` | 是 | 不存：拖拽 / 选择拖拽是瞬时状态 |
| `find` | 是 | 可选存 query / target-vid / index；matches 按文本重算 |
| `jobs` | 结构可存，语义不可 | **不存**：job-id / 结果都只属于当前进程 |
| `errors` | 大多可存 | 可选；`context` 需 sanitize 成可打印纯数据 |
| `async?` | 是 | 不存：由 host 启动参数决定 |

### 2.3 engine（真正的对象图）

| 对象 | 字段 | 可序列化性 | 策略 |
|---|---|---|---|
| user doc | doc-id / name / text | 是 | 存文本 / 名字 / id |
| user doc | history | 文本可存，document 对象不可 | 可选：存文本历史快照；见 §8 |
| user doc | face / readonly | 是，但大 | 用户文档的 face 由 racket-color 重算；不存 |
| user doc | 开放槽 | opaque | 当前未使用；如果以后使用，需要每个槽自己的 codec |
| user view | selections | 是 | 存 anchor/head 列表 + primary index |
| user view | viewport | 是 | 存 mode / line-numbers? / top-line / top-segment / left-column |
| user view | width / height | 是，但派生 | 不存；由 `panels-sync!` 从 panel 写回 |
| UI doc | text / face / readonly | 是，但派生 | 不存；启动 / 每帧由 host 重新投影 |
| UI view | selections / viewport | 是 | 存；文本重建后 clamp |
| UI view | width / height | 派生 | 不存 |
| derived doc | text | 是 | 由 owner 插件 codec 决定；bilingual 存 mirror |
| derived doc | meta（owner / source-doc-id / edit-policy） | 是 | 跟随 derived doc 一起存 |
| derived doc | face | 是 | 跟随 owner 插件 / derived 记录存 |
| engine caches | `projection-cache` / `face-track-cache` / `derived-projection-cache` | 是，但派生 | 不存，启动后重建 |

### 2.4 插件状态

| 插件 | 当前状态 | 可序列化 | 建议 |
|---|---|---|---|
| `pair` | `#t` | 是 | 存 `#t` |
| `indent` | `#t` | 是 | 存 `#t` |
| `layout` | `#t` | 是 | 存 `#t` |
| `racket-color` | doc-id -> `color-entry(version, color-state, face-track)` | 纯值但含版本 token / 大缓存 | **不存**；sync 重算 |
| `filetree` | root / expanded / show-hidden / rows / find 状态 | 大多可存 | 存 root / expanded / show-hidden / rows（可选）/ find-query；其它重置 |
| `resources` | view / rows | rows 是派生 | 不存 rows；启动 sync 重算 |
| `completion` | 菜单 / candidates / request-id / timer-id | 部分是纯值但全是瞬时 | 不存；恢复为 closed |
| `docs` | lines / faces / name / request-id | lines/name 可存，request-id 不可 | 存 lines + name；faces 由 lines 重算；request-id `#f` |
| `workspace` | requests（timer-id / job-id） | 结构可存，语义不可 | **不存**；恢复为空 request |
| `bilingual` | translator（含 procedure）/ lexicon / pairs | 只有纯数据部分可存 | codec：存 translator id + version、lexicon、pair 元数据 + mirror 文本/face；procedure 由代码重建 |

### 2.5 host 侧（不进 State，也不应该存）

| 对象 | 策略 |
|---|---|
| `editor.sources`（source-store） | 启动后由 `source-sync!` 从 resource 重建 |
| `editor.workspace`（analysis 缓存） | 启动后由 `workspace-sync!` 重建 |
| `editor.timer-service` / timer runtime | 重新创建；旧 timer-id 全部作废 |
| job runtime / worker / channel | 重新创建；旧 job 全部作废 |
| `command-table-cache` | 重新建 |
| theme / tui 样式 | 由启动代码重新安装 |

---

## 3. 核心原则

1. **只存语义，不存对象图。**
   存 “text / id / point / rect / path / symbol”，不存 `buffer` / `view` / `document` /
   `history` / `face-track` 对象。
2. **只存稳定 ID。**
   doc-id / view-id / panel-id / area-id / split-id / resource-id 可以存；
   document version、job-id、timer-id、gensym 不能存。
3. **派生状态默认不存。**
   color / workspace / source-store / resources rows / status 都在加载后重算。
   为了第一帧观感，可以存“presentation cache”（filetree rows、docs lines），但必须
   标成 cache，失败可以丢弃。
4. **异步工作不跨进程。**
   保存时忽略 job ledger / timer；恢复时把依赖异步过程的插件状态归一化
   （completion closed、filetree stale、workspace empty、bilingual force-full）。
5. **插件自己负责自己的 state codec。**
   core / host 不猜测 opaque `ps` 的内部结构。
6. **快照是 generation，不是一堆散文件。**
   先写完整 generation，再原子切换 `CURRENT`；任何时刻只读到一个完整快照。
7. **损坏 / 旧版本不能阻止启动。**
   校验失败 -> 备份旧目录 -> 用空会话启动，记录错误。
8. **路径尽量相对 workspace root。**
   `.editdata` 跟着项目移动时，路径仍然可解析。

---

## 4. `.editdata` 目录与文件格式

### 4.1 目录

```text
.editdata/
  CURRENT                         ; 文本：当前 generation 目录名
  LOCK                            ; 可选：单实例锁
  .gitignore                      ; 内容 "*"：默认不提交会话缓存
  gens/
    20241114T101500Z-12345/
      meta.rktd                   ; schema / 生成时间 / 版本
      session.rktd                ; layout / areas / resources / views / plugin meta
      buffers/
        10.rktd                   ; 一个 user buffer（文本 / 可选 history）
        11.rktd
      derived/
        12.rktd                   ; 一个 plugin-owned derived doc
  corrupt/                        ; 损坏快照的备份（可选）
```

- `CURRENT` 里写 generation 目录名，例如 `20241114T101500Z-12345`。
- 写盘顺序：新 generation 写完整 -> `CURRENT.tmp` -> `rename` 到 `CURRENT`。
- 保留最近 2 个 generation；旧的安全删除。
- `buffers/` / `derived/` 可以按文件硬链接上一代未变化的文件，减少重复写。
- 权限：Unix 下目录 `#o700`、文件 `#o600`；里面可能有未保存源码和项目词表。

### 4.2 格式：纯 S-expression，不用 `racket/serialize`

推荐用 `write` / `read` 的纯数据形式：

```racket
;; 允许：symbol / string / number / boolean / list / vector / hash（只用 alist 更好）
;; 禁止：procedure / port / thread / channel / exn / box / mutable struct / gensym
```

**不要用 `racket/serialize`。**
原因：

- 它会把 struct 类型、代码依赖、可变对象一起带进来，跨版本非常脆弱；
- 恢复时可能实例化任意 struct；
- 我们的状态里本来就有 procedure / timer / job / gensym，serialize 也处理不了。

读取时关闭 reader 的求值功能：

```racket
(parameterize ([read-accept-reader #f]
               [read-accept-lang #f]
               [read-accept-compiled #f])
  (read port))
```

然后自己校验结构。`.editdata` 可能位于共享仓库里，不能把 `#.` / `#lang` 当成可信输入。

### 4.3 示例（节选）

```racket
;; meta.rktd
((format . edit-session)
 (schema . 1)
 (generated-at . 1731579300)
 (workspace-root . ".")
 (root-marker . "workspace"))

;; session.rktd
((workspace-root . ".")
 (current-area . 1)
 (area-slot (parent . 4) (side . right))
 (next-view-id . 42)
 (next-panel-id . 120)
 (layout . <layout>)
 (areas . ((2 . <area>) (3 . <area>)))
 (resources . (<resource> ...))
 (views . (<view> ...))
 (derived . (<derived> ...))
 (plugins . ((filetree . <payload>) (bilingual . <payload>)))
 (session (find . <find>) (errors . <errors>)))

;; <resource>
(resource
 (id . 10) (doc-id . 10)
 (path (kind . workspace) (value . "src/main.rkt"))
 (name . "main.rkt")
 (views . (10 11))
 (mode . racket)
 (saved (hash . "...sha1...") (dirty? . #f))
 (disk (mtime . 1731579000) (size . 8321)))

;; <view>
(view
 (id . 10) (doc . 10) (kind . user)
 (selections (primary . 0)
             (items . (((anchor 4 2) (head 4 8))
                       ((anchor 9 0) (head 9 0)))))
 (viewport (mode . clip) (line-numbers? . #f)
           (top-line . 0) (top-segment . 0) (left-column . 0)))

;; <layout>
(layout
 (root (split (id . 1) (axis . lr) (ratio . 1/2)
              (left (leaf . editor))
              (right (leaf . docs))))
 (panels
  ((id . editor) (kind . editor)
   (views . (10 11)) (active . 10)
   (fixed-w . #f) (fixed-h . #f) (hidden? . #f)
   (restore . #f)
   (borders . (up down left right)) (face . window-border) (weight . 0))
  ...)
 (focus . editor)
 (next-split-id . 2))
```

`<layout>` / `<panel>` / `<rect>` 全部用 tagged list，避免 `#s(...)` / `#(struct:...)`
依赖已加载的 struct 类型。

---

## 5. 模块划分与依赖

建议新增：

```text
edit-tui/
  persist/
    model.rkt        ;; snapshot 纯值、schema 常量、tagged-list 编解码辅助
    path.rkt         ;; workspace 相对路径编码 / 解码
    io.rkt           ;; generation 目录 / 原子写 / 读取 / 备份 / 锁
    snapshot.rkt     ;; ed + state -> snapshot（纯读）
    restore.rkt      ;; snapshot -> ed + state（host 侧重建）
    api.rkt          ;; 对 host 暴露 load/save/restore
  host/
    persist.rkt      ;; 连接 app/bootstrap / edit.rkt / 自动保存
  test/
    persist-roundtrip.rkt
    persist-corrupt.rkt
    persist-plugins.rkt
    persist-paths.rkt
    persist-history.rkt
```

依赖方向：

```text
core pure values
  ↑
editor/engine/persist.rkt（engine 快照 / 恢复，窄 API）
  ↑
persist/model.rkt / path.rkt
  ↑
persist/snapshot.rkt / restore.rkt
  ↑
host/persist.rkt
  ↑
app/bootstrap.rkt / edit.rkt
```

`persist/` 不 require `app/`；`app/` 只调用 `host/persist` 或 `persist/api`。
不要让 `core/` 认识 `.editdata` / IO。

### 5.1 需要新增的窄 core / engine API

`persist` 不应该直接摸 core 内部结构。建议加：

```racket
;; core/editor/persist.rkt（纯值，无 IO）
(view-state v)          -> view-state   ; mode / line-numbers / top-line / top-segment / left-column
(view-restore! v state) -> void         ; 先 set selections（#:ensure? #f），再恢复 viewport
(buffer-history-state b) -> history-state
(buffer-restore-history! b state) -> void
```

`view-restore!` 的顺序很重要：

1. `view-set-mode!`
2. `view-set-selections! #:ensure? #f`（否则 `ensure` 会把视口滚到光标，覆盖恢复的 top-line）
3. 恢复 viewport（`view-set-anchor!` / 新加的 raw viewport setter）
4. 用 text 长度重新 clamp

`buffer-restore-history!` 用 `document-open` 逐版本建 document，再构造
`history(past, current, future, limit, enabled?)`。文本-only 即可，因为用户文档的 face 会
被 racket-color 重算。

`editor/engine/persist.rkt` 负责：

```racket
(engine-user-doc-snapshot e did)  -> doc-snapshot
(engine-view-snapshot e vid)      -> view-snapshot
(engine-restore-user-doc! e snapshot) -> void
(engine-restore-view! e snapshot) -> void
(engine-derived-doc-snapshot e did) -> ...
(engine-restore-derived-doc! e snapshot) -> void
```

### 5.2 插件持久化扩展点

在 `editor/plugin.rkt` 增加：

```racket
(struct plugin-persist (version save load) #:transparent)

(make-plugin-persist
 #:version 1
 #:save (lambda (pctx ed state ps) <sexpr> | #f)
 #:load (lambda (pctx ed state ps payload) ps'))
```

`make-plugin` 增加 `#:persist [persist #f]`。
`editor/api.rkt` 导出 `make-plugin-persist`，让插件只通过既有 API 注册 codec。
`editor/host-api.rkt` 导出 `plugins->persist` 聚合。

`pctx` 提供：

```racket
;; persist-context
workspace-root
(path->workspace-relative path) -> string
(workspace-relative->path string) -> path
```

这样 filetree / 未来插件不用自己实现路径相对化。

约定：

- `save` 返回 `#f` = 不写这个插件；
- `load` 只返回新的 `ps'`，不直接改 `state` / `engine`；
- `load` 抛异常 -> 保留插件初始 state，记录诊断，不阻塞其它插件；
- 插件可以读写自己的 state，但不能借 load 改其它插件的 state；
- 需要创建 derived doc 的插件（当前 bilingual）由 host 先按 `derived` 记录恢复 doc，
  然后插件 codec 只重建 pair。

---

## 6. 保存流程

### 6.1 触发点

1. **正常退出**：`run-editor` 返回 `state-quit? = #t` 后，在 `run-demo-editor` 里保存。
2. **自动保存**（建议第二版）：事件循环每帧检查时间；距上次保存超过 N 秒且状态有变化时保存。
3. **崩溃**：只能依赖上一次自动保存；`.editdata` 不是事务日志。
4. **显式命令**（可选）：以后可加 `C-x C-s` 之外的 session save 命令，或环境变量关闭。

不要在每次按键都写盘。第一版“退出保存”就足以满足需求。

### 6.2 快照步骤（主线程）

```racket
(define snap (snapshot-session ed state #:workspace-root root))
```

`snapshot-session` 只读 engine / state，不做 IO。包含：

- `workspace-root` 标记；
- layout / areas / current-area / area-slot / next ids；
- resources（不存 command-stack）；
- 所有 user doc（文本 / 名字 / 可选 history）；
- 所有 view（user + UI + derived）；
- 所有 derived doc（meta / text / faces，只有 owner 有 codec 的才存）；
- 每个插件的 `save` 结果（可能 `#f`）；
- 可选 session（find / errors）。

保存时归一化：

- `pending` / `flash` / `modal` / `input` / `pointer` / `quit?` 不写入；
- `jobs` / timer-id / job-id 不写入；
- `completion` 插件的 `open?` 置 `#f`、candidates 清空；
- `filetree` 的 `pending` / `find-pending` 置 `#f`，`stale?` 加载时置 `#t`；
- `workspace` 的 requests 置空；
- `bilingual` 的 `timer-id` / `pending-job-id` / `pending-version` 置 `#f`，
  加载时若 source/mirror 文本不一致则 `force-full? = #t`。

### 6.3 写盘步骤（可后台线程）

1. 生成新 generation 目录名（时间 + pid + 随机）。
2. 创建目录（权限 `#o700`）。
3. 写 `meta.rktd`。
4. 写 `session.rktd`（纯数据）。
5. 写每个 `buffers/<did>.rktd`；未变化的文件从上一代硬链接。
6. 写每个 `derived/<did>.rktd`。
7. 关闭所有输出 / flush。
8. 写 `CURRENT.tmp` 为 generation 名。
9. `rename` `CURRENT.tmp` -> `CURRENT`（同目录，原子替换）。
10. 删除旧 generation（保留最近 2 个）。
11. 失败：删除新 generation，旧 `CURRENT` 不动；记录错误 / flash。

### 6.4 单实例锁

同一 workspace 开两个编辑器时，退出会互相覆盖 session。建议：

- 启动时尝试原子创建 `.editdata/LOCK`；
- 拿到锁的实例正常持久化；
- 没拿到的实例禁用持久化（或使用 `.editdata/instance-<pid>`），flash 提示；
- 正常退出删除锁；异常退出留下 stale lock 时，按 `(pid, 时间)` 判断，超过一天自动改名。

第一版可以先不加锁，但要在文档 / 测试里明确“并发实例最后退出者覆盖”的行为。

---

## 7. 恢复流程

恢复必须在 `source-sync!` / `workspace-sync!` / 第一次插件 sync 之前完成。
顺序如下。

### 7.1 启动骨架

`app/bootstrap.rkt` 拆成：

```racket
(make-editor-skeleton ...)   ; 只建 UI doc / UI view / 初始 layout
(make-editor-app ... #:restore? #f ...)
```

`make-editor-app` 默认不恢复（避免测试受仓库里的 `.editdata` 影响）；
`run-demo-editor` 显式 `#:restore? #t`。

骨架负责：

- 创建固定 UI doc / view：status / filetree / resources / input / completion / docs / errors；
- 创建空 user doc（无 resource）作为 fallback；
- 初始 layout / areas / screen；
- 初始 plugin states / view-scopes / layout-config。

建议把固定 view-id 常量移到 `app/views.rkt`，避免 `persist/` 反向 require `bootstrap.rkt`。

### 7.2 读取与校验

1. 读 `CURRENT`，找不到就试最新 generation，再找不到 -> 空会话。
2. 读 `meta.rktd`，检查 `schema`：
   - `schema > current`：版本太新，拒绝加载，备份并空启动；
   - `schema < current`：跑迁移；没有迁移就备份并空启动。
3. 读 `session.rktd`，做结构校验（tag / 类型 / 必填字段）。
4. 任何异常：把 generation 移到 `.editdata/corrupt/<...>`，空启动，记录一条 error。
5. 校验所有 id 唯一；重复 id 取第一条 / 丢弃后面的。

### 7.3 重建 engine

顺序：

1. **UI docs / views**：骨架已经建好；不要重建。
2. **user docs**：按 `buffers/` 记录创建 buffer；设置 name / text。
   - 如果 snapshot 有 user doc 但骨架也有初始空 doc（id 1），策略：
     - snapshot 有 doc 1 -> 复用 / 覆盖骨架的空 doc；
     - snapshot 没有 doc 1 -> 删除骨架的空 doc 和对应 view，除非 layout 仍引用它。
   - 更简单的方案：骨架不建 user doc；如果没有 snapshot，再建空 doc。
3. **user views**：按 view 记录创建 view，记录 `vid -> did`。
4. **derived docs**：按记录创建 `engine-create-derived-buffer!`，带 owner / source / edit-policy；
   再创建 view。只恢复“owner 有 codec”的 derived doc。
5. **derived faces**：如果有 face-track 记录，用 `engine-set-derived-projection!` 装上；
   否则由插件首次 sync 重投影。
6. **view 状态**：对每个存在的 view，按 §5.1 恢复 selections + viewport。
   - 先 `view-set-selections! #:ensure? #f`；
   - 再恢复 viewport；
   - 最后按当前文本 clamp。
7. **history**（可选）：按 §8 恢复。

### 7.4 重建 state

1. **layout**：
   - 用 snapshot 的 root + panel-map 构造 `layout`；
   - panel 的 `views` 过滤掉不存在的 view-id；
   - `active` 不在 views 里 -> 取第一个 view / `#f`；
   - `restore` 用 `restore` struct 重建；
   - `focus` 不存在 / 不可见 / 不可聚焦 -> `layout-focus-fallback` 或第一个可聚焦 panel；
   - 用 `layout-valid?` 校验；失败 -> 用骨架 layout。
2. **areas**：
   - 每个 `editor-area` 的 layout 只应包含 editor panel；非 editor panel 过滤；
   - focus 校验，失败取第一个 editor panel；
   - 无效 area 丢弃。
3. **current-area / area-slot**：
   - current-area 不在 `areas` / 当前 frame 里 -> 回 1；
   - area-slot 父 split 不存在 -> 用 `area-slot-for-editor` 重算；
   - 仍然无效 -> 关闭多 area（`areas = {}`，`area-slot = #f`），只保留当前 frame。
4. **resources**：
   - 对每个记录，找 doc-id；不存在则丢弃；
   - `views` 过滤到存在的 view；
   - `command-stack` 用 `mode-command-stack` 重建；
   - `saved`：
     - 如果 snapshot 记录了 saved-hash，重新计算当前文本 hash；
     - 相等 -> `saved-version = 当前 engine version`（clean）；
     - 不等 -> `saved-version = #f`（dirty）；
   - 文件不存在：保留 buffer / resource，标 dirty，flash “file missing”；不要丢文本。
5. **next ids**：`next-view-id` / `next-panel-id` 取 snapshot 与现有最大 id 的 max+1。
6. **view-scopes / layout-config**：由插件和 config 重建，覆盖 snapshot。

### 7.5 恢复插件状态

1. 从 `plugins->states` 得到初始 state。
2. 对每个 plugin codec：
   - snapshot 没有该 id -> 保留初始 state；
   - codec `version` 不匹配 -> 保留初始 state，记录诊断；
   - `load` 抛异常 -> 保留初始 state，记录诊断；
   - 成功 -> `state-set-plugin-state`。
3. 顺序 = 插件安装顺序；插件之间不互相读 ps。
4. `completion` 即使没有 codec，也应确保恢复为 closed（初始 state 即是）。
5. `workspace` 恢复为 `empty-workspace-plugin-state`。

### 7.6 恢复 session（可选）

- `find`：query / target-vid / index 存；恢复时按当前文本重算 matches，index clamp；
  target view 不存在 -> 清空 find。
- `errors`：存 time / severity / source / owner / context(sanitized) / message；
  启动后错误面板立即有内容。
- `input`：默认清空；不恢复 active modal。
- `pending` / `flash` / `pointer` / `quit?` / `jobs`：清空。
- `async?`：由 host 设置。

### 7.7 第一次 frame

恢复完成后：

1. `source-sync!` 从 resource 重建 source-store；
2. `workspace-sync!` 重建 workspace（async 模式提交 job）；
3. `panels-sync!` 按 layout 重新写 view width/height；
4. 插件 sync：
   - racket-color 重算颜色；
   - filetree 立即写 presentation cache / 提交扫描；
   - resources 重算行；
   - docs 写回持久化的 lines；
   - completion closed；
   - bilingual 校验 pair，必要时 full 重投影；
5. render。

注意：`panels-sync!` 会改 view width/height；不要把它存进快照后又在 load 时覆盖 panel 计算值。

---

## 8. undo / redo 历史

### 8.1 为什么第一版可以不做

- 历史里每个版本都是完整 `document` 值，含 face / readonly / slots / revision gensym；
- 当前用户文档的 face 可由 racket-color 重算，但历史文档的 face 也一样；
- 直接存 document 会引入 box / mutable struct / procedure 风险；
- 文本快照历史可能很大。

### 8.2 如果要做

建议文本-only、带预算：

```racket
(history
 (limit . 1000)
 (enabled? . #t)
 (past . ("text newest" "text older" ...))
 (current . "...")
 (future . ("..." ...))
 (truncated? . #f))
```

- 只对 `user` doc 存；UI / derived 无 history；
- 每个 buffer 最多 `N` 步（默认 100）且总字节上限（默认 4 MB）；
- 超过预算：丢最旧的 past，`truncated? = #t`；
- 每个 buffer 文件用 gzip 压缩；
- 用 `buffer-restore-history!` 构造 `history`；
- saved-version：在当前 / past / future 中找文本 hash 等于 saved-hash 的版本，
  把 resource 的 saved-version 指到那个 document 的 version token；
  这样 undo 回到保存点仍然 clean；
- 如果 saved 版本被预算裁掉，退化为“当前文本匹配才算 clean”。

第一版建议：**不存 history，文档里明确写“重启后 undo 栈清空”**；
第二版再按上面的预算实现。

---

## 9. 各插件 codec 建议

### 9.1 `filetree`

存：

```racket
((root (kind . workspace) (value . "."))
 (view . 3)
 (expanded . ("src" "src/parser" "docs"))
 (show-hidden? . #f)
 (rows . (((path . "src") (kind . dir) (text . "  src") (depth . 1)) ...))
 (pending-cursor . "src/parser/main.rkt")
 (find-query . "main"))
```

加载：

- root 相对 workspace root 解析；
- expanded 路径转绝对 `path`；
- rows 作为 presentation cache 写回，`stale? = #t`；
- `pending = #f`，`find-pending = #f`，`find-matches = '()`，`find-index = 0`，
  `find-stale? = #t`（下一次 sync 重新查）；
- view 的光标由 view-state 恢复；`pending-cursor` 可在第一次 scan 后定位到当前文件。

### 9.2 `docs`

存：

```racket
((view . 7) (panel-id . docs) (name . "map") (lines . ("map" "── 文档 ──" ...)))
```

加载：`request-id = #f`；`faces` 用 `docs-faces` 重算。
如果面板在 layout 中 hidden，仍然可以恢复 lines，下次打开时显示。

### 9.3 `bilingual`

存：

```racket
((default . zh-racket)
 (translators . ((zh-racket (version . ("v2" ...)))))
 (lexicon
  (forward . (("foo" "福" bilingual-function) ...))
  (inverse . (("福" . "foo") ...))
  (generation . 7))
 (pairs
  ((source-doc . 10)
   (mirror-doc . 11)
   (mirror-view . 11)
   (translator-id . zh-racket)
   (translator-version . (...))
   (source-lines . (...))
   (mirror-lines . (...))
   (mirror-faces . (...))
   (source-anchor . (line . 3) (col . 0))
   (mirror-anchor . (line . 3) (col . 0))
   (force-full? . #f))))
```

加载：

- `translators` 里的 procedure **不存**；用 `default-translator` /
  `translator-with-overrides` 从 lexicon 重建；
- translator version 不匹配 -> `force-full? = #t`；
- `source-version` / `mirror-version` 用恢复后的 engine version 覆盖；
- `pending-version` / `pending-job-id` / `timer-id` 全部 `#f`；
- source doc 或 mirror doc 不存在 -> 丢弃该 pair；
- mirror doc 由 host 的 generic derived restore 先建好；codec 只写 pair state；
- 首次 sync 用 `mirror-lines` / `mirror-faces` 调
  `editor-set-derived-view-projection!` 装上，或标记 `force-full? = #t` 让插件自己重算。

### 9.4 `completion`

不存。加载后保持 `empty-completion-state`（closed）。

### 9.5 `workspace`

不存。加载后 `empty-workspace-plugin-state`；host 的 workspace 缓存由
`workspace-sync!` 重建。

### 9.6 `racket-color`

不存。加载后 `empty-color-cache`；第一次 sync / changes hook 重算。

### 9.7 `pair` / `indent` / `layout`

存 `#t` 或直接不存（初始 state 就是 `#t`）。

---

## 10. 关键边界与决策

### 10.1 dirty / saved-version

`resource-saved-version` 是 document 对象，不能存。方案：

- snapshot 存 `saved-hash`（当前保存文本的 SHA-1）和可选 `dirty?`；
- 恢复后计算当前文本 hash：
  - hash 相等 -> clean，`saved-version = 当前 version`；
  - 不相等 -> dirty，`saved-version = #f`；
- 如果恢复 history，优先把 saved-version 指到历史中匹配的版本（§8）。

### 10.2 关闭时磁盘文件变了

两种策略：

- **session 优先（默认，保证“和关闭时一样”）**：恢复 snapshot 文本；如果磁盘
  fingerprint 变化，flash 提醒，但不自动覆盖。
- **disk 优先（更安全）**：clean buffer 从磁盘重读；dirty buffer 保留 snapshot。

建议默认 session 优先，并在 meta 里记录 `disk` fingerprint；以后加
“Reload from disk” 命令 / 启动提示。
不要静默把“磁盘已变”的 clean buffer 再保存回去。

### 10.3 屏幕尺寸

`screen` 不存。旧 layout 的 rect 也不存（layout 本身不存 rect，只存树 / ratio / fixed）。
panel 的 `restore` 只用于隐藏面板恢复，存 rect / parent-rect；加载时按新屏幕重新 solve。

### 10.4 UI 文本

- status / resources / errors：启动后立刻重算；
- filetree：存 rows 作为 presentation cache，先显示再异步刷新；
- docs：存 lines；
- completion / input：不存，关闭 / 清空；
- color：不存，sync 重算。

### 10.5 文件树里的 `.editdata`

filetree 的 `hidden-entry?` 默认隐藏 dotfile；建议再加固定排除：

```racket
(define (session-dir-name? name) (equal? name ".editdata"))
```

否则 `C-h` 显示 dotfile 时用户可能误编辑会话缓存。`.editdata/.gitignore` 里写 `*`，
默认不会被版本控制带走。

### 10.6 插件缺失 / 插件版本变化

- snapshot 里有 plugin id，但当前 editor 没有该插件 -> 丢弃该 payload；
- plugin codec 的 `version` 不匹配 -> 丢弃该 payload，保留初始 state；
- derived doc 的 owner 没有 codec -> 不恢复该 derived doc；
- layout 引用了已删除插件的 panel kind -> panel 仍可保留（kind 只影响规则 / 键位）；
  如果 kind 不存在于 config，用 `default-panel-rule`。

### 10.7 多实例

第一版：最后退出的实例覆盖。第二版：`.editdata/LOCK` 单实例锁。
不要在另一个实例运行时直接写 `CURRENT`。

### 10.8 大文件 / 性能

- buffer 文件单独写，避免每次保存重写全部文本；
- gzip 压缩 buffer / history；
- 自动保存异步化：主线程生成 snapshot，后台线程写 generation；
- 不要在主线程做全量 `write` 大文件；否则输入会卡。

### 10.9 安全

- 只用纯 S-expression `read`，关闭 reader eval；
- 校验所有 tag / 长度 / 类型；
- 文件权限 0600 / 0700；
- 不跟随 `.editdata` 里的符号链接写文件；
- `.editdata` 可能包含未保存代码，提醒用户不要提交。

---

## 11. 测试计划

### 11.1 纯快照 roundtrip

`persist-roundtrip.rkt`：

- 创建 app；打开多个文件；编辑（含未保存修改）；
- split / 关闭 panel / 显示 docs / 展开 filetree / 建 bilingual pair；
- 移动光标 / 扩选 / 滚动 / 切 area；
- `snapshot-session` -> `write` -> `read` -> `restore`；
- 断言：
  - user doc ids / text / resources 一致；
  - 每个 view 的 point / selections / viewport 一致；
  - layout tree / panel views / active / focus 一致；
  - areas / current-area / area-slot 一致；
  - filetree expanded / show-hidden / find-query 一致；
  - docs lines 一致；
  - bilingual pair 存在且 mirror 文本一致；
  - dirty 状态一致。

### 11.2 损坏 / 降级

`persist-corrupt.rkt`：

- 空文件 / 截断 / 非法 tag / 未知 schema / 非法 id；
- 恢复必须返回空会话 + diagnostics，不抛异常；
- 旧 generation 仍然可读；
- 迁移函数失败时备份到 `corrupt/`。

### 11.3 插件 codec

`persist-plugins.rkt`：

- filetree：rows cache、expanded、pending/find 字段重置；
- docs：lines 恢复、request-id 清空；
- bilingual：translator version 不匹配 -> full；mirror doc 缺失 -> drop pair；
- 未知插件 payload -> 忽略；
- codec 抛异常 -> 初始 state + error。

### 11.4 路径

`persist-paths.rkt`：

- workspace 内路径存相对；root 外存绝对；
- `.editdata` 移动到同级目录后仍能恢复；
- root 外文件不存在 -> buffer 保留 + dirty；
- Windows 分隔符 / 大小写（如果支持）。

### 11.5 历史

`persist-history.rkt`（第二版）：

- undo / redo / saved 点；
- 超预算截断；
- gzip roundtrip；
- history disabled 的 buffer。

### 11.6 并发 / 原子性

- 写盘过程中模拟异常：旧 `CURRENT` 仍指向完整快照；
- 两个实例：锁 / 最后写者策略符合设计；
- 自动保存线程与主线程：snapshot 后 engine 继续编辑，不影响已生成快照。

### 11.7 性能

- 50 个打开文件、每个 100 KB：save / load 目标 < 200 ms（不含压缩）；
- 自动保存不阻塞按键超过 16 ms（主线程只做 snapshot）；
- 1 MB 历史 / 大 buffer 不导致内存翻倍失控。

---

## 12. 分阶段实现

### Phase 0：可行性与骨架（建议先做）

- 新增 `persist/model.rkt` / `path.rkt` / `io.rkt`；
- 只 snapshot / restore：
  - workspace-root；
  - user doc 文本 / name / id；
  - user / UI view state；
  - layout / areas / current-area / area-slot；
  - resources（command-stack 重建、saved-hash）；
- 不存插件 state / history / session；
- `run-demo-editor` 退出保存，启动恢复；
- roundtrip / corrupt 测试。

这个阶段就能验证“关闭再打开，布局、文件、光标、滚动位置一致”。

### Phase 1：插件状态 + 可用性

- `plugin-persist` 扩展点；
- filetree / docs codecs；
- 可选 session find / errors；
- `.editdata` 权限 / `.gitignore` / 单实例锁；
- 自动保存（可选）。

### Phase 2：完整会话

- bilingual derived + pair codec；
- 可选 undo/redo 历史（带预算 + gzip）；
- 磁盘变更策略 / reload；
- schema migration；
- 性能优化（硬链接、后台写、压缩）。

### Phase 3：长期

- 多实例 / 只读共享；
- 会话 profile（不同 workspace / branch）；
- crash journal；
- 插件 codec 版本迁移框架；
- 导出 / 导入会话（可选）。

---

## 13. 主要风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| plugin state 含 procedure / opaque 值 | 无法直接存 | 插件 codec 只存 id / version / 纯数据，加载时重建 |
| document version 是 gensym | 无法跨进程比较 | 不存 version；存文本 / hash；加载时重建 |
| job/timer id 失效 | 恢复后异步流程断 | 保存时归一化，加载时置空 / force-full |
| undo 历史过大 | 文件大 / 启动慢 | 第一版不做；第二版预算 + gzip |
| 快照损坏 | 启动失败 | generation + 校验 + 备份 + 空启动 |
| 两实例覆盖 | 丢会话 | 锁 / 最后写者策略 |
| 磁盘文件被外部修改 | 恢复旧文本 / 覆盖风险 | 存 fingerprint，提示 / 可选 disk-wins |
| 插件版本变化 | 旧 state 不兼容 | 每插件 codec version，不匹配即丢弃 |
| 路径移动 | 打不开文件 | workspace 相对路径 + 绝对 fallback |
| 权限 / 隐私 | 未保存源码泄露 | 0600 / 0700 + `.editdata/.gitignore` |

---

## 14. 需要确认的产品决策

1. 默认恢复策略：`session-wins`（完全和关闭时一样）还是 `disk-wins-for-clean`
   （更安全但可能不是“完全一样”）？建议默认 `session-wins`，磁盘变化只提示。
2. 是否默认保存 undo/redo 历史？建议第一版不保存，第二版默认保存最近 100 步。
3. 是否恢复 find 会话 / error log？建议恢复，但都算“可选 session”。
4. 是否恢复 input seed？建议不恢复 active prompt，避免启动时出现半截保存 / 退出确认。
5. 多实例：禁用持久化，还是每个实例独立目录？建议先禁用第二个实例的持久化。
6. 是否把 `.editdata` 加入 filetree 的固定排除？建议是。

---

## 15. 建议的第一版行为（一句话）

> 启动时读 `<workspace>/.editdata/CURRENT`；恢复 user buffer 文本、resources、layout、
> view 光标/选区/视口、filetree 展开与 docs 内容；丢弃 jobs/timers/临时模式；
> 退出时原子写新 generation。语法颜色、workspace、source-store、status 全部重算。
> undo 栈第一版不恢复。

---

## 16. 最小版本：只恢复“关闭时的布局 / 焦点 / buffer”

如果只要求**正常关闭后再次打开时**恢复：

- layout（split / 比例 / panel 显隐 / active view）；
- focus（当前 panel / 当前 area）；
- 当时打开的 buffer（文本、路径、名称、mode、dirty）；
- 可选：每个 user view 的光标 / 选区 / 滚动位置；

其它都不管，那么上一套完整设计可以砍掉一大半。建议直接做这个最小版本。

### 16.1 只存这些

**存：**

- `workspace-root` 标记（加载时用当前目录）；
- `layout` / `areas` / `current-area` / `area-slot`；
- `next-view-id` / `next-panel-id`；
- `resources`：id / doc-id / path / name / views / mode / dirty?；
- user doc：doc-id / name / text；
- user view（可选）：selections / viewport / mode / line-numbers?。

**不存：**

- 所有 `plugin-states`（启动时恢复插件初始 state）；
- derived doc / bilingual pair；
- undo / redo history；
- find / errors / input seed / 任何 session；
- UI doc 文本、UI view 光标/滚动、filetree rows、docs lines；
- source-store / workspace / color cache；
- screen / job ledger / timer / job-id。

### 16.2 恢复行为

1. `make-editor-app` 仍按现有逻辑建 UI doc / UI view / 初始 layout。
2. 如果存在 session 文件：
   - 删掉 bootstrap 的初始 user doc 1 和 view 1；
   - 按 session 里的 user doc 创建 buffer，按 view 创建 view；
   - 恢复 user view 的 selections / viewport（先 selections `#:ensure? #f`，再 viewport）；
   - 用 session 的 layout / areas / current-area / area-slot 替换 bootstrap 布局；
   - 用 session 的 resources 替换 bootstrap resources；
   - `command-stack` 用 `(mode-command-stack mode)` 重建；
   - `saved-version`：dirty? = #f 时设成当前 doc version，dirty? = #t 时设成 #f。
3. 校验 / 降级：
   - panel 里不存在的 view-id（例如 bilingual mirror）从 views 里删掉；
   - `active` 不在 views 里 -> 取第一个 view / `#f`；
   - focus 不存在 / 不可聚焦 -> `layout-focus-fallback`；
   - area / area-slot 无效 -> 回退到单 area；
   - 整个 layout 无效 -> 用 bootstrap layout。
4. 第一次 frame 照常跑 `source-sync!` / `workspace-sync!` / 插件 sync；
   - 颜色、workspace、filetree rows、resources 行、docs 面板内容全部重算；
   - completion 是 closed；
   - filetree 只有 root 展开；
   - bilingual pair 不存在。
5. undo 栈为空：重启后不能撤销关闭前的编辑。

### 16.3 文件格式

不需要 generation 目录，也不需要每个 buffer 一个文件。最小版本用一个文件：

```text
.editdata/
  session.rktd
  session.rktd.bak
  .gitignore        ; "*"
```

```racket
;; .editdata/session.rktd
((schema . 1)
 (workspace-root . ".")
 (layout . <layout>)
 (areas . <areas>)
 (current-area . 1)
 (area-slot (parent . 4) (side . right))
 (next-view-id . 42)
 (next-panel-id . 120)
 (resources
  ((id . 10) (doc-id . 10)
   (path (kind . workspace) (value . "src/main.rkt"))
   (name . "main.rkt")
   (views . (10 11))
   (mode . racket)
   (dirty? . #f)))
 (buffers
  ((id . 10) (name . "main.rkt") (text . "...")
            (views ((id . 10)
                    (selections (primary . 0)
                                (items . (((anchor 4 2) (head 4 8)))))
                    (viewport (mode . clip) (line-numbers? . #f)
                              (top-line . 0) (top-segment . 0)
                              (left-column . 0)))))))
```

写盘：

1. 写 `session.rktd.tmp`；
2. flush / close；
3. 把旧 `session.rktd` 重命名为 `session.rktd.bak`（可选）；
4. `rename` `session.rktd.tmp` -> `session.rktd`。

读盘失败 -> 尝试 `.bak`；都失败 -> 空会话启动，不阻塞。

### 16.4 代码改动范围

新增：

```text
edit-tui/persist/minimal.rkt   ;; snapshot / restore / tagged-list 编解码
edit-tui/persist/io.rkt        ;; 单文件原子读写 / 路径相对化
```

修改：

- `app/bootstrap.rkt`：允许“先建骨架，再 restore”，并允许跳过初始 user doc；
- `edit.rkt`：`run-demo-editor` 启动时 load，退出时 save；
- 可能给 `core/editor/query.rkt` / `ops.rkt` 加一个小的 `view-state` 读写函数
  （如果不想依赖 `view-set-anchor!` 的非公开导出）；
- 测试：`test/persist-minimal.rkt`。

不需要：

- `plugin-persist` 扩展点；
- 插件文件改动；
- derived doc / bilingual 恢复；
- history 恢复；
- session（find / errors / input）恢复；
- 自动保存 / 多实例锁 / generation 目录；
- schema 迁移框架（第一版只有一个 schema，版本不匹配就备份 + 空启动）。

### 16.5 最小版本的已知限制

- 关闭时如果有 bilingual mirror split，重启后镜像 panel 消失；layout 会过滤掉不存在的 view。
- filetree 展开状态、docs 内容、错误日志、find query、补全菜单都不恢复。
- 只保存正常退出；直接 kill / 终端崩溃不保证有 session。
- 不保存 undo / redo。
- 不处理“关闭期间磁盘文件被修改”；恢复的是关闭时的文本。
- 两个实例同时打开同一 workspace 时，最后退出的覆盖前一个。

### 16.6 一句话

> 最小版本只做四件事：存 user buffer 文本 + resources、存 layout/areas/focus、
> 存 user view 光标/选区/视口、退出时原子写一个 `session.rktd`。
> 插件、derived、history、session、UI 缓存全部不碰，启动后重算。
