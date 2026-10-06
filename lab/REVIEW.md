# lab-rebuild 整体体检：配合、别扭点、组合手感

> 基于当前实现（kernel 1555 行，其中 `pipeline.rkt` 539 行）+ 各 feature 的依赖面与
> 状态落点实测。结论：**四通道组合子本身很好用、配合顺畅；别扭点集中在"注册与状态落点"
> 三处，其中一处是设计需要调整的**。

---

## 1. 一句话结论

- **组合子（registry / effect / policy / layer / frame / focus / overlay / runner+gate）配合良好**：
  高亮、补全、文档浮窗、前缀、保存确认这些新功能**没有改动任何组合子的语义**。
- **摩擦集中在**：
  1. **effect 集合是封闭的** → 每加一个功能都要改 `kernel/effect.rkt` + `kernel/pipeline.rkt`；
  2. **feature 键位集中在 `config/keys.rkt`** → 功能不能自带默认键；
  3. **feature 状态有三种落点**（layer 实例 / service / session 字段）→ 不统一。
- 还有一批**死参数 / 死 effect**在误导读者。

---

## 2. 好的部分（有证据）

| 观察 | 证据 |
|---|---|
| effect 语义无歧义 | 37 个 tag，`pipeline` 每个恰好一个 case（实测 `case=1`） |
| 组合子语义稳定 | 高亮/补全/文档/前缀/剪贴板/indent/autopair 接入**未改组合子语义** |
| layer 真能承载多模态 | prompt（fallthrough、on-blur）、prefix（capture all、pop next）、complete（fallthrough）、docs（capture all）共存且测试过 |
| policy 与 effect 正交 | 保存确认（before+Interaction）、撤销合并（after）都不在命令里 |
| 异步闸门一处实现 | `e-await`/`e-deliver` 被 docs 复用；`kernel/runner` 被 doc-job 复用 |
| 命中测试统一 | 鼠标走 resolve，无特判分支 |
| 装配可配置 | `config/packages.rkt` 折叠 register 过程，app 不认识具体包 |

**结论**：作为"组合子基石"，方向是对的、也能用。

---

## 3. 别扭点（按影响排序）

### P1（设计要调整）effect 集合封闭 → 功能必须改 kernel

**现象**：每个新功能都要在 **两个 kernel 文件**各改一处：

| 功能 | kernel/effect.rkt | kernel/pipeline.rkt |
|---|---|---|
| 前缀 | +e-pane-swap / e-pane-resize / e-focus-push | +3 case |
| 剪贴板 | +e-copy/cut/paste | +3 case |
| 高亮 | +e-attr-highlight! | +1 case |
| 补全/文档 | +e-input-set / e-await / e-deliver | +3 case |
| 鼠标 | +e-pointer / e-scroll | +2 case |

这与"功能包只通过扩展点接入、不 require 平台内部"的目标**矛盾**：功能不能自造 effect。

**为什么当初封闭**：`DESIGN` §3.2 说"kernel 可穷举 apply 语义、可测"。

**修正（推荐）**：effect **处理器**开放注册，但**施加入口仍唯一**：
```racket
;; kernel: 默认处理框架 effect（edit/open/show/focus/input/notify/await/deliver/quit…）
;; feature: 注册自己的 effect 处理器
(reg-add r (contrib 'effect 'attr-highlight 0
  (lambda (ctx did fills combine) ...)))   ; 返回新 ctx
```
`pipeline` 的 `apply-effect` 先查 `'effect` registry，命中则调用，否则走内建。
- 保留"单一写入点 + 可枚举"；
- 功能自带 effect 构造器（用 `fx`）与处理器，不再改 kernel；
- 框架 effect 仍内建（安全/顺序敏感）。

### P2（设计要调整）feature 键位集中在 config

**现象**：`config/keys.rkt` 里出现 `(key 'n 'ctrl) 'complete`、`(key 'd) 'show-docs`。
即 feature 的默认键写在**配置**里，删掉包后键位残留。

**修正**：把当初删掉的 `contrib 'binding` 补回来（只做组装期）：
```racket
(contrib 'binding 'complete 0 (binding 'edit (key 'n 'ctrl) 'complete))
(contrib 'binding 'docs 0 (binding 'focus (key 'd) 'show-docs))
```
`app-init` 把 `'binding` 贡献折进 `command-set`/命名表。config 只留**覆盖**用途。

### P3（一致性）feature 状态有三种落点

| 落点 | 谁在用 | 适合 |
|---|---|---|
| layer 实例 state | prompt / prefix / complete / docs | 模态会话态 |
| runtime.services | highlight（machine/token）、doc-job（runner） | 长生命周期 |
| session 字段 | `panels` / `active-panel` / `status-vid` / `input-vid` | 框架？ |

`panels`/`active-panel` 其实是 **buffers 面板这个 feature 的状态**，却占用了 kernel 的
`session` 结构。后果：加功能可能要在 `session` 加字段（kernel 又被 feature 牵动）。

**修正**：`session` 只留框架状态（editor/frame/focus/input/cs/paths/awaiting/pending/
尺寸）。面板状态放进 `service 'panels`，或泛化为"装饰内容来源"。

### P4（清理）死参数 / 死 effect

实测：
- `e-place` / `e-arrange`：**pipeline case 是 no-op**，且无人调用；
- `e-emit`：no-op 且无人调用；`save` 直接在 pipeline 里写文件（**状态与 IO 混一起**）；
- `e-show` 的 `placement` 参数被忽略（`show-document` 永远 replace-active）；
- `kernel/job.rkt` 的 `job` struct：**无人使用**（异步已走 runner + `e-await/e-deliver`）；
- `session.temp`：只存过 `'last-did`，且从不清理。

**修正**：删掉死 effect（或实现）；`save` 改为产 `(e-emit (write-file …))`，由 driver 执行
（pipeline 回归纯施加）；`job` struct 删除；`temp` 要么删，要么 step 末尾清空。

### P5（体量）`pipeline.rkt` 成了 god module

`pipeline` 539 行，`apply-effect` 约 284 行。它是唯一写入点（设计如此），但继续长会难维护。

**修正**：`apply-effect` 按通道拆到 `kernel/apply/{edit,workspace,input,async,io}.rkt`，
pipeline 保留 resolve/perform/post + 分派。配合 P1 后会更小。

### P6（手感）require 样板

feature 包 require 5–12 个 kernel 模块（docs 12 个）。没有门面。

**修正**：`kernel/api.rkt` 重导出稳定公开面（registry/effect/policy/layer/table/binding/
hooks/overlay/session/runtime/paths/frame/focus + editor-api）。feature 只 require 一个模块。

### P7（命名陷阱）构造器 / 访问器 / 参数同名

已踩 4 次：`ctx`、`area`、`runner-source`、`runtime-sources`。
**修正**：约定 struct 变量用短名（`c`/`r`/`a`），访问器不当函数名用；给 `ctx` 构造点加注释。

### P8（一致性）异步两处"pending"命名

`session.pending`（Interaction 挂起） vs `session.awaiting`（版本闸门）。
**修正**：改名 `interactions` / `awaiting`。

### P9（半接线）deco 的 overlay 未上屏

补全菜单选中行标 `(cons 'cursor 'state)`，但后端只画 `run-face`、**忽略 overlay**，
选中态不可见。
**修正**：后端处理 pane 的 overlay attr（或在菜单里改用高亮 face）。

### P10（宣称 vs 实际）高亮"增量"未接线

`machine-change!` / `shadow` 支持增量，但 `highlight.rkt` 每个 token 变化都**整篇重开**。
**修正**：用 `after-edit` 的 edits 走 `machine-change!`，或干脆删掉 shadow/change 的骨架
（避免"有增量 API 却不用"的误导）。

### P11（小）面板模型重复

`refresh-buffers` 与 `cmd-panel-activate` 各自重算 `doc-list`。
**修正**：模型放 service/state，两者共用。

---

## 4. "组合是否顺手"的量化

**加一个功能要动几处？**

| 功能类型 | 现在要动 | 目标 |
|---|---|---|
| 纯命令（如 indent） | feature + packages +（键位改 config） | feature + packages |
| 带键位（如 complete） | feature + packages + config/keys + effect + pipeline | feature + packages |
| 带新状态（如 docs） | 上面 + 可能 session/effect | feature + packages（状态进 layer/service） |
| 带新 effect（如 attr） | feature + packages + effect.rkt + pipeline.rkt | feature + packages（effect 处理器开放） |

**目标态**：功能只需改 **feature 模块 + `config/packages.rkt`**。
现在的差距 = P1（effect 开放）+ P2（binding 贡献）+ P3（状态落点）。

---

## 5. 建议的处理顺序

1. **P4 清理死代码**（低风险，立刻让 API 诚实）。
2. **P8 改名 + P7 约定**（低风险，消除持续踩坑）。
3. **P2 binding 贡献**（中，解锁"功能自带键位"）。
4. **P1 effect 处理器注册**（中，最关键，解锁"功能自带 effect"）。
5. **P3 状态落点收敛**（中，稳定 kernel `session`）。
6. **P5 拆 pipeline + P6 kernel 门面**（结构整理）。
7. **P9/P10/P11**（收尾一致性）。

---

## 6. 总评

- **组合子层：优**。四通道职责清晰，交叉功能（prompt×layer×slot、save×policy×interaction、
  highlight×gate×attr、docs×deco×runner）都能组合，且测试覆盖。
- **扩展接缝：中**。影响最大的是 effect 封闭与键位集中——这正好是我们当初"收得太拢"的
  两处（`DESIGN-NEXT §3.5` 已预见 binding，effect 封闭则低估了）。
- **实现卫生：中**。死 effect、god module、同名陷阱、半接线需要清理。

一句话：**基石没问题，把"扩展接缝"再打开一点（effect 处理器 + binding 贡献 + 状态落点），
功能包就真正做到"只改自己 + 目录"。**

---

## 7. 处理结果（本次已做）

| 项 | 处理 | 结果 |
|---|---|---|
| P1 effect 封闭 | **改成处理器注册**：`contrib 'effect tag handler`，`apply-effect` 先查 registry 再走内建 | ✅ 高亮/鼠标的 effect 已移到功能包，不再改 kernel |
| P2 键位集中 | **补回 `contrib 'binding`**：组装期折进命名表；前缀键按表名解析；features 自带键 | ✅ complete 的 `C-n`、docs 的 `C-p d` 移出 config |
| P3 状态落点 | 约定：`session` 只放框架状态；feature 放 layer 实例 / service | ✅ 本次无 feature 新增 session 字段 |
| P4 死代码 | 删 `e-open`/`e-place`/`e-arrange`/`e-emit`/`e-job`/`job` struct/`session.temp` | ✅ 并修正 `show` 会破坏分屏的 bug（place 进 active 叶） |
| P5 pipeline 体量 | 未做（apply 仍 524 行，但已分出 `apply-builtin-effect`） | ⏳ 留待（可用 P1 的门面继续） |
| P6 require 样板 | **`kernel/api.rkt` 门面**；13 个 builtin 收敛为 `../kernel/api.rkt` | ✅ feature 只多 require lang/config |
| P7 同名陷阱 | 本次已消除；约定访问器不当函数名用 | ✅ |
| P8 两处 pending | `session.pending` → `interactions`；`suspension` 移入 `policy.rkt`；删 `job.rkt` | ✅ |
| P9 overlay 未上屏 | 后端改成 **patch 绘制**（`app-render-patch`），处理 `(overlay . face)`（cursor→反色、region→背景） | ✅ 选区/菜单选中态可显示 |
| P10 高亮增量 | 接上 `after-edit → machine-change!`（有上一版本 + edits 则增量） | ✅ 测试覆盖 |
| P11 面板模型 | `refresh` 与 `activate` 已共用 `doc-list` | ✅ 本已满足 |

**量化改善**：新增一个带键位 + 新 effect 的功能，现在只需改
**feature 模块 + `config/packages.rkt`**（之前还要改 `config/keys.rkt` + `kernel/effect.rkt` + `kernel/pipeline.rkt`）。

**验证**：`raco make main.rkt smoke.rkt` 通过；`smoke.rkt` 全绿（含新增的增量同步断言）；TUI 编译通过。

**仍留**：P5（拆 pipeline）、以及 `emit` 独立通道（当前 `save` 仍就地写盘）——不影响组合手感。
