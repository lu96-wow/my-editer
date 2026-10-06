# lab-rebuild 阶段审计与下一批功能设计

> 只设计、不动手。三方对齐：**原 lab**（功能说明书）、**前面的设计文档**
> （`lab/DESIGN*.md`、`REVIEW.md`）、**当前 lab-rebuild 实现**。
> 结论先行：主体设计成立；有 **2 处我们前面的设计不完整/过度统一**、**1 处实现语义 bug**、
> 若干缺口。下一批功能（属性插件 / 补全 / 文档浮窗 / 前缀 / 主题 / 包加载）按修正后的设计做。

---

## 1. 原 lab ↔ lab-rebuild 功能对照

| 能力 | 原 lab | lab-rebuild | 结论 |
|---|---|---|---|
| 文本编辑（多光标） | ✅ | ✅ | 对齐 |
| 撤销合并 | policy（命令内 if） | after-policy | 更干净 |
| 保存确认 | 命令内递归 | before-policy + Interaction | 更干净 |
| 底部槽位 state/input | ✅ | ✅（status-vid/input-vid + effective-slot） | 对齐 |
| submit prompt | mode(prompt) | layer(prompt) | 对齐，语义更强 |
| 前缀键 / 键序列 | mode(prefix) | layer 支持，**未接** | 缺口 |
| 分屏 / 焦点 | edit-panes | frame + focus | 对齐 |
| 左栏面板 | panel provider ×2（tree/buffers） | panel ×1（buffers） | **缺 tree** |
| 装饰浮层（菜单/浮窗） | overlay provider（每帧产 pane） | **完全没有** | 缺口 |
| 属性插件（高亮） | highlight 全家桶 | 完全没有 | 缺口 |
| 异步 place | job + doc-job + highlight runner | **内核 job 未被使用，无 runner** | 缺口 |
| face / 主题 | face + theme + 后端配色 | face/theme 全无，后端不配色 | 缺口 |
| 剪贴板 | copy/cut/paste | 只有 select-all/undo/redo | 缺口 |
| indent / autopair | ✅ | 无 | 缺口 |
| 配置驱动包加载 | package + catalog | app 直接注册 | 缺口 |
| 文件树新建/删/改名 | tree.rkt | 无 | 缺口 |
| 鼠标 | 特判分支 | 走 resolve | **更干净** |
| 键表运行时补键 | keymap-add! | 无（assembly 静态） | 缺口（低优先） |

---

## 2. 与前面设计文档的偏差审计

逐条对照 `DESIGN.md` / `DESIGN-POLICY-EFFECT.md` / `DESIGN-LAYER.md` / `REVIEW.md`。

| # | 设计说 | 实现 | 判定 |
|---|---|---|---|
| A1 | 四通道之一「输出 = decoration(scope document/frame/slot)」 | 只有 hook+reload，无 decoration | **设计需修正**（见 §3.1） |
| A2 | `job` 统一所有异步，删掉两套 runner | job 未用；highlight 那种「带状态流式」无法用请求/响应 job 表达 | **过度统一，需修正**（见 §3.2） |
| A3 | focus = target + history；`focus-move`/`focus-push`/`focus-restore` | 只有 `focus-move`（每次都压栈） | **实现语义 bug**（见 §3.3） |
| A4 | hook 是 notify effect；point 与实现分离 | 已按此实现（`(struct hook (point proc))`） | 修正完成（曾因 name 冲突踩坑） |
| A5 | `registry` 按 (kind,name) 唯一，priority 排序 | 已实现 | 对齐 |
| A6 | layer 栈、capture、pop、on-blur、模板/实例 | 已实现并通过 prompt 测试 | 对齐 |
| A7 | policy before 首个决定者 / after 全变换 | 已实现 | 对齐 |
| A8 | Interaction `resume ctx sid response` | 已实现（曾少传 sid） | 对齐 |
| A9 | effect 无返回值；复合用 show / temp | show 用了；temp 未用 | 对齐（temp 备用） |
| A10 | `binding` 贡献 / 命名 keymap 可变 | 用静态 table + command-set；`contrib 'binding` 未用 | **声明过宽**（见 §3.5） |
| A11 | `emit` 逃逸副作用 | no-op | 待接（低优先） |
| A12 | notify 重入预算 | 未实现 | 缺口（见 §3.6） |
| A13 | service 生命周期（place 在 with-tui 内建） | 未实现 | 缺口（随异步一起做） |
| A14 | 属性写回 = effect `attr!`，不做 decoration(document) | 未实现 | 与 A1 一起修正 |
| A15 | 面板/槽位「选择是字段，内容是 effect」 | 已实现 | 对齐 |
| A16 | 派生量不进 session | 大体对齐；`active-panel` 已存但 render 用 `(car panels)`，不一致 | 小修 |

---

## 3. 需要修正的设计（先改设计，再写代码）

### 3.1 输出通道修正：内容 vs 浮层是两条路

**发现**：原 lab 实际上也是两条路——
- 状态行 / 面板：`before-render` 钩子 + `editor-view-assign!`（改真实视图内容，走 effect）；
- 菜单 / 浮窗：`overlay-register!` 每帧纯函数产 `pane`。

而我们在 `DESIGN.md` 里把两者都塞进 `decoration`，是**过度抽象**。正确模型：

```racket
;; 机制一：视图内容（document / slot）—— 走 effect（reload / attr!）
;;   触发时机用 hook（before-render），内容写入是 effect（唯一写入点）。
;;   适用于：状态行、面板、输入行、属性高亮。

;; 机制二：浮层 pane（frame）—— 纯 per-frame provider（不经 effect）
(provide overlay-register! overlay-panes)
(struct deco (id priority render) #:transparent)
;; render : Ctx -> (listof pane)
(overlay-panes ctx) = (append* (map render (reg-kind reg 'deco)))
```

render 时：`layout(frame) ⊕ overlay-panes(ctx) ⊕ bars` → core 合成。
- **没有 effect 参与浮层**：浮层是当前 session 的纯函数，不进历史、不需版本门。
- 锚点 / 边框原语（`anchor-screen-pos` / `frame-pane` / `box-line`）放 `kernel/overlay.rkt`。

**为什么这样对**：内容是可编辑/可持久的「状态」，浮层是瞬态「装饰」。前者必须走状态通道
（唯一写入、可撤销/可同步），后者每帧重算即可。混在一起会让浮层也必须经 effect、进管线，反而重。

### 3.2 异步修正：内核「版本闸门」+ 特性「传输」，不是统一 runner

**发现**：异步其实两类——
1. **无状态请求/响应**（查文档）：`submit(request) → result`，可直接用通用 runner。
2. **有状态流式**（高亮）：worker 维护影子文本，主进程发**增量**（open/change/drop/job），
   还要「多插件结果到齐才写回」。这不是请求/响应能表达的。

我们前面说「删掉两套 runner，统一为 job」是**错的**。修正为：
- **内核只统一「版本闸门 + 挂起表」**（安全不变量，必须一处实现）；
- **传输（sync / place 协议、影子状态）由特性自管**。

```racket
;; kernel/job.rkt
;; 提交：登记一个带版本闸门的挂起
(define (pipeline-pending! ctx id version current? on-result) -> ctx)
;; 交付：闸门校验 → 命中则 on-result 产 effect（过 after-policy）
(define (pipeline-deliver! ctx id result) -> ctx)
;; session.pending : hash id -> (list version current? on-result)
```
- 查文档：doc-job 用 place runner，结果到达 → `pipeline-deliver!`；version=文档句柄。
- 高亮：feature runner（sync/place）管影子；每个 (did,token) 结果到达 → 同样 `pipeline-deliver!`
  （version=token），「到齐才写回」是 on-result 里的特性逻辑。

这样**闸门只写一遍**，传输各随其需，避免了硬统一。

### 3.3 focus 语义修正：set / push / restore 分离

**bug**：`focus-move` 每次都压栈，方向键/鼠标移动会无限堆积历史，而 `restore` 只弹一个，
侧栏「显示→聚焦面板，隐藏→还原」的配对会被后续移动打乱。

修正：
```racket
(focus-set f target)      ; 普通移动，不动栈
(focus-push f target)     ; 记住当前 + 移动（侧栏/prompt 用）
(focus-restore f)
```
effect：`e-focus target`（set）；`e-focus-push target`（push）。
- 方向键 / 鼠标点击 / 打开文档 → `e-focus`（set）
- toggle-sidebar 显示 → `e-focus-push`；隐藏 → `e-focus 'restore`
- prompt 入栈 → layer.focus 自动 `e-focus-push`；出栈 → `restore`

### 3.4 派生一致：render 用 `active-panel` 而非 `(car panels)`

小修，避免「字段存了却不用」。

### 3.5 收回过宽声明：binding 贡献

`DESIGN` 说键表是 registry 贡献、可运行时补键。实现用静态 table + command-set，
这对现有功能足够。**结论**：`contrib 'binding` 暂不实现；若将来确需运行时补键
（插件往已有表补键），再引入。文档改成「键表是组装期合成（assembly-time）」。

### 3.6 notify 重入预算

hook 产出的 effect 可能再含 `notify`，形成环。内核在 `run-notify` 上加深度预算（如 16），
超限丢弃并记警告。这是安全底线，放内核而非 policy。

---

## 4. 下一批功能设计

### 4.0 新增内核基石（先立，后续都用）

| 模块 | 内容 |
|---|---|
| `kernel/face.rkt` | `palette-color` / `face-stack` / `face-compose` / `face-layers`（#:prefab，可跨 place） |
| `kernel/overlay.rkt` | `deco` 注册 + `overlay-panes` + `frame-pane`/`box-line`/`box-hline` + `anchor-screen-pos` |
| `kernel/job.rkt` | 扩展：`pipeline-pending!` / `pipeline-deliver!`（版本闸门） |
| `kernel/theme.rkt` | `theme` 值 + `theme-face-colors`（含 face-stack 逐分量合并）/ `theme-overlay-colors` |
| `kernel/wrap.rkt` | 纯折行（浮窗复用） |
| `kernel/package.rkt` | 包加载（见 4.6） |
| `kernel/focus.rkt` | set/push/restore（§3.3） |

新增 effect：
```racket
(e-attr-highlight! did fills combine)  ; 写高亮轨（就地 box，不记 history）
(e-attr-readonly!  did fills)          ; 写只读轨
(e-focus-push target)
```

### 4.1 属性插件 / 高亮（highlight）

**接缝**（与原 lab 同构，但用新架构）：
- 插件 = 纯 `open`/`change`（`kernel` 不解释，registry kind `'prop-plugin`）。
- 特性状态（影子、token、latest）放 `runtime.services['highlight]`（per-runtime，可测）。
- 传输：feature runner（先 sync，后 place）；worker 按 name 查同一 registry。
- 版本闸门：走 `pipeline-pending!`/`deliver!`，version = document token（weak-hasheq）。
- 写回：on-result → `e-attr-highlight!`（compose face-stack）。
- 接线：
  - `after-edit` → 记增量（带插入文本）
  - `document-closed` → forget
  - `before-render` → sync + poll
  - `app-service-source` → 后端唤醒（place 时）
- 只对真实文件（`path-table-path` 存在）。

**验收**：打开 .rkt，括号/词/关键字上色；undo/redo 回到旧 token 不重算（命中缓存）。

### 4.2 补全（complete）

- `layer 'complete`（fallthrough, pop never, 不占槽、不抢焦点）
- `keymap`：`complete` 表 + 往 `edit` 表补 `C-n`
- 命令：`complete` / `-move` / `-accept` / `-cancel`
- `deco 'complete`（frame 浮层：菜单 + 选中项内嵌 bluebox）
- `job`：查文档（place）→ `pipeline-deliver!`
- hooks：`after-insert`（refine）/ `after-nav` / `focus-changed`（取消）/ `job-tick`
- 纯逻辑：`lang/{ident,source,complete,docs}`（可单测）

**验收**：打字弹菜单、`↑↓` 选择、`Tab/Enter` 接受、`Esc` 取消、导航/失焦取消。

### 4.3 文档浮窗（docs）

- `layer 'docs`（capture all）
- `deco 'docs`（frame 浮窗，`frame-pane` + `wrap`）
- `job`（place）+ `job-tick`
- `C-p` 前缀 + `d` 绑定（需要 §4.4 前缀层）

**验收**：`C-p d` 弹出标识符文档、`↑↓/PgUp/PgDn` 滚动、`Enter/Esc` 关闭、结果版本门。

### 4.4 前缀层（multi-key）

- `prefix` layer-spec：`capture='all'`、`pop='next'`、`slot=#f`、`focus=#f`；state 带 label+tables。
- 命令 `e-input-push 'prefix (prefix label tables kind)`。
- `C-p`（焦点表）、`M-m`（窗格移动）、`M-s`（缩放）、`C-x`（键序列）。
- 键序列 = 嵌套 push。

**验收**：`C-p` 后方向键移焦点、`M-m` 后方向键换窗格、`Esc` 退出；未绑定键也按 `pop='next'` 退出。

### 4.5 剪贴板 / indent / autopair（小功能，验证输入插件）

- 剪贴板：`copy`/`cut`/`paste`（core clipboard 已支持），命令 + 键位。
- `indent`：覆盖 `newline-and-indent`（同名命令 upsert）。
- `autopair`：`before-*` 钩子（需要内核加 `before-insert` / `before-backspace` 钩子点与「first-wins」语义）。

**验收**：`(` 自动补 `)`；`C-c/C-x/C-v`；Enter 按括号缩进。

### 4.6 主题 + 后端配色

- `config/theme.rkt`：`theme` 值（faces / overlays / default / palettes），默认深色。
- 后端把 `piece` 的 attr（`(overlay . face)`）→ ANSI：face-stack 逐分量合并，palette 取模。
- `runtime.theme` 持有当前主题。

**验收**：语法/括号/词着色上屏；selection overlay 配色。

### 4.7 配置驱动包加载

- `config/packages.rkt`：`(name register-proc)` 列表（静态、可测）；
  `app-init` 折叠 `register!`。若确实要动态：`dynamic-require` 包模块的 `register` 导出。
- 内容：把现有 `register-edit!/status!/prompt!/panels!/mouse!/policy!` + 新增
  `register-highlight!/complete!/docs!/prefix!/clipboard!/indent!/autopair!` 收进目录。
- `config/plugins.rkt`：启用哪些属性/输入插件（只给名字）。

**验收**：从目录增删一个包即增删功能，`app.rkt` 不改。

---

## 5. 实现顺序与判定

1. **修正三处**（§3.3 focus、§3.6 notify 预算、§3.4 active-panel）—— 小，先做，避免后续返工。
2. **立新基石**（§4.0：face / theme / overlay / wrap / job-gate / focus）。
3. **前缀层**（§4.4）—— 只依赖 layer，风险低，且 docs 需要。
4. **剪贴板 / indent / autopair**（§4.5）—— 验证钩子与命令覆盖。
5. **高亮**（§4.1）—— 验证版本闸门 + place + face 分层写回。
6. **补全 / 文档浮窗**（§4.2/4.3）—— 验证 deco 浮层 + layer + 异步文档。
7. **主题配色**（§4.6）。
8. **包加载**（§4.7）—— 最后把装配改成目录驱动。

**每步以 smoke 断言收口**，并保持 `raco make` 通过。

---

## 6. 结论

- 主体组合子设计（registry / effect / policy / layer / frame / focus）经实现与测试**成立**；
- 两处需要收回：**输出统一成 decoration**（改为「内容走 effect、浮层走纯 provider」）、
  **异步统一成 job**（改为「内核统一闸门、特性自管传输」）；
- 一处实现语义 bug：**focus 压栈**；
- 其余为功能缺口，按 §4 逐个补，不触碰基石。
