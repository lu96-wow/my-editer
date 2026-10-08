# lab-rebuild

在固定的 `../core`（编辑器平台）之上重建的编辑器。三根柱子：**编辑 / 焦点管理 / 命令**；
布局是 **主区(frame) + 停靠区(dock)**，dock 机制共用、逻辑各自独立。
设计见 `DESIGN-LAYOUT.md`；重构进度 / 耦合点 / 下一步见 `REFACTOR.md`。

```
racket lab-rebuild/main.rkt        # TUI
racket lab-rebuild/smoke.rkt       # 无头冒烟
```

## 分层

```
kernel/                 组合子内核（机制）
  editor-api.rkt        唯一 require core 的窄边界
  registry.rkt          统一扩展点（contrib：kind + name + value）
  effect.rkt            Effect 数据（编辑 / 焦点 / 主区 / dock / 层 / 异步 / 会话）
  focus.rkt             焦点：target + 历史；set / push / restore
  session.rkt           editor + workspace + focus + edit-vid + 层栈 + 键表 + 尺寸 + 异步挂起
  runtime.rkt           runtime / ctx（registry + services：root 等）
  frame.rkt             主区编辑叶树（leaf/split）+ 纯派生 rectangles
  dock.rkt              dock-spec / dock（通用停靠区）
  workspace.rkt         main + docks；条带布局 + 焦点几何
  geometry.rkt          方向导航 / 命中 / 浮层锚点（主区叶 + dock 统一算）
  documents.rkt         文档在主区的放置/显示（不懂文件/磁盘）
  paths.rkt             did ↔ 规范化路径（数据结构；由特性持有）
  layer.rkt             输入层栈（前缀 / 菜单 / 浮层模态）
  action.rkt policy.rkt 动作意图 / before-after 策略
  face.rkt theme.rkt    带参 face + 分层；主题解释（face → 颜色）
  wrap.rkt overlay.rkt  纯折行；每帧 deco provider → 浮层 pane
  runner.rkt            通用异步执行器（sync / place）
  command.rkt           invoke-command（kind='command）
  hooks.rkt             生命周期通知 run-hooks / 拦截型 run-hooks-first（kind='hook）
  binding.rkt           tui 事件 → 绑定键
  table.rkt             keytable（lookup / merge）
  pipeline.rkt          step / apply-effect（唯一写入点）；层解析 + 策略 + 异步闸门
  render.rkt            before-render → workspace 布局 + 浮层 → core 合成
  api.rkt               功能包唯一 require 的门面
app/app.rkt             唯一装配点（建主区 + 各 dock 实例）
backend/tui.rkt         racket-tui 后端（增量 patch + 定位 piece + face 配色 + 软件光标）
config/keys.rkt         基础键表：edit / global / base
config/theme.rkt        深色主题（静态 face / 色板 / overlay）
config/packages.rkt     功能包目录
config/plugins.rkt      属性插件启用名单（名字，纯数据）
config/translate.rkt    对照翻译词典（纯数据）
builtin/edit.rkt        基础编辑命令 + 分屏/关窗格/焦点方向
builtin/indent.rkt      换行语法缩进（覆盖 newline）
builtin/lang/file-kind.rkt  文档类型判定（是否 Racket 源）
builtin/autopair.rkt    自动配对（before-insert）
builtin/mouse.rkt       鼠标定位 / 滚动
builtin/buffers.rkt     缓冲区/视图树（left dock；文档/视图两级 + 新建/切换/关闭）
builtin/prefix.rkt      前缀键层（layer；C-p 焦点方向）
builtin/highlight.rkt   font-lock 属性包（async + face 分层写回）
builtin/highlight/       machine / shadow / 内置插件（brackets/words/syntax）
builtin/complete.rkt    补全菜单（layer + deco + 异步文档）
builtin/docs.rkt        文档浮窗（C-p d；layer + deco + 异步）
builtin/doc-job.rkt     异步查文档服务 + 查询组合子（view-modules / doc-await）
builtin/translate.rkt   对照翻译（src ↔ dst 双向同步）
builtin/lang/           共享词法 / 词表 / 模块 / 源码 / 文档（纯原子）
builtin/document-api.rkt 文档元数据读写接口（did↔路径、脏）
builtin/document.rkt    文档/文件逻辑：打开(去重+读盘)、保存、find-file、脏标记
builtin/doc-scope.rkt   「能力对哪些文档启用」的声明与查询（doc-applies?）
builtin/policy.rkt      undo-merge / quit-confirm（跨切面策略）
builtin/prompt.rkt      输入行（bottom dock 'input；暴露 effect 'prompt）
builtin/status.rkt      状态栏（bottom dock；只经 document-api 读元数据）
builtin/tree.rkt        文件树（left dock，展开/打开/新建/删除；带类型配色）
smoke.rkt               无头冒烟
```

## 数据流

```
Event
 ├─ resolve   事件 → binding → 层栈优先（capture/fallthrough）+ 焦点 base 表 → spec + owner
 ├─ perform   命令（before 策略门控 → invoke-command → after 策略变换）
 └─ apply     逐个 effect 施加（唯一改 editor / session 的地方）；post-pop / on-blur
render: before-render 通知 → workspace-areas(条带) ⊕ overlay-panes → core 合成
async : e-await 登记（版本闸门）→ 特性传输回灌 e-deliver → 命中且版本当前才施加
```

## 布局与焦点

- **两种焦点**：
  - `focus`（输入焦点）——决定键表与输入去向，可以是主区叶或某个 dock。
  - `edit-vid`（活动编辑视图，**粘性**）——只在 `focus` 落在主区叶时更新；进 dock 不改。
    需要「当前文档」的命令（状态行 / 保存 / 补全…）读它，不再回退「第一个编辑叶」。
- **workspace = main(frame) + docks**：
  - 布局纯派生：先切 top/bottom（横跨全宽），再切 left/right，剩余给主区。
  - 焦点几何：主区叶 + dock 的 rectangle 统一参与方向导航（同排/同列优先）。
  - dock 贡献：`(dock-spec id side size visible? make keys)`；`app-init` 折叠注册。
  - 显隐 / 尺寸：`e-dock-visible / e-dock-toggle / e-dock-resize`。
- **共用 vs 分开**：布局/命中/方向/显隐/键表选择在 kernel（共用）；状态行文本、目录内容、键位在各自 `builtin`（分开）。

## 键位（当前）

```
打字/Enter/Tab/Backspace/Delete/方向/Home/End   编辑
Ctrl-A/C/X/V 选择/复制/剪切/粘贴   Ctrl-Z/Ctrl-Y 撤销/重做
Ctrl-L / Ctrl-K 左右、上下分屏     Ctrl-D 关当前主区窗格
Ctrl-B 开关文件树 dock              Ctrl-S 保存活动文档
Ctrl-O find-file（输入路径打开）
Alt-H/J/K/L 焦点方向；Ctrl-P 前缀层（方向 / d=文档浮窗）
Alt-B 开关缓冲区 dock              Ctrl-N 补全菜单
Alt-M 前缀（方向=窗格对调）   Alt-S 前缀（方向=窗格缩放）
Ctrl-T 后 Up/Down：对照翻译（Up=水平拆/上下，Down=垂直拆/左右）   Alt-T 关闭翻译

在 buffers dock 内：
  Enter  文档=展开/折叠；视图=切换过去
  Ctrl-N 新建视图   Ctrl-L/Ctrl-K 分屏打开（左右/上下）
  Backspace 关视图/文档   Tab 切换 tree ↔ buffers
在 tree dock 内：
  Enter  目录展开/折叠；文件在活动主区叶打开
  Ctrl-N 新建文件   Ctrl-L 新建目录   Backspace 删除（y/n 确认）
  Tab 切换 tree ↔ buffers   Up/Down 导航
在 input dock 内（prompt）：Enter 提交   Escape 取消
Ctrl-Q 退出
```

## 已就绪的内核基石（第 2 步）

- `run-hooks-first`（拦截）/ `doc-scope`（能力适用范围）/ `layer`（输入层栈）
- `policy`（before 门控 / after 变换）/ `face`+`theme`（分层配色）/ `deco`+`wrap`（浮层）
- `runner`（sync/place 异步）+ 版本闸门（`e-await`/`e-deliver`）

## 留白（后续）

第 3 步特性已全部搬完：`indent` / `autopair` / `mouse` / `buffers` / `prefix` /
`highlight` / `complete` / `docs` / `translate`。
后续可选：place 后台异步（替掉 sync runner）、更多属性/输入插件、翻译视口同步细节。
每搬一个：`config/packages.rkt` 加一行、`smoke.rkt` 加断言、`raco make` + smoke 全绿。

## 渲染约束（坑）

raw 模式下 `\n` 不回到列 0，且硬件光标会停在输出末尾（底行 = 状态栏）。
所以后端**不能**整屏 `screen->string`：必须按下标 `app-render-patch`，用 piece 的 (row,col)
定位绘制，并用反色格软件画光标（`format-cursor-hide` + cursor overlay）。
