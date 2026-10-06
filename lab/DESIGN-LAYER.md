# Layer 接口详设

> 配套 `DESIGN.md` / `DESIGN-POLICY-EFFECT.md`。本文细化第三个控制流组合子
> **Layer（输入归属）**：谁收到事件、按什么顺序、何时退出、底部槽位归谁、焦点归谁。
>
> 三者正交闭环：
> **layer 决定"事件给谁" → policy 决定"准不准 / 怎么改" → job 决定"异步"。**

---

## 0. 病根：`mode` 单值

旧 lab 的输入状态是一个**单值** `mode`：

```racket
(struct mode-type (name match? tables bottom focus exclusive? transient?) …)
```

由此产生的问题（对应 `DESIGN.md` 的隐式契约）：

| 病 | 现象 | 契约 |
|---|---|---|
| 单值 | 补全与文档不能并存；加一种模态就改一处 | I11 |
| 按注册顺序 `match?` + 首个命中 | 优先级隐式；无法固定相对次序 | — |
| `exclusive?` 布尔 | 只有"全占 / 全放"两档，不能精细 | I10 |
| `transient?` 布尔 | 只有"一次性 / 永久"，且退出时机写死在 app 里 | I10 |
| 无 `on-blur` | prompt 失焦取消靠 app 事件后硬编码 `if` | I9 |
| 无实例状态 | 模态状态（候选、pending）挂在别处，靠 `mode?` 强转 | — |
| 鼠标特判 | M-m 前缀点击在 `app-handle-mouse` 里单独分支 | I23/I24 |

**根因**：输入归属被压成一个值 + 一个注册表匹配，而不是一条**可叠加、带生命周期、
带实例状态**的层。

---

## 1. 选型：为什么不沿用 mode-type，也不用别家的做法

| 方案 | 代表 | 问题 |
|---|---|---|
| 单值 mode + match? | 旧 lab | 单值、隐式优先级、无实例、无失焦 |
| 单一 `keymap` 切换 | 简化编辑器 | 无栈，无法叠加浮层 |
| 全局 `key-translation-map` + `overriding-*` | Emacs | 隐式、互斥、难枚举当前状态 |
| **层栈 + 模板/实例** | 本文 | 可叠加、显式、可枚举、带生命周期 |

**关键抉择：显式 push/pop 的实例，而不是 `match?` 自动激活。**
- 自动 `match?` 要求"谁匹配"由注册表扫描决定 → 回到隐式优先级；
- 显式实例让"当前激活了哪些层"成为可枚举数据 → 可调试、可测试、可序列化；
- 实例可以带**自己的状态**（候选、pending、回调），不必把状态藏在别处再靠类型断言取回。

---

## 2. 类型

### 2.1 层模板（注册一次，feature-free）

```racket
(struct layer-spec
  (id
   on-enter    ; Ctx -> (listof effect)        入栈时（通常设槽位内容、移焦点）
   on-exit     ; Ctx -> (listof effect)        出栈时（通常还原焦点、清槽位）
   on-blur     ; #f | Ctx -> (listof effect)   焦点离开本层声明的焦点目标时
   tables      ; Ctx -> (listof table)         本层的键表（可依赖实例状态）
   capture     ; 'all | 'fallthrough
   slot        ; #f | 'state | 'input
   focus       ; #f | focus-target
   pop)        ; 'never | 'next | 'handled
  #:transparent)
```

- `layer-spec` 是**纯模板**，无实例状态；注册进统一 registry（`contrib` kind `'layer-spec`）。
- 同一 spec 可被 push 多次（理论上），每次一个实例，互不干扰。

### 2.2 层实例（会话状态）

```racket
(struct layer-inst (spec-id state) #:transparent)
;; spec-id : symbol
;; state   : any    实例自己的状态（候选 / pending / 回调 …）；模板函数通过 ctx 读它
```

> **为什么模板与实例分离？**
> 模板是"这类层怎么工作"，注册一次、可复用、无状态、可推理；
> 实例是"这一次弹层的数据"。分开后：
> - 模板可静态枚举 / 测试（喂一个 ctx 看它产什么表）；
> - 实例可序列化 / 检查（"当前栈里有 complete(state=…)")；
> - 同一模板可以并存多实例（未来多浮层）。

### 2.3 输入值（栈）

```racket
(struct input (instances) #:transparent)   ; (listof layer-inst)，栈顶在前
```

**栈，不是集合**：后进先出天然给出优先级，无需 `priority` 字段。
（旧 `mode` 的优先级靠注册顺序，这里靠 push 顺序，显式且可预期。）

---

## 3. 解析算法：事件归属

```
resolve(ctx, event) -> (values spec owner-layer-id) | #f

1. base  = command-set-tables(did-of(focus))        ; 全局 + 该 did 的表（per-did）
2. 从栈顶往下收集层表：
      overlay = []
      for inst in stack (top → bottom):
          overlay = (inst.tables ctx) ++ overlay    ; 维持"底在前、顶在后"
          if (spec-of inst).capture == 'all: return lookup(overlay, event)
      ; 全部 fallthrough：
      return lookup(base ++ overlay, event)

lookup(tables, event) = command-lookup(tables, (event->binding event))
                        ; 查不到时做一次字符回退（见 §3.2）
```

### 3.1 为什么 base 不是一层

base 是**每个 did 的命令集**（global + per-did，含 readonly、面板键表），
它：
- 随焦点文档变化，不是"被推入的模态"；
- 没有 enter/exit/blur 生命周期；
- 永远在栈底，且 capture='all' 的层要能把它整个屏蔽。

把它做成层会引入"每换文档就重推 base"的无谓状态变更。所以 base 由 command-set
直接给，`resolve` 每次现取。层只表达**叠加在 base 之上的模态**。

### 3.2 字符回退

模态表常按字符键绑（如 `C-p` 后按 `d`）。`event->binding` 会把无修饰字符键归一成
`'text`（编辑用），于是模态表查不到。`lookup` 在 miss 时再用字符本身的键查一次：

```
if event is key(char c) and no spec:
    spec = command-lookup(tables, (key (char->key-symbol c)))
```

> **为什么要这一步？** 否则"前缀后按字母"要么绑不上，要么强制编辑表先吃掉字符。
> 回退只在 miss 时发生，不改变正常编辑路径。

---

## 4. 生命周期

### 4.1 push

effect `('input (push spec-id state))`：

```
inst = (layer-inst spec-id state)
session.input = (cons inst (input-instances))
run (spec.on-enter ctx)      ; 通过 handle-effects 施加（受 after-policy 约束）
```

### 4.2 pop

effect `('input (pop spec-id))` / `('input (pop-until spec-id))`：

```
run (spec.on-exit ctx)       ; 施加 on-exit 的 effects（常含还原焦点）
session.input = 去掉该实例（及其上方所有实例，pop-until）
```

**顺序**：先 on-exit 再移除，让 on-exit 里的 ctx 还能看到该层声明（例如 slot）。
（与栈操作相反，是刻意的：退出钩子常需读层状态。）

### 4.3 pop 策略（声明式一次性）

事件处理完后，kernel 按栈从顶到底应用每条实例的 `pop`：

| pop | 语义 |
|---|---|
| `'never` | 保持（prompt / complete / docs 显式 pop） |
| `'next` | 处理完**下一个事件**后移除（不管该事件是否命中）——前缀键 |
| `'handled` | 仅当命中本层（或下层？见下）表时移除 |

**归属判定**：`resolve` 返回 `owner-layer-id`。`'handled` 只在 owner == 本层时移除。

> **为什么需要声明式 pop，而不是全部显式 effect？**
> 前缀键"按任意下一键就退出"是**纯时序**语义，用 effect 表达要在每个可能分支都写 pop，
> 且"未绑定的键也要退出"很难表达。声明成 `'next` 一行搞定。
> 其余需要条件逻辑的退出（accept/cancel）仍走显式 effect。

### 4.4 on-blur

focus 变化后，kernel 检查每条**声明了 focus 的**实例：

```
if current-focus != (inst.focus 目标):
    run (inst.on-blur ctx)        ; 典型：('input (pop id)) + 取消
```

- 只对"声明了 focus"的层触发（没有 focus 声明的层不关心焦点）；
- 用一次性标记防重入（on-blur 里 pop 会改栈）；
- prompt 的 on-blur = `('input (pop prompt))` + 触发 cancel 回调。

> **为什么放声明而不是 app 里的 `if`？** 因为"失焦即取消"是**层的属性**，
> 不是全局语义。不同层可能想要不同反应（有的取消、有的只是隐藏菜单）。
> 声明后，app 的通用事件后处理里再不需要认识任何具体模态。

---

## 5. 槽位与焦点（派生）

层只**声明诉求**，kernel 派生有效值：

```
有效槽位 = 从栈顶往下第一个非 #f 的 layer.slot，否则 'state
有效焦点 = 从栈顶往下第一个非 #f 的 layer.focus，否则 保持当前焦点
```

- prompt：`slot='input'`, `focus=(input-view)`；
- 前缀 / 补全 / 文档：`slot=#f`, `focus=#f`（不改变槽位与焦点）；
- 槽位**内容**由 `on-enter`/`on-exit` 的 `reload` effect 设置（prompt 的 label 文档）。

> **为什么 slot/focus 用字段，不做成 effect？**
> - `focus` 必须是可派生的：`on-blur` 判定需要知道"本层声明的焦点目标是谁"；
> - `slot` 必须是可派生的：状态栏刷新要知道当前底部该显示哪份文档；
> - 内容变化（不同 label）用 effect，目标选择（state vs input）用字段，各司其职。
>
> 判定法则：**"选哪个目标"是字段；"目标的内容/具体变化"是 effect。**

---

## 6. 鼠标

鼠标事件与键盘**走同一条 resolve**：`event->binding` 对鼠标产出
`('mouse 动作 按钮 mods)`。于是：

- 前缀层可直接绑 `('mouse press …)` → 窗格互换（旧 I23/I24 的特判消失）；
- prompt 层绑"点击输入视图"与"点击别处取消"，都在它的表里，而不是 app 分支；
- 命中测试（点到哪个 pane）由 kernel 服务 `hit-test` 提供，命令用它决定目标。

> **为什么鼠标要并入？** 旧 lab 把鼠标单开一个 `app-handle-mouse` 大分支，
> 导致"前缀 + 点击"这种组合必须特判。并入后，鼠标只是"另一种 event"，
> 层的 capture/pop/on-blur 对鼠标同样生效，组合自然。

---

## 7. 为什么这样设计（逐条决策）

| 决策 | 否决了什么 | 为什么 |
|---|---|---|
| 层**栈** | 单值 mode | 多浮层并存、LIFO 优先级、可枚举 |
| **显式 push/pop 实例** | `match?` 注册表扫描 | 去掉隐式优先级；实例带状态 |
| **模板/实例分离** | 把状态塞进 mode 值 | 模板可静态测；实例可序列化/检查 |
| **capture 两档** | `exclusive?` 布尔 | 语义更精确；fallthrough 是常态 |
| **pop 声明** | 退出时机硬编码在 app | 前缀"下一键退出"一行表达 |
| **on-blur 声明** | app 里检查 prompt | 失焦反应是层的属性 |
| **base 独立** | base 也当层 | per-did、无生命周期，避免重推 |
| **mouse 并入** | 单开鼠标分支 | 前缀+点击天然组合 |
| **无 priority 字段** | 注册顺序定优先级 | 栈序即优先级，显式可预期 |
| **on-enter/exit 产 effect** | 层直接改状态 | 与全局 effect/policy 模型一致 |
| **字符回退** | 强制编辑表先吃字符 | 模态表可按字符绑 |

---

## 8. Worked examples

### 8.1 prompt（输入 / 确认）

```racket
(reg-add (contrib 'layer-spec 'prompt 0
  (layer-spec 'prompt
    #:on-enter (λ (ctx) (list (reload (slot 'input) (prompt-doc ctx))
                              (move (slot 'input) (caret-at-label-end ctx))))
    #:on-exit  (λ (ctx) (list (reload (slot 'state) (state-doc ctx))))
    #:on-blur  (λ (ctx) (list (input-pop 'prompt)
                              (notify 'prompt-cancelled …)))   ; 触发 cancel 回调
    #:tables   (λ (ctx) (list (if (editable? ctx) input-edit-table confirm-table)))
    #:capture  'fallthrough     ; 文本仍落 base 编辑（输入进 input 文档）
    #:slot     'input
    #:focus    '(input-view)
    #:pop      'never)))
```

### 8.2 前缀键

```racket
(layer-spec 'prefix
  #:on-enter (λ (ctx) '())     ; 只改状态栏提示（一条 decoration）
  #:tables   (λ (ctx) (list (prefix-table ctx)))   ; 实例 state 带表
  #:capture  'all              ; 只查自己的表
  #:pop      'next)            ; 下一键后必退
```

多层前缀（键序列）就是嵌套 push：`C-x` 推 `prefix`，其中 `C-f` 再推 `prefix`。

### 8.3 补全菜单

```racket
(layer-spec 'complete
  #:tables   (λ (ctx) (list complete-table))   ; ↑↓ / Tab / Enter / Esc
  #:capture  'fallthrough       ; 打字仍落 base → after-insert 钩子 refine
  #:pop      'never)            ; accept/cancel 显式 effect
;; 菜单本身是 decoration(scope frame)，与层正交
```

### 8.4 文档浮窗

```racket
(layer-spec 'docs
  #:tables   (λ (ctx) (list docs-table))   ; ↑↓/PgUp/PgDn/Enter/Esc，text→noop
  #:capture  'all              ; 独占，吞掉所有键
  #:pop      'never)
```

### 8.5 窗格移动（含鼠标）

```racket
(layer-spec 'pane-move
  #:tables   (λ (ctx) (list move-table))   ; 方向键 + ('mouse press …)
  #:capture  'all
  #:pop      'next)
;; move-table 里直接绑鼠标：命中窗格→互换。app 里再无 pane-move-prefix? 分支。
```

---

## 9. 组合律与不变式

1. **栈序即优先级**：后 push 覆盖先 push；`resolve` 从顶往下。
2. **capture 短路**：遇到 `capture='all'` 的层即停，不再看其下与 base。
3. **pop 至多一次**：一个事件处理完，每条实例最多被自身 pop 规则移除一次；
   effect 显式 pop 与声明式 pop 不重复。
4. **on-blur 幂等**：焦点未变不触发；触发时先标记再执行，防重入。
5. **on-exit 先于移除**：on-exit 的 ctx 仍能看到该层（含 slot 声明）。
6. **槽位/焦点派生确定**：从栈顶第一个声明取值；无声明保持默认。
7. **模板纯**：`layer-spec` 的函数只读 ctx，不产生副作用，返回自然数效应。
8. **实例可枚举**：`input.instances` 任何时候是当前全部激活层的完整列表。

---

## 10. 与其它组合子的边界

| | 管什么 | 不做什么 |
|---|---|---|
| **layer** | 事件归属、模态生命周期、槽位/焦点诉求 | 不管状态变换内容、不做异步 |
| **policy** | 动作门控与效果变换 | 不拥有输入、不决定谁能收到事件 |
| **job** | 异步计算 + 内建版本闸门 | 不参与输入归属 |
| **decoration** | 每帧输出（菜单/浮窗/状态行） | 不参与输入 |
| **table** | binding→spec 的纯映射 | 无生命周期、无 capture |

**正交性检验**：一个功能可能同时用四者（补全用 layer + table + decoration + job + hook 的 notify），
但每个组合子各管一段，互不侵入。

---

## 11. 取舍与已知风险

| 决定 | 收益 | 代价 | 缓解 |
|---|---|---|---|
| 显式 push/pop | 可枚举、带状态 | 忘记 pop 会泄漏层 | 提供 `with-layer` 组合子糖；退出清理 |
| 无 priority | 栈序显式 | 需要固定相对序时依赖 push 顺序 | 约定 push 顺序；必要时加显式 priority |
| capture 短路 | 独占简单 | 部分放行的模态要拆多档 | 需要时加 `'except` 名单 |
| on-blur 声明 | 通用 | 焦点抖动可能误触发 | 只对声明 focus 的层触发 |
| base 独立 | 无生命周期负担 | base 不能捕获独占 | capture='all' 层屏蔽 base 即可 |
| 字符回退 | 模态可按字符绑 | 与编辑表的 'text 语义有重叠 | 只在 miss 时回退 |

---

## 12. 三件套闭环回顾

```
Event
  │
  ├─[layer]── 归属：查 base + 层栈，capture 短路  ──▶ Action
  │
  ├─[policy]─ 门控：before（许可 / 挂起 / 替换） ──▶ Effects
  │
  └─[job]──── 异步：提交 / 版本闸门 / 结果回灌 ─────▶ Effects
                                                      │
                                              apply ──▶ Session
```

- **layer** 回答"这一击归谁"；
- **policy** 回答"准不准、怎么改"；
- **job** 回答"哪些要异步、迟到怎么办"。

三者都建立在同一套 **Action / Effect / registry** 上，因此可以互相组合：
layer 的表可以绑出 policy 能门控的命令；命令可提交 job；job 结果回灌成 effect
再由 policy 变换。控制流全程是数据，可枚举、可测、可回放。
