# lab 新架构设计：从功能逆推基石

> 方法：**不参考 lab 的结构体**，只把它当成「功能说明书」。
> 先把功能全集（显式 + 隐式契约）摊开 → 逆推「必须存在哪些概念」→
> 把概念拆成「值 / 原语 / 组合子」→ 用组合实现功能。
> core 固定，当黑盒。

---

## 1. 功能全集

### 1.1 显式功能（用户可见）

| 组 | 功能 |
|---|---|
| **F1 文本** | 打字 / 退格 / 删除 / 粘贴（多光标）；撤销 / 重做；选区（普通 / 扩展）；导航（字符 / 视觉行 / 行首尾）；全选 / 复制 / 剪切 |
| **F2 文档·视图** | 开文件（幂等）；新建未命名；多视图共享文档（follow / link 视口同步）；保存；修改检测；关视图 / 关文档 |
| **F3 工作区** | 主区分屏（左右 / 上下）；窗格互换；窗格缩放；关窗格；焦点方向移动；空区恢复 |
| **F4 左栏面板** | 文件树（展开 / 打开 / 新建 / 删除确认）；文档-视图列表（展开 / 切换 / 新视图 / 关闭）；面板轮换；侧栏显隐 |
| **F5 底部槽位** | 状态行（焦点 / 行列 / 文档名 / 前缀提示）；输入行（只读 label + 可编辑；确认型全只读）；槽位共享 |
| **F6 模态** | prompt（输入 / 确认）；前缀键；补全菜单（打字 / C-n 触发、选择、接受、取消、内嵌文档）；文档浮窗（C-p d、滚动） |
| **F7 异步** | 属性插件（括号 / 词 / 关键字：增量、版本、分层写回）；查文档（补全 / 浮窗）；place worker |
| **F8 外观** | 静态 face / 动态 palette / overlay；分层 face；逐分量合并 |
| **F9 配置** | 包表 / 启用集 / 键位 / 默认值 / 主题；装配与 init |
| **F10 文件系统** | 路径规范化；did↔path；目录下枚举；链接 / 隐藏文件 |

### 1.2 隐式契约（代码没明说、但行为依赖）

这些才是重构的关键 —— 它们现在以 `if` / 特判 / 注释的形式散落在 app、edit.rkt、state.rkt：

| # | 隐式契约 | 现状位置 | 本质 |
|---|---|---|---|
| I1 | 打开文档后焦点落到编辑视图 | `app-open-path!`→`app-show-document! #t` | 焦点策略 |
| I2 | 从侧栏打开文档会**替换当前 active 编辑窗格** | `app-show-document!`→`app-edit-open!` | 放置策略 |
| I3 | 内部视图（槽位 / 面板）不进文档列表 | `app-internal-vids` | 角色过滤 |
| I4 | 隐藏侧栏且焦点在侧栏 → 焦点回编辑 active | `app-toggle-sidebar!` | 焦点恢复 |
| I5 | 关闭改过的文档先逐个问保存；esc 放弃整个操作；嵌套关闭被守卫 | `close-documents!` / `closing?` | 动作拦截器 |
| I6 | 删除磁盘文件 → 强制关闭不保存 | `app-close-path! #:save? #f` | 动作参数化 |
| I7 | 改布局输入必须走特定 setter，否则缓存过期 | `state.rkt` 注释 | 派生量失效 |
| I8 | 焦点方向移动**不含底部槽位** | `app-focus-panes` | 角色过滤 |
| I9 | prompt 焦点一离开输入视图即取消 | `app-handle-input` | 层失焦策略 |
| I10 | prefix 独占 + 一次性；prompt 非独占 + 持久 | `mode.rkt` | 层捕获策略 |
| I11 | 模态是单值，补全与文档不能并存 | `app.mode` 单字段 | 层栈缺失 |
| I12 | overlay 锚在光标；光标不可见则不画 | `anchor-screen-pos` | 锚点派生 |
| I13 | 异步结果必须版本闸门（迟到丢弃） | complete/docs 手写 + highlight token | 任务版本 |
| I14 | 属性插件只对真实文件 | `path-table-path` 判断 | 任务守卫 |
| I15 | 连续打字并成一步撤销；遇空白断步 | `undo-typing-policy` | 编辑拦截器 |
| I16 | 文档开 / 关驱动面板刷新 | `document-opened/closed` 钩子 | 生命周期 |
| I17 | 多视图共享文档；视图廉价；sync follow/link | editor 模型 | 视图关系 |
| I18 | 编辑窗格 leaf 只放一个 vid；show 时替换 | `edit-panes-open!` | 放置策略 |
| I19 | 命令可被覆盖（indent 覆盖 newline） | 命令注册同名覆盖 | 注册表 upsert |
| I20 | 键表可运行时补键（docs / complete） | `keymap-add!` | 注册表可变 |
| I21 | 面板顺序 = 注册顺序；左栏显示第一个 | `app-init` 顺序 | 优先级 |
| I22 | 状态行每帧刷新；prompt 时不刷 | `app-state-refresh!` | 装饰 scope |
| I23 | 鼠标：prompt 点输入移光标、点别处取消；普通点击聚焦 + 移光标；滚轮滚动 | `app-handle-mouse` | 命中测试 + 动作 |
| I24 | 前缀 + 点击有特殊含义（M-m 互换） | `pane-move-prefix?` | 层钩子 |
| I25 | 后端要求 place 在 with-tui 内创建（线程约束） | `job.rkt` 注释 | 服务生命周期 |

**结论**：显式功能只占一半；另一半是**策略**（放置 / 焦点 / 过滤 / 拦截 / 版本 / 失焦）。
旧 lab 把它们写成 `if`，所以难组合。新架构必须让它们成为**一等组合子**。

---

## 2. 从功能逆推概念

每个功能簇，问「要支持它，必须存在哪类东西」：

| 功能簇 | 逆推出的概念 |
|---|---|
| F1 文本 | 位置、选区、编辑值、变更描述（+ combine） |
| F2 文档·视图 | 文档（core）、视图（文档×视口×选区）、路由（did↔path）、视图自旋 |
| F3 工作区 | 窗格、排列树、尺寸、放置、焦点 |
| F4 面板 | 视图 + 角色 + 面板状态 + 该视图的键绑定 |
| F5 槽位 | 输出装饰（slot scope）、输入内容 |
| F6 模态 | 输入层栈、键表、命令、捕获 / 失焦 / 出栈策略 |
| F7 异步 | 任务、执行器、版本、结果合并 |
| F8 外观 | face 值、调色板、解算（主题） |
| F9 配置 | 注册表、包清单、服务 |
| F10 文件 | 路由表 |
| **隐式契约** | **策略（放置 / 焦点 / 过滤 / 拦截 / 版本 / 失焦）+ 派生（布局 / 锚点）** |

把概念归并，得到 **5 类不可再约的东西**：

1. **值**：Pos / Span / Sel / Edit / Change / Face / Pane / Rect / Binding / Spec / View。
2. **原语**：Table（binding→spec）、Registry（贡献存储）、Job（异步）、Policy（决策）。
3. **组合子**：Layer（输入叠加）、Decoration（输出叠加）、Frame（空间组合）、Focus（活动 + 历史）、Effect（动作 = 数据）。
4. **会话 / 运行时**：Session（状态）、Runtime（注册表 + 服务）、Driver（事件循环）。
5. **功能**：对上述的组合。

---

## 3. 基石分层

```
L0 值        pos span sel sels edit change binding spec face rect pane screen
L1 原语      table registry contrib job policy route
L2 组合子    layer decoration frame focus effect input
L3 会话      session pending
L4 运行时    runtime ctx driver services theme
L5 功能      包（对 L0–L4 的组合）
```

依赖方向严格向下；L0 无依赖，L2 只依赖 L0/L1，L5 只依赖 L4 的贡献接口。

---

## 4. 组合子详设（全新结构体）

### 4.1 Table —— binding → spec

```racket
(struct table (bindings) #:transparent)     ; hash binding -> spec
(define (table-merge ts) …)                 ; 后者覆盖前者（结合律，恒等 = 空表）
(define (table-lookup t b) …)
```

**律**：`merge` 满足结合律；`lookup(merge(a,b),k)` 取 b 优先。

### 4.2 Registry —— 统一贡献存储

```racket
(struct contrib (kind name priority value) #:transparent)
;; kind : 'command | 'binding | 'layer | 'decoration | 'panel
;;      | 'hook | 'prop-plugin | 'job | 'policy | 'service
;; value 的契约由 kind 决定
(struct registry (entries) #:transparent)   ; assoc (kind . name) -> contrib
(define (reg-add r c) …)                    ; upsert（同名覆盖 = I19/I20）
(define (reg-del r kind name) …)
(define (reg-kind r kind) …)                ; 按 priority 升序，稳定
(define (reg-fold r kind init f) …)
```

这是**唯一的全局机制**：所有扩展点都是 `contrib` 的不同 kind。
- 显式 `priority`（取代注册顺序，解 I21）；
- 可枚举 / 卸载 / 清空（测试隔离）；
- 同名 upsert（解 I19）。

### 4.3 Layer —— 输入层（取代 mode 单值）

```racket
(struct layer (id priority match? tables capture slot focus on-blur pop)
  #:transparent)
;; match?  : Ctx -> bool         该层此刻是否激活
;; tables  : Ctx -> (listof table)
;; capture : 'all | 'fallthrough
;; slot    : #f | slot-id        占底部槽位
;; focus   : #f | target         要焦点
;; on-blur : #f | (listof effect) 焦点离开时（解 I9）
;; pop     : 'never | 'handled | 'next   出栈策略
```

输入 = **激活层的栈**（不是单值）。`resolve` 在层上 fold tables，后层覆盖。
- prompt = 一层（fallthrough，pop never，on-blur cancel）；
- 前缀 = 一层（capture all，pop next）；
- 补全 = 一层（fallthrough，pop handled）；
- 文档 = 一层（capture all，pop never）。
→ 解 I9/I10/I11/I24：多浮层、失焦、特殊点击都成数据。

### 4.4 Decoration —— 输出贡献（统一属性 / 浮层 / 槽位）

```racket
(struct decoration (id priority scope render) #:transparent)
;; scope  : 'document | 'frame | 'slot
;; render : Ctx -> (listof fill)          ; document：属性写回
;;               | (listof pane)           ; frame：浮层
;;               | view                    ; slot：底部文档
```

每帧：
```
panes = frame-panes(session)                       ; 工作区窗格
      ⊕ reg-fold('frame, …, decoration-panes)      ; 浮层
screen = core-render(editor, panes, focus, size)
```
→ 解 I22（状态行是 slot decoration，每帧算，prompt 层替换它）、I12（浮层自取锚点）。
旧的三套 API（overlay / slot / 属性写回）收敛成一套。

### 4.5 Effect —— 动作即数据

```racket
;; effect = (tag . args)
;;   ('edit    vid (listof edit))
;;   ('move    vid sels)
;;   ('reload  vid value)                 ; 面板 / 槽位换内容
;;   ('open    path)                      ; → did（幂等，解文件复用）
;;   ('close   (listof (or vid did)))
;;   ('focus   target)                    ; pane-id | (dir d) | 'restore
;;   ('place   vid placement)             ; 放置策略（解 I2/I18）
;;   ('arrange op)                        ; split / swap / resize / remove
;;   ('input   op)                        ; push / pop / set layer
;;   ('prompt  prompt)
;;   ('job     job request)
;;   ('notify  hook args)
;;   ('emit    output)                    ; 文件写 / place 消息等 side effect
;;   ('quit    )
```

命令 = `(Ctx Event . args) -> (listof effect)`。内核 `apply-effects!` 统一施加。
→ 动作可拦截、可回放、可测；解 I5/I6/I15（拦截器）与 I7（frame 变更自动使派生失效）。

### 4.6 Policy —— 动作 / 视图的决策组合子

```racket
(struct policy (id priority phase match? decide) #:transparent)
;; phase  : 'before | 'after
;; match? : Ctx Action -> bool
;; decide : Ctx Action -> 'pass | 'abort | (listof effect) | (defer Continuation)
```

- **保存确认** = `before close/quit` 的 policy（改过则 prompt，再继续 / 中止）→ 解 I5；
- **撤销合并** = `before edit` 的 policy（算 merge-tag，空白断步）→ 解 I15；
- **属性任务守卫** = `before job`（仅真实文件）→ 解 I14；
- **放置** = `before place` 的 policy 链，决定 replace / split / float → 解 I2/I18；
- **角色过滤** = 对视图集合的 policy（内部视图 / 焦点可及）→ 解 I3/I8。

**这是新架构最重要的新增组合子**：把旧 lab 的 `if` 全部提为可组合策略。

### 4.7 Job —— 异步 + 版本闸门内建

```racket
(struct job (id priority handler runner version current? merge) #:transparent)
;; handler  : request -> result             纯；runner='place 时到 worker 跑
;; runner   : 'sync | (place n)
;; version  : Ctx -> token    发起时抓
;; current? : Ctx token -> bool           结果到达时校验
;; merge    : (listof result) -> contribution
```

- 查文档 = 一个 job（version = 视图文档句柄）；
- 每个属性插件 = 一个 job（version = token，merge = `face-compose`）；
- 版本闸门从「每个调用方手写」变成字段 → 解 I13；
- 统一 `submit / poll / source / stop`，删掉两套 runner。

### 4.8 Frame —— 空间组合（工作区）

```racket
(struct leaf  (pane view role) #:transparent)
(struct split (dir size a b)   #:transparent)
;; role : 'edit | (panel name) | (slot state) | (slot input) | 'float
(struct frame (root active) #:transparent)  ; root = leaf | split | #f
```

- 一个 `leaf` = 一块屏幕格 + 一个 view + 一个 role；
- `layout(frame, size) -> (listof pane) + (listof bar)` **是纯派生量**；
  缓存可按 `frame` 值 memo，无需手工失效 → 解 I7；
- `active` 是唯一焦点来源（取代 app-focus + edit-panes-active 两份）；
- 侧栏 / 分屏 / 槽位 / 浮层统一成一棵树 → 解 I3/I8（按 role 查询）。

### 4.9 Focus —— 活动 + 历史

```racket
(struct focus (target stack) #:transparent)
;; target : pane-id | #f
;; stack  : (listof pane-id)   焦点历史
```

- `focus-move dir`：在 `frame` 的可及角色间找几何邻居；
- `focus-push` / `focus-restore`：一键保存 / 还原 → **解 I4**（隐藏侧栏回编辑）；
- `focus-exclude role`：过滤可及角色 → 解 I8。

### 4.10 Input —— 层栈

```racket
(struct input (layers) #:transparent)   ; (listof active layer)，栈顶在前
```

---

## 5. 隐式契约 → 组合表达式

新架构下，每个隐式契约都是一行组合：

| # | 旧写法（if） | 新写法（组合） |
|---|---|---|
| I1 | 打开后手动 focus | `show = open ≫ place ≫ focus` |
| I2 | show 里调 `app-edit-open!` | `(place vid 'replace-active)` 策略 |
| I3 | `app-internal-vids` 硬编码 | `(frame-views :exclude-role 'internal)` |
| I4 | toggle 里分支 | `(focus-push)` + hide 时 `(focus-restore)` |
| I5 | `close-documents!` 递归询问 | `policy before close (confirm-modified)` |
| I6 | `#:save? #f` 参数 | delete 流程组合 `(close :confirm? #f)` |
| I7 | 注释要求走 setter | `layout = f(frame,size)`，frame 变则 memo 失效 |
| I8 | `app-focus-panes` 排除槽位 | `(focus-exclude '(slot))` |
| I9 | 事件后检查焦点 | layer 的 `on-blur` 字段 |
| I10 | mode-type 的 exclusive/transient | layer 的 `capture` / `pop` |
| I11 | 单值 mode | `input` 是层**栈** |
| I12 | 到处算 anchor | decoration 内 `(anchor ctx vid pos)`（光标不可见返回 #f）|
| I13 | 调用方手写版本 | `job` 的 `version` / `current?` |
| I14 | `path-table-path` 判断 | `policy before job (real-file-only)` |
| I15 | `undo-typing-policy` | `policy before edit (merge-by-whitespace)` |
| I16 | 手动 `hook-run!` | `document-opened/closed` 是 registry 的 hook |
| I17 | editor 内部关系 | `view` 关系字段（sync/link）|
| I18 | leaf 单 vid | 放置策略 `replace-active` |
| I19 | 同名覆盖 | `reg-add` upsert |
| I20 | `keymap-add!` | `reg-add` binding 贡献（registry 可增）|
| I21 | 注册顺序 | `contrib.priority` |
| I22 | `unless prompt?` | slot decoration 被模态层替换 |
| I23 | 鼠标大分支 | `HitTest → Effect`，各动作 = 命令 |
| I24 | `pane-move-prefix?` | 层的 `match?` 里绑定鼠标动作 |
| I25 | 注释约束 | `service` 的 `acquire` 生命周期 |

---

## 6. 会话与运行时

### 6.1 Session —— 状态

```racket
(struct session
  (editor       ; core editor（固定；内部可变）
   frame        ; Frame 值
   focus        ; Focus 值
   input        ; Input 值（层栈）
   routes       ; hash path <-> did
   panels       ; hash name -> panel（角色 / 状态 / 视图）
   pending      ; hash job-id -> pending（版本 token）
   clip         ; 剪贴板（core clipboard）
   meta         ; 杂项（sidebar? / 尺寸 / 上次焦点 …）
   ) #:transparent)
```

**关键**：`session` 是不可变值（除 core editor 内盒）。`step` 返回新 session。

### 6.2 服务（生命周期受约束的副作用）

```racket
(struct service (name acquire release) #:transparent)
;; acquire : runtime -> handle        惰性；在驱动线程内建 place（解 I25）
;; release : handle -> void
```

`place` 执行器、文件监视、文档索引都作为 service，由 runtime 惰性获取。

### 6.3 Runtime / Ctx / Driver

```racket
(struct runtime (registry services theme config) #:transparent)
(struct ctx (session runtime) #:transparent)       ; 贡献收到的只读快照
(struct driver (runtime read present) #:transparent)
```

### 6.4 主循环（新）

```racket
(define (step ctx ev)
  (define act (resolve ctx ev))            ; 层栈 + table → (spec ev)
  (define effs (run-with-policies ctx act)) ; policy 链包裹命令
  (values (apply-effects ctx effs)         ; 新 session
          (effects->output ctx effs)))     ; 侧效（emit/quit/source）

(define (run d)
  (let loop ([s (initial-session d)])
    (define-values (s* out) (step (ctx s d) (read d)))
    (present d out)
    (unless (quit? out) (loop s*))))
```

`resolve` / `run-with-policies` / `apply-effects` 都只依赖 registry + session，**不认识任何功能**。

---

## 7. 完整结构体目录

| 层 | 结构体 | 字段 |
|---|---|---|
| L0 | `pos` | line col |
| L0 | `span` | start end（归一） |
| L0 | `sel` | anchor head |
| L0 | `sels` | items primary |
| L0 | `edit` | span text |
| L0 | `change` | before after |
| L0 | `binding` | source key mods |
| L0 | `spec` | name args |
| L0 | `face` | tag data（opaque） |
| L0 | `rect` | x y w h |
| L0 | `pane` | id rect depth content |
| L0 | `view` | id did vp sels |
| L1 | `table` | bindings |
| L1 | `contrib` | kind name priority value |
| L1 | `registry` | entries |
| L1 | `policy` | id priority phase match? decide |
| L1 | `route` | did path |
| L2 | `layer` | id priority match? tables capture slot focus on-blur pop |
| L2 | `decoration` | id priority scope render |
| L2 | `job` | id priority handler runner version current? merge |
| L2 | `leaf` / `split` / `frame` | 见 §4.8 |
| L2 | `focus` | target stack |
| L2 | `input` | layers |
| L3 | `session` | editor frame focus input routes panels pending clip meta |
| L3 | `panel` | name role view data |
| L4 | `runtime` | registry services theme config |
| L4 | `ctx` | session runtime |
| L4 | `service` | name acquire release |
| L4 | `driver` | runtime read present |

---

## 8. 组合规则与律

1. **Table**：merge 结合；后者覆盖。
2. **Registry**：upsert 幂等；`reg-kind` 按 (priority, 注册序) 稳定排序。
3. **Layer**：输入层栈 fold 出的 tables，栈顶优先；同栈内后者覆盖。
4. **Decoration**：同 scope 的 render 结果按 priority 依次叠加；face 用 combine 合并
   （不是覆盖）；pane 用 depth 合成。
5. **Effect**：顺序施加；`edit` 的 span 须同一编辑前坐标系（沿用 core 约束）。
6. **Policy**：链式，`'pass` 继续，`'abort` 终止，返回 effect 先施加再继续。
7. **Job**：结果按 version 闸门；多插件用 merge 合成后再写回（到齐才写）。
8. **Frame**：split 树；layout 纯派生；active ∈ frame。
9. **Focus**：target ∈ frame 的可及角色；stack 后进先出。

---

## 9. 功能如何成为组合

### 9.1 文件树面板

```racket
;; 状态：树模型 + 展开集
;; 贡献：
(reg-add (contrib 'panel 'tree 0
  (panel role='(panel tree) view=(tree-doc) data=(tree-model)
    keys=(tree-table))))
(reg-add (contrib 'hook 'tree-refresh 0        ; document-opened/closed
  (hook 'document-opened (λ (ctx did) (tree-refresh! ctx)))))
;; 行为（命令）返回 Effect：
;;   Enter → ('focus ...) + ('open path)      （打开走统一 show 组合）
;;   C-n   → ('prompt (new-file …))
```

### 9.2 补全

```racket
(reg-add (contrib 'layer 'complete 50 (layer …)))      ; fallthrough, pop handled
(reg-add (contrib 'binding 'complete 0 (table {(C-n) complete})))
(reg-add (contrib 'command 'complete 0 cmd-complete))
(reg-add (contrib 'decoration 'complete 50 (decoration 'complete 'frame complete-panes)))
(reg-add (contrib 'job 'complete-doc 0 (job handler doc version complete-v)))
(reg-add (contrib 'hook 'complete-refine 0 (hook 'after-insert …)))
```

### 9.3 属性高亮

```racket
;; 3 个纯插件 = 3 个 job（version=token, merge=face-compose）
;; 2 个 hook：after-edit（记增量）、before-render（flush+poll）
;; 1 个 decoration(scope document)：写回属性轨
```

### 9.4 关闭 / 退出（拦截器）

```racket
(reg-add (contrib 'policy 'confirm-save 100
  (policy 'before (λ (ctx act) (memq (action-tag act) '(close quit)))
          (λ (ctx act)
            (if (any-modified? ctx act)
                (prompt-save-chain ctx act)   ; 返回 deferred continuation
                'pass)))))
```

---

## 10. 与旧 lab 的对照（仅供参考，不作为设计依据）

| 旧 lab | 新架构 | 变化 |
|---|---|---|
| `app`（可变 struct，内嵌一切） | `session`（不可变值）+ `runtime` | 状态 / 注册表分离 |
| `mode`（单值 union） | `layer` 栈 | 多模态 / 失焦 / 栈策略 |
| command / keymap / mode-type / overlay / panel / hooks 六个全局 | `registry` + `contrib` | 统一、显式 priority |
| `overlay` + `slot` + 属性写回三套 | `decoration`（scope） | 一套输出通道 |
| `platform/job` + `highlight/runner*` 两套 | `job` | 版本闸门内建 |
| `app-focus` + `edit-panes-active` | `focus` | 单一焦点 + 历史 |
| `panes` + `panels` + `edit-panes` | `frame` | 一棵 role 树 |
| 布局缓存 + setter 纪律 | `layout(frame,size)` | 纯派生 |
| `if` 散布（save/focus/place/filter） | `policy` | 显式策略 |
| 命令直接 mutate | `Effect` 数据 | 可拦截 / 回放 / 测 |

---

## 11. 不变式（可在测试中固化）

1. `frame.active` 永远是树里可及角色的 pane-id。
2. `layout(frame,size)` 是纯函数；同输入同输出。
3. `registry` 中 `(kind,name)` 唯一；`reg-kind` 排序确定。
4. 每个 `Effect` 施加后 `session` 自洽（active 存在、routes 双向一致）。
5. `job` 结果只在 `current?` 为真时写回；多结果按 merge 到齐才写。
6. `layer` 栈顶的 `capture='all'` 时，事件不会落到下层。
7. `decoration('document)` 只写属性轨，不改文本；不产生 history 步。
8. `policy` 链不产生无限递归（`before` 施加的 effect 不再走同类 before）。

---

## 12. 落地路线（当要动手时）

1. 立 L0/L1 值与原语（纯，先测律）。
2. 立 `registry` + `contrib`，把旧六个注册表搬进来（并行期）。
3. 立 `layer`，prompt / prefix 先表达为层。
4. 立 `policy`，save-confirm / undo-merge / real-file 先迁移。
5. 立 `job`，合并两套 runner。
6. 立 `decoration`，合并三套输出。
7. 立 `frame` / `focus`，合并工作区与焦点。
8. 立 `Effect` + `apply-effects!`，命令逐个返回 effect。
9. 功能包改为「注册贡献」，删掉对平台内部的 require。
