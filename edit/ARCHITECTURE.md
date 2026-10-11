# ARCHITECTURE —— 极简编辑器骨架

目标：一个 **布局纯函数、多线程、带浮动窗口、控制流 CPS 声明式** 的编辑器。
状态定下来后尽量不再变；一切都是 State 的投影。

core/ 的命令式编辑器（有 id、有 box）是**引擎**，被穿过，不改。
本骨架是引擎外面的**协调层**：State 是纯数据，step / layout / paint / jobs 是纯函数。

---

## 1. 四个纯函数

```
layout : LayoutTree -> Size -> Metrics -> [Placement]   ; 几何，纯
paint  : State -> [Placement] -> Frame                  ; 帧，纯
step   : State -> Event -> State + [Effect]             ; 转移，纯；Effect 是数据
jobs   : State -> [Job]                                  ; 后台需求，纯
```

主循环只做：取帧 → 画 → 等事件 → step → 执行 IO。**可变只有：终端、worker 池、缓存。**

---

## 2. State（7 字段，定下即稳定）

```racket
;; ---- 值 ----
(struct doc  (text saved analysis))   ; text 不可变；analysis 按版本缓存（face 层等）
(struct view (doc cursor scroll extra)) ; cursor = selection/range；scroll = 视口

;; ---- 布局树：用户意图，不是几何 ----
;; pane / float 有自己的身份 wid（窗口），并引用一个 vid（视图）。
Layout = (pane wid vid)
       | (split 'h|'v (list (weight . Layout)))
       | (float wid vid anchor want-w want-h)   ; 浮动窗 = 这里的一种
       | (empty)

;; ---- 唯一状态 ----
(struct state
  (docs    ; id -> doc
   views   ; id -> view
   layout  ; Layout            意图树；几何永不存
   focus   ; wid               窗口身份（不是 vid）
   stack   ; (listof wid)      浮窗 z 序 + 模态序（栈头接键）
   input   ; #f | (prefix sym) | (prompt label text on-submit)
   jobs))  ; id -> (kind . key) 在途请求
```

**派生，永不存**：`Placement`、可见集合、脏标志、浮层栈头、face 层、菜单内容。
面板（状态行 / 树 / 日志 / 补全 / 文档窗）都是「一个 vid 显示一个生成的 doc」；
其局部状态挂在对应 `view` 上（如 `extra`），不新增全局字段。

---

## 3. 布局纯函数

```racket
;; metrics : vid -> (values want-w want-h)   ; 浮窗要内容尺寸；平铺窗拿剩余
(define (layout tree size metrics) -> (listof (cons vid rect)))
```

- `split` 按 weight 切剩余空间；`pane` 取一块。
- `float` 最后放置：按 anchor 定位，clamp 进屏幕，z 最高。
- 纯数字进出，可脱离编辑器单测。布局树一旦设定，结果只是它和尺寸的函数。

---

## 4. 浮动窗口

浮动窗不需要独立引擎，只有两件事：

1. `Layout` 里是 `(float vid anchor want-w want-h)` → `layout` 负责摆位；
2. `stack` 里 → 栈头接键、画在最上。

```racket
(define (top st) (car (state-stack st)))   ; 谁接键 = 栈头
(define (open-float st vid) ...)           ; 压栈
(define (cycle-float st) ...)              ; Tab：栈头移到栈尾
(define (close-float st vid) ...)          ; 弹栈
```

补全菜单、文档窗、对话框统一为同一个东西。

## 4.5 区域（region）—— 共享面板的显式描述

多个面板可以**共用同一块面板**（互斥显示），由一个显式的 `region` 描述：

```racket
(struct region (id side size members))   ; 配置，装配时固定
(define regions
  (list (region 'sidebar 'left   28 (list "*tree*" "*buffers*"))
        (region 'log     'bottom  6 (list "*log*"))))
```

- **成员**：同区面板互斥，同时只显示一个（active）。
- **显隐**：`layout` 里有没有该区当前成员的 `pane`（不另存布尔）。
- **状态**：每区 active 成员名存 `feature-ref st 'region-active`；不新增 State 字段。

命令语义（显式、无歧义）：

| 命令 | 含义 |
|---|---|
| `toggle-region! st 'sidebar` | 整个侧栏显 ↔ 隐（`C-b`）；显示时回到上次 active 成员 |
| `show-member! st 'sidebar "*buffers*"` | 切侧栏成员为缓冲区（隐藏则一并显示）（`M-b`） |
| `focus-named st "*tree*"` | 聚焦树：所在区域一并显示并置 active（`M-t`） |

于是“文件树与缓冲区共用同一个面板、`C-b` 隐藏/显示整个面板”就是数据 + 三个纯函数，
不靠隐式的相互替换。隐藏当前聚焦的面板时，焦点自动回编辑器。

---

## 4.6 面板 = document（一切皆 document）

面板（树 / 缓冲区 / 状态 / 日志）没有自己的「游标 / 选择」变量：

- 面板就是一个 vid 显示一个生成的 doc；面板的**选择 = 该 doc 视图的光标行**（`view-line`）。
- **导航** = 文档导航（`nav! ed vid 'up/down`），不是自己 += 1。
- **回车/激活** = 取光标行对应的行（树行文本 ↔ 路径由内容生成函数重建）。
- **点击** = 同一套屏幕→document 定位（`layout-hit` + `screen->point`），面板与编辑器无别。
- face（选中行高亮）每帧重应用——因为光标移动不改变文本。

于是 edit2 里只保留真正不是文档的东西：树的 root/展开集/目录缓存（`feature 'tree`）。
曾经的 `feature 'buffers`（独立游标）和 `tree.cursor` 已删除。

---

## 4.7 资源生命周期：窗口 ⊂ 视图 ⊂ 文档

`view` 与 `document` 是 core 里的**持久资源**；`layout` 里的 `pane` 只是一个展示位。
三者是包含关系，操作互不混淆：

| 操作 | 动作 | 动 layout | 动 core 资源 |
|---|---|---|---|
| 关**窗口** `close-window!` | 只摘掉 pane（+ 浮窗栈） | 是 | 否 |
| 关**视图** `close-view-resource!` | 关掉该 view | 是 | view −1；document 保留 |
| 关**文档** `close-doc!` | 关掉 document | 是 | document −1，且**连带其全部 view** |

- **保存只在关文档 / 退出时问**：只有关文档会丢文本；关窗口、关视图资源不动
  document 的文本，因此不问（脏标志未变，退出时照样会问）。
- **孤儿文档**：视图可独立关闭，doc 即使 0 个视图仍在 core 里，并出现在缓冲区面板；
  面板回车会为它重建一个视图。
- **一文档多视图**：`C-w` 分屏 = 给同一 doc 再加一个 view（document 不增）。资源面板是一棵
  可折叠的树：**document 是根，view 是子，多个 document 并列**；子行用 `line:col` 区分，
  `●` = 已显示在窗格里，`·` = 未显示。`←/→/空格` 收起/展开；Enter 激活（多窗口时进放置模式选目标）。
  关其中一个视图资源不影响文档和其余视图。
- **按路径复用文档**：打开已在资源里的文件不新建 document：复用它的视图（已显示就聚焦，
  否则显示）；没有视图的孤儿文档现建一个视图。资源身份 = 规范化路径（`simplify-path`）。
- **wid / vid 分离**：窗口（pane / float）有自己的身份 **wid**，并引用一个视图 **vid**。
  焦点、浮窗栈、命中定位都用 wid。同一个 vid 可以出现在多个 wid → **同 view 多位置**。
- **分裂（`C-w`）只新建窗口 wid**，显示同一个 vid——不产生新 view；关一个窗口其他窗口不受影响，
  关 view 资源（vid）则显示它的所有窗口一起消失。
- **视图只在资源面板创建**：`n` 给选中的 document 新建一个 view。树打开：有 view 就复用，
  只有新文档 / 孤儿文档才建第一个 view。
- core 提供全部结构原语：`editor-close-view`、`editor-close-document`（后者自动连带视图）；
  `edit2` 只负责把「窗口 / 视图 / 文档」这三个动作接到 layout 与焦点上。
- **资源显示路径**：`doc-meta.path` 有值时，状态栏与缓冲区面板都显示相对文件树根
  （工作路径）的路径；否则显示文档名。

---

## 4.8 打开时选目标窗格（放置模式）

把视图放上屏（`place-view`）按编辑窗格数量分三种：

- **0 个**：填空位 / 新建 pane；
- **1 个**：直接替换（无歧义）；
- **多个**：进入**放置模式**，不猜，让用户选。

放置模式不新增 State 字段，只用 `feature 'placing`：

```racket
(struct placing (vid prev-focus))   ; 候选窗格不存：从 layout 现算
```

- 候选 = 当前 layout 里所有非面板窗格（`editor-vids`），布局变了也不会拿到失效 vid；
- 焦点即选择：鼠标点窗格、`Tab` / `M-n` 在候选间循环；`Enter` 把待放视图替换到当前窗格；
  `Esc` 取消（待放视图资源保留，可在缓冲区再显示）；
- **瞬时模式**：放置模式下按任何无关命令，先自动退出放置（`run-ops` 里做），
  不会出现“命令生效了但模式还在”的死角。

于是“打开时总是替换第一个视图”被拆成：单窗直接替换，多窗显式选目标。

---

## 5. 输入：CPS 声明式路由

路由表是**数据**（守卫 + 处理器）；处理器是 **CPS 函数**，第三个参数就是「下一个处理器」
（续延 `k`）。调用 `k` = 交接，直接返回 = 处理完毕。

```racket
;; guard   : State Event -> Boolean
;; handler : State Event Cont -> Reply
;; Cont    : State Event -> Reply
;; Reply    = (values State (listof Effect))
;; routes   : (listof (cons guard handler))

(define (route-input routes st ev)
  (define (chain rs)
    (cond
      [(null? rs) (lambda (st ev) (values st '()))]
      [else
       (define r (car rs))
       (define guard (car r))
       (define h     (cdr r))
       (define k     (chain (cdr rs)))
       (lambda (st ev)
         (if (guard st ev) (h st ev k) (k st ev)))]))
  ((chain routes) st ev))
```

处理器的写法：

```racket
;; 处理并终止
(lambda (st ev k) (values (update st) (list effect)))

;; 交接给下一条（fallthrough）
(lambda (st ev k) (k st ev))

;; 改写事件再交接（按键替换 / forward）
(lambda (st ev k) (k st (key-event 'up #f)))

;; 携带改动后的状态交接
(lambda (st ev k) (k (set-focus st vid) ev))

;; 重新进入整张表（高级：跨链重派发）
(lambda (st ev k) (route-input other-routes st ev))

;; 广播：同一事件顺序跑多个处理器，状态串接
(lambda (st ev k)
  (define-values (st1 e1) (handler-a st ev k))
  (define-values (st2 e2) (handler-b st1 ev k))
  (values st2 (append e1 e2)))
```

示例路由表：

```racket
(list
 (cons (lambda (st ev) (and (key? ev 'escape) (float-open? st))) close-top)
 (cons (lambda (st ev) (and (key? ev 'tab)    (float-open? st))) cycle-float)
 (cons (lambda (st ev) (and (key? ev 'up)     (menu-open? st)))  menu-up)
 (cons (lambda (st ev) (and (key? ev 'up)     (editor-focus? st))) cursor-up)
 (cons (lambda (st ev) (key? ev 'p 'ctrl))                       begin-C-p)
 (cons (lambda (st ev) (and (key? ev 'up) (prefix? st 'C-p)))    focus-up))
```

没有 host 协议、没有按焦点硬编码的键表栈、没有 hook 链、没有事件专用 effect 类型。

---

### 5.1 指针 / 光标事件 + 定位

指针事件是**一等数据**，与布局一起完成「屏幕坐标 → 窗格 → 缓冲坐标」的定位，
再交给命令绑定：

```racket
;; 事件（event.rkt）
(struct cursor-event (kind button x y))   ; kind: press|release|move|scroll；x/y 屏幕 0-based
(on-cursor 'press 'left)                  ; 守卫（可直接进路由表）

;; 命中定位（layout.rkt，纯）
(layout-hit placements x y)   ; 最上层（z 最大）包含该点的 placement | #f
(rect-local p x y)            ; → (values vid 窗格内列 窗格内行)
```

命中后转成缓冲坐标并定位（core）：`adapter.screen->point` → `editor-view-screen-position->point`。

**派生上下文进路由**：需要几何的输入不能只拿 State，所以路由运行多带一个 `Ctx`：

```racket
(struct ctx (size placements))                 ; 上一帧的尺寸 + 布局结果
handler : Ctx State Event Cont -> Reply        ; 指针处理器用 ctx 做命中
```

指针路由（声明式，可直接换成别的命令绑定）：

```racket
(route (on-cursor 'press 'left)  press-handler)   ; 命中编辑器 → 聚焦 + 定位光标；面板 → 聚焦
(route (on-cursor 'scroll 'up)   scroll-handler)  ; 滚命中窗格（不改焦点，面板不动）
(route (on-cursor 'scroll 'down) scroll-handler)
```

---

## 6. 多线程：声明式需求 + 不可变消息

```racket
;; 需求 = State 的函数：该跑哪些后台计算（高亮 / 补全 / 文档 / 目录扫描）
(define (jobs st) -> (listof (job id kind key input)))

;; worker 是纯函数 job -> result，跑在其它线程 / place，结果丢回 channel
;; 结果作为事件回流：
(define (step st (job-done id key result))
  (if (current? st id key) (apply-result st result) st))   ; 过期就丢
```

- 运行时把 `(jobs st)` 与在跑集合做 **diff**：需要就启，不需要就停。无需登记表。
- 过期判定是 `step` 里的**纯比较**（key = 文档版本 / 光标 / 目录）。
- 没有 `awaiting` 闭包表、没有版本闸门 box、没有跨线共享状态。

---

## 7. 帧与主循环

```racket
(define (paint st placements size) -> Frame)   ; 字符网格 + 属性；浮窗按 stack 顺序覆盖
```

```racket
(define (run cfg init)
  (let loop ([st init] [running (hash)])
    (define running* (sync-workers running (jobs st)))          ; diff 启停 worker
    (define placements (layout (state-layout st) (screen-size) (metrics st)))
    (draw! (paint st placements (screen-size)))
    (define ev (next-event))                                    ; 终端输入 | worker 结果 | tick
    (define-values (st* effs) (step st ev))
    (for-each perform! effs)                                    ; 文件 IO / 退出 / 日志（一次性）
    (loop st* running*)))
```

`Effect` 只承载一次性 IO：`(open-file p) / (save-file did p) / (quit) / (log s)`。
后台计算走 `jobs`，不走 Effect。

---

## 8. 模块清单

```
state.rkt    State(7 字段) + doc-meta + Layout 树 + feature-ref/set
adapter.rkt  core 边界：结构 / 编辑 / 布局 / 渲染 / face（唯一 require core/editor）
event.rkt    Event ADT：(key …) (text …) (cursor …) (resize …) (job-done …) (tick)
effect.rkt   Effect ADT（一次性 IO：open/save/quit/log）
route.rkt    guard/handler 类型 + route-input（CPS 链）
layout.rkt   layout（纯）+ 布局树手术（remove/replace/split/add-side/float）
render.rkt   placements → core rectangle → patch（返回 piece）
fs.rkt       文件系统原语（read-dir/read-file/write-file）
panels.rkt   面板内容（树/缓冲区/状态）+ 面板契约/焦点/树状态机
theme.rkt    face / overlay → ANSI 属性
step.rkt     路由（全局/面板/编辑三层）+ 命令 + 布局手术 + 装配
runtime.rkt  run + worker 池 + 后端协议（唯一可变）
backend/tui.rkt  racket-tui 输入解码 / 字节输出
main.rkt     入口
```

**core 集成**：State 的 `ed` 是 core 编辑器句柄（命令式引擎，box 是设计）。
`adapter.rkt` 是唯一 require `core/editor` 的模块；文本真身在 core，State 只记
`did → 路径 / 存档句柄`。注意 core 编辑原地 mutate：State 必须**线性使用**
（同一 State 分叉会共享 box），测试里每个用例从 `boot` 新建。

**插件 = 数据**：`(listof route) + (listof panel) + (listof job-kind)`，
不再是会改 session 的 install 函数。

---

## 9. 相对现有 edit，直接删除

`session`(11 字段)、`layout-state`、`ui-state`、`input-state`、`surfaces`、`docs-state`、
`runtime` 结构体；`hooks / emit / reaction / rules`；`host` 协议；旧 `keymap` + `engine` 桥；
插件的 service box 与 `awaiting` 闭包；`adapter` 的几十个 `session-ed-*!` 导出。

全部塌缩成：**State + 4 个纯函数 + CPS 路由 + 事件循环。**
