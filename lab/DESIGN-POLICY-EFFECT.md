# Policy 与 Effect 接口详设

> 配套 `DESIGN.md`。本文只细化两个最关键的组合子：**Effect（动作即数据）** 与
> **Policy（决策组合子）**。仍不写实现，只定接口、语义、律、取舍。

---

## 0. 病根：旧 lab 的「动作即过程」

旧 lab 里，命令是过程，直接改状态：

```racket
(define (cmd-quit e a) (app-quit! a))
(define (app-quit! a)
  (define dids (…))
  (close-documents! a dids (λ () (set-app-quit?! a #t))))
```

于是五个跨切面全被写死成命令内部的 `if` / 递归：

| 跨切面 | 旧做法 | 后果 |
|---|---|---|
| 保存确认 | `close-documents!` 里递归询问 | 无法复用、无法和其它关闭策略组合 |
| 撤销合并 | `undo-typing-policy` 在插入处算 tag | 策略散在命令里 |
| 真实文件守卫 | `when (path-table-path …)` | 每个异步入口各写一遍 |
| 版本闸门 | 调用方手写 `(cons id doc)` 或 token | 重复且易漏 |
| 焦点 / 放置 / 过滤 | app-handle-input、show 里分支 | 无法声明、无法排序、无法测 |

**根因**：动作没有中间表示。没有中间表示，就无法在"意图"和"执行"之间插入策略。

---

## 1. 设计选型：为什么不直接上常见的四种方案

| 方案 | 代表 | 为什么不够 / 不适合 |
|---|---|---|
| **命令即过程**（旧 lab） | Emacs 部分命令 | 跨切面只能硬编码；命令不可拦截/回放/测 |
| **通用中间件链** | Ring / Express | 中间件只包裹"请求"，没有**结构化状态变换**；无法表达"关闭多个文档"这种复合动作的取消/续做 |
| **call/cc 续延** | 部分 Scheme 编辑器 | 挂起要跨事件（等用户回答），捕获宿主续延跨事件循环不现实、不可序列化、难测 |
| **Redux 式 event→state reducer** | 前端 | reducer 是纯 state 变换，但编辑器有异步/命令/模态/多视图，把一切塞进单一 reducer 会爆；且失去 core 的增量模型 |

**本设计选**：**动作 = 数据（Effect）+ 决策 = 组合子（Policy）+ 挂起 = 显式交互（Interaction）**。
理由：

1. 动作有中间表示 → 可在"意图"与"执行"间插入任意策略；
2. Policy 是纯函数 → 可排序、可枚举、可 mock 单测；
3. 挂起用**显式状态机**而非宿主续延 → 跨事件、可序列化、可回放、可测；
4. Effect 只描述**状态变换**，不表达控制流 → 控制流全在 Policy 层，两者正交。

---

## 2. 四件套总览

```
Event ──resolve──▶ Action ──before-policy──▶ (决策) ──▶ invoke──▶ Effects ──after-policy──▶ apply ──▶ Session + Output
                     ▲                                        │
                     └──────── Interaction.resume ◀──────────┘（挂起时）
```

| 件 | 是什么 | 关键性质 |
|---|---|---|
| **Action** | 一次"请求做某事"的意图（命令 / 钩子 / 任务结果 / 定时器 / 续延） | 可匹配、可拦截 |
| **Effect** | 一次状态变换 / 副作用的**描述**（数据） | 可排序、可改写、可测 |
| **Policy** | 对 Action 的**决策函数**（before 阶段）/ 对 Effect 列表的**变换函数**（after 阶段） | 纯、有序、优先级 |
| **Interaction** | 被挂起的 Action 的**显式状态机**（跨事件） | 可序列化、可续做 |

为什么把 Action 和 Effect 分开，而不是都叫"意图"？
- Action 有**事件上下文**（哪个命令、哪个键、什么时机）→ 适合"许可 / 挂起"类决策；
- Effect 没有事件上下文（只有"改什么"）→ 适合"改写 / 过滤"类变换。
- 分开后，before-policy 不必假装自己懂 Effect，after-policy 不必关心事件。职责单一。

---

## 3. Effect：动作即数据

### 3.1 类型

```racket
;; Effect = 一个带 tag 的值。用 struct 而非裸 list，换取契约与可读性。
;; 每个 tag 一个 struct；见目录 3.2。
(define effect? (λ (x) (effect-tag x)))
(define (effect-tag e) …)      ; 'edit | 'move | 'open | …
```

> **为什么用 struct 而不是 symbol+args？**
> 旧 lab 的钩子用 symbol+变参，参数错误只在运行时、且无类型。Effect 是策略匹配与
> 改写的对象，必须可安全内省。struct 给出字段名、可加 contract、可模式匹配。
> 代价：扩 effect 要加类型。可接受，因为 effect 集合是**受控的**（见 3.2），
> 不像插件值那样开放；插件只能**组合**已有 effect，不能发明新 effect。

### 3.2 目录（受控集合）

| Effect | 字段 | apply 语义 | 服务的功能 / 契约 |
|---|---|---|---|
| `edit` | vid edits [tag] | 走 core 多光标编辑；产 changes；发 after-edit/after-insert | F1、I15 |
| `move` | vid sels | 设选区（夹紧、ensure） | F1 |
| `reload` | vid value | 换内容，不记 history、封口 | F4/F5 面板与槽位 |
| `open` | path | 幂等：已有 did 复用，否则建文档 | F2、I17 |
| `view-new` | did placement | 为文档建视图并按 placement 放置 | F2/F3、I2/I18 |
| `close` | vids/dids | 关视图 / 文档（含连带） | F2 |
| `save` | did [path] | 写盘 | F2 |
| `place` | vid placement | 把视图放进工作区（策略可见，见 5.4） | F3、I2/I18 |
| `arrange` | op | split/swap/resize/remove | F3 |
| `focus` | target | 设焦点（vid / 方向 / restore） | F3、I1/I4/I8 |
| `sidebar` | #f \| panel-name | 显隐 / 切面板 | F4、I4 |
| `input` | op | push/pop/set 输入层、换槽位内容 | F6、I9/I10/I11 |
| `prompt` | prompt | 起一次输入（挂输入层） | F6 |
| `resume` | sid response | 触发交互续做 | 挂起机制 |
| `job` | job request | 提交异步任务（版本闸门内建） | F7、I13/I14 |
| `cancel` | job-id | 取消任务 | F7 |
| `notify` | hook args | 触发生命周期钩子（其本身也产出 effects） | I16 |
| `emit` | op | 逃逸到驱动（写盘 / place 消息 / 响铃 / 剪贴板） | F2/F10 |
| `quit` | — | 请求退出 | F2 |

**为什么 effect 集合是封闭的？**
插件不需要发明新状态变换，只需要**组合**已有变换（编辑、打开、弹层、提交任务）。
封闭集合让 kernel 可以穷举 apply 语义、可测、可校验。需要新变换时改 kernel（受控升级），
而不是让每个插件自定义——那正是旧 lab 不可控的来源。

**为什么 `notify` 是 effect 而不是直接调用？**
因为它也有顺序与一致性问题：after-edit 必须在 `edit` **应用之后**、`emit` 之前触发；
文档关闭的钩子必须在文档真正移除**之前/之后**有确定语义。把它作为 effect，
就能被排序、被策略过滤、被测试断言。旧 lab 到处 `hook-run!`，顺序靠调用位置隐式决定。

**为什么 `save` 和 `emit` 分开？**
`save` 是**编辑状态相关**的状态变换（要按 did 取内容、可能改修改标志）；
`emit` 是**与编辑器状态无关**的副作用（写任意文件、发 place 消息、响铃）。
分开后，`save` 可被策略门控（比如"只读模式禁止保存"），`emit` 只由驱动解释。

### 3.3 apply 语义（三条硬规则）

1. **顺序施加**：Effect 列表从左到右。前面的 effect 影响后面看到的 session
   （例如先 `open` 得 did，再 `view-new`）。
2. **无返回值**：effect 不返回东西。需要"结果"（如新建的 did/vid）时，
   由 kernel 把它写进 session 的派生表（routes / frame），后续 effect 从 ctx 读。
   > 为什么：effect 有返回值会让列表无法顺序表达依赖（y 依赖 x 的结果），
   > 退化成回调地狱。用 session 作唯一交换媒介，保持"数据流向下、状态集中在 session"。
3. **崩溃隔离**：单个 effect 的 apply 失败不吞没整批（记警告、跳过），
   但 `edit` 这类原子变换要么全成要么不动（沿 core 语义）。

### 3.4 不变式

- Effect 只通过 kernel 施加；命令 / 钩子 / 插件**禁止**直接改 session。
- `edit` 的 span 必须同一编辑前坐标系（沿用 core 约束）。
- `notify` 产生的 effects 与顶层一样过管线（一致语义），但有**重入预算**防无限递归（见 7.3）。
- `reload` 不产生 history 步；`edit` 产生。

---

## 4. Action：请求

```racket
(struct action (source payload) #:transparent)
;; source = (command name) | (hook name) | (job-result job-id) | (tick) | (resume sid)
;; payload : 该来源的上下文（命令参数 / 钩子参数 / 任务结果 / 响应）
```

**为什么要有 Action，不直接对 Effect 做策略？**
- "许可"类决策（保存确认、只读禁写）需要知道**意图来源与时序**（用户按了 quit？还是
  系统 tick？），Effect 没有这个信息。
- "改写"类决策（撤销合并、过滤任务）只需看 Effect。
- 两者都重要，所以引入 Action 作为 before 阶段的匹配对象。

**为什么 source 用 tagged value 而不是单纯命令名？**
钩子、任务结果、定时器也会产生 effect，也必须能被门控（例如"真实文件守卫"要拦
钩子提交的任务）。统一用 source，策略不必区分"命令"与"钩子"两套机制。

---

## 5. Policy：决策组合子

### 5.1 类型

```racket
(struct policy (id priority phase match? decide) #:transparent)
;; id      : symbol（唯一，注册表 upsert）
;; priority: 数字（大者先）
;; phase   : 'before | 'after
;; match?  : Ctx Action -> bool
;; decide  :
;;   'before -> Ctx Action -> BeforeDecision
;;   'after  -> Ctx Action (listof effect) -> (listof effect)

;; BeforeDecision = 'pass | 'abort | (listof effect) | interaction?
(struct interaction (start resume) #:transparent)
;; start  : Ctx sid -> (listof effect)
;; resume : Ctx sid response -> (listof effect)
```

### 5.2 before 阶段语义（门控）

按 priority 从高到低，对**匹配的**策略依次询问，直到有人做决定：

```
'pass     → 继续问下一个（默认：不插手）
'abort    → 丢弃该 Action，整批 effects 为空（终止）
effects   → 用这些 effect 取代该 Action 的运行结果（终止）
interact  → 挂起该 Action，登记 interaction 并用 (start ctx sid) 产出首批 effect（终止）
```

**为什么是"首个决定者终止"，而不是"所有策略都过一遍"？**
门控语义天然互斥（要么允许要么不允许），且优先级显式排序。若允许累积，
"abort 之后又有人 pass"这类组合需要额外规则，反而难推理。需要多道门控时，
让优先级高的先跑；通常它们匹配不同 Action，不会互相干扰。
（已知边界：两个真正需要**先后都执行**的门控，要合并成一个策略或用 interaction 链，
见 §11。）

**为什么 `'pass` 不产生效果？**
gate 只回答"准许与否"。要改行为用 after 阶段。这样 before 阶段的策略都极其简单可测。

### 5.3 after 阶段语义（变换）

按 priority 从高到低，每个匹配的策略接收**上一个策略输出的 effect 列表**，返回新列表：

```
effects' = (decide ctx action effects)
```

- **全部运行**（不是首个终止）；
- 可**过滤器式**丢弃 effect（返回去掉某些项的列表）→ 真实文件守卫；
- 可**注入** effect（在前面插 `notify`、`save`）→ 审计 / 自动保存；
- 不改 `match?` 的 action。

**为什么 after 用变换而非决策？**
因为 after 的典型需求是"在原有效果上增删"，不是二选一。变换可连续叠加，
且对顺序友好（priority）。撤销合并、过滤、审计都是变换。

### 5.4 放置 / 焦点 / 过滤：为什么也做成 Policy

旧 lab 把"打开文档替换 active 窗格"写进 `app-show-document!`。新设计里它是一个
**after-policy on Action `(command show-document)`**：把 `view-new` effect 的
`placement` 字段改写成目标策略。或者更直接：`show` 命令发出 `place` effect，
`place` 的 apply 会咨询 `'place` 子策略链。两种都行；推荐后者的**变体**：

```racket
;; 放置策略不是 policy，而是 placement 值的一部分（数据）
(struct placement (mode))  ; 'replace-active | (split dir) | 'reuse | 'float
```

**为什么放置用数据而不是 Policy？**
因为放置是**参数的枚举**，不是决策逻辑；把它做成数据更简单、可测、可扩展。
Policy 留给**真正需要条件判断**的场合（保存确认、只读、真实文件）。
判定标准：**能用有限枚举表达的选择 → 数据；需要看 ctx 才能决定 → Policy。**

### 5.5 Policy 的注册

Policy 与其它扩展点同构，走同一个注册表：

```racket
(reg-add (contrib 'policy 'confirm-save 100 confirm-save-policy))
```

好处：统一枚举 / 卸载 / 排序，且"有哪些跨切面策略"可被调试界面列出。

---

## 6. Interaction：显式挂起

### 6.1 类型与语义

```racket
(struct interaction (start resume) #:transparent)
;; start  : Ctx sid -> (listof effect)        挂起时立即产出的效果（通常弹 prompt）
;; resume : Ctx sid response -> (listof effect) 响应到达后产出的效果
```

- kernel 在拦截到 `interact` 时分配唯一 `sid`，把它存进 session 的 `suspensions` 表，
  然后施加 `(start ctx sid)`。
- `start` 通常发出 `prompt` effect，prompt 的提交回调会发出 `('resume sid answer)`
  effect（回调返回 effects）。
- kernel 收到 `('resume sid response)` 时：取出 interaction、删除登记、
  施加 `(resume ctx sid response)` 的产物。
- `resume` 可以再次发出 `('resume sid …)`（**同一个 sid**）实现多步循环，
  也可以发出原来的命令效果（通过 `run-unchecked`）、或任何其它 effect。

### 6.2 为什么用显式状态机，而不是续延 / 阻塞

| 备选 | 问题 |
|---|---|
| 阻塞等待用户输入 | 编辑器是单线程事件循环，阻塞 = 死界面 |
| `call/cc` 捕获续延 | 续延跨事件循环不可序列化、不可测试、易泄漏 |
| 把"询问"写进命令内部（旧法） | 不可组合、不可复用、不可拦截 |
| **显式 Interaction** | 跨事件、纯数据可登记、可单测、可序列化（理想情况） |

**关键点**：`sid` 让"挂起"成为 session 里的一条**可枚举数据**。
可以打印"当前挂起了哪些交互"，可以测试"回答后的效果列表"，可以在退出时清理。

### 6.3 状态携带

`resume` 是闭包，可闭包捕获进度（如"还剩哪些文档待询问"）。
**代价**：闭包不可序列化。若将来要持久化挂起状态（崩溃恢复），需把进度显式化：

```racket
(struct ask-save (pending done) …)   ; 或放进 suspension 的 payload
```

设计上**推荐显式携带**（把状态放进 interaction 的字段或 session），
这样连挂起都可序列化。闭包只作便利。

### 6.4 多步交互示例（保存确认的状态机）

```
action = (command quit)
policy confirm-save 匹配 → interact
  start  = 弹第一个 prompt：("save a.rkt? (y/n/all/esc)") + 记 sid
  用户答 "n"
  resume = 把 a.rkt 标记为"不保存"，若还有待问 → 再发 prompt（同 sid）
  用户答 "esc"
  resume = 发出 ('abort) 的等价：不产生任何关闭效果（放弃退出）
  用户答 "all" → 对剩余全部 save，然后 run-unchecked(quit) 得 effects
```

注意：**放弃 / 继续**都在 resume 的返回值里表达，不需要任何 `if` 埋在别处。

---

## 7. 管线与不变式

### 7.1 管线

```racket
(perform ctx action)
  = let loop over before-policies (priority 高→低, 匹配者):
      'pass    → continue
      'abort   → []
      effs     → handle-effects ctx action effs
      interact → sid = register(interaction)
                 handle-effects ctx action (start ctx sid)
    else
      handle-effects ctx action (invoke action)

(handle-effects ctx action effs)
  = effs1 = fold after-policies (priority 高→低, 匹配者) over effs
    for e in effs1: apply-effect ctx e     ; 顺序

;; resume
(on-effect ('resume sid resp))
  = it = take(suspensions, sid); remove
    handle-effects ctx (action '(resume sid) resp) (resume it ctx sid resp)
```

### 7.2 为什么挂起续做不再走 before-policies

- before 是"许可"：许可已经给过了，重复许可会再弹一次保存框（死循环）。
- 续做只应走 **after**（变换 / 过滤），这正好覆盖"继续关闭时丢弃已保存的文档"等需求。
- 所以 kernel 对 `resume` 用 `handle-effects` 而非 `perform`。

### 7.3 重入预算

`notify`（钩子）产生的 effects 也会过管线，其中可能又有 `notify`，可能无限递归。
kernel 维护**深度预算**（如 32）与**同类去重**（同 tick 内同 hook 不重复触发）。
**为什么放在 kernel 而不是策略？** 因为这是**不变量**（安全底线），
不能被插件绕过；策略是开放可扩展的。

### 7.4 不变式

1. Effect 只由 kernel 施加；任何命令 / 钩子 / 插件不得直接改 session。
2. before 链在首个决定者处终止；after 链全部运行。
3. `resume` 不再过 before；`sid` 一旦消费即失效（不可重放）。
4. `notify` 的重入受预算约束。
5. 每个 effect 的 apply 使 session 自洽（active ∈ frame、routes 双向）。
6. Policy 是纯函数：只读 ctx，不改 session，不产生除返回值外的副作用。
7. 同 `(phase, id)` 的策略唯一（注册表 upsert）。

---

## 8. 四个 worked examples

### 8.1 保存确认（I5 / I6）— before + interact

```racket
(define confirm-save-policy
  (policy 'confirm-save 100 'before
    (λ (ctx a) (and (memq (action-name a) '(quit close))
                    (any-modified? ctx a)))
    (λ (ctx a)
      (interact
        (interaction
          (λ (ctx sid) (list (ask-next ctx a sid (modified-docs ctx a) '())))
          (λ (ctx sid resp) (save-step ctx a sid resp)))))))
```

### 8.2 撤销合并（I15）— after 变换

```racket
(define undo-merge-policy
  (policy 'undo-merge 10 'after
    (λ (ctx a) (eq? (action-name a) 'insert))
    (λ (ctx a effs)
      (map (λ (e) (if (edit-effect? e)
                      (edit-with-tag e (typing-tag (edit-effect-text e)))
                      e))
           effs))))
```

**为什么放 after 而不是命令内？** 命令只管"插入文本"；合并策略是**横切**的
（粘贴、补全接受、缩进插件插入都要各自决定合不合并）。集中成一条策略，
所有插入路径一致。

### 8.3 真实文件守卫（I14）— after 过滤

```racket
(define real-file-policy
  (policy 'real-file 10 'after
    (λ (ctx a) #t)
    (λ (ctx a effs)
      (filter (λ (e) (or (not (job-effect? e))
                         (real-file-job? ctx (job-effect e))))
              effs))))
```

任务可能来自命令、钩子、定时器任意来源，**统一在 after 层按 ctx 过滤**，
不依赖调用方记得判断。

### 8.4 版本闸门（I13）— 内建在 job，不做 policy

```racket
(struct job (id priority handler runner version current? merge) …)
```

**为什么不做成 policy？** 版本闸门是**安全不变量**：迟到结果绝不能写错版本。
policy 是开放、可卸载、可被优先级绕过的；把安全底线放在开放层是危险的。
所以 job 自带 `version`/`current?`，kernel 在任务结果到达时**无条件**校验。
（"真实文件"这种业务守卫才是 policy。）

---

## 9. 组合律

1. **before 链**：优先级偏序；首个非 `'pass` 决定生效；`'pass` 是恒等。
2. **after 链**：函数复合；结合律；空列表是恒等；优先级决定复合顺序。
3. **Effect 施加**：顺序性；`apply` 与列表拼接不交换（有依赖）。
4. **Interaction**：`sid` 线性（消费一次）；`resume` 返回的 effects 合法且过 after。
5. **Policy 纯度**：`decide` 无副作用；恒等测试可断言输入输出。
6. **notify**：深度预算内幂等（同一 tick 同一 hook 不重复）。

---

## 10. 与 hooks / job / layer 的边界

| 机制 | 不是什么 | 是什么 |
|---|---|---|
| **hook** | 不能 abort / 挂起 / 排序到 before | 生命周期**通知**（其实是 `notify` effect） |
| **job** | 不是策略 | 异步计算 + **内建**版本闸门 |
| **layer** | 不管状态变换 | 输入**归属**（谁能收到事件） |
| **policy** | 不直接算异步、不拥有输入 | 意图门控 + 效果变换，**唯一的跨切面组合子** |

四者正交：layer 决定"事件给谁"，policy 决定"准不准 / 怎么改"，job 决定"异步"，hook 决定"通知"。

---

## 11. 取舍与已知风险

| 决定 | 收益 | 代价 / 风险 | 缓解 |
|---|---|---|---|
| Effect 封闭集合 | kernel 可穷举、可测 | 加新变换要改 kernel | 受控升级；插件用组合 |
| before 首个决定者 | 简单、可推理 | 两个都需执行的门控要合并 | 合并策略或 interaction 链 |
| after 全部运行 | 可叠加、过滤器友好 | 顺序敏感 | 显式 priority |
| 显式 Interaction | 跨事件、可测 | 多步流程要写状态机 | 提供 `ask-each` 之类组合子糖 |
| 不返回值的 effect | 数据流清晰 | 需要派生值时得写回 session | session 作交换媒介 |
| 版本闸门内建 | 安全底线不可绕过 | 不如 policy 灵活 | 业务守卫仍可用 policy |

---

## 12. 落地时必须一起定的三件事

1. **`sid` 的作用域**：全局递增？还是 per-session？建议 per-session 递增，随 session 走，
   便于回放/测试。
2. **`notify` 产生的 action 的 source**：建议 `(hook name)`，这样策略可针对钩子门控。
3. **effect 的构造 API**：建议提供 `(edit vid …)` 之类构造器，而非裸 struct 构造，
   以便统一加默认 `tag`、校验坐标。
