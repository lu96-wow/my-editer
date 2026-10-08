# lab-rebuild 重构记录

> 目标：在固定的 `../core` 之上，用一个**通用组合子内核**重建编辑器，逐步对齐原 `lab` 的功能，
> 同时把原 lab 里「内核 ↔ 特性」的坏耦合收干净。
> 本文记录：耦合点、已完成、当前依赖、下一步。

---

## 0. 原则（不变量）

1. `core` 只被 `kernel/editor-api.rkt` require。
2. 命令 / 钩子 / 特性只返回 **effect**，不直接改 session / editor；`pipeline.apply-effect` 是唯一写入点。
3. 特性的运行时状态放 `runtime.services`，不进 `session`。
4. 特性之间**不 require 对方的实现**；通过 effect / 查询接口 / service 组合。
5. 每步以 `smoke.rkt` 断言收口，`raco make` + `racket smoke.rkt` 必须全绿。

---

## 1. 耦合点清单

| # | 位置 | 问题 | 状态 |
|---|---|---|---|
| C1 | `pipeline` 的 `open/save/close` | 内核直接做文件 I/O + 路径 + editor/frame | ✅ 已解 |
| C2 | `session.paths` | 文件概念进 session | ✅ 已解 |
| C3 | `status → document`（require 实现） | 特性依赖特性实现 | ✅ 已解 |
| C4 | `tree → prompt`（require 实现） | 特性依赖特性实现 | ✅ 已解 |
| C5 | `pipeline.rkt` 巨模块 | effect + 几何 + 文档 + 焦点全挤一起 | ✅ 已解 |
| C6 | 缺内核基石 | 新特性会各自造轮子 | ✅ 已解（第 2 步全部完成） |
| C7 | hook 点是裸字符串 | 约定弱、易写错 | ⏳ 低优先 |
| C8 | `editor-api` 全量 re-export core | 「窄边界」不窄 | ⏳ 低优先 |

---

## 2. 已完成：第 1 步「解耦」

### C1 — 文件 I/O 移出内核
- kernel 只保留**通用**原语：`e-doc-add text name placement focus?`（装文档）、
  `e-doc-show did placement focus?`（显示）、`e-notify point args`（生命周期通知）。
- 读盘 / 去重 / 写盘 / find-file 移到 `builtin/document.rkt`：
  - `e-file-open path placement focus?`（`'file-open` effect 处理器：去重 → 读盘 → `e-doc-add`）。
  - `save` 命令（写盘）→ `e-notify 'document-saved`；`find-file` 命令（`e-prompt` + `e-file-open`）。

### C2 — 路径移出 session
- `session` 去掉 `paths` 字段。
- 元数据（did↔路径、脏）放 `runtime.services['document]`，读写统一走
  `builtin/document-api.rkt`（`doc-path` / `doc-open?` / `doc-dirty?` / `doc-set-path!` / …）。

### C3 — status 只走查询接口
- `status.rkt` require 的是 `document-api.rkt`（接口），不 require `document.rkt`（实现）。

### C4 — prompt 走 effect
- kernel effect 语言新增 `e-prompt label on-submit`（通用「询问一行」）。
- `prompt.rkt` 注册 `'effect 'prompt` 处理器（设回调 + 显示 input dock + 聚焦）。
- `tree.rkt` 只发 `(e-prompt label cb)`，**不再 require prompt**。

### C5 — 拆分 pipeline
- `kernel/geometry.rkt`：方向导航 `pane-dir`（主区叶 + dock 统一算，同排/同列优先）。
- `kernel/documents.rkt`：`place-view` / `show-document` / `main-view?` / `sticky-edit`（纯 workspace）。
- `kernel/pipeline.rkt`：`resolve / perform / apply-effect / run-notify`（唯一写入点），已无文件 I/O。
- `kernel/api.rkt`：门面补 `geometry.rkt` / `documents.rkt` / `paths.rkt`。

---

## 3. 当前模块与依赖

```
kernel/                        功能包只 require kernel/api.rkt（门面）
  editor-api.rkt               唯一 require core 的边界
  registry.rkt  effect.rkt     扩展点 / effect 数据（含通用 prompt/notify/doc-add）
  focus.rkt     session.rkt    focus(target+stack)；session(editor+workspace+focus+edit-vid+键+尺寸)
  runtime.rkt   command.rkt    runtime/ctx+services；invoke-command
  binding.rkt   table.rkt      tui 事件→binding；keytable
  frame.rkt     dock.rkt       主区叶树；停靠区
  workspace.rkt geometry.rkt   main+docks 布局；方向几何
  documents.rkt                place/show（不懂文件）
  paths.rkt                    did↔path（数据结构，由特性持有）
  layer.rkt                   输入层栈（前缀 / 菜单 / 浮层模态）
  action.rkt policy.rkt       动作意图 / before-after 策略
  face.rkt theme.rkt          带参 face + 分层；主题解释（→ 颜色）
  wrap.rkt overlay.rkt        纯折行；每帧 deco provider → pane
  runner.rkt                  通用异步执行器（sync / place）
  hooks.rkt     pipeline.rkt   run-hooks / run-hooks-first；step / apply-effect / run-notify
  render.rkt                   before-render → 布局 → core 合成
  api.rkt                      门面
app/app.rkt                    装配：主区 + 各 dock 实例 + init
backend/tui.rkt                增量 patch + 软件光标
config/keys.rkt  packages.rkt  edit/global 键表；功能包目录
config/theme.rkt              深色主题（静态 face / 色板 / overlay）
builtin/
  edit.rkt                     基础编辑 + 分屏/关窗格/焦点方向
  document-api.rkt             文档元数据读写接口
  document.rkt                 打开/保存/find-file + 脏
  doc-scope.rkt                「能力对哪些文档启用」声明/查询
  policy.rkt                   undo-merge / quit-confirm（跨切面策略）
  prompt.rkt                   输入行 dock（暴露 effect 'prompt）
  status.rkt                   状态栏 dock（只经 document-api）
  tree.rkt                     文件树 dock
```

依赖纪律：`builtin/*` 只 require `kernel/api.rkt`；`status → document-api`、`document → document-api`、
`tree → document`（仅 effect 构造）+ `document-api`。**没有**特性 require 特性的实现。

---

## 4. 已完成：第 2 步「立内核基石」

| 顺序 | 基石 | 给谁用 | 落点 / 状态 |
|---|---|---|---|
| 1 | `doc-scope` | indent / complete / docs | ✅ `builtin/doc-scope.rkt`（走 document-api 取 path） |
| 2 | `run-hooks-first` | autopair | ✅ `kernel/hooks.rkt` + `cmd-insert` 接入 |
| 3 | `layer` 栈 | prefix / complete / docs 模态 | ✅ `kernel/layer.rkt` + `session.input` + pipeline 解析/post-pop/on-blur |
| 4 | `policy` | undo 合并 / 退出确认 | ✅ `kernel/action.rkt`+`policy.rkt`；`builtin/policy.rkt`（`e-save` 走 effect） |
| 5 | `face` + `theme` + 后端配色 | highlight / 浮层 | ✅ `kernel/face.rkt`+`theme.rkt`；`config/theme.rkt`；后端 ANSI |
| 6 | `deco`/`overlay` + `wrap` | complete / docs | ✅ `kernel/overlay.rkt`+`wrap.rkt`；render 传 decorations |
| 7 | `async runner` + 版本闸门 | highlight / complete / docs | ✅ `kernel/runner.rkt` + `session.awaiting` + `e-await/e-deliver` |

每项都有 `smoke.rkt` 断言：doc-scope 声明/查询、before-insert 三种返回、layer 的
capture/pop/fallthrough/on-enter/set、undo-merge 断步、退出确认、theme 分层配色、
wrap/anchor/overlay-panes、sync runner + 版本闸门。

## 5. 第 3 步：搬特性（依赖第 2 步）—— 全部完成

| 顺序 | 特性 | 用到基石 | 落点 / 状态 |
|---|---|---|---|
| 1 | `indent` | doc-scope | ✅ 覆盖 newline；`lang/file-kind.rkt` |
| 2 | `autopair` | run-hooks-first | ✅ before-insert；主区限定（prompt 不插手） |
| 3 | `mouse` | hit-pane | ✅ pointer/scroll effect 处理器 |
| 4 | `buffers` | dock | ✅ 左 dock 列文档 + Enter 切换 + Alt-b 开关 |
| 5 | `prefix` | layer | ✅ C-p 前缀层（capture/pop next） |
| 6 | `highlight` | face + async | ✅ `builtin/highlight.rkt` + `highlight/` 子包（machine/shadow/插件）；`config/plugins.rkt` |
| 7 | `complete` / `docs` | layer + deco + async + doc-scope | ✅ `builtin/complete.rkt` + `docs.rkt` + `doc-job.rkt` + `lang/*` |
| 8 | `translate` | after-edit | ✅ `builtin/translate.rkt` + `config/translate.rkt` |

每搬一个：`config/packages.rkt` 加一行、`smoke.rkt` 加断言、`raco make` + smoke 全绿。

> `highlight/` 子包内部需的 core 行序列化（`string->lines` / `lines->string`）与 `editor-view-line-before`
> 已由 **`kernel/editor-api.rkt`** 显式转出，保持「只有 editor-api 碰 core」的纪律。
>
> 差异：lab-rebuild 前端用 **sync runner**（无 place / background）；complete 的 C-n 键
> 放进 `config/keys.rkt`（无 'binding 贡献机制）；前缀单字符键用 `prefix.chars` 分派
> （因为普通字符统一绑定到 `text-binding`）。

### 5.1 document/view 管理 + 文件树配色

- 内核补 effect：`e-show-view` / `e-view-new` / `e-view-close` / `e-pane-swap` / `e-pane-resize`；
  pipeline 有对应 handler（`place-view` / `editor-add-view` / `editor-close-view` / `frame-swap` / `frame-resize`）。
- `buffers` 升级为**文档/视图两级树**：doc 行 Enter 展开，view 行 Enter 切换；`C-n` 新建视图、
  `C-l/C-k` 分屏打开、`Backspace` 关视图/文档、`Tab` 在 tree ↔ buffers 间轮换。
- 前缀补 `M-m`（窗格对调）/ `M-s`（窗格缩放）。
- `tree` 加类型配色（`tree-dir/tree-file/tree-link/tree-hidden/tree-open`），已打开文件标 `tree-open`。

---

## 6. 验收

- 每步：`raco make main.rkt smoke.rkt` + `racket smoke.rkt` 全绿。
- 后端约束（坑）：raw 模式下不能整屏 `screen->string`（`\n` 不回列 0、硬件光标停末尾）；
  必须 `app-render-patch` 按 piece `(row,col)` 定位绘制 + 软件光标。
