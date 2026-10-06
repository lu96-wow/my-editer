# lab-rebuild

按 `../lab/DESIGN.md` / `DESIGN-POLICY-EFFECT.md` / `DESIGN-LAYER.md` / `REVIEW.md`
实现的**新架构骨架**。core 固定不动，lab 只在其上做组合。

```
racket lab-rebuild/main.rkt [文件]
racket lab-rebuild/smoke.rkt          # 无头冒烟
```

## 目录

```
kernel/                 组合子内核（feature-free）
  editor-api.rkt        唯一 require core 的模块（窄边界）
  registry.rkt          contrib / registry（统一扩展点：kind+name+priority）
  binding.rkt           事件 → 绑定键
  table.rkt             keytable / command-set（binding→spec）
  action.rkt            Action（意图：命令 / 钩子 / 任务结果 / 续延）
  effect.rkt            Effect 目录（状态变换的描述）
  policy.rkt            Policy / Interaction（门控 / 变换 / 挂起）
  layer.rkt             layer-spec / layer-inst / input（输入层栈）
  job.rkt               job / suspension（异步 + 版本闸门）
  frame.rkt             leaf / split / frame + 纯派生布局
  focus.rkt             focus（唯一活动目标 + 历史）
  session.rkt           session（不可变会话状态）
  runtime.rkt           runtime / ctx
  hooks.rkt             生命周期通知
  command.rkt           命令调用
  pipeline.rkt          事件 → 动作 → 效果 → 会话（唯一写入点）
  render.rkt            每帧：通知 → 布局 → core 合成
app/app.rkt             唯一装配点
backend/tui.rkt         racket-tui 后端
config/keys.rkt         默认键位
builtin/*               功能包（只注册 contribution）
smoke.rkt               无头冒烟
```

## 数据流（与设计对应）

```
Event
 ├─ resolve     层栈 + base，capture 短路 + 字符回退      → Action
 ├─ perform     before-policy 门控 → 命令 → after-policy  → Effects
 ├─ handle      apply-effect（notify/job/resume 递归）    → Session
 └─ post        pop / on-blur / post-command
render: before-render 通知 → layout(frame) → decoration → core 合成
```

## 本骨架已实现

- **统一 registry**（contrib，priority、可枚举、可 upsert）。
- **Effect 即数据**：命令只返回 `(listof effect)`，`pipeline` 是唯一写入点。
- **Policy**：before 门控 / after 变换；`Interaction` 挂起机制。
- **Layer 栈**：`capture` 短路、声明式 `pop`、`on-blur`、`set`/`push`；模板/实例分离。
- **Frame**：role 窗格树 + 纯派生 layout + swap/resize；`Focus` set/push/restore。
- **Overlay（deco）**：每帧纯 provider 产浮层 pane；`frame-pane`/`box-line`/`anchor`。
- **异步版本闸门**：`pipeline-pending!` / `pipeline-deliver!`（内核统一；传输特性自管）。
- **service**：runtime.services（per-runtime 特性状态）。
- **editor-api**：core 只被一个模块 require。
- 基础编辑（打字 / 退格 / 删除 / 导航 / 撤销 / 重做 / 全选 / 复制 / 剪切 / 粘贴 / 打开 / 保存 / 退出）。
- **prompt**（输入/确认）+ 保存确认（`quit-confirm` + Interaction）。
- **前缀层**（`C-p` / `M-m` / `M-s`）+ 窗格交换 / 缩放。
- **左栏面板**：文件树（tree）+ 文档/视口两级树（buffers）；鼠标命中测试走 resolve。
- **indent**（覆盖 newline）+ **autopair**（before-insert 钩子）。
- **属性高亮**：3 个纯插件（当前 `applies?` 均限定 Racket 文件）+ 版本闸门 + `face-stack` 分层写回 + `attr!` effect。
- **补全菜单**（仅 Racket 文件，`lang/file-kind.rkt` 判定）：打字自动弹（after-insert）+ `C-n` 显式；layer + deco 浮层 + 候选池 refine；候选含 `#lang`/`require` 导出，选中项内嵌 bluebox 文档（异步）。
- **文档浮窗**：`C-p d`（layer + deco + 异步；bluebox）。
- **通用异步执行器**：sync / place runner（服务惰性创建）；后端 on-source 唤醒。
- **主题配色**：face/palette → ANSI（后端）。
- **配置驱动包加载**：`config/packages.rkt` 折叠 register 过程。

## 异步边界（重要）

- **内核只统一版本闸门**：`pipeline-pending!`（`e-await`） / `pipeline-deliver!`（`e-deliver`）。
- **传输自管**：`kernel/runner`（sync/place）是通用原语；高亮用特性 machine/runner，
  查文档用 `doc-job` 服务，各自决定同步或 place。
- place runner 必须在 `tui:with-tui` 之后惰性创建。

## 键位（当前）

```
Ctrl-O  find-file        Ctrl-B  toggle-sidebar      Ctrl-S  save
Ctrl-Q  quit（改脏先问）  Ctrl-L  split-lr            Ctrl-K  split-tb
Ctrl-D  pane-close       Ctrl-N  补全                 Ctrl-A/C/X/V 选择/复制/剪切/粘贴
Ctrl-Z  undo / Ctrl-Y redo
C-p     焦点前缀         M-m     窗格互换前缀        M-s     窗格缩放宽前缀
方向/Home/End/Tab/Enter  鼠标：点击聚焦+定位、滚轮滚动
面板内：Tab 在 tree ↔ buffers 轮换
  tree:    Enter 展开/打开，C-n 新建文件，C-l 新建目录，Backspace 删除
  buffers: Enter 展开文档/显示 view（替换活动编辑叶），C-l / C-k 分屏插入选中 view，C-n 新建 view，Backspace 关闭（view/文档）
```

## 尚未实现（骨架留白）

- **高亮的 place 传输**（目前 sync；machine/shadow 已具备，差 runner 接线）。
- `emit` 独立通道（当前 `save` 就地写盘）。
- 多工作区 / 窗口。

## 硬约束（实现时遵守）

1. Effect 只由 `pipeline` 施加；命令 / 钩子 / 插件不得直接改 session。
2. `layout` 是 frame 的纯派生，不缓存真身。
3. 派生量（active / slot-vid / panel-vid）不进 session。
4. 选择是字段，内容是 effect。
5. core 只允许 `editor-api` require。
