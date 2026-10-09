# DESIGN — `edit/plugin/analysis/`：Racket 结构 / 语义分析工具层

> 目标：**不使用 racket-langserver 的代码**，直接用 DrRacket 官方公共 API
> （`drracket/check-syntax`、`syntax-color/module-lexer`、`syntax-color/racket-lexer`、
> `data/interval-map`），给编辑器做词法 / 结构查询、语义 token、定义引用、hover、诊断。
>
> 策略：**先把工具搭好（独立、headless、可进 place worker），再接编辑器。**

---

## 0. 参考：RLS 的哪部分值得抄

| RLS 组件 | 我们抄什么 | 不抄什么 |
|---|---|---|
| `doclib/lexer/` | 扁平 token 快照 + token forest + 结构查询的分层 | 它每次都全量 re-lex（我们后续可增量） |
| `doclib/check-syntax.rkt` | `drracket/check-syntax` 的 `make-traversal/expand/add-syntax` + collector | 它把一切都塞进可变 `Doc` |
| `doclib/service/*` + `doc-trace.rkt` | **一次展开、多服务扇出**（`walk-stx`） | 类继承 + `syncheck-*` mixin 那套 |
| `lsp/safedoc.rkt` | **版本门控**：结果只装到发起版本 | rwlock + 可变文档 |
| `lsp/scheduler.rkt` | 同 `(doc, type)` 任务**去重/顶掉**；等待式查询 | 线程 + break-thread |
| `workspace/` | 每文件一份 contribution（defs/uses）合并成索引 | 具体 LSP 结构 |

我们的优势：文档不可变 + 版本槽 + place 异步 + 版本闸门，天生就是 RLS 费力搭的那套。

---

## 1. 依赖边界（硬约束）

```
tools/                       ← Phase 1，唯一允许的依赖：racket 官方库
  span.rkt  pos.rkt  lexer.rkt  forest.rkt  expand.rkt  analyze.rkt  worker.rkt
adapter/                     ← Phase 2，唯一允许 require session 的部分
  service.rkt  semantic.rkt  (后来) hover.rkt  definition.rkt  diagnostic.rkt
```

- **tools 禁止** require `edit/session`、`core/editor`、`tui`、`plugin/registry`。
  → 这样工具能：headless `raco test`、丢进 place worker、被复用。
- **adapter** 是唯一把这些工具接进会话的地方。
- 依赖方向单向：adapter → tools → `racket/*`。

---

## 2. 坐标约定（先钉死，否则后面全是坑）

- 工具内部统一 **0-based 字符偏移**（char offset，半开区间 `[start,end)`）。
  - `drracket/check-syntax` 的 `syntax-position` 是 **1-based**，减一；`syntax-span` 是长度。
  - `syntax-color` lexer 也报 1-based，减一。
  - 跨行 token（字符串 / 注释 / 多行字符串）用偏移天然能表达，不必先切行。
- **行列换算独立成 `pos.rkt`**：由整篇文本建「行首偏移向量」，之后 O(log n) 查。
  行列用 0-based，与 `track` 的 `(line,col)` 对齐。
- 编辑器接入时由 adapter 做 `offset ↔ (line,col)`；工具不 import `track`。

---

## 3. 数据形状（`span.rkt`，全部 `#:prefab` 以便跨 place）

```racket
;; 半开字符区间
(struct span (start end) #:prefab)

;; 词法 token（forest / 缩进 / 结构查询用）
(struct token (span type) #:prefab)                 ; type : symbol
;;   类型集（归一化后）：open-paren close-paren symbol string number comment
;;   white-space quote quasiquote unquote unquote-splicing sexp-comment
;;   syntax-quote ... lang-directive reader-directive other

;; 语义 token（展开后）
(struct sem-token (span type modifiers) #:prefab)   ; type ∈ function|variable|string
;;                                                   ;        |number|regexp|comment
;;                                                   ; modifiers : (listof symbol)

;; 定义 / 引用（草稿；Phase 3 细化）
(struct occurrence (span name) #:prefab)
(struct definition (span name path) #:prefab)

;; 诊断
(struct diagnostic (span severity message) #:prefab)   ; severity ∈ error|warning|info

;; 结果（可增量、可分阶段）
(struct lex-result    (path tokens) #:prefab)
(struct expand-result (path sem-tokens definitions uses diagnostics) #:prefab)
(struct analysis-result(path version lex expand) #:prefab)  ; expand : expand-result | #f
```

设计点：`lex` 与 `expand` **分开**，对应 RLS 的两层——
词法结果便宜、可先出（缩进/结构/括号配对立刻可用），展开结果贵、异步后到（语义高亮/诊断）。

---

## 4. 模块职责与接口

### Phase 1 —— 工具（本轮要搭的）

| 文件 | 职责 | 公开接口 |
|---|---|---|
| `span.rkt` | 数据形状 + 构造 + 判空 / 包含 / 相交等纯工具 | `(struct-out …)`、`span-contains?`、`span-intersect?` |
| `pos.rkt` | 偏移 ↔ 行列 | `(make-line-index text)`、`(offset->line/col idx off)`、`(line/col->offset idx l c)` |
| `lexer.rkt` | `syntax-color` 包装：文本 → `(listof token)` | `(lex-text text [path])`；类型归一化（照 RLS `normalize-token` 的思路，但自己写） |
| `forest.rkt` | 扁平 token → **token forest**（平衡括号 / quote 前缀 / sexp comment）；结构查询 | `(build-forest tokens)`、`(forest-enclosing-list f off)`、`(forest-form-head f off)`、`(forest-sexp-comment-spans f)` |
| `expand.rkt` | `drracket/check-syntax`：一次展开 + collector → `expand-result` | `(expand-analyze path text)`；**只在 worker 里调** |
| `analyze.rkt` | 工具门面：orchestrate lex/forest/expand | `(analyze-lex path text) → lex-result`、`(analyze-expand path text) → expand-result`、`(analyze path text version) → analysis-result` |
| `worker.rkt` | place worker 入口；沙箱 + 限额；请求分派 | 用 `runner.job-worker-main` 包一个按 `(type . args)` 分派的 handler |

### Phase 2 —— 编辑器接入（先设计，后实现）

| 文件 | 职责 |
|---|---|
| `service.rkt` | `analysis-state` 文档槽 `(path version lex expand pending?)`；编辑 → 标脏 + debounce → 提交 job（同 did 顶掉旧的）；结果经 `session-await` 版本门控装槽；发 `after-analysis` hook |
| `semantic.rkt` | `expand-result` 的 sem-tokens → 每行 face 向量（`track`），复用现有 face 层写回（脏行增量；叠在 syntax/words 之上） |
| `hover.rkt` / `definition.rkt` / `diagnostic.rkt` | 后续：overlay 浮窗 / 跳转 / 波浪线 + 面板；用「等待在途分析」而不是轮询 |

### 与现有代码的接点（不新增抽象）

- **异步/版本**：`edit/plugin/runner.rkt`（place）+ `edit/session/async.rkt`（`session-await`，token = document handle）。
- **状态**：`define-document-slot`（`edit/session/core.rkt`）。
- **写回**：`session-doc-face-lines!` + 每行 face 向量（就是 `words`/`syntax` 用的那套）。
- **触发**：`after-edit` / `after-nav` / `document-closed` hook。
- **共享服务**：`session-service-ref/put`（放 workspace 跨文件索引）。

---

## 5. 安全（硬要求）

`expand` 会**执行被打开文件的编译期代码**（`#lang` / 宏），可能死循环、弹窗、写文件。因此：

1. `expand.rkt` **只允许经 `worker.rkt` 调用**，绝不跑在 UI 线程 / 主 place。
2. worker 里用 `with-limits`（时间 + 内存）包住；超时 / 异常 → 返回 **失败结果**（`expand = #f`），不注入半成品。
3. worker 用独立 namespace（`make-base-namespace` + `current-load-relative-directory` + `current-annotations`），照 `expand-source` 的做法。
4. 测试**只用仓库自带 fixture**（`edit/plugin/analysis/test-fixtures/*.rkt`），绝不展开任意外部代码。
5. 结果全部 `#:prefab`，跨 place 安全。

---

## 6. 构建步骤（每步都能独立编译 + headless 测试）

> 验证命令（工具在第 4 层，make 补一段）：
> `raco make edit/*.rkt edit/*/*.rkt edit/*/*/*.rkt edit/*/*/*/*.rkt` +
> `raco test edit/test/*.rkt`。测试放扁平 `edit/test/analysis-*-test.rkt`，与现有约定一致。

- **Step 1 — `span.rkt` + `pos.rkt`**
  测：偏移/行列 roundtrip、跨行、CJK、空文档、末尾无换行。
- **Step 2 — `lexer.rkt`**
  测：`(` `[` `{` 归一到 `open-paren`；字符串 / 行注释 / 块注释 / `#;` / quote 系列 / `#lang` 行分类正确；类型归一化稳定。
- **Step 3 — `forest.rkt`**
  测：enclosing list（最内层）、form head（跳过空白 / 注释 / sexp-comment）、sexp-comment 区间；不平衡括号不崩。
- **Step 4 — `expand.rkt`**
  测：自带 fixture 上的 sem-tokens / definitions / uses / diagnostics；**只跑 fixture**。
- **Step 5 — `analyze.rkt` + `worker.rkt`**
  测：`analyze` 端到端；经 place 往返（序列化正确）；超时/异常返回失败；同请求不串。
- **Step 6（Phase 2）— `service.rkt`**
  测：编辑 → 提交 → 版本闸门（过期结果丢弃）→ 装槽 → hook；document-closed 清理。
- **Step 7（Phase 2）— `semantic.rkt`**
  测：sem-tokens → 每行 face 层，与 syntax/words 叠加；脏行增量正确。
- **Step 8+（Phase 3）— hover / definition / diagnostic / workspace 索引。**

---

## 7. 与编辑器衔接的设计（Phase 2 先想清楚，避免返工）

- `analysis-state` 槽值 `(path version lex expand pending?)`，随 document 版本 fork。
- 编辑：`after-edit` → 若与上次版本相差不大，先 `text-replaced/expand/contract` 平移旧区间（乐观），再 **debounce ~300ms** 提交 `analyze` job。
- job：`(list 'analyze path text version)`；同 did 只保留最新（顶掉旧的，结果回来时比对 version / handle）。
- 结果：`session-await` 版本门控 → 装槽 → `after-analysis` hook。
- semantic：`semantic.rkt` 把 sem-tokens 变成 per-line face 层，交给现有写回原语；不必改 `session-doc-face-lines!`。
- 等待式查询：hover / definition 若在途，用 `session-await` 注册回调，结果到了再渲染（不轮询）。
- 跨文件：成功分析后产 `contribution`（path + defs/uses），存全局 index 服务；references/definition 先查本地再查全局。

---

## 8. 暂不做 / 待定

- 增量 lexer：RLS 全量 re-lex；我们 Phase 1 先全量（放 worker），Phase 4 再考虑按行状态增量。
- 多光标 / 编辑期乐观平移的具体区间算法：Phase 2 用 core 的 `change-map-point` 复用。
- Typed Racket / Scribble / Rhombus 的语言策略：先只做 `#lang racket` 家族，其余「不分析、不报错」。
- 格式化 / code action / rename：更后面。
- 诊断：Phase 1 只在读取 / 展开失败时给粗粒度 error；`walk-log` 的精细诊断留 Phase 3。

---

## 9. 进度

- [x] Step 1 `span.rkt` + `pos.rkt`（`edit/test/analysis-span-pos-test.rkt`）
- [x] Step 2 `lexer.rkt`（`edit/test/analysis-lexer-test.rkt`）
- [x] Step 3 `forest.rkt`（`edit/test/analysis-forest-test.rkt`）
- [x] Step 4 `expand.rkt`（`edit/test/analysis-expand-test.rkt`）
- [x] Step 5 `analyze.rkt` + `worker.rkt`（`edit/test/analysis-worker-test.rkt`）
- [ ] Step 6 `adapter/service.rkt`
- [ ] Step 7 `adapter/semantic.rkt`
- [ ] Step 8+ hover / definition / diagnostic / workspace 索引
