# edit4 · 13 双文档映射同步（sync）—— 功能统计 + 设计

> 需求：两个文档之间做**对应词映射 + view 同步**。一个文档改动 → 中间转换 → 写到另一个
> document（双向）。用于代码在两种语言/方言间转换。第一阶段：**中文 Racket ↔ 英文 Racket**
> （例：`(define a 3)` ↔ `(定义 a 3)`）。
>
> 本文先统计 core / edit4 现有能力（§1–§3），再给设计（§4–§9）、缺口（§10）、分期（§11）、
> 待拍板项（§12）。

---

## 1. 引擎（`core/`）能提供什么

| 能力 | 模块 / API | 对本功能 |
|---|---|---|
| 文档 + 多视图 | `editor-add-document-view` / `editor-document-view-list`；did / vid | 两个文档各有 did；peer 用 did 定位，经它的视图写 |
| 程序化整篇写 | `editor-view-assign!`（adapter `assign!`） | 变换结果整篇写到 peer；封存 peer history |
| 相对光标编辑 | `editor-view-insert! / -backspace! / -delete! / -paste-text!` | 增量写（需先把光标挪到目标位） |
| op 级编辑 | `editor-view-edit! ed vid op` | 自定义 op（任意区间）——但没经 adapter 暴露 |
| 异步 CAS 写 | `editor-view-apply-text-if-version! ed vid base-text new-doc` | 大文档/并发写回：版本不匹配就丢弃 |
| 变更描述 | `change{before,after}`；`change-map-point` / `changes-map-point` / `document-change-text` | 源改动 → 目标位置映射；增量基础 |
| 历史 | 每文档 history；`editor-document-history-record!/seal`；merge-tag | 决定同步是否进 peer 的 undo |
| 属性端口 | face / readonly：`editor-document-face-*` | peer 里高亮「对应词」 |
| 文档槽 | `define-document-slot ... #:fork`；`editor-document-slot-ref/set!` | 缓存「上次同步结果/行映射」；fork 自动带 changes |
| 版本层 | `editor-document-handle-*` | 句柄式异步写回（按抓取时那一版） |
| 文本结构 | track（持久 rope）/ line / point / range / rebase | 行/位置运算 |
| 渲染 patch | `editor-render-layout-patch`（adapter `render-layout`） | 不需要碰：视图会自动反映文档 |

**结论**：引擎具备「读整篇 / 写整篇 / 位置映射 / 异步 CAS / 属性高亮」全部原语。缺的只是
**任意区间编辑**在 adapter 上的一个口子（§10）。

## 2. edit4 core / runtime 能提供什么

| 能力 | 模块 / API | 对本功能 |
|---|---|---|
| World | layout / floats / focus / content / **signals** / **jobs** / **store** | store 存配对 session；signals 跑钩子 |
| 命令 | `command-registry`，handler `Ctx World args -> (values World effects) \| #f` | sync-link / unlink / toggle … |
| 调度 | `dispatch`：文档键表 → keymap；scope 数据 | 键位、按文件类型挂键（`doc-key-matchers`） |
| 键表 | `config/plugins.rkt` 名字列表 + `plugins/catalog.rkt` | 启用插件 |
| 钩子 | `reaction* point …`；`run-hooks` 排空 signals | **after-edit / after-insert / after-nav / focus-changed / before-render / document-opened / job** |
| 异步 | `job-submit` + `service`（worker 里跑纯函数）+ `'job` 钩子 | 大文档变换、去抖 |
| 插件状态 | `world-store` + `store-ref/set`（命名空间） | session 表、上次文本、in-flight 标记 |
| Effect | `quit/log/open-file/save-file/...`（runtime 边缘解释） | 打开/保存镜像文件 |
| 模式 | `match-doc-keys`（ext/name/regexp/any） | 按扩展名给 sync 键表 |

## 3. edit4 内容 / 投影层能提供什么

| 能力 | 模块 / API | 对本功能 |
|---|---|---|
| 内容模型 | `content{docs path/saved, bindings id→vid, …}` | did↔path↔vid |
| 引擎边界 | `content/adapter.rkt`（**唯一** require `core/editor` 的模块） | 所有读写的唯一入口 |
| 读写原语 | `assign! set-point! ensure! insert! document-string document-track document-view-list view-did …` | 写 peer、同步光标 |
| 打开/放置 | `content/placing.rkt` `reveal-or-place-doc!`（0/1/≥2） | 打开 peer 或聚焦已开 |
| 浮窗 | `content/float.rkt` `open-overlay` | 同一 vid 的镜像预览 |
| 装饰 | `view/decor.rkt`（每文档槽 + 增量 + path 门控）| peer 里高亮对应词 |
| 面板 | `view/panel.rkt` `named-panel`（World→投影；集中写回）| sync 状态/会话面板 |
| 输入行 | `content/prompt.rkt` + prompt-kind | 选择 mapping / 输入文件名 |
| 钩子点 | 各命令 `emit!`（edit.rkt: `after-insert`/`after-edit`）| 触发同步 |

## 4. 关键架构结论（决定设计）

1. **改一行 → 中间转换 → 同步** 三步都可在 edit4 内完成，不必改 core 分层：
   - 触发：`after-edit` / `after-insert` 钩子（拿到被编辑的 vid）。
   - 读：`document-string ed did`（或 track 逐行）。
   - 转换：纯函数 text → text。
   - 写：`assign! ed peer-vid text'`。
2. **程序化写不 emit 钩子**（钩子是 `content/edit.rkt` 命令发的，adapter 直写不发）⇒
   **天然无回环**。若以后为状态栏 `emit! 'sync-applied`，用 store 里的 `syncing?` 标记抑制。
3. **peer 写整篇后装饰自动全量重算**：`assign!` 换的是新 document 值，decor 槽默认 `#f`，
   下一帧 `apply-faces!` 走 `slot-open` 全量重扫 → 正确（只是不增量）。
4. **同步发生在钩子（同步 phase）**，不在命令里：命令只改源文档，钩子读源写 peer。符合
   「投影/副作用集中」的项目风格。

---

## 5. 术语与值类型

```racket
;; 一种映射规则（双向）：term 对 + 方向自反
(struct mapping (id a-lang b-lang terms))     ; terms : (listof (cons string string))
;; session：一篇文档绑定另一篇 + 用哪条 mapping
(struct session (id a-did b-did mapping-id))  ; did 稳定；vid 每次现取
```

- `mapping` 是**部分双射**：同一 term 不能映射到两个不同 term（否则 round-trip 不稳）。
- `session` 存 `World.store`，键 `'sync.sessions`：`(listof session)`；
  另存 `'sync.state`：`hash session-id -> (hash 'a-text … 'b-text … 'peer-caret …)` 用于去抖/回环判断。

## 6. 转换器（纯，本功能的核心）

### 6.1 词法切片
复用 `decor/syntax.rkt` 的跨行状态机思想（块注释 `#|…|#`、字符串、`;` 注释、字符字面量），
把一行切成 token：`空白 | 字符串 | 注释 | 括号 | 符号/标识符 | 数字`。

```racket
;; transform.rkt（纯）
(translate : mapping direction string -> string)
;;   direction = 'a->b | 'b->a
;;   只把「符号 token」按 terms 查表替换；字符串/注释/数字/空白原样。
;;   未命中的符号原样（identity 兜底）。
```

### 6.2 位置映射（view 同步用）
转换时同时产出**编辑表** `(listof (list src-range dst-range))`：

```racket
(translate+edits : mapping direction string -> (values string (listof edit)))
;; edit = (list (point line col) (point line col)  ; src 区间
;;              (point line col) (point line col)) ; dst 区间
;; 段落/行号不变（只换 token 文本），所以 line 一一对应；列按 token 长度差平移。
(map-caret : (listof edit) point -> point)   ; 源 caret → peer caret（可能落 token 内）
```

### 6.3 中文↔英文 Racket 词表（初版）
- 关键字：`define↔定义`、`lambda↔函数`、`let↔令`、`let*↔令*`、`if↔如果`、`cond↔分支`、
  `begin↔开始`、`define/contract↔定义/契约` …（放 `config`，纯数据）。
- 标识符：默认识别符不改；可选用户词表。
- **反向 = 同一个表反转**，保证 `translate b->a (translate a->b x) = x`（对未歧义文本）。

## 7. 同步引擎（钩子）

```
after-edit / after-insert (vid_src[, text])   ; 源侧编辑
  did_src = content-did-of vid_src
  session = 查 store：did_src 属于某 session？
  ↓ 是
  text_src = document-string ed did_src
  (text_dst*, edits) = translate+edits mapping 方向 text_src
  text_dst = document-string ed did_dst
  ↓ text_dst* ≠ text_dst
  peer-vid = (car (document-view-list ed did_dst))
  assign! ed peer-vid text_dst*          ; 整篇写（v1）
  map-caret + set-point! ed peer-vid …   ; view 同步
```

- **去抖/幂等**：写前先比 `text_dst* ≠ text_dst`（v1 逻辑简单）；v2 用 store 里的
  `last-text` 快速判断并做行级 diff。
- **方向**：由「哪个 did 的钩子触发」决定。若同帧两边都改（罕见），以焦点所在侧为准。
- **view 同步**（第二条）：`after-nav` / `focus-changed` 时，把源 caret 经 `map-caret` 映射到
  peer 的 `set-point!` + `ensure!`；用 `store` 记录「程序化设置的 caret」避免来回抖动。
- **对应词高亮**（可选）：一个 path 门控的 `decor`，读 store 里 peer 的 caret，把本文档中
  对应的 token 涂 `face`（或直接在 `assign!` 后 `face-batch!` 对应行）。

## 8. 增量（v2，对应「改一行」）

### 8.1 需要 engine 的 `change`
现状：`content/edit.rkt` 的钩子只带 `(vid)` / `(vid text)`，`adapter` 把
`editor-view-insert!` 返回的 `changes` 丢掉了。**两个小改动**可补齐：

```racket
;; content/adapter.rkt：让编辑原语返回 changes
(define (insert! ed vid text) (editor-view-insert! ed vid text))   ; -> (values changes ok?)
;; content/edit.rkt：钩子参数带上 changes
(emit! world 'after-edit (list v changes))
```

`changes` 是 `(listof change)`，可直接喂 `decor/dirty.rkt` 的 `changes->dirty-lines`
拿到脏行（已存在，复用）。于是：

```
脏行集 L（源）
  for each 源行 → translate 该行 → 目标同号行
  行数变化（change 的 before/after 端点行差）→ 在目标插入/删除对应行
```

### 8.2 目标侧最小编辑
adapter 现在只有整篇 `assign!` 和「相对光标 insert/delete」。要增量需补一个原语（§10）：

```racket
;; content/adapter.rkt（新增）
(replace-range! ed did l0 c0 l1 c1 text)   ; 内部 editor-view-edit! 自定义 op
;;   → 引擎记 change，peer 的 decor 增量推进；caret 自动 rebase
```

## 9. 交互 / 装配

### 9.1 命令（`plugins/sync/cmds.rkt`）
| 命令 | 作用 |
|---|---|
| `sync-link` | 两步选取 peer（复用我们刚做的 swap 选择 UX）或从 buffers 选一个文档，建 session |
| `sync-open` | 按命名约定（如 `a.rkt` ↔ `a.zh.rkt`）打开/创建镜像文档并 link |
| `sync-unlink` | 解散焦点文档所在 session |
| `sync-toggle` | 会话内开关同步（保留 mapping，暂停写回） |
| `sync-refresh` | 全量重放一次（修复漂移） |
| `sync-cycle-mapping` | 切换 mapping 规则 |

### 9.2 键表 / 作用域
- 可用 `doc-key-matchers`：`(ext "rkt")` → sync 键表；或全局几个键。
- 需要双窗：`sync-link` 里可以顺带用 layout 把两篇文档并排（split + `reveal-or-place`）。

### 9.3 状态显示
- 状态栏一行 `sync: rkt↔zh`（可加个 `sync` scope 给 `*status*` 投影）；
- 或一个 `named-panel` 列出所有 session + 方向 + dirty。

### 9.4 异步（大文档）
- `service 'sync-transform`（纯）：`payload = (mapping-id dir text)` → 结果。
- 命令/钩子去抖后 `job-submit`，tag `(sync sid dir src-version)`；`'job` 钩子里用
  `editor-view-apply-text-if-version!` 写回（源已变则丢弃重算）。

### 9.5 文件/命名约定
- 约定镜像：`foo.rkt` ↔ `foo.zh.rkt`（或 `foo.en.rkt`）；`sync-open` 据此创建/打开。
- 也可以用「同一文件的两种 view」——**不行**：本需求是**两篇 document**，映射文本不同。

## 10. 缺口清单（必须补的接口）

| # | 缺口 | 现状 | 建议 |
|---|---|---|---|
| 1 | 钩子不带 `change` | `after-edit` 只有 vid；adapter 丢 changes | adapter 原语返回 changes；edit.rkt 带进钩子参数 |
| 2 | 无任意区间编辑 | adapter 只有 `assign!` / 相对光标 | 新增 `replace-range!`（内部 `editor-view-edit!`） |
| 3 | peer 整篇写不进 undo | `assign!` 会 seal | 决策：derived 文档不 undo（默认）或改走 CAS+record |
| 4 | 无跨文档依赖 | 无 | 插件 store 自管 session（本设计） |
| 5 | 无 token 级词法器 | `decor/lex.rkt` 只扫标识符 | 在插件内写带状态行扫描（参考 `decor/syntax.rkt`） |
| 6 | 无命名约定 | 无 | `config` 数据 + `#:applies?` |

## 11. 建议分期

- **S0 纯核心**：`mapping` + `transform` + `translate+edits` + 单测（round-trip、字符串/注释不误改）。
- **S1 手动配对 + 整篇同步**：`session` store + `sync-link/unlink` + `after-edit/insert` 钩子整篇写回；
  测试「编辑 A → B 恰好变一次、无回环」。
- **S2 增量 + view 同步**：补 §10 的 #1#2；按脏行同步；caret/scroll 同步；高亮对应词。
- **S3 体验**：并排布局、状态栏/面板、按扩展名键表、`sync-open` 命名约定。
- **S4 异步**：大文档 job + CAS 写回 + 去抖。

## 12. 已拍板

1. **映射范围**：词表放 `config/sync.rkt`（纯数据）；初版只换关键字，标识符不改。
2. **镜像**：**内存文档**（path #f，不落盘）。
3. **方向**：**双向**——哪边输入就以哪边为源、同步到另一边。
4. **undo**：同步写入**不进** peer 的 undo（peer 视为派生；走 `assign!` 封存）。
5. **触发**：**每个按键**（`after-edit` / `after-insert` 钩子即时同步）。
6. **对应词高亮**：跟上。

## 13. 落地状态（已实现）

```
edit4/config/sync.rkt              词表（纯数据）
edit4/plugins/sync/mapping.rkt     词表访问 + 方向表 + mapped-term?
edit4/plugins/sync/transform.rkt   纯：scan-symbols / translate/edits / map-caret
edit4/plugins/sync/session.rkt     session 值 + World.store 读写
edit4/plugins/sync/mark.rkt       对应词高亮 decor（sync-mark）
edit4/plugins/sync/sync.rkt        钩子（after-edit/insert/nav/focus-changed）+ 命令
edit4/plugins/sync/plugin.rkt     装配（C-o 前缀：o/i/p）
```

- 命令（`C-o` 前缀）：`C-o o` `sync-open`（为**焦点现有文档**创建/打开翻译文档：
  已配对→打开它（新编辑区或聚焦旧窗）；否则按内容判方向翻译一份内存文档 + 新开编辑区 + link）、
  `C-o i` `sync-link`（焦点窗↔下一个编辑器窗）、`C-o p` `sync-unlink`（解除）。
- 方向判定：`detect-direction`——源文本里出现 b 侧词（中文）→ b->a，否则 a->b。
- 钩子：源侧 `after-edit`/`after-insert` → `translate/edits` → 文本不同才 `assign!` peer；
  `after-nav`/`focus-changed` → 只搬光标。程序化写不 emit 钩子 ⇒ 无回环。
- 高亮：`sync-mark` decor（`plugins/sync/mark.rkt`）把光标所在映射词整段涂色；配合光标同步 =「对应词高亮」。
- 测试：`edit4-test/sync.rkt`（纯变换 round-trip / 串注释不误改 / 光标映射 / 双向同步 / 命令 / 高亮）。

**下一步（可选）**：adapter 带 `changes` + `replace-range!` 做行级增量；大文档异步 job + CAS；
状态栏/会话面板；命名约定 `foo.rkt ↔ foo.zh.rkt` 自动配对。
