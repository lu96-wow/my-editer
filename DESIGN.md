# 插件线程化 + undo/redo 设计（调研稿）

> 本文是「先搜集资料 + 设计」阶段的产物，未实现。目标是给两件事定方案：
> 1. 让耗时插件不阻塞输入（参考 Emacs）。
> 2. undo/redo，含**时间窗口合并**与**粒度**设计。

---

## 0. 现状回顾（决定设计约束）

- 插件是纯函数 slot：`buffer → buffer`（吃 `dirty`，见 `framework/slots.rkt` 的
  `run-plugins` / `run-plugins-init`）。目前全在事件循环主线程里同步 fold。
- buffer 是 `#:transparent` 的**持久化结构**，每次编辑返回新 buffer + 一个
  `edit-desc`（统一 splice：删 `[s..e)` 插 `new-text`）。`tick` 单调递增，
  `dirty` 是插件唯一的增量依据。
- 事件循环：`framework-run` = `render → output → read(阻塞) → handle`，`read`
  由 tui 后端注入（`read-event` 阻塞）。
- 编辑管线是「自由」的：命令作者在 `reference/commands.rkt` 的 `edit-active` 里
  手动组合 `frame-edit-active → run-plugins → frame-sync-buffer → frame-ensure-active`。

这两点很关键：
- **纯函数 + 持久化** 让 undo 可以走「快照」路线（结构共享，便宜）。
- **阻塞式 read** 是线程/异步化要改的第一处（否则后台结果没人收）。

---

## 1. Emacs 调研

### 1.1 Emacs 的「线程」到底是什么

Emacs Lisp 线程（Emacs 26+，`make-thread` / `thread-yield`）是**协作式**的：
- 有全局解释器锁，Lisp 线程之间**不能真并行跑 CPU**，只能靠 `thread-yield`
  主动让出，让 UI 在间隙里响应。
- 所以 Emacs 的语法高亮**不用线程**，而是 `jit-lock`：**延迟 + 分块**——把
  fontify 拆成小块，在 idle 定时器里一段一段做，两次按键之间做一点。
- 真正的异步（子进程 / LSP / 网络）走**子进程 + sentinel/filter 回调**，不是线程。

> 结论：Emacs 的「不阻塞」核心是**协作式分块（jit-lock）** + **异步回调（sentinel）**，
> 而不是并行线程。

### 1.2 Emacs 的 undo 模型

- `buffer-undo-list` 是一条**线性列表**：`(记录* 边界 记录* 边界 ...)`，`nil` 是
  **边界（boundary）**。
- 记录存的是**被删除的原文 + 位置**（不是快照）：
  - 插入记录 `(pos . text)`
  - 删除记录 `(pos text)`（text 是被删内容）
  - 位置调整记录（给 marker 用）
- **一次 `undo` = 回退到上一个边界为止**；**没有独立 redo 栈**——redo 就是
  「再 undo 一次」（undo 记录里已经含正/反两方向的信息）。
- **合并（amalgamate）**：
  - `undo-auto-amalgamate`：相邻的自插入字符（打字）自动合成一个边界组。
  - idle 定时器：用户停顿一段时间后自动插入边界 → 「快速连打的一段」是一个
    undo 单元，停顿后重新分组。
- **内存预算**：`undo-limit` / `undo-strong-limit` / `undo-outer-limit`
  （字节预算），超了丢最老记录。

### 1.3 直接搬 Emacs 到本项目的差异

| Emacs | 本项目 | 影响 |
|---|---|---|
| 可变 buffer，undo 记录存「被删文本」 | 不可变 buffer，编辑产生 `edit-desc` | 记录式要补「被删原文」 |
| marker 要位置调整 | 我们也有 marker/overlay | 快照路线免掉这一步 |
| 线性 undo，无独立 redo | 我们可自由选 | 快照路线用 past/future 两栈更清晰 |

### 1.4 VSCode 的插件模型（对照）

VSCode 插件跑在**独立的 Extension Host 进程**（Electron：main / renderer /
extension host 三进程），不在 UI 进程里——插件卡死/崩溃不冻结界面。

- 扩展宿主内部是**单线程 Node 事件循环**，JS 本身不并行；同步死循环会卡住所有
  插件（但 UI 没事）。
- 真并行靠 `worker_threads`（少数 CPU 密集插件）或**外部进程**（语言服务 = 独立
  LSP server，JSON-RPC over stdio，与 Emacs 的「子进程 + sentinel」本质相同）。
- 语法高亮：TextMate tokenization 在渲染进程**异步分块**做（≈ jit-lock）；
  semantic highlighting 来自 LSP 进程。

> 三家共同结论：**别让耗时计算阻塞 UI**，手段不是「线程」而是
> 「分块/让出 + 外部进程 + 需要时才并行」。见 2.1 的 Racket 三档对照。

---

## 2. 设计一：插件线程化

### 2.1 Racket 三档「线程」：先分清并发与并行（关键修正）

| 原语 | 本质 | 多核并行 | 数据怎么传 | 适用 |
|---|---|---|---|---|
| `thread` | 绿线程，单 OS 线程上并发 | ❌ | 共享堆（同 place） | 异步 I/O、回调 |
| `future` | **真并行**，为纯函数设计 | ✅ | 共享堆，无需序列化 | **纯 CPU 插件** |
| `place` | 真并行 + 独立内存空间 | ✅ | 序列化（贵） | 极端隔离/大块任务 |
| `subprocess` | 独立进程 | ✅ | 管道/JSON-RPC | LSP、lint 等语言服务 |

**关键澄清**：纯数据变换 + lambda 应用，**完全能真并行**，而且这正是 Racket
`future` 的设计目标场景——`(future (lambda () (p b)))` 里 `p` 是纯 `buffer→buffer`，
就能真·多核跑，且共享堆、不用序列化。此前说「要真并行才需要 place」不准确，
`future` 才是正解（place 只是要隔离时才用）。

### 2.2 分层方案（按代价从低到高）

#### 2.2.1 同步（现状，轻插件）

`buffer → buffer`，事件循环里直接 fold。demo 的 regexp 高亮属于此类，不改。

#### 2.2.2 协作式分块（jit-lock 风格，限时不让步）

不改线程，只改「每帧跑多少」：重插件拆成 chunk，idle 调度器用时间预算
（每帧 ≤ 2ms）跑几个 chunk 就 `yield` 回输入。语义不变，只是**不阻塞**。

#### 2.2.3 future 真并行（重 CPU 插件，新增正道）

把重插件标成 `parallel`，用 `future` 真并行。两个前提：

- **粒度阈值**：dirty 只有几行时 future 调度开销 > 收益，此时退回 2.2.1/2.2.2；
  预计工作量够大（如全文件重扫）才上 future。
- **组合语义**：`run-plugins` 是顺序 fold（后插件看见前插件输出）。跨插件并行
  只在「插件互相独立」时成立；否则在**单插件内部**并行——把 dirty 行分片，
  `(map touch (map (lambda (chunk) (future (lambda () (p-chunk b chunk)))) chunks))`，
  再按序合并。

> 基准已验：4 个纯 CPU job 用 future 跑 1198ms vs 顺序 2018ms，确实并行。

#### 2.2.4 异步 I/O 插件（LSP / lint 子进程）

I/O 型用 `thread` + channel（或 `subprocess` + 端口），结果回主循环后按
`buffer-tick` 校验：tick 变了就丢弃重算（= Emacs sentinel / VSCode LSP 的 stale 处理）。

#### 2.2.5 place（可选，仅当需要 OS 级隔离）

独立内存空间 + 序列化，成本高。语言服务用 `subprocess` 即可，一般不碰 place。

### 2.3 事件循环改造（支撑 2.2.2 / 2.2.3 / 2.2.4）

现在是 `read` 阻塞式；要支持 idle 分块 / 收 future 结果 / 收后台结果，把
`framework-run` 的 `read` 改成**可多路复用**：

```racket
;; 输入事件 | 插件结果 | 定时器到期 三选一
(framework-run cfg f0 next-event draw)
;; next-event : (-> (or/c event 'tick 'plugin-result ...))  用 sync 组合
```

tui 后端用 `read-event-noblock` + `sync`（channel / 定时器）实现；GUI/Web 后端
本来就事件驱动，天然适配。

### 2.4 插件 slot 的最终形态（建议）

保持「类型明确、不搞万能 Plugin」：

```racket
;; 轻插件（现状，不变）
buffer-plugin   : (-> buffer buffer)

;; 重插件：限时分块（不阻塞，不并行）
chunked-plugin  : (-> buffer (values buffer more?))

;; 重 CPU 插件：future 真并行
parallel-plugin : (-> buffer buffer)

;; I/O 型插件：后台线程/子进程，结果按 tick 校验
async-plugin    : (-> buffer buffer)
```

组合器相应加 `run-chunked-plugins`（时间预算）、`run-parallel-plugins`（future）、
`run-async-plugins`（channel 收集）。**demo 高亮保持同步轻插件不动**。

**future-safety 提醒**：纯数据变换没问题；但插件若内部碰到 future-unsafe 操作
（I/O、部分带缓存的 regexp、FFI）会**静默退化为同步执行**。上 future 前要对
 demo 的 regexp 高亮做个基准确认。

### 2.5 两类插件：无状态 map vs 有状态 fold+view（重要补充）

「丢弃重算」只对**无状态**插件成立。语言服务器这类**累计型**插件要换一套规则。

| | M 类：无状态 map | F 类：有状态 fold+view |
|---|---|---|
| 例子 | 高亮、lint 规则 | LSP、增量索引、符号表 |
| 本质 | `f : Buffer → Buffer`，只依赖当前 buffer | `State` 是 edit 流上的 left-fold |
| 可丢 | 结果可丢、可整体重算 | **状态不可丢、不可跳步**；只有投影可丢 |
| 顺序 | 无关 | **必须按序**消费 edit-desc |

F 类的精确描述：

```
S_i        = step(S_{i-1}, edit_i)   ; 累计状态（不可交换，按序消费）
patches_i  = view(S_i)                ; 投影（渲染图），可丢、可重算
```

- 只能丢 `view(S_i)`（渲染图）；`S_i` 是事件日志上的 scan，丢了只能从头重放。
- 按序消费发生在插件自己的 worker 队列里，不阻塞 UI。
- 接入已有 `edit-desc` 流（架构里 desc 本就透传、不丢弃）。

合并与失效：

- M 类：独立并行（写集不相交）+ 可丢弃重算（前文 R4 原样）。
- F 类：对 UI 永远串行，合并 =「该插件最新投影覆盖自己的 key」；不「失效」，只是投影**滞后**。
  - 版本匹配：投影带版本号，版本不符先丢这条投影等下一版（状态照常前进）。
  - 位置映射：用 `edit-desc-map-position` 把投影坐标从 i 版映射到 m 版（进阶）。
  - full resync：队列追不上 / 文档被整体替换时兑底。

类型草图：

```racket
(struct stateful-plugin (init step view) #:transparent)
;; init : -> State
;; step : State edit-desc -> State
;; view : State -> (listof patch)
```

---

## 3. 设计二：undo / redo

### 3.1 数据模型：快照 zipper（推荐）

利用「buffer 不可变 + 结构共享」，undo 不存编辑记录，**直接存 buffer 快照**：

```racket
;; history.rkt（新，纯函数）
(struct history-entry (buffer anchor) #:transparent)  ; anchor = 编辑起点(光标回跳用)
(struct history
  (past future          ; (listof history-entry)  栈
   last-key last-time   ; 合并判定：分组键 + 单调时间戳
   limit)               ; 最多保留多少步
  #:transparent)

(history-commit h old-b new-b anchor key now) -> history
  ;; 同 key 且 now-last-time < T → 不 push（合并进上一步），只清 future
  ;; 否则 push old-b 进 past，清 future

(history-undo h) -> (values h* buffer? anchor?)
(history-redo h) -> (values h* buffer? anchor?)
```

- undo：把当前 buffer 推入 future，从 past 弹一个快照 → 替换 buffer。
- redo：对称。
- **合并 = 不 push**。这是快照路线最优雅的地方：Emacs 的 boundary/amalgamate
  在这里退化成一个 `if`。

### 3.2 时间窗口合并 + 粒度设计（你要的重点）

合并判定三元组：**`(key 相同) ∧ (Δtime < T) ∧ (位置相邻)`**。

| 粒度 | key | 说明 | 例子 |
|---|---|---|---|
| 字符 | `'insert` / `'backspace` | 连续打字/退格，Δtime<T 合并 | `"hello"` 一次 undo 全删 |
| 命令 | 命令名（或 `#f`=不合并） | 每个语义命令一个单元 | 粘贴、删除整词、回车 |
| 事务 | 显式事务 id | 命令作者包多个原语成一步 | `with-undo-group` 括起来 |
| 停顿 | —（由 Δtime 触发） | 停顿超 T 自动断组 | 打字 → 停 2s → 再打字 |

- **时间窗 T**：可配置，建议默认 ~500ms（打字合并）；Emacs 用 idle 定时器实现
  同效果（停顿即插边界）。
- **位置相邻**：只在「同一光标位置连续编辑」时合并，避免「编辑 A 处、快速跳到
  B 处又编辑」被误合并（Emacs 的 self-insert amalgamate 也有这个约束）。
- **粒度开关**：命令作者用 `key` 声明本命令的粒度；框架只负责「同 key + 时间窗」
  的机械合并，不含具体策略（符合「策略在命令层」的分工）。

### 3.3 为什么选快照而不是 Emacs 的记录式

| | 快照 zipper | 记录式（Emacs） |
|---|---|---|
| undo/redo 复杂度 | O(1) 弹栈 | 回放 N 个记录 |
| 内存 | N 个 buffer（结构共享，只差改动行+小结构） | N 条记录（存被删文本） |
| marker/overlay 恢复 | 免费（快照里带着） | 要位置调整 |
| 合并/粒度 | 一个 if | boundary 管理 |
| 选择性 undo（只撤某区域） | 不支持 | 支持 |

本项目「纯函数 + 持久化 + 最清晰实现」的取向，明显偏**快照 zipper**；记录式
只在「超大 buffer + 深历史」内存吃紧时再考虑。

### 3.4 集成点（不改 core 语义）

- 新模块 `core/text/history.rkt`：纯 `history` + 上述原语，独立可测。
- history **不放 buffer 里**（buffer 保持纯内容），也不放 config（config 是静态策略）。
- 短期最省事：作为 `frame` 的一个字段（frame 本就是被线程化的状态，且已管
  linked-buffer 同步）；undo 换 buffer 后复用 `frame-sync-buffer` 的同步逻辑
  把共享窗口一起换。
- 多文档（未来 workspace 层）时，把 `history` 从「单值」改成
  `hashof doc-id history`，接口不变。

### 3.5 与线程插件的交互

- 快照自带属性/marker → undo 后 **dirty 清空、无需重跑插件**（顺便省一次高亮）。
- 若后台插件结果在 undo 期间回来，`tick` 校验自动判过期丢弃——与 2.1.2 同一套机制。
- 时间窗用**单调时钟**（`current-inexact-monotonic-milliseconds`），不被打断/睡眠影响。

---

## 4. 开放问题（需要你拍板）

1. **undo 深度**：`limit` 按「步数」（如 100）还是「字节预算」（如 Emacs）？
2. **时间窗 T 默认值**：500ms？还是学 Emacs 的「停顿即断组」语义？
3. **插件并行**：纯 CPU 重插件走 `future` 真并行（2.2.3）——先做这个，还是
   先做限时分块（2.2.2）？粒度阈值（多少 dirty 行才上 future）定多少？
4. **history 挂哪**：挂 `frame` 字段（快、单文档够用）还是直接起 `workspace` 层
   做 `doc-id → history`（为多文件铺路）？
5. **redo 语义**：快照 zipper 的 redo 是「撤销 undo」；要不要支持「新编辑后
   redo 栈清空」？（标准做法：要清空，见 3.1 的 commit）

---

## 5. 逻辑边界（实现契约，动手前对齐）

把「机制 / 插件 / 组合 / 调度」四层边界钉死，实现时各自只在自己这层动。

### 5.1 已有机制（core，不动）

- `buffer`（不可变：content + properties + markers + overlays + tick + dirty）
- `edit-desc`（统一 splice，编辑必产、不丢弃）
- `dirty`（插件增量依据）、`tick`（任何 buffer 变化都 +1）
- 属性/marker/overlay 及 `buffer-put-text-properties` 等原语

### 5.2 内容版本判定（新增一个小原语）

async 失效要区分「用户改了内容」与「插件只写了标注」。现有 `tick` 两者都涨，
所以用 `eq?` 直接比 content（content 是不可变 struct，只在 splice 时换新）：

```racket
;; (buffer-content-same? a b) : 内容未变（插件可以安全合并）
(define (buffer-content-same? a b) (eq? (buffer-content a) (buffer-content b)))
```

### 5.3 插件输出 = patch（新增，边界核心）

插件不能返回整块 buffer（否则无法并行/延后合并），必须返回 **delta**：

```racket
(struct patch (key first-line last-line segs) #:transparent)
;; key   : 归属键（不同插件写不同 key → 并集合并无冲突）
;; first/last : 本次重新推导的行范围（应用时先清范围内该 key 旧值）
;; segs  : (listof (list line start end val))
```

应用原语（core 提供，不 bump content，只 bump tick）：

```racket
(buffer-apply-patches buffer patches) -> buffer
```

### 5.4 插件两形（输入边界）

- **M 类（无状态）**：`buffer -> (listof patch)`，只读 buffer + dirty，返回自己的 delta。不知道线程。
- **F 类（有状态）**：`(struct stateful-plugin (init step view))`
  - `init : -> State`
  - `step : State edit-desc -> State`（按序消费 edit-desc，不可跳）
  - `view : State -> (listof patch)`（投影，可丢）

### 5.5 组合声明（spec）

```racket
(struct plugin-spec (name plugin deps mode) #:transparent)
;; deps : (listof name)   非空=串行链；空=独立可并行
;; mode : 'sync | 'async
```

- 依赖 = 串行；无依赖 = 独立（并行）。
- 「独立」的前提 = 写集不相交（不同 key），用 debug 断言可查，不硬性强制。

### 5.6 调度器（唯一知道线程的地方）

- 输入 `(listof plugin-spec) + buffer`；
- 按「最长依赖深度」分层，同层用 `future` 并行，层间串行（见 `plugin-pipeline-demo.rkt`）；
- `sync`：阻塞返回最终 buffer；`async`：立即返回基线 buffer + 结果句柄（channel）。

### 5.7 失效判定（async）

- **M 类**：结果携带启动时的 content 引用；应用 iff `buffer-content-same?`，否则丢弃重算。
- **F 类**：不丢状态、只丢投影；投影带版本号，版本不符可丢或 `edit-desc-map-position` 映射（进阶）。

### 5.8 事件循环边界（framework/tui 改造）

`framework-run` 的 `read` 从阻塞改为**多路复用**：`输入事件 | 插件结果 | idle 定时器`。
tui 用 `read-event-noblock` + `sync`；异步插件结果作为「结果事件」回循环，通过
`buffer-content-same?` 后应用 → 触发重渲染。

### 5.9 实现顺序建议

1. `core/text/patch.rkt`：`patch` + `buffer-apply-patches` + `buffer-content-same?`。
2. `framework/` 调度器：`run-plugins-spec`（依赖分层 + future + sync/async + 失效校验，M 类）。
3. 把 demo 的 `keyword-hl` 改成返回 patch，接入验证。
4. 事件循环多路复用（async 结果回 UI）。
5. F 类（edit-desc 队列 + step/view）最后做。
