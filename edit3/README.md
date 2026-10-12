# edit3

布局/指针交互重构版（见 `DESIGN.md`）。文本引擎复用根目录 `core/`。
在 edit3 的布局/指针内核之上，已把 edit2 的**协调层**（命令系统 / 区域 / 文件 / 面板）平移进来。

```
racket edit3/main.rkt [file]
```

## 现在能做什么

| 输入 | 作用 |
|---|---|
| 可打印字符 / Enter / BS / Del | 编辑焦点窗（`(` `{` `[` 自动配成对；再输 `)` `}` `]` 跳过已存在的） |
| ↑↓←→ / Home / End | 移动光标 |
| `C-s` 后接方向 | 分屏前缀：↑新窗在上 / ↓在下 / ←在左 / →在右 |
| `C-d` | 关焦点窗（浮窗则关浮窗；编辑器只摘窗口，不丢缓冲） |
| `M-j` / `M-k` | 浮起日志 / 文件树浮窗（已在则提到最上） |
| `M-g` | 开 / 关日志浮窗 |
| `M-b` | 侧栏区域循环成员：文件树 ↔ 缓冲区 |
| `C-b` / `C-l` | 显示 / 隐藏侧栏 / 日志区域 |
| `C-t` | 焦点窗口开关边框（每窗独立） |
| `M-/` | 补全（浮窗菜单：↑↓/Tab 选，Enter 接受，Esc 取消；候选含 require 绑定名；require/`#lang` 位置补模块路径；选中项另开**文档弹窗**） |
| `M-d` | 查光标处标识符的文档（本地定义 + 标准库 bluebox/HTML） |
| `M-e` | 焦点回编辑器 |
| `M-n` / `M-p` | 焦点在窗口间循环 |
| 文件树上 ↑↓←→ / Enter | 选择、展开/收起、打开文件 |
| 文件树 `C-n` 后 `f` | 新建文件（`C-n C-n f` 新建目录） |
| 文件树 `C-d` / `C-h` | 删除（确认）/ 显隐隐藏项 |
| `C-u` | 重读磁盘刷新文件树 |
| 缓冲区面板 ↑↓←→ / Space / n | 选择、展开收起、新建视图 |
| `M-s` | 保存焦点文档（写盘 effect） |
| `C-q` | 退出（脏文档走输入行逐个询问保存） |
| 鼠标拖平铺缝 | 改两侧尺寸（只改相邻 basis，其余精确不动） |
| 鼠标拖分隔线**交点** | 同时拖横、竖两条线 → 四窗一起缩放（`'junction` handle） |
| 鼠标拖浮窗边框 / 角 | 移动 / 缩放浮窗（对边不动） |
| 鼠标滚轮 | 滚动命中窗口 |

启动布局：左侧固定 28 列的**文件树**侧栏 + 右上编辑区 + 右下固定 2 行**状态栏**（面板 = 文档，
每帧由 State 纯投影写回；面板不可编辑）。平铺窗最小尺寸**由叶子自己决定**（编辑窗 2×2，面板/
状态条 1×1）；相邻窗之间预留 **1 格分隔线**
（不占内容），交点取 `┌┐└┘├┤┬┴┼`；浮窗有框。

## 结构

```
main.rkt
core/
  state.rkt        值类型 + State（ed/docs/views/tiling/floats/focus/drag）
  layout.rkt       纯求解器（basis/grow/shrink/min）+ 几何/命中 + 树手术 + 区域贴边
  resize.rkt       浮窗移动 / 缩放手术
  interaction.rkt  指针状态机（press/move/release）
  border.rkt       纯装饰（分隔线 + 浮窗框）
  render.rkt       geometry → core rectangle → piece
  window.rkt       wid ↔ vid（平铺/浮窗统一）
  job.rkt          异步工作（job / service / jobs 账本）
  runtime.rkt      backend 协议 + 事件循环 + 输入/worker 线程
  session.rkt      会话操作（纯）：open/save/show/split/close/dirty/区域/输入行/树/浮窗/指针
  step.rkt         路由 + op 解释器 + 装配（领域原语调 session）
  panels.rkt       面板 = 文档（状态栏 / 文件树 / 缓冲区 / 输入行 / 日志）
  adapter.rkt      core/editor 边界（唯一 require core/editor）
  route.rkt        CPS 声明式路由
  op.rkt           op 注册表（纯值）
  prompt.rkt       输入行 kind 注册表（纯值）
  keymap.rkt       键表组合
  command.rkt      binding/entry → route 编译
  mode.rkt         路径 → document 键表匹配
  plugin.rkt       插件契约（贡献包）+ 装配器
  extension.rkt    插件门面（白名单：插件只 require 这个）
  hook.rkt         生命周期钩子（reaction + emit）
  face.rkt         face 分层值（face-stack / face-compose）
  face-plugin.rkt  face 插件协议 + 每文档刷新
  bracket.rkt      括号配对（光标处括号与其配对位置）
  bracket-depth.rkt 括号嵌套深度背景（整篇，词法跳过字符串/注释/字符字面量）
  lex.rkt kind.rkt 词法器 / 文档类型判定（插件共用）
  theme.rkt        face → ANSI
  backend/tui.rkt  racket-tui 后端
  event.rkt effect.rkt fs.rkt
config/
  theme.rkt keys.rkt layout.rkt floats.rkt syntax.rkt plugins.rkt app.rkt
plugins/
  catalog.rkt      插件目录（名字 → 实现）
  demo.rkt         示例插件
  syntax.rkt       语法高亮（face 插件；关键字用主题 'keyword 调色板）
  brackets.rkt     括号高亮（嵌套深度背景 + 光标配对；'bracket / 'bracket-match）
  auto-pair.rkt    括号自动配对（成对插入 / 跳过右括号）
  words.rkt        当前词高亮（光标驱动）
  completion.rkt   补全（不抢焦点的浮窗菜单；候选含 require 绑定名 / 模块路径）
  docs.rkt         标识符文档弹窗（本地定义 + 标准库 xref/bluebox/HTML；M-d / 订阅 complete-selection）
  async-demo.rkt   异步 jobs 示例（M-o 发 worker，'job 钩子接结果）
  lang/source.rkt  #lang / require / 定义 / provide 的启发式扫描（纯）
  lang/pool.rkt    require spec → 最终绑定名（only-in/prefix-in/rename-in…）+ 模块导出
  lang/module-index.rkt  已安装模块路径索引（require / #lang 补全用）
  lang/local-docs.rkt    打开缓冲区里的顶层定义 → 一行摘要（纯）
  lang/docs.rkt          标识符 → 文档（setup/xref 找 tag；bluebox 签名；HTML 兜底）
  lang/doc-html.rkt      HTML 文档页 → markdown（bluebox 缺失时用）
测试在 ../edit3-test/core/。
```

## 插件 / 扩展

一个 **plugin** 是纯数据包，向 edit3 的注册表贡献能力；`boot` 把贡献叠加到基础表上，
编译好存进 State（`step` 从 State 读，不依赖具体插件）：

```racket
(make-plugin #:name 'demo
             #:ops              (list (cons 'demo-bump handler))
             #:prompt-kinds     (list (cons 'kind handler))
             #:panels           (list (panel-spec "*demo*" #f render))
             #:regions          (list (region 'demo 'right 24 '("*demo*") 'main))
             #:key-tables       (list '(((key y alt) always (demo-bump))))
             #:doc-key-matchers (list (cons '(ext "rkt") table))   ; 文档打开时匹配
             #:faces            (list face-plugin)                   ; 高亮层（可多个叠加）
             #:hooks            (list (reaction* 'after-edit proc))  ; 生命周期钩子
             #:services         (list (service 'words words-handler)) ; worker（payload -> result，纯）
             #:on-open          (lambda (st did path) st)
             #:boot             (lambda (st) st))
```

- **文档键表可组合**：打开文件时，把所有 `doc-key-matchers` 里命中的表（多个插件可同时
  命中）按顺序 `compose-keymaps` 成一张，绑到该 document；`focused-keymap` 返回它，
  doc 路由在全局路由之前先试它。同槽 `(binding scope)` 后表覆盖前表。
- **生命周期钩子**：`reaction = point + when(st) + priority + proc(st,args)`；事件点
  `before-render / after-edit / after-insert / after-nav / focus-changed /
  document-opened / document-closed / log-appended`。
- **face 插件**：`face-plugin = name + applies?(path,text) + scan(path,text,cursor)`；
  `scan` 返回每行一个 face 向量，多个插件按顺序叠层写成引擎 face。颜色可用命名 face，
  也可用主题调色板 `palette-color`/`palette-bg`（如关键字按分组取色）。
  核心在 `after-edit / after-insert / after-nav` 与鼠标点击后刷新；
  示例 `plugins/syntax.rkt`（关键字/字符串/注释/数字）、`plugins/words.rkt`（当前词）、
  `plugins/brackets.rkt`（嵌套深度背景 + 匹配括号）。
- **补全插件**用现成的**浮窗**做菜单（不引入新 overlay 机制），且**不抢焦点**：
  编辑器保持焦点与光标 → 能**边打边筛**（after-insert/after-edit 重筛）；菜单随光标
  落位（before-render 钩子每帧重算），候选窗口滚动（`popup-window`）；选中行铺满用
  `complete-selected`、其余 `complete`。`M-/`（editor 作用域）打开；Up/Down/Tab/Enter/Esc
  用「有菜单就操作菜单、否则回落原行为」的 op 接住。菜单**只在目标编辑窗格内**摆位：
  输入行下方放得下就放下方，否则放上方（都不盖住输入行）。焦点离开目标视图（如切文件）自动关。
  候选 = 本地文档词 + 关键字 +
  require 绑定名（`rename-in`/`prefix-in`…，见 `plugins/lang/`）；模块导出走
  `#:services 'completion-exports` 的**异步 worker**，`'job` 钩子写缓存后再开菜单。
- **文档弹窗**：`plugins/docs.rkt` 在补全选中项变化时（`emit 'complete-selection`）或在 `M-d`
  时，算「来源模块 + 原名」（`spec-binding-of`）+ 当前缓冲区的**本地定义**（`lang/local-docs`）；
  标准库/已安装包走 `#:services 'doc` 的**异步 worker**（`lang/docs`：`setup/xref` 找定义 tag →
  `scribble/blueboxes` 取签名 → 兜底抽 HTML 正文 `lang/doc-html`）。**同一时刻只允许一个 doc
  查询在途**（结果按 key 缓存），上下快速切换不重复发请求、也不会卡死；`lang/docs` 内部还用
  信号量串行化（xref/bluebox 缓存非线程安全）。选中普通标识符就**立即弹**（先显示名字/来源，
  标准库段异步补；无文档显示 "(无文档)"）；只有 require 路径补全不回文档。
  **位置**：贴**整个编辑区**（所有平铺编辑器窗的包围盒，`rect-bounds`）的上/下边、宽度取编辑区宽；
  当输入行靠近底边时自动**翻到顶边**，始终避开正在输入的行；移开光标 / 菜单关 / 切换文件则关。
  两边不 require 对方，只靠事件解耦。
- 插件只 `(require "core/extension.rkt")`（白名单门面），不碰 step，不会循环依赖。
- **异步 jobs**：插件用 `job-submit` 登记工作（纯），`jobs` 从 State 取待办；runtime 的
  worker 线程池按 `#:services` 的 `kind` 跑纯 handler，结果以 `job-event` 回注事件流；
  `step` 完成后 `emit 'job`，插件在 `'job` 钩子里按 `tag` 消费。示例 `plugins/async-demo.rkt`。
- 启用名单在 `config/plugins.rkt`（只给名字），`plugins/catalog.rkt` 解析成实现；
  未知名字直接报错。默认启用 `'(syntax brackets words auto-pair completion docs)`。
- 示例插件 `plugins/demo.rkt`（op + 面板 + 区域 + 键 + 文档匹配 + on-open + boot）。

启动**不建 scratch 文档**：编辑区是空窗口，从文件树打开文件（或命令行带文件名）。

## 还没做（对齐 edit/ 插件所需的内核能力）

- **overlay / popup + modes + 自定义路由**：浮层焦点栈、popup 几何、`modes`、
  插件直接贡献带 guard/priority 的路由。
- 文档弹窗目前不滚动（内容超出 `max-rows` 截断）；edit/ 有滚动与浮层接键栈。
- `*.rkt` 等模式键表（`config/keys.rkt` 的 `rkt-keys` 还是占位）。
