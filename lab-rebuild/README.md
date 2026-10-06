# lab-rebuild

从 `lab` 拆出来的「核心命令平台 + 插件」重建。分层依据见
`../lab/ARCHITECTURE.md`。原则：**平台只提供机制与扩展点，功能都做成包 / 插件**。

## 阶段

- **Phase 1（已完成）L1 平台骨架** —— 可编译、可跑、不含任何功能插件。
- **Phase 2（已完成）扩展点** —— 命令 / 键表 / mode / overlay / hook 全部注册化。
- **Phase 3（已完成）内置包** —— 面板（文件树 / 文档列表）、补全、文档（含统一异步 job）。
- **Phase 4（已完成）插件系统** —— 属性插件（brackets / words / syntax）+ 输入插件
  （auto-pair）按扩展点接入；启用集在 `config/plugins.rkt`。
- **Phase 5（已完成）配置驱动加载 + 补全内嵌文档** —— 包表 `config/packages.rkt` +
  `platform/package.rkt` 动态加载；补全菜单复用 `doc-job` 内嵌 bluebox。

## 扩展点 API

功能包只通过这些接口接平台，不 require 平台内部：

| 扩展点 | 接口 | 说明 |
|---|---|---|
| 命令 | `command-register!` / `define-command` | 注册 `(event app . args) -> any` handler |
| 键表 | `keymap-define` / `keymap-add!` / `keymap-remove!` | 命名 keymap 可变，运行时补键立即生效 |
| 模式 | `mode-type-register!` | 声明 匹配 / 键表 / 底部槽位 / 焦点 / 独占 / 一次性 |
| 装饰层 | `overlay-register!` | `(app -> (listof pane))`，每帧拼接 |
| 面板 | `panel-provider-register!` | 左栏面板：`context -> (values ed panel)` |
| 异步 | `make-sync-job-runner` / `make-place-job-runner` | 统一 job：submit / poll / source |
| 加载 | `config/packages.rkt` + `platform/package.rkt` | 包表 `(name module init)`，`dynamic-require` |
| 属性 | `after-edit` / `job-tick` / `before-render` 钩子 + `editor-document-handle-*highlight*` | 高亮写回 |
| 输入 | `before-insert` / `before-backspace` 钩子 | 返回 `#f` / `'()` / changes |
| 钩子 | `hook-add!` / `hook-run!` / `hook-run-first!` | 见下 |

### 命名 keymap

`config/keys.rkt` 注册：`edit` / `global` / `readonly` / `focus` / `input-edit` / `confirm`。
包往已有表补键：`(keymap-add! (keymap-ref 'edit) binding spec)`。
command-set 持有同一对象 → 追加对 dispatch 立即可见。

### mode-type

```racket
(mode-type name match? tables bottom focus exclusive? transient?)
;; match?     : mode -> bool
;; tables     : mode -> (listof keymap)
;; bottom     : mode -> 'state | 'input
;; focus      : mode -> #f | 'input
;; exclusive? : 只查它的表，不回落 did/global
;; transient? : 处理一个事件后自动退出到 #f
```

内置 `prompt` / `prefix` 已注册；补全 / 文档作为独立 mode-type 注册。

### 钩子点

```
post-command     (app)
before-render    (app)                        ; 每帧渲染前（插件同步 / 写回属性）
after-edit       (app vid changes)            ; 任何文本变更（属性插件）
after-insert     (app vid changes)            ; 用户打字 / 退格 / 粘贴（补全 refine）
after-nav        (app)                        ; 光标移动
before-insert    (app text) -> #f | '() | changes     ; 第一个插手的赢
before-backspace (app)      -> #f | '() | changes
document-opened  (app did)
document-closed  (app did)
focus-changed    (app vid)
mode-changed     (app old new)
job-tick         (app)                        ; 异步结果可能到达 / 每事件
```

handler 第一参数永远是 `app`。`before-*` 用于输入改写（auto-pair）；`after-edit` +
`job-tick` + `before-render` 用于属性插件同步与写回。

### 包加载

`config/packages.rkt` 是包表；`app-init` 在其中 `dynamic-require` 每个模块（触发
顶层注册：命令 / 键表 / mode / overlay / panel / 插件），再调它的 init 导出。
基础编辑包 `builtin/edit.rkt` 例外（提供 `app-resize!` 等，直接 require）。

## 目录

```
platform/            平台核心（机制 + 状态，不认识任何功能）
  layout/{area,split,focus,main}   窗口几何
  input.rkt            事件 → 绑定键
  face.rkt             face / palette-color / face-stack 值类型
  wrap.rkt path.rkt    小工具
  slot.rkt             底部槽位文档（state / input）
  mode.rkt             prompt / prefix + mode 注册表
  hooks.rkt            具名钩子点
  overlay.rkt          装饰图层 provider 注册表 + 浮层绘制原语
  panel.rkt            左栏面板 provider 注册表
  job.rkt              统一异步任务执行器（sync / place）
  package.rkt          配置驱动加载（dynamic-require + init）
  panes.rkt            单值 pane registry（state / input）
  edit-panes.rkt       编辑区分屏模型
  paths.rkt            did ↔ path 表
  state.rkt            app 数据结构 + setter + 钩子存储 + 异步源 + 运行时参数
  keymap.rkt           keymap / command-set（binding → spec，命名表可变）
  command.rkt          命令注册表（command-register! / define-command）
  dispatch.rkt         按 did / mode 选表并执行
builtin/
  edit.rkt             基础编辑包（编辑 / 文件 / 分屏 / 面板 / 模态）
  tree.rkt             文件树面板
  buffers.rkt          文档 / 视图列表面板
  complete.rkt         补全包（mode + 键表 + overlay + 菜单内嵌文档 + 钩子）
  docs.rkt             文档浮窗包（mode + overlay + 异步）
  doc-job.rkt          异步查文档服务（单例，惰性起 place）
  doc-worker.rkt       异步查文档 place 入口
  autopair.rkt         自动配对（输入插件，走 before-insert）
  highlight.rkt        属性插件包入口（钩子 / 异步源接线）
  highlight/           属性插件实现
    api.rkt            plugin 协议 (name open change)
    machine.rkt        影子状态机（按 token 缓存）
    shadow.rkt         影子文本（增量 splice）
    runner.rkt         runner 接口 + 同步实现
    runner-place.rkt   place 实现
    worker.rkt         place 入口
    manager.rkt        版本 token / 调度 / 合并 / 写回
    brackets.rkt words.rkt syntax.rkt   三个内置插件
    lex.rkt            极简词法
    bracket-pair.rkt   括号配对 + 嵌套深度
    registry.rkt       插件目录 + 启用集解析
    syntax-config.rkt  关键字表 / 扩展名
  lang/{ident,source,complete,docs}.rkt   纯语言逻辑
app/
  app.rkt              唯一装配点 + 事件入口
  render.rkt           state 行 + 分隔线 + overlay 汇总
backend/
  tui.rkt              racket-tui 后端
config/
  keys.rkt             命名 keymap 注册
  packages.rkt         要加载的功能包表（name / module / init）
  plugins.rkt          启用哪些属性 / 输入插件
  defaults.rkt theme/  默认值 / 主题
main.rkt               TUI 入口
smoke-*.rkt            冒烟
```

## 运行

```
racket lab-rebuild/main.rkt [文件]
```

（无参数 = 空编辑器；给文件则打开。后端用 `#:background? #t`，属性插件跑在 place worker。）

⚠ racket-tui 要求 `tui:with-tui` 之前不能有 OS 线程。所有 place runner 都只能在
`app-init`（已在 with-tui 内）里创建；doc-job 进一步惰性到首次请求 / 后端登记 source。

## 冒烟

```
racket lab-rebuild/smoke-platform.rkt   # 平台 + 扩展点
racket lab-rebuild/smoke-builtin.rkt    # 内置包（文件树 / 文档列表）
racket lab-rebuild/smoke-lang.rkt       # 补全（含菜单内嵌文档）/ 文档（含异步）
racket lab-rebuild/smoke-plugin.rkt     # 高亮 / 自动配对（同步 + 后台 place）
```
