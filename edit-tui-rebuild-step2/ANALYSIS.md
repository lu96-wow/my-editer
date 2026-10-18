# edit-tui-rebuild 分析与收敛方案

> 目标：先回答 `edit-tui-rebuild` 相对 `edit-tui` 到底做了什么、把哪些逻辑局部化了；
> 再把全部实现按“函数 / 状态 / 布局 / 命令与插件”做一次归纳；
> 最后给出一个**不再靠不断加 hook** 的扩展点收敛方案。
>
> 全量顶层定义索引见 [`FUNCTION-INDEX.md`](FUNCTION-INDEX.md)（自动生成，含行号）。
>
> **step2 更新**：本文第 6 节建议的第 1 步已经落地：
> `env/extension.rkt`（contribution / owner / validate）、`env/panel-spec.rkt`、
> `plugin #:contributions`、`plugins-env` / `plugins-apply` 装配期校验。
> 另外已加 `environment.base` + `environment-remove-owner`：可以从 base 重建，
> 按插件撤销 commands / rules / hooks / decors / panel-syncs 等贡献。
> 执行器没有改；详见 [`STEP2.md`](STEP2.md)。

---

## 0. 结论先行

### 0.1 rebuild 不是重写

`diff -rq edit-tui edit-tui-rebuild` 的实际源码差异只有 7 个文件：

| 文件 | 变化 |
|---|---|
| `model/layout.rkt` | `tree-insert` / `tree-split` 返回 `(values tree ok?)`；新增 `empty-tree?`；`tree-move` 接住 `ok?` |
| `bootstrap/commands/view.rkt` | `mount-split` 检查 `ok?`，布局失败立即报错，不再登记“布局里不存在的 region” |
| `plugins/filetree/commands.rkt` | `ensure-editor-region` 接住 `tree-split` 的 `ok?` |
| `model/workspace.rkt` | 删除 `chrome-member`；`view` / `region` 消失时同步丢弃引用它的浮层（`drop-floats`） |
| `projection/render.rkt` | 删除 `chrome-entry` / `chrome-diff-pieces` / `clear-rect-pieces` / `text-piece`；`frame-cache` 只保留 core；`project-frame` 从 3 值变 2 值 |
| `projection/status.rkt` | 删除 `chrome-line` / `region-line`（状态栏不再有第二条渲染通道） |
| `runtime/run.rkt` | 每帧同步统一成 `environment.panel-syncs` + `state-frame-syncs`；runtime 不再硬编码状态栏 |

另外更新了 `ARCHITECTURE.md` 和对应测试。
`REBUILD.md` 里真正标成 ✅ 的只有第 1、4、5 步；其余（input session、validate-env、toggle-region、完整 panel-spec、interaction 栈、query/service、provenance/uninstall、layout snapshot、effect continuation 数据化）仍是待办。

所以更准确的说法是：

> **rebuild 是一次“先拆掉同一件事的第二条路、让装配错误立刻显形、把资源生命周期绑在一起”的收敛，而不是另起一套架构。**

### 0.2 已经变清晰的东西

1. **布局装配不再静默失败**
   - 以前 `tree-split` 找不到 target 时静默返回原树，调用方却已经把 region 写进 `workspace.regions`，形成“登记了但不可见、不可点、焦点能落上去”的死状态。
   - 现在 `tree-insert` / `tree-split` 显式返回 `ok?`，`mount-split` / `ensure-editor-region` 必须接住。
   - 这是把“结构操作”和“装配策略”分开：`model/layout.rkt` 只回答“插没插进去”，`bootstrap/commands/view.rkt` 决定失败时怎么报错。

2. **浮层生命周期绑定到 view / region 资源**
   - `workspace-remove-view` / `workspace-remove-region` 现在会丢弃引用它们的 `float`。
   - 浮层不是独立像素层，而是“不在 layout 树里的 region + view”；资源消失，浮层必须消失，否则 `completion-open?` 这类“浮层存在 = 菜单开着”的判断会失真。

3. **显示只剩一条路径：所有显示都是 document**
   - 删除 `region-member` 的 `'chrome` 种类、`chrome-entry` 自绘缓存、`chrome-line` / `region-line`。
   - 状态栏 / 输入栏也是普通 core view；文本由 `sync-chrome!` 写进 buffer，渲染只走 `project-frame` 的 panel 路径。
   - 这样“状态栏文本从哪里来”“为什么状态栏不支持滚动/光标/face”这类问题就不存在了：它就是 document。

4. **每帧同步变成注册表，runtime 不认识具体面板**
   - 插件面板走 `environment.panel-syncs`。
   - 框架状态栏走 `state-frame-syncs`，但是否安装由 State 事实 `chrome.slot-info` 决定，不按模块名特判。
   - 新增一个“每帧投影到 view”的东西，不需要改 `runtime/run.rkt`。

### 0.3 但 rebuild 没有解决全部问题

`REBUILD.md` 的审查结论仍然成立：

| 块 | 仍然存在的问题 |
|---|---|
| A 数据 `document / view / panel` | 真身 / 镜像基本分开，但 layout 解树、焦点解析、project-frame 仍有重复路径 |
| B 状态 / 命令 / layout | 交互状态仍有多个家：`pending`、`modes`、`gesture`、`placement`、`confirm`、`chrome.input`、插件 session |
| C 插件 / hook | 有 6+ 张注册表，**没有 owner / provenance / uninstall / validate**；`panel-spec` 仍是半描述符；异步三件套逐插件复制 |

这些正是“需要新功能时只能继续加 hook”的根源。

---

## 1. rebuild 把哪些逻辑局部化了

### 1.1 三块边界

| 边界 | 以前 | 现在 |
|---|---|---|
| **布局结构 vs 几何** | `model/layout.rkt` 同时管树、尺寸、显隐、切分；失败用 `#f` / 原树表示 | 树结构仍在这里，但失败变成 `(values tree ok?)`；真正的格数分配、命中、接缝在 `projection/geometry.rkt` |
| **布局装配 vs 布局策略** | `mount-split` 先登记 region 再切树，失败静默 | 先切树、拿 `ok?`，失败就不登记；命令层负责报错 |
| **显示内容 vs 渲染通道** | 状态栏既是 core view，又有一条 `chrome-entry` 自绘通道 | 只有 core view + panel 一条通道 |

### 1.2 四个“局部化”手法

1. **把布尔哨兵换成显式结果**
   - `tree-insert` / `tree-split` → `(values tree ok?)`。
   - `empty-tree?` 代替 `(pair? (split-children ...))` 探针。
   - 优点：调用方无法忽略失败；测试可以直接断言 `ok? = #f` 且树不变。

2. **把资源失效做成一个原子动作**
   - `drop-floats` 只在 `workspace-remove-view` / `workspace-remove-region` 里调用。
   - 不让每个删除路径各自记得清浮层。
   - 这是“资源的生命周期在拥有资源的模块里闭环”。

3. **删掉第二条渲染通道**
   - 不是把 `chrome-entry` 修好，而是承认它和 core view 是同一件事的两条路。
   - 删掉后 `frame-cache` 只剩 core 一项，`project-frame` 只剩 panels + placements 两个返回值。

4. **把“谁每帧跑”变成数据**
   - `environment.panel-syncs` 是插件注册的同步器。
   - `state-frame-syncs` 是框架自带的同步器，是否安装由 State 事实决定。
   - runtime 只遍历列表，不认识 `sync-chrome!` / `sync-filetree-panel!` 这些名字。

### 1.3 这次收敛的局限

- 只处理了“重复路径”和“静默失败”，没有处理“扩展点碎片化”。
- 没有引入 owner / provenance，因此 `plugin-uninstall!` / reload 仍然做不了。
- `project-frame` 仍然在 `run-frame` 和 `render-frame` 里各调一次（`REBUILD.md` 第 11 步未做）。
- `panel-spec` 仍只有 `name / role / mode / sync`，安装位置仍由宿主决定。

---

## 2. 全函数归纳：按层看

> 这一节按“层 + 模块 + 函数组”归纳。每个模块的完整顶层定义（含行号）在
> [`FUNCTION-INDEX.md`](FUNCTION-INDEX.md)。纯函数内部可能用局部 `set!` 做累加，
> 但不读写共享状态；下表“纯度”指**是否触碰 State / core / IO / 线程**。

### 2.1 层 0：词汇与后端

| 模块 | 函数组 | 职责 | 纯度 / 状态 |
|---|---|---|---|
| `base/id.rkt` | `id`、`doc-id?` / `view-id?` / `region-id?` / `job-id?`、`id-counter-next`、`next-id` | 带 kind 的稳定 id + 纯分配器 | 纯；分配器是 State 字段，返回新 counter |
| `base/event.rkt` | `key-event` / `mouse-event` / `resize-event` / `paste-event` / `internal-event` / `tick-event` / `quit-event`、`event-kind` | 应用事件 ADT，不依赖 tui | 纯 |
| `base/effect.rkt` | 26 个 effect struct、`effect?`、`effect-kind` | 效果 ADT；引擎写 / IO / 调度 | 纯值；`open-doc` / `read-file` 等的 `k` 是闭包，**不可序列化** |
| `base/transition.rkt` | `transition`、`transition-pure`、`transition-with-effects`、`transition-bind`、`transition-all`、`transition-map-*` | 新 State + 有序 effects，组合子 | 纯 |
| `base/keymap.rkt` | `binding` / `keymap`、`keymap-add` / `lookup` / `navigate` / `prefix?`、`keys` 宏 | 通用 token → 值的前缀 trie | 纯 |
| `base/signal.rkt` | `signal`、`signals`、`signals-add` / `signals-take`、`standard-signal-points` | 信号值 + FIFO 队列 + 标准点词表 | 纯 |
| `base/status-part.rkt` | `status-part`、`make-status-part` | 状态栏段（名字 + render） | 纯；render 是闭包 |
| `base/face.rkt` | `face`、`face-set-fg/bg/attrs`、`face-add/remove-attr`、`face-has-attr?` | face 三分量读写；不做合并策略 | 纯 |
| `command/key.rkt` | `key-token`、`key`、`key?`、`key->string`、`mods` 规范化 | 键 token | 纯 |
| `command/mouse.rkt` | `mouse-token`、`mouse`、`mouse-action/button/mods`、`mouse->string` | 鼠标 token | 纯 |
| `command/command.rkt` | `command`、`cmd`、`->command`、`command-needs-input?` | 命令值（run / note / input） | 纯；run 是闭包 |
| `command/keymap.rkt` | `keymap` / `keytable` / `matcher`、`keytable-merge!`、`matcher-feed!` | 旧 command 层的前缀表 / 可匹配器 | **有可变 keytable / matcher**；新 dispatch 主要用 `base/keymap.rkt` |
| `command/tui.rkt` | `event->key` / `event->mouse`、`key-reader` | 终端事件 → token；可复用键读取器 | token 纯；`key-reader` 有可变 matcher |
| `core-render/render.rkt` | `render-piece(s)`、`face-fragment`、`style-fragment`、`render-clear` | core piece → tui bytes | 纯 |
| `theme/theme.rkt` | `rgb` / `style`、`install-style!`、`define-theme!` | face 符号 → tui 样式表 | `install-style!` 写 tui 全局样式表 |
| `theme/main.rkt` | require 即 `define-theme!` | 安装默认主题 | **require 副作用** |

### 2.2 层 1：纯 State

| 模块 | 函数组 | 职责 | 纯度 / 状态 |
|---|---|---|---|
| `model/state.rkt` | `window` / `runtime` / `state`、`state-set-*`、`state-*-*`、`state-emit` / `state-drain-signals`、`plugin-state*`、`state-next-id`、`state-focus` | 根 State 与纯更新助手 | 纯快照；`store` 里可放插件状态 |
| `model/workspace.rkt` | `doc-meta` / `view-meta` / `region-member` / `region` / `float` / `workspace`、`workspace-add/remove/attach/detach`、焦点栈、root、placement | 文档 / 视图 / 区域 / 布局树 / 浮层 / 焦点 | 纯；`layout` 只是结构，不含屏幕几何 |
| `model/layout.rkt` | `dim` / `leaf` / `split`、`tree-find` / `leaves` / `regions`、`tree-insert/split/detach/close/move`、`empty-tree?` | 布局树结构、尺寸、显隐、切分 | 纯；`tree-insert` 的局部 `set!` 只用于返回 `ok?` |
| `model/input.rkt` | `gesture` / `input`、`input-pending?`、`input-push-mode/pop-mode`、`input-set-gesture` | 键序列 / 临时 mode / 手势 | 纯 |
| `model/chrome.rkt` | `chrome-slot` / `chrome`、`chrome-set-message` / `chrome-clear-message`、`chrome-log-append`、`chrome-set-slot` | 消息 / 日志 / status+input 槽 | 纯 |
| `model/save.rkt` | `save-confirm`、`make-save-confirm` | 保存确认队列 / 当前 index / 完成动作 | 纯 |
| `model/face-layer.rkt` | `compose-face`、`compose-layers` | face 按层序逐分量合成；fills 合成 | 纯 |
| `model/face-decor.rkt` | `face-decor` / `face-ctx` / `dirty`、`dirty-*`、`changes->dirty-lines`、`scan-track`、`blank-layer-track`、`refresh-layer`、`stateful-advance`、`face-runs` | 增量 face 协议 + 行级算法 | 纯；只依赖 core 的 track / change / point / range 纯值 |

### 2.3 层 2：Env（纯策略）

| 模块 | 函数组 | 职责 | 纯度 / 状态 |
|---|---|---|---|
| `env/environment.rkt` | `environment`、`make-environment`、`environment-role/mode/command/keymap/doc-type`、`environment-add-*`、`environment-merge` | 13 张注册表：roles / modes / scopes / commands / keymaps / rules / status / doc-types / input-commands / panel-syncs / hooks / face-layers / decors | 纯值；`panel-syncs` / `hooks` / `decors` 里是闭包，**不可序列化** |
| `env/hook.rkt` | `hook`、`make-hook` | 信号点 + when + priority + proc | 纯值；proc 返回 transition |
| `env/plugin.rkt` | `panel-spec`、`plugin`、`plugins-env`、`plugins-apply`、`plugin-env-apply` | 插件描述符 + 纯 fold | 纯；插件字段与 env 有重叠 |
| `env/role.rkt` | `role`、`make-role`、`role-default` | 区域行为：splittable / close / focusable / target / switchable | 纯 |
| `env/mode.rkt` | `mode`、`make-mode`、`mode-default` | document mode → keymaps + fallback | 纯 |
| `env/scope.rkt` | `scope`、`make-scope`、`scope-known?`、`scope-ok?` | 条件层谓词 | 纯 |
| `env/rule.rkt` | `rule`、`make-rule` | scope + keymap | 纯 |
| `env/doc-type.rkt` | `doc-type`、`make-doc-type`、`doc-type-matches-path?` | 路径 → mode + per-doc keymaps | 纯 |
| `env/input-command.rkt` | `input-command`、`make-input-command`、`input-command-prefix/regexp/list` | 输入栏字符串匹配 | 纯 |
| `env/defaults.rkt` | `default-roles` / `default-modes` / `default-environment` | 无命令也能成立的默认值 | 纯 |

### 2.4 层 3：Effects（唯一可变边界）

| 模块 | 函数组 | 职责 | 纯度 / 状态 |
|---|---|---|---|
| `effects/engine.rkt` | `engine`、`make-engine`、`engine-create-doc/view!`、`engine-remove-*`、`engine-apply!`、`engine-set-view-text!`、`engine-replace-range!`、`engine-sync-view(s)!`、`engine-ensure-view!`、`engine-attach-decors!`、`engine-paint-advance!`、`engine-view` 只读接口、`open-doc-spec` | core buffer / view 的唯一可变拥有者；引擎 effect 解释 | **可变**：`engine.docs/views/face-order/doc-decors`；core 句柄只在这里和 paint / panel |
| `effects/paint.rkt` | `paint-state`、`paint-open!`、`paint-reset!`、`paint-fork`、`paint-advance!`、`paint-set-static-layer!`、`fills->layer-track`、`paint-write!` | 每文档 face-paint slot：decor 状态 / 静态层 / 脏行写回 | **可变**：写 core face port；slot 本身是纯值 |
| `effects/panel.rkt` | `panel-create-view!`、`panel-region-add!`、`panel-region-install!`、`panel-install!`、`panel-uninstall!`、`panel-visible?`、`panel-sync-buffer!` | 面板 ↔ engine 适配；建/删 core 对象；写面板 buffer | 不纯：engine + workspace |
| `effects/interpreter.rkt` | `interpret-effect!`、`interpret-effects!`、`interpret-effect-tree!`、`interpret-open-doc/open-view/save-doc!`、`interpret-replace-range!`、`edit-write?`、`effect-doc` | effect → engine / IO / State；发 `after-edit` / `after-nav` / `document-opened` | 不纯：core 写、文件 IO、回调 |

### 2.5 层 4：Projection（纯读）

| 模块 | 函数组 | 职责 | 纯度 / 状态 |
|---|---|---|---|
| `projection/geometry.rkt` | `region-panel` / `cut`、`geometry-solve`、`solve`、`alloc-dims` / `alloc-flex` / `int-alloc`、`region-panel-at`、`region-neighbor`、`region-content-size`、`cuts-at` / `cut-at`、`tree-resize-seam` / `resize-dims` | 布局树 → 屏幕矩形 / 内容区 / 接缝；命中与拖缝 | 纯；只读 layout |
| `projection/render.rkt` | `frame-cache`、`project-frame`、`project-view-placements`、`render-frame` | State + engine → panels / placements / bytes | 纯；只读 engine，不写 core、不输出 |
| `projection/status.rkt` | `status-line`、`status-position/path/sequence/message`、默认段、`state-line` | 状态栏文本投影 | 纯 |
| `projection/float.rkt` | `float-panel`、`project-floats`、`float-panel-at`、`float-rect` | 浮层 region → 屏幕矩形；鼠标命中 | 纯 |

### 2.6 层 5：Dispatch（纯派发）

| 模块 | 函数组 | 职责 | 纯度 / 状态 |
|---|---|---|---|
| `dispatch/context.rkt` | `ctx`、`make-ctx` | 命令看到的 env / state / event / subject / engine-view | 纯值 |
| `dispatch/rules.rkt` | `subject-doc-meta`、`subject-mode-id`、`input-mode-rules`、`doc-layer-rules`、`mode-rules`、`global-rules`、`extra-rules`、`rules-for`、`prefix-rules`、`lookup-rules` | 规则层序：input modes > per-doc > env.rules > mode > global | 纯查表 |
| `dispatch/hooks.rkt` | `run-hooks`、`point-hooks`、`run-point`、`max-rounds` | 排空信号 → 按 priority 跑 hook → 折叠 transition | 纯；hook 返回 transition |
| `dispatch/pipeline.rkt` | `dispatch`、`dispatch-key` / `dispatch-key-normal`、`dispatch-mouse*`、`dispatch-paste`、`dispatch-resize`、`run-command`、`dispatch-unbound`、`focusable-subject?` | event → transition；键盘 / 鼠标统一；未命中 / fallback / 消息清理 | 纯 |

### 2.7 层 6：Chrome

| 模块 | 函数组 | 职责 | 纯度 / 状态 |
|---|---|---|---|
| `chrome/slot.rkt` | `install-chrome!`、`chrome-status-view` / `chrome-input-view`、`chrome-show-input/status`、`input-show`、`input-finish`、`input-read-text`、`input-write-prompt`、`sync-chrome!` | 安装 status / input 两个 core view；切换 active；每帧写 status buffer | 不纯：建 core view、写 buffer |
| `chrome/input.rkt` | `input-active?`、`input-value`、`input-cancel`、`input-show`、`input-show-state` | 通用输入栏 API；新 input 替换旧 input | 只发 engine effect / 改 State |

### 2.8 层 7：Bootstrap

| 模块 | 函数组 | 职责 | 纯度 / 状态 |
|---|---|---|---|
| `bootstrap/defaults.rkt` | `text-keys` / `pointer-keys` / `nav-keys` / `input-keys` / `core-global-keys`、`core-env` | 框架默认命令 / 键 / mode / doc-type / scope / 状态栏段 | 纯值 |
| `bootstrap/panel.rkt` | `panel-spec-install!` | `panel-spec` → `panel-install!` 的唯一缝 | 调 effects |
| `bootstrap/commands/util.rkt` | `message` / `notice-state`、`view-subject`、`region-subject`、`input-busy?`、`frame-area`、`real-view?`、`fallback-attached-view` | 命令共用小工具；区分真实文档 / internal | 纯 transition 构造 |
| `bootstrap/commands/edit.rkt` | `nav-command`、`insert-command`、`edit-command`、`undo-command`、`redo-command`、`quit-command` | 编辑类命令 → engine / quit effect | 纯命令；发 effect |
| `bootstrap/commands/view.rkt` | `split-region-command` / `split-region` / `mount-split`、`close-view-command` / `close-view`、`new-document-command`、`detach-view-command`、`attach-detached-command`、`switch-member-command`、`target-region-for-new-view*` | view / region 生命周期；split 出空 region；detach / attach；Tab 切换 | 纯 State + close/open effect |
| `bootstrap/commands/region.rkt` | `close-region`、`drop-region-views`、`fallback-view`、`last-region-of-role?` | 按 role close-policy 关闭 region；view 只 detach 不销毁 | 纯 State |
| `bootstrap/commands/focus.rkt` | `focus-move`、`screen->point`、`pointer-press-command`、`pointer-drag-command` | 方向焦点；鼠标落点 / 拖选 | 纯 State + select effect |
| `bootstrap/commands/document.rkt` | `open-file-from-path`、`save-current-command`、`save-doc-to-path`、`request-quit`、`request-close-doc`、`dirty-docs`、`doc-dirty?`、`save-confirm-*`、`handle-save-answer`、`default-input-commands` | document 生命周期 + 保存确认 + 输入栏提交 | 纯 State + IO effect；保存确认是流程状态 |
| `bootstrap/commands/placement.rkt` | `place-into`、`place-commit-command`、`place-at-command`、`placement-scope`、`placement-keys` | 把 detached view 放进目标 panel；两步交互 | 纯 State；框架级 |
| `bootstrap/commands/table.rkt` | `default-command-table` | command-id → 命令值 | 纯 |

### 2.9 层 8：Plugins

| 模块 | 函数组 | 职责 | 纯度 / 状态 |
|---|---|---|---|
| `plugins/builtin.rkt` | `default-plugins`、`default-env`、`editor-plugins`、`editor-env` | 内置插件组合 | 纯装配 |
| `plugins/filetree/model.rkt` | `filetree`、`empty-filetree`、`filetree-expanded?`、`toggle-expand`、`set-view` / `set-width` | 文件树插件切片：view / expanded / width | 纯数据；在 `store['filetree]` |
| `plugins/filetree/scan.rkt` | `filetree-normalize-path`、`entry-kind`、`name<?`、`dir-entries` | 读目录（唯一 IO） | 不纯：目录 IO |
| `plugins/filetree/lines.rkt` | `filetree-line`、`filetree-lines`、`filetree-line-at`、`filetree-dir?` / `file?` | 目录条目 → 行（root / dir / file / open） | 纯；`entry-lister` 是参数 |
| `plugins/filetree/panel.rkt` | `filetree-panel-view`、`sync-filetree-panel!` | 每帧生成行 → `panel-sync-buffer!` | 不纯：写 buffer |
| `plugins/filetree/commands.rkt` | `selected-line` / `selected-dir`、`open-file-placement`、`ensure-editor-region`、`toggle-filetree-command`、`filetree-enter`、`create/delete` 命令、`filetree-input-commands`、`filetree-command-table` | 树内导航 / 打开 / 创建 / 删除 / 显隐 | 纯 State + IO effect；命令里有存在性检查 |
| `plugins/filetree/plugin.rkt` | `filetree-plugin-mode`、`filetree-panel-spec`、`install-filetree-panel!`、`filetree-plugin` | 插件声明 + 面板 spec + 便捷安装 | 纯声明；install 调 effects |
| `plugins/resource/model.rkt` | `resource-panel`、`empty`、`collapsed?`、`toggle-collapse`、`set-view` | 资源列表插件切片 | 纯数据；在 `store['resources]` |
| `plugins/resource/lines.rkt` | `resource-line`、`resource-lines`、`resource-line-at`、`doc-line?` / `view-line?` | doc / view → 行；折叠 / active / focus / placing | 纯 |
| `plugins/resource/panel.rkt` | `resource-view`、`sync-resource-panel!` | 每帧写资源面板 buffer | 不纯 |
| `plugins/resource/commands.rkt` | `toggle-collapse`、`resource-enter`、`new-view`、`new-doc`、`start-placement`、`detach/close-selected`、`resource-command-table` | 资源列表命令 | 纯 State + engine effect |
| `plugins/resource/plugin.rkt` | `resource-plugin-mode`、`resource-panel-spec`、`install-resource-panel!`、`resource-plugin` | 插件声明 + 面板 spec | 纯声明；install 调 effects |
| `plugins/highlight/lex.rkt` | `symbol-char?`、`keyword-set`、`lex-line`、`syntax-line`、`lex-fills`、`merge-fills` | 纯词法：行 + 状态 → face 符号 / fills | 纯 |
| `plugins/highlight/depth.rkt` | `depth-face-of`、`depth-line`、`depth-fills`、括号匹配 | 括号栈 → 背景 | 纯 |
| `plugins/highlight/kind.rkt` | `racket-path?`、`racket-doc-meta?` | Racket 文档判断 | 纯 |
| `plugins/highlight/syntax-decor.rkt` | `syntax-open`、`syntax-change`、`scan-line`、`syntax-face-decor` | 语法前景增量 decor | 纯 |
| `plugins/highlight/depth-decor.rkt` | `depth-open`、`depth-change`、`depth-face-decor` | 括号背景增量 decor | 纯 |
| `plugins/highlight/word-color-decor.rkt` | `word-hash`、`word-color-line`、`word-color-open/change`、`word-color-face-decor` | 同词同色前景 | 纯 |
| `plugins/highlight/words-decor.rkt` | `words-line`、`words-open/change`、`words-face-decor` | 光标当前词背景 | 纯 |
| `plugins/highlight/*plugin.rkt` | `highlight-plugin` / `depth-bg-plugin` / `word-color-plugin` / `words-plugin` | 只贡献 face layer + decor | 纯声明 |
| `plugins/completion/plugin.rkt` | session / popup / cache / pending / job、`prefix-at`、`base-pool`、`filter-pool`、`rank-candidates`、`open-with-pool`、`completion-open/move/refine/accept/cancel`、`completion-on-job`、`completion-plugin` | 补全浮层 + 本地词 + require 导出 + 模块路径 | 不纯：effects + worker；session / cache / jobs 在 `store` |
| `plugins/docs/plugin.rkt` | `docs-panel-spec`、`identifier-at`、`doc-context`、`docs-lines`、`write-docs`、`docs-show-impl`、`docs-on-nav/selection/job`、`docs-plugin` | 文档面板 + 本地定义 + xref/bluebox + HTML 兜底 | 不纯：effects + worker；state/cache/jobs 在 `store` |
| `plugins/lang/source.rkt` | `skip-leading-trivia`、`module-context`、`requires-context`、`spec->paths`、`definitions-of-forms`、`provides-of-forms`、`require-context?` / `lang-context?` | 源码启发式解析：require / define / provide | 纯（对任意半成品文本全函数） |
| `plugins/lang/pool.rkt` | `module-exports`、`distinct-strings`、`spec-names`、`spec-local-paths`、`spec-binding-of`、`leaf-module` | require spec → 绑定名 / 模块导出 | **进程内 `exports-cache` 可变**；主线程 / worker 都可能用 |
| `plugins/lang/context.rkt` | `focused-vid`、`doc-meta-of-view`、`open-local-texts`、`source-context`、`export-key` | 当前文档 require 上下文（补全 / docs 共用） | 纯查询 |
| `plugins/lang/local-docs.rkt` | `form->string`、`def-snippets`、`local-defs`、`local-def` | 当前文档顶层定义摘要 | 纯 |
| `plugins/lang/module-index.rkt` | `rkt-file?`、`rel->module`、`dir-modules`、`collects-modules`、`pkg-modules`、`module-paths` | 已安装模块路径索引 | IO + 惰性 `delay` 缓存；只在 worker |
| `plugins/lang/docs.rkt` | `doc`、`tag-for`、`docs-for`、`tag->doc`、`tag->bluebox`、`tag->html-body`、`doc->text` / `result` | xref + blueboxes + HTML 文档查询 | 进程内 `xref` / `doc-cache` / bluebox cache / semaphore；只在 worker |
| `plugins/lang/doc-html.rkt` | `html->markdown`、`extract-documentation`、`weak-cache` 等 | HTML 文档页 → markdown | HTML cache + IO；只在 worker |
| `plugins/worker.rkt` | `service-kinds`、`service-run`、`syntax-fills-for`、`depth-fills-for` | worker 服务分派：syntax / depth / completion-exports / doc / module-paths | 后台纯计算 / 只读 IO |
| `plugins/highlight/depth-plugin.rkt` 等 | 见上 | 插件组合 | 纯 |

### 2.10 层 9：Runtime

| 模块 | 函数组 | 职责 | 纯度 / 状态 |
|---|---|---|---|
| `runtime/tui-adapter.rkt` | `tui-event->app` | 终端事件 → 应用事件；鼠标 1-based → 0-based | 纯适配 |
| `runtime/run.rkt` | `subject-for`、`ensure-doc-decors!`、`settle`、`process-events`、`drain-and-process`、`run-transition-effects`、`run-one-effect`、`inline-service-run`、`drain-channel`、`startup!`、`state-frame-syncs`、`run-frame`、`run-app` | 事件循环；effect 解释；settle；每帧同步；渲染输出；worker / inbox | **唯一不纯壳**：read-event / put-bytes / thread / box / async-channel |
| `runtime/worker.rkt` | `worker`、`worker-entry-path`、`worker-start!`、`worker-submit!`、`worker-stop!` | 独立 place，一条队列；结果回 `job-done` | 多进程；place / thread / channel |

### 2.11 公共面

`main.rkt` 只 require / provide。注意：它**没有** re-export `env/hook.rkt`。
插件作者目前要写 hook，需要直接 require `env/hook.rkt`。这本身说明 hook 是独立模块，
但也说明公共扩展 API 还不完整。

---

## 3. 状态地图：可变 / 不可变

### 3.1 四个所有权域

```
┌─────────────────────────────────────────────────────────────┐
│ 1. 纯 State（可快照 / 可重放）                              │
│    state = window workspace input chrome runtime ids        │
│            confirm signals store                            │
│    Environment = roles modes ... hooks panel-syncs decors   │
├─────────────────────────────────────────────────────────────┤
│ 2. core 真身（可变，版本化）                                │
│    engine.docs / views / face-order / doc-decors            │
│    buffer / view / document / history / slots / face port   │
│    唯一写入口：engine / paint / panel / interpreter          │
├─────────────────────────────────────────────────────────────┤
│ 3. runtime 壳（可变，进程内）                               │
│    state-box / cache-box / inbox / worker / frame-cache     │
│    terminal / threads                                       │
├─────────────────────────────────────────────────────────────┤
│ 4. 进程级缓存 / 模块安装（可变，跨 State 生命周期）          │
│    lang/pool exports-cache / docs xref & doc-cache /        │
│    module-index delay / theme style table / keytable        │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 不可变状态（按值替换）

| 状态 | 位置 | 说明 |
|---|---|---|
| `state` 整棵树 | `model/state.rkt` | 每次命令 / effect 返回新值；没有原地改 |
| `workspace.docs / views / regions / layout / floats / focus / stack / root / placement` | `model/workspace.rkt` | 纯数据；`layout` 是结构树 |
| `input.pending / modes / gesture` | `model/input.rkt` | 交互的纯数据 |
| `chrome.message / log / slot-info` | `model/chrome.rkt` | 状态栏槽的安装事实 |
| `runtime.quit? / revision` | `model/state.rkt` | revision 只用于重绘 |
| `ids` | `base/id.rkt` | 纯分配器；同事件序列可重放 |
| `confirm` | `model/save.rkt` | 保存确认队列 |
| `signals` | `base/signal.rkt` | FIFO 信号队列；settle 排空 |
| `store` | `model/state.rkt` | 插件命名空间；值本身不可变，但语义上是缓存 / session |
| `Environment` | `env/environment.rkt` | 不可变值；含闭包，不可跨进程序列化 |
| `transition` / `effect` 值 | `base/transition.rkt` / `base/effect.rkt` | 不可变值；`k` 是闭包 |
| `paint-state` | `effects/paint.rkt`，存于 core document slot | 纯值；每次编辑 fork 出新值；undo 回旧值 |
| `layout` 的 `dim / leaf / split` | `model/layout.rkt` | 纯结构；修改用 `struct-copy` |
| `face` / `face-decor` / `dirty` | `base/face.rkt` / `model/face-decor.rkt` | 纯值 |
| plugin / panel-spec / role / mode / rule / scope / doc-type / input-command / status-part | `env/*` | 纯声明值；部分含过程 |
| `project-frame` 的输出 panels / placements | `projection/render.rkt` | 纯投影结果；不写 core |

### 3.3 可变状态（原地改 / 持有句柄）

| 状态 | 拥有者 | 写入路径 | 生命周期 / 版本 |
|---|---|---|---|
| `engine.docs` / `engine.views` | `effects/engine.rkt` | `engine-add-*!`、`engine-remove-*!` | 直到 doc / view 关闭；State 只存 id |
| `engine.face-order` | `effects/engine.rkt` | `engine-set-face-layers!` | 启动时设置；决定 paint 合成顺序 |
| `engine.doc-decors` | `effects/engine.rkt` | `engine-attach-decors!` | 文档级 decor 注册；幂等；set-text 后复用 |
| core `buffer` / `view` / `document` | core，engine 持有 | `buffer-edit!`、`buffer-set-document!`、`buffer-replace-range!`、`view-*!` | 版本 token；undo / redo 换 document |
| core `history` | core | `buffer-undo!` / `buffer-redo!` | 与 document 版本绑定 |
| core `document` slot（face-paint） | core slot，paint 读写 | `paint-open!` / `paint-fork` / `paint-advance!` / `paint-set-static-layer!` | 随 document 版本 fork / undo 恢复 |
| core `face port` | core | `buffer-face-batch!`（只在 `paint-write!`） | 随 document 版本；只写 dirty 行 |
| `state-box` / `cache-box` | `runtime/run.rkt` | `set-box!` | 进程生命周期；单线程回调 |
| `inbox` | `runtime/run.rkt` | `async-channel-put` / `try-get` | 进程生命周期；worker / timer / spawn 回投 |
| `worker`（place channel + out thread） | `runtime/worker.rkt` | `worker-start!` / `submit!` / `stop!` | 进程生命周期；一条队列 |
| `frame-cache` | `runtime/run.rkt` | 每帧 `render-frame` 返回新 cache | 进程生命周期；resize 时置 `#f` |
| `exports-cache` | `plugins/lang/pool.rkt` | `module-exports` 的 `hash-ref!` | 进程级；主线程 / worker 都可能用 |
| `xref` / `doc-cache` / `bluebox-cache` / `bluebox-dir-caches` / `docs-lock` | `plugins/lang/docs.rkt` | `docs-for` / `tag->doc` | worker 进程级；semaphore 串行化 |
| `module-paths` | `plugins/lang/module-index.rkt` | `delay` 首次求值 | worker 进程级 |
| `weak-cache` / `reference-links-table` | `plugins/lang/doc-html.rkt` | `hash-set!` / weak hash | worker 进程级 |
| `keytable.tables` / `matcher.typed` / `key-reader.matcher` | `command/keymap.rkt` / `command/tui.rkt` | `keytable-merge!` / `matcher-feed!` / `key-reader-feed!` | 旧 command 路径；可变 |
| tui style table | `theme/theme.rkt` | `style-define!`（require `theme/main.rkt` 时） | 进程级；同名覆盖 |
| `store` 里的 session / cache / pending / jobs | `state.store` | 插件用 `plugin-state-set` / `plugin-state*` | 逻辑上可变；实际是 State 快照中的纯值；没有 GC / 卸载 |

### 3.4 交互 / 流程状态（纯值，但语义是“进行中”）

| 状态 | 位置 | 谁负责取消 / 完成 |
|---|---|---|
| `input.pending` | `model/input.rkt` | `dispatch-key` 清空；前缀未命中丢弃 |
| `input.modes` | `model/input.rkt` | 插件 `input-push-mode` / `input-pop-mode`（补全） |
| `input.gesture` | `model/input.rkt` | 鼠标 release / 命令 |
| `workspace.placement` | `model/workspace.rkt` | `place-into` / `place-cancel` / 插件发起 |
| `state.confirm` | `model/save.rkt` | `confirm-next` / `confirm-finish` / input cancel |
| `chrome.slot-info` | `model/chrome.rkt` | `install-chrome!` 安装；`chrome-show-*` 切换 |
| 输入栏 buffer / readonly prefix | core `*input*` document | `input-finish` / `input-cancel` |
| completion session / popup / pending / jobs | `store` | `close-popup` / `completion-on-job` |
| docs state / pending / jobs | `store` | `docs-on-job` / hide |
| filetree expanded / width | `store['filetree]` | 插件命令 |
| resource collapsed | `store['resources]` | 插件命令 |

### 3.5 关键不变量

1. **State 不存 core 句柄 / 线程 / inbox / cache**：State 只存 id + 元数据 + 纯数据。
2. **core 写只有 engine / paint / panel / interpreter**：命令 / hook / projection 不能直接写。
3. **paint 只写 dirty 行**：`paint-write!` 用 `dirty->lines`，先清行再写 runs。
4. **decor 的 `change` 必须是纯函数**：不能原地改 state / layer / 向量；旧 document 还在 history 里。
5. **layer 与 new-text 逐行对齐**：行数相同、行向量长度 = 字符数。
6. **undo / redo 靠 document 版本恢复**：decor state / layer / face port 一起回来，不重算。
7. **hook 在 effect 解释之后跑**：`settle` 先解释 effect，再 `run-hooks`，所以读到新文本。
8. **hook 的 proc 只拿只读 engine-view**：写 core 必须发 effect。**注意**：目前这是约定，不是类型保证（见 §3.6）。
9. **`after-edit` 只在文本真的变了时发**；`set-text-effect` / `set-face-layer-effect` 不算编辑。
10. **所有显示都是 document**：状态栏 / 输入栏 / 面板 / 浮层都是 region + view + panel。
11. **布局失败必须显形**：`tree-insert` / `tree-split` 的 `ok?` 不能忽略。
12. **浮层引用 view / region**：资源消失，浮层必须跟着消失。

### 3.6 状态审计发现（需要特别注意）

1. **`engine-view` 不是强类型只读**
   - `effects/engine.rkt` `(provide (struct-out engine-view) ...)` 会导出 `engine-view-engine`。
   - 任何拿到 `ctx.engine` / hook 的 `engine-view` 的代码，都可以 `(engine-view-engine ev)` 拿回 `engine`。
   - 而 `(struct-out engine)` 又导出了 `engine` 的访问器 / `#:mutable` 的 setter（以及 `engine-doc-buffer` / `engine-view-object`）。
   - 所以“命令 / hook 只读 engine”目前是**约定**，不是封装。建议：
     - `engine` 不 `struct-out`，只导出需要的查询函数；
     - `engine-view` 不导出 `engine-view-engine`（`except-out`）；
     - `engine-doc-buffer` / `engine-view-object` 只给白名单模块（projection / panel / runtime），不给插件层。
2. **`store` 的命名空间不统一**
   - filetree / resources 是 `store['filetree]` / `store['resources]`；
   - completion 用 `'completion-session` / `'completion-popup-view` / `'completion-cache` / `'completion-jobs`；
   - docs 用 `'docs` / `'docs-state` / `'docs-cache` / `'docs-jobs`。
   - 同一插件的状态散落在多个顶层 key，卸载 / 清理 / 调试都难。建议统一成 `store[plugin-id]` 下的一个 hash。
3. **进程级缓存不在 State**
   - `plugins/lang/pool.rkt` 的 `exports-cache`、`docs.rkt` 的 `doc-cache` / xref / bluebox cache、`module-index.rkt` 的 `module-paths`、`doc-html.rkt` 的 weak cache、`theme` 的样式表。
   - 它们不在 State 里，不能随 State 快照恢复，也不参与 undo。
   - 其中 `pool.rkt` 会被主线程的 completion / docs 通过 `spec-binding-of` 调用，不只是 worker。
   - 这些缓存目前是“正确的性能优化”，但应该明确标注为 **process-global cache**，不要误以为 headless replay 完全确定。
4. **`Environment` 含闭包**
   - `panel-syncs` / `hooks` / `decors` / `status` 的 render / `commands` 的 run / `input-commands` 的 handler 都是过程。
   - Environment 是纯值（不可变），但不是可序列化值，也不能跨 place。
5. **effect 的 `k` 是闭包**
   - `open-doc-effect` / `read-file-effect` / `write-file-effect` / `save-doc-effect` 都带 continuation 闭包。
   - 效果日志 / 跨进程重放 / effect 数据化仍不可行（`REBUILD.md` 第 12 步）。
6. **`project-frame` 被调用两次**
   - `run-frame` 先 `project-frame` 拿 placements，`render-frame` 内部又 `project-frame` 一次。
   - 不是状态错误，但违反“一帧一次投影”的目标（`REBUILD.md` 第 11 步）。
7. **`doc-decors` 与 `paint-state` 是两份 decor 信息**
   - `engine.doc-decors` 存 `(path . decors)`，用于 `set-text` 后重新 open；
   - `paint-state.decors` 是文档 slot 里的当前 decors。
   - 两者必须同步；目前 attach 幂等，但如果将来 env 动态加 decor，需要明确 reattach 策略。

---

## 4. 布局平面 vs 命令 / 插件平面

### 4.1 布局 / 显示平面

```
core document/view（文本、history、slots、face port）
        ▲
        │ engine（id -> core handle，唯一可变拥有者）
        │
State.workspace
  docs / views / regions / layout / floats / focus / stack / root / placement
        │
        ├── model/layout.rkt          布局树：split / leaf / dim / visible / borders
        ├── projection/geometry.rkt   布局树 -> region-panel / content / cut
        ├── projection/float.rkt      浮层 -> 屏幕矩形
        ├── projection/render.rkt     panels / placements -> bytes
        ├── effects/panel.rkt         安装 / 卸载 / 写面板 buffer
        └── runtime/run.rkt           每帧 sync + engine-sync-views! + put-bytes
```

这一平面内部还可以再分：

| 子逻辑 | 位置 | 只回答什么问题 |
|---|---|---|
| **逻辑组合** | `workspace.regions`（members / active / role） | 一块位置里显示谁？ |
| **结构布局** | `model/layout.rkt` | 树怎么切？尺寸是 fixed / flex？可见吗？边框在哪？ |
| **屏幕几何** | `projection/geometry.rkt` | 每个 region 的实际 rect / content / 接缝在哪？ |
| **面板装配** | `effects/panel.rkt` + `bootstrap/panel.rkt` | 怎么建 doc / view / region？怎么卸载？ |
| **面板内容** | `env.panel-syncs` + `plugins/*/panel.rkt` | 每帧把什么文本 / face 写进 buffer？ |
| **浮层** | `workspace.floats` + `projection/float.rkt` | 浮层贴哪个 anchor？矩形多大？ |
| **视口** | `engine-sync-view(s)!` / `ensure-view-effect` | view 尺寸变了怎么夹光标？ |
| **策略** | `env.roles` + `bootstrap/commands/{view,region,focus,placement}.rkt` | 能不能切 / 怎么关 / 能不能聚焦 / 能不能 placement / Tab 能不能切？ |

关键点：**布局平面不应该认识具体插件**。它只认识 `region-id` / `view-id` / `role`。
`panel-spec` 是插件声明的“面板身份”，但安装位置 / 布局叶子仍由宿主决定。

### 4.2 命令 / 插件平面

```
terminal event
  → runtime/tui-adapter
  → base/event
  → dispatch/pipeline
       subject 解析 + rules-for 层序 + command 查找
  → command(ctx)
       ctx = env + state + event + subject + engine-view
  → transition{ state', effects }
  → effects/interpreter / engine
       engine 写 / 文件 IO / open / close / save
  → signals
       after-edit / after-nav / focus-changed / document-opened / job-done / tick
  → dispatch/hooks
       hook(state, engine-view, args) -> transition
  → 再解释 effect（最多 8 轮）
```

这一平面的数据源：

| 数据 | 位置 | 作用 |
|---|---|---|
| commands | `env.commands` | command-id → command |
| keymaps / rules | `env.keymaps`、`env.modes[].keymaps`、`doc-meta.keymap-layers`、`env.rules` | 键 → command-id |
| scopes | `env.scopes` | 规则条件 |
| modes / doc-types | `env.modes`、`env.doc-types` | 文档类型 → mode / 键表 |
| roles | `env.roles` | 区域策略 |
| input-commands | `env.input-commands` | 输入栏提交 |
| status-parts | `env.status` / `plugin.status-parts` | 状态栏段 |
| panels | `plugin.panels`（`panel-spec`） | 面板声明 + 每帧 sync |
| hooks | `env.hooks` / `plugin.hooks` | 信号旁观者 |
| decors | `env.decors` / `plugin.decors` | 每文档增量 face |
| face-layers | `env.face-layers` | 层序 |
| services | `submit-service-effect` + `plugins/worker.rkt` | 后台纯计算 |

### 4.3 两个平面的接缝

| 接缝 | 谁声明 | 谁消费 | 约束 |
|---|---|---|---|
| `panel-spec` | 插件 | `bootstrap/panel.rkt` / `effects/panel.rkt` | 只描述 name / role / mode / sync；位置由宿主给 |
| `role` | `env.roles` | 命令 / 派发 / 布局策略 | 不在 region 里存行为，只存 role 名 |
| `doc-meta.internal?` | 创建方（panel / chrome） | 保存 / 资源列表 / placement / decor | 基础设施文档不参与用户流程 |
| `workspace.placement` | 插件发起，框架提交 | placement 命令 / scope | 框架级交互，不属于插件 |
| `state.store` | 插件 | 插件自己 | 插件 UI 状态；不存 core |
| `env.panel-syncs` | 插件 / 框架 | runtime 每帧 | **不纯**：直接写 core buffer |
| `env.hooks` | 插件 / 框架 | dispatch/hooks | 纯：返回 transition |
| `env.decors` | 插件 | paint slot fork | 纯：open / change |
| `face-layers` | 插件 env | engine / paint | 层名唯一；后层覆盖前层分量 |
| `status-parts` | 插件 / env | projection/status | 每帧投影 |
| `doc-type` | 插件 env | interpreter 打开文件 | 路径 → mode / keymaps |

### 4.4 为什么这个分法是对的

- **布局平面只依赖值和几何**，不依赖命令实现；所以 headless 投影、测试、resize 都可重放。
- **命令平面只产生 transition / effect**，不直接碰 core；所以 undo / 多实例 / 测试不被污染。
- **插件两侧都能贡献**：既能贡献命令 / 键（动作平面），也能贡献面板 / 状态栏 / decor（显示平面）。
- **接缝数量少且明确**：`panel-spec`、`role`、`internal?`、`placement`、`store`、四类回调。

问题在于：接缝现在还是“散落的字段”，不是“统一的扩展清单”。见下一节。

---

## 5. 扩展点全景（当前实现）

### 5.1 全部扩展点

| # | 扩展点 | 注册位置 | 形状 | 触发 | 消费者 | 顺序 | 纯度 / 写权限 | 生命周期 |
|---|---|---|---|---|---|---|---|---|
| 1 | 命令 | `env.commands` | symbol → `command` | 键 / 鼠标 / 命令 | `dispatch/pipeline` | keymap 叶子 | 纯 transition；发 effect | env |
| 2 | 键位 | `env.keymaps` / `mode.keymaps` / `doc-meta.keymap-layers` | keymap | 按键 | `dispatch/rules` | input > doc > rules > mode > global | 纯查表 | env / doc |
| 3 | 条件键表 | `env.rules` + `env.scopes` | `rule{scope,keymap}` | 按键 | `dispatch/rules` | 插入在 mode 之上、global 之下 | 纯 | env |
| 4 | 临时模态 | `state.input.modes` + `env.keymaps[name]` | symbol 列表 | 按键 | `dispatch/rules` 第一层 | 最高 | 纯 State | 交互期 |
| 5 | mode | `env.modes` | `mode{keymaps,fallback}` | 文档打开 / 按键 | `dispatch/rules` | 低于 doc / rules | 纯 | env |
| 6 | doc-type | `env.doc-types` | `doc-type{extensions,mode,keymaps}` | 打开文件 | `effects/interpreter` | 按路径匹配 | 纯 | env |
| 7 | role | `env.roles` | `role{splittable?,close,focusable?,target?,switchable?}` | 关闭 / 切分 / 焦点 / Tab / placement | 命令 | 查表 | 纯 | env |
| 8 | input-command | `env.input-commands` | `input-command{name,match,handler,cancel}` | 输入栏 Enter | `chrome/input` / `document` 命令 | 列表顺序，首个匹配 | 纯值 + handler | env |
| 9 | 状态栏段 | `env.status` / `plugin.status-parts` | `status-part{name,render}` | 每帧投影 | `projection/status` | 追加在前 | 纯 render | env / plugin |
| 10 | 面板声明 | `plugin.panels` | `panel-spec{name,role,mode,sync}` | 宿主安装 / 每帧 | `bootstrap/panel` / `env.panel-syncs` | 注册顺序 | sync 不纯 | plugin / 装配 |
| 11 | 每帧面板同步 | `env.panel-syncs` | `(state engine -> any)` | 每帧渲染前 | `runtime/run-frame` | 注册顺序；框架 sync 在后 | **不纯**：写 core | env |
| 12 | 信号 hook | `env.hooks` / `plugin.hooks` | `hook{point,when,priority,proc}` | 信号 | `dispatch/hooks` | priority 降序，稳定 | 纯 transition；只读 engine-view | env |
| 13 | face decor | `env.decors` / `plugin.decors` | `face-decor{id,layer,applies?,open,change}` | document open / 编辑 fork / 光标推进 | `effects/paint` | 注册顺序 | 纯 | env / doc slot |
| 14 | face 层序 | `env.face-layers` | `(listof symbol)` | 启动 / 合成 | `engine` / `paint` | 先低后高 | 纯 | env |
| 15 | 一次性静态 face 层 | `set-face-layer-effect` | doc + layer + fills | 命令 / hook | `paint-set-static-layer!` | 层序 | 写 core face | command |
| 16 | 后台服务 | `submit-service-effect` + `plugins/worker.rkt:service-kinds` | job + kind + payload | 命令 / hook | runtime worker / inline | 一条队列 | 纯 / 只读 IO | job |
| 17 | 自定义信号 | `state-emit` / `emit-effect` | symbol + args | 任意 | `env.hooks` | 按 point | 纯 | 临时 |
| 18 | 插件状态 | `state.store` | symbol → any | 插件自己 | 插件自己 | — | 纯 State 快照 | 插件 |
| 19 | 主题 | `theme/*` | face 符号 → style | require / render | tui | 同名覆盖 | 全局样式表 | 进程 |
| 20 | placement / interaction | `workspace.placement` / `state.confirm` / `input.gesture` | 纯状态 | 命令 | 命令 / scope | — | 纯 State | 交互期 |

### 5.2 当前插件描述符

```racket
(struct plugin (id env status-parts panels hooks decors state-init))
```

| 字段 | 作用 | 与 env 的重叠 |
|---|---|---|
| `id` | `state.store` 的键（但实际插件常不用它做命名空间） | — |
| `env` | roles / modes / scopes / commands / keymaps / rules / doc-types / input-commands / hooks / decors / panel-syncs / face-layers | 与 `hooks` / `decors` / `panels` 有重叠 |
| `status-parts` | 状态栏段（加法语义） | `env.status` 是覆盖语义 |
| `panels` | `panel-spec` 列表 | `env.panel-syncs` 也可直接加 |
| `hooks` | 信号 hook | `env.hooks` 也可直接加 |
| `decors` | face decor | `env.decors` 也可直接加 |
| `state-init` | `state -> state` | 可以写任意 store key |

`Environment` 有 13 个字段：

```
roles modes scopes commands keymaps rules status doc-types
input-commands panel-syncs hooks face-layers decors
```

### 5.3 问题清单

1. **同一个扩展点有两条注册路径**
   - `plugin.hooks` 和 `env.hooks`；`plugin.decors` 和 `env.decors`；`plugin.panels[].sync` 和 `env.panel-syncs`。
   - 插件作者不知道该用哪个；`plugin-env-apply` 还要分别 append。

2. **没有 owner / provenance**
   - 每个贡献没有“来自哪个插件”的标记。
   - 因此不能 disable / uninstall / reload；`environment-merge` 只是覆盖，无法反查来源。
   - `panel-uninstall!` 只能拆一个 region，不能拆插件贡献。

3. **没有装配期校验**
   - keymap 叶子指向不存在的 command；
   - rule 的 scope 未注册；
   - decor 的 layer 没在 `face-layers`；
   - 两个 decor 用同一个 layer；
   - status-part 重名；
   - panel mode / role 未注册；
   - hook point 拼错。
   - 这些现在都是运行时静默失效或部分覆盖。

4. **`panel-spec` 是半描述符**
   - 只有 `name / role / mode / sync`，没有 install / placement / layout hint。
   - 安装需要 region-id 和布局位置，所以宿主必须写额外的 `install-*` 函数。
   - 每个插件都重复“安装 + 设置 store view-id + 可选 root / expanded”。

5. **异步 job 三件套逐插件复制**
   - completion：`session` + `cache` + `pending` + `jobs` + `job-add/take` + `on-job`。
   - docs：`state` + `cache` + `pending` + `jobs` + `job-add/take` + `on-job`。
   - 同样的 job-id 对账、pending 清理、错误处理写了两遍。

6. **交互 / 取消分散**
   - `input.pending`、`input.modes`、`input.gesture`、`workspace.placement`、`state.confirm`、`chrome.slot-info`、插件 session。
   - 取消路径：`C-g` / `Esc`、`input-cancel`、`place-cancel`、`close-popup`、`confirm-finish`……
   - 没有统一的 interaction 栈，新增一个交互就要再想一遍“谁负责取消”。

7. **effect 解释器是封闭 `cond`**
   - 插件只能用内置 effect + `emit-effect`；不能注册自定义 effect。
   - 这不一定坏（避免 effect 爆炸），但需要明确“不要用 hook 硬凑 effect”。

8. **布局策略仍有分散**
   - `role` 决定 splittable / close / focusable / target / switchable；
   - `split` / `close` / `switch` / `focus` / `placement` 各自在命令里查 role；
   - `filetree` 的显隐自己记录 width；
   - `docs` 的显示 / 隐藏自己改 layout。
   - 缺少 `toggle-region!` / `layout-snapshot` 这类原语。

9. **hook 容易被误用**
   - 现在 `completion` / `docs` 用 hook 做 `after-edit` / `after-nav` / `job-done`；
   - 高亮已经改成 decor，这是对的；
   - 如果新功能继续“发生一件事 → 加一个 hook”，hook 表会变成隐式总线，顺序 / 取消 / 状态所有权都会失控。

---

## 6. 统一方案：一份贡献清单，四类执行器

### 6.1 原则

1. **扩展点种类由“触发时机 + 纯度 + 生命周期”决定，不由“我想挂个回调”决定。**
2. **hook 只用于“一件事已经发生，旁观者看一眼”**；不用于每帧、每文档持续状态、异步、布局。
3. **插件贡献是数据**；执行器仍是现有的几个模块，不把 runtime 变成大 hook 表。
4. **每个贡献带 owner**；这样 disable / uninstall / validate / 冲突检测才有可能。
5. **先统一描述，不急着统一执行**。执行器分开是好事：它们的纯度 / 触发 / 写权限不同。

### 6.2 建议的模块布局

```
env/extension.rkt        ; 新：贡献种类 / contribution / validate / add / remove
env/hook.rkt             ; 保留：hook 值（独立模块）
env/plugin.rkt           ; 改：plugin = id + contributions + state-init
env/environment.rkt      ; 改：保留 compiled 索引 + provenance
dispatch/hooks.rkt       ; 保留：hook 执行器
effects/paint.rkt        ; 保留：decor 执行器
runtime/run.rkt          ; 保留：panel-sync / service 执行器
dispatch/rules.rkt       ; 保留：rules 执行器
```

`env/extension.rkt` 在 `env` 层，不依赖 effects / runtime，所以不会破坏层序。
如果希望目录更清楚，可以做 `env/extension/` 子目录：

```
env/extension/manifest.rkt   ; contribution / kind / 构造器
env/extension/validate.rkt   ; validate-environment
env/extension/hook.rkt       ; 只 re-export env/hook.rkt（可选）
env/extension/panel.rkt      ; panel-spec 相关贡献
```

但**执行器不要搬进 `env/extension/`**：`dispatch/hooks.rkt`、`effects/paint.rkt`、
`runtime/run.rkt` 各自有层依赖。

### 6.3 Contribution 描述符

建议用“tagged payload”，而不是把所有字段塞进一个大 struct：

```racket
(struct contribution (owner kind payload) #:transparent)
;; owner : symbol          ; plugin id / framework id
;; kind  : symbol          ; 见下表
;; payload : any/c         ; kind-specific value（command / rule / hook / decor / ...）

(struct plugin (id contributions state-init) #:transparent)
```

`kind` 的初始集合：

| kind | payload | 执行器 | 触发 |
|---|---|---|---|
| `'command` | `(cons id command)` | `dispatch/pipeline` | 键 / 鼠标 |
| `'rule` | `rule` | `dispatch/rules` | 按键 |
| `'keymap` | `(cons name keymap)` | `dispatch/rules` | 按键 |
| `'mode` | `(cons id mode)` | `dispatch/rules` | 文档 / 按键 |
| `'scope` | `(cons id scope)` | `dispatch/rules` | 按键 |
| `'doc-type` | `doc-type` | `effects/interpreter` | 打开文件 |
| `'role` | `(cons id role)` | 命令 | 关闭 / 切分 / 焦点 / placement |
| `'input-command` | `input-command` | `chrome/input` | 输入栏 Enter |
| `'status-part` | `status-part` | `projection/status` | 每帧 |
| `'panel` | `panel-spec` | `bootstrap/panel` | 装配 |
| `'panel-sync` | procedure | `runtime/run-frame` | 每帧 |
| `'hook` | `hook` | `dispatch/hooks` | 信号 |
| `'decor` | `face-decor` | `effects/paint` | document open / edit / cursor |
| `'face-layer` | symbol | `engine` / `paint` | 启动 / 合成 |
| `'service` | service descriptor | `runtime/worker` | 异步 |
| `'store-init` | `state -> state` | `plugins-apply` | 装配 |

`environment-add-contribution` 的职责：

```racket
(define (environment-add-contribution env c)
  (case (contribution-kind c)
    [(command) (environment-add-command env (car p) (cdr p))]
    [(hook)    (environment-add-hook env p)]
    ...
    [else (error 'environment-add-contribution ...)]))
```

这样：
- 插件作者只写一种 `contribution` 列表；
- 现有 `environment-add-*` 仍是底层原语；
- 执行器完全不变；
- `plugins-env` 变成 `(for/fold ([e env]) ([c contributions]) (environment-add-contribution e c))`。

### 6.4 Provenance / uninstall / validate

**owner**：

```racket
(struct contribution (owner kind payload) #:transparent)
```

`environment` 可以另外存：

```racket
(struct environment (...
                     contributions   ; (listof contribution)
                     ...))
```

或保持现在的 compiled 字段，同时用一个 `owners` hash：

```racket
owners : (hash/c (cons symbol symbol) (listof contribution))
```

**uninstall**：

```racket
(environment-remove-owner env 'completion)
```

实现方式二选一：
- 从 `contributions` 重新 fold（干净，推荐）；
- 或按 owner 建反向索引，精确删除。

**validate**：

`validate-environment` 在 `startup!` / `plugins-env` 后跑一次：

1. 每个 keymap 叶子是已注册 command（或允许的 symbol）；
2. 每条 rule 的 scope 已注册或 `always`；
3. 每个 decor 的 layer 在 `face-layers`，且 layer 名唯一；
4. 每个 status-part 名唯一；
5. 每个 panel-spec 的 mode / role 已注册，sync 是过程或 `#f`；
6. 每个 hook 的 point 是 symbol；priority 是整数；
7. 每个 service kind 在 `service-kinds`；
8. 每个 contribution 有 owner；
9. env.face-layers 不重复。

失败时在装配期报错，而不是运行时静默失效。

### 6.5 hook 的定位：独立模块，但不是总线

结论：**hook 已经可以独立成模块，而且现在就是独立的。**

- `env/hook.rkt`：hook 值（point / when / priority / proc）。
- `dispatch/hooks.rkt`：排空信号 + 按 priority 跑 hook。
- `base/signal.rkt`：标准信号点词表。
- `runtime/run.rkt` 的 `settle`：先 effect，再 hook，再 effect。
- `main.rkt` 目前没有 re-export hook；插件要直接 require `env/hook.rkt`。
  如果要统一公共 API，可以在 `main.rkt` 增加 `(all-from-out "env/hook.rkt")`。

建议：

1. **保留 `env/hook.rkt` 独立**，不要把它塞进 `env/plugin.rkt` 或 `env/environment.rkt`。
2. 在统一贡献清单里，hook 只是 `kind = 'hook` 的一种贡献。
3. 给 hook 加“使用边界”：
   - ✅ 一件事发生后的旁观逻辑（刷新补全候选、刷新文档面板、日志、统计）。
   - ❌ 每帧工作 → `panel-sync`。
   - ❌ 每文档持续状态 / 增量 → `decor`。
   - ❌ 慢查询 / 后台 → `service`。
   - ❌ 布局 / 几何 → 命令 + `role` / layout 原语。
   - ❌ 写 core → 发 effect。
4. 给 hook 加 **point 词表校验**：未知 point 默认报错或警告（现在 `known-signal-point?` 只用于文档）。
5. 可选：把 `hook` 的 `when` / `proc` 签名统一成 `(state engine-view args -> ...)`，已经是这样；不要为不同 hook 再加不同 arity 的表。

### 6.6 交互栈（解决“交互状态有 7 个家”）

建议新增一个轻量、纯数据的 interaction 栈：

```racket
(struct interaction (id kind owner data cancel finish) #:transparent)
;; kind : 'input | 'placement | 'confirm | 'completion | 'gesture | ...
;; cancel / finish : (state -> transition) | #f
```

`state.input` 增加 `interactions` 字段（或单独 `state.interactions`），
现有 `pending` / `modes` / `gesture` 可以先保留，逐步迁移：

- `placement` → interaction `'placement`；
- `confirm` → interaction `'confirm`；
- completion session → interaction `'completion`；
- input 栏 → interaction `'input`；
- mouse gesture → interaction `'gesture`。

取消统一走 `input-cancel` / `interaction-cancel`：从栈顶找 owner，调 cancel，再 pop。
好处：新增交互不再需要“再加一个 state 字段 + 一条取消路径”。

这一步不要一次做完；先做 `input session` 身份（`REBUILD.md` 第 2 步），
再把 `placement` / `confirm` 迁进去。

### 6.7 通用 service / job 管理器

现在 completion 和 docs 各自维护：

```
cache (done/pending) + jobs (id -> tag) + job-add/take + on-job + pending-add/del
```

建议抽到 `env` 或 `model` 的通用结构：

```racket
(struct service-state (cache pending jobs) #:transparent)
```

或者更彻底：

```racket
(struct job (id kind key payload) #:transparent)
```

由 runtime 维护 `job-id -> {owner,key}`，结果回 `job-done` 后：
- owner 自己决定缓存 / 丢弃；
- 通用逻辑负责 pending 清理、错误归一化、过期 job 丢弃。

不要求现在做；但这是删掉两份重复代码的最直接办法。

### 6.8 panel-spec 补全

建议 `panel-spec` 增加可选字段：

```racket
(struct panel-spec (name role mode sync install hint) #:transparent)
;; install : (engine state rid -> (values state vid)) | #f
;; hint    : 'left | 'right | 'bottom | 'top | (fixed n) | (flex n) | #f
```

- `install` 由宿主 `panel-spec-install!` 调用，插件可以在里面设置自己的 store（view-id / root / expanded）。
- `hint` 只是布局建议；最终位置仍由宿主决定。
- 不要在 `panel-spec` 里放绝对坐标 / layout path；那是宿主策略。

另外，把 `filetree` 的显隐 / 宽度记忆抽成框架原语：

```racket
(toggle-region! state rid #:axis ... #:min ...)
```

这样 `C-b`、docs 面板、未来的 sidebar 不需要各写一遍“记录 width / tree-hide / tree-show”。

### 6.9 自定义 effect（可选，不建议现在做）

如果确实需要：
- 在 `env` 增加 `effect-handlers : (hash/c symbol handler)`；
- `effects/interpreter.rkt` 的 `cond` 最后查这张表；
- handler 必须是 `(engine state effect -> transition)`，并声明是否纯 / 是否 IO；
- 这仍然不是 hook：它是“新 effect 类型”，需要独立的校验 / 文档 / 测试。

在出现第二个真实需求前，保持 interpreter 封闭是合理的。

### 6.10 新功能选型表

| 需求 | 应该用 | 不应该用 |
|---|---|---|
| 新命令 / 键位 | `command` + `rule` | hook |
| 条件键表 | `rule` + `scope` | 改 `global` keymap |
| 文档类型专属行为 | `doc-type` / `mode` | hook 里判断路径 |
| 每文档持续上色 / 词法状态 | `decor` | `after-edit` + 全量 `set-face` |
| 每帧刷新面板 | `panel-sync` / `panel-spec.sync` | hook |
| 事件发生后的旁观逻辑 | `hook` | 每帧 hook |
| 慢查询 / 模块导出 / 文档 | `service` + `job-done` | 主线程同步 + hook |
| 输入栏流程 | `input-command` + interaction | 新 state 字段 + 新 hook |
| 布局显示 / 隐藏 / 切换 | `panel-spec` + `role` + `toggle-region!` | 插件直接改 layout |
| 插件 UI 状态 | `store[plugin-id]` | 根 State 新字段 |
| 新显示内容 | document + panel / float | 自绘通道 |
| 主题 / 颜色 | `theme` + face 符号 | 插件写 RGB |

---

## 7. 建议的实施顺序

> 原则：每一步独立可跑，`test/run.sh` 全绿再进下一步；不为了对称加 API。

### 第 1 步：只加“描述 + 校验”，不改行为

- 新增 `env/extension.rkt`：
  - `contribution` / `kind` / `environment-add-contribution`；
  - `validate-environment`。
- `env/plugin.rkt` 保留现有字段，但内部把它们转成 contributions。
- `plugins-env` 末尾跑 `validate-environment`。
- 测试：`test/plugin.rkt`、`test/env.rkt`、`test/layers.rkt`。
- 收益：所有扩展点第一次有统一清单；新功能必须先选 kind。

### 第 2 步：加 owner / provenance / uninstall

- 每个 contribution 带 `owner`。
- `environment-remove-owner`；`plugins-uninstall`。
- 插件 store 统一成 `store[plugin-id]` 下的一个 hash（先兼容旧 key）。
- 测试：`test/plugin-detach.rkt` 增加“卸载后 env / state / panel 干净”。

### 第 3 步：input session 身份 + interaction 栈

- 对应 `REBUILD.md` 第 2 / 8 步。
- 先给 input 加 `tag` / `data`，不再靠 prompt 正则认亲。
- 再把 `placement` / `confirm` / completion session 迁进 interaction 栈。
- 测试：`test/save.rkt`、`test/sidebar.rkt`、`test/plugins.rkt`。

### 第 4 步：通用 service / job 管理器

- 抽出 completion / docs 重复的 cache / pending / jobs / job-done。
- 测试：`test/worker.rkt`、`test/plugins.rkt`。

### 第 5 步：panel-spec 补全 + toggle-region

- `panel-spec` 加 `install` / `hint`。
- 抽 `toggle-region!`，替换 filetree 的 width 记忆和 docs 的 show/hide。
- 测试：`test/panel.rkt`、`test/sidebar.rkt`、`test/filetree.rkt`、`test/float.rkt`。

### 第 6 步：project-frame 一次 + layout snapshot

- `run-frame` 只调一次 `project-frame`，把 panels / placements 传给 render。
- 对应 `REBUILD.md` 第 11 步。
- 测试：`test/projection.rkt`、`test/runtime.rkt`。

### 第 7 步：effect continuation 数据化（可选）

- 把 `open-doc` / `read-file` / `save-doc` 的 `k` 换成 `command-id + args` 或数据化 continuation。
- 这是 effect 日志 / 跨进程重放的前提，但不影响当前编辑功能。
- 对应 `REBUILD.md` 第 12 步。

### 第 8 步：自定义 effect（只在有真实需求时）

- 加 `env.effect-handlers`；保持 interpreter 的校验 / 白名单 / 测试。

---

## 8. 一句话建议

**不要继续加 hook。** 先把“插件贡献”收成一份带 owner 的数据清单，让每个新功能必须先回答：

> 它是命令、规则、每文档 decor、每帧 panel-sync、一次性 service，还是一次性的旁观 hook？

hook 继续独立存在（`env/hook.rkt` + `dispatch/hooks.rkt`），但它只是四类执行器之一，
不是新的扩展总线。这样布局 / 显示平面可以继续只依赖 `region / view / layout / role`，
命令 / 插件平面则通过统一的 `contribution` 进入，不需要每次都改 `env/plugin.rkt`、
`env/environment.rkt` 和 runtime。
