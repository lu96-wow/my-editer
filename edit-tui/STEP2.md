# step2：统一贡献清单 + 装配期校验

> 承接 `edit-tui-rebuild/ANALYSIS.md` 的第 1 步：
> **先加描述和校验，不改执行路径。**
>
> 本目录是 `edit-tui-rebuild` 的副本，只做这一步；原有分层 / 副作用白名单 / 测试保持不变。

## 1. 新增模块

| 模块 | 作用 |
|---|---|
| `env/extension.rkt` | `contribution{owner,kind,payload}`；把 contribution 落到已有 env 字段；`validate-environment` / `validate-environment!` |
| `env/panel-spec.rkt` | `panel-spec` 从 `env/plugin.rkt` 拆出，避免 `plugin ↔ extension` 循环依赖 |
| `test/extension.rkt` | contribution / provenance / 校验 / 内置 env / `#:contributions` 的回归测试 |

## 2. 数据结构

```racket
(struct contribution (owner kind payload) #:transparent)

;; kind 初始集合：
;;   status-parts status-part
;;   command keymap rule mode scope role doc-type input-command
;;   panel panel-sync hook decor face-layer
```

`environment` 新增两个字段：

```racket
(environment roles modes scopes commands keymaps rules status
             doc-types input-commands panel-syncs hooks face-layers
             decors contributions base)
```

`contributions` 只记录来源，不替代执行字段：

- `environment-add-contribution` 仍然调用 `environment-add-command` / `add-hook` / `add-decor` …；
- 执行器完全不变：`dispatch/hooks.rkt`、`effects/paint.rkt`、`runtime/run-frame`、`dispatch/rules.rkt`；
- `environment-merge` 追加两边的 `contributions`（不重新编译）；
- `base` 是“第一次加 plugin contribution 前的快照”，供 `environment-remove-owner` 重建。

`plugin.env` 的字段也会被分解成 contribution（owner = 插件 id），所以
`environment-remove-owner` 不只删 status-parts / hooks / decors，也能删
commands / modes / rules / face-layers / doc-types / input-commands。

重放顺序：

- rules / input-commands 是 cons 表，`environment->contributions` 反向生成，
  重建时再 cons 回原顺序；
- status 用 `'status`（替换语义）和 `'status-parts`（加法语义）分开；
- panel-syncs / hooks / decors / face-layers 是 append 表，保持正序。

`plugin` 新增可选字段：

```racket
(make-plugin 'demo
             #:contributions
             (list (make-contribution 'demo 'command (cons 'demo-hi cmd))))
```

旧字段 `env / status-parts / panels / hooks / decors` 保留，装配时也会转成 contribution
（owner = plugin id），所以 `environment.contributions` 能看到完整来源。
`make-plugin` 要求 `contribution-owner` 等于插件 id。

## 3. 按 owner 移除

```racket
(environment-remove-owner env 'plugin-id)
```

- 要求 `env.base` 存在（`plugins-env` 会在第一个插件贡献前写入）；
- 从 `base` 重建，只保留其他 owner 的 contributions；
- 环境没有 base（例如 `environment-empty`）时抛错，避免“删了清单但字段还在”的假卸载；
- 不存在的 owner 原样返回；
env 只负责“贡献清单”。高层卸载入口在 `bootstrap/plugin.rkt`：

```racket
(define-values (env' state')
  (plugin-uninstall! engine state env 'plugin-id
                     #:regions (list sidebar-rid)))
```

它做三件事：

1. `environment-remove-owner`：撤销 env 贡献；
2. `plugin-state-clear`：清掉 `store['plugin-id]`；
3. `#:regions` 里的每个 region：`panel-uninstall!`（doc / view / region / layout）。

`#:regions` 由宿主给：布局位置是宿主策略，插件描述符里没有绝对坐标。
不传 `#:regions` 时只做 env + store，面板留给宿主。

### 3.1 store 命名空间

为了让 `plugin-state-clear` 一次清干净，completion / docs 的 store 也统一成
“一个插件一个 key”：

```racket
store['completion] = hash 'session / 'popup-view / 'popup-region / 'cache / 'jobs
store['docs]       = hash 'panel / 'state / 'cache / 'jobs
```

filetree / resources 本来就是这个形状。`plugin-state-clear` 只做
`hash-remove store plugin-id`，不再需要插件自己列一堆 key。

### 3.2 通用 service 状态

completion / docs 原来各自维护一套 `cache + pending + jobs + job-add/take`。
新增纯模块 `model/service.rkt`：

```racket
(struct service-state (cache pending jobs))

(service-cache-ref / has? / set / remove)
(service-pending? / add / del)
(service-job-add / tag / take)
(service-request state service kind payload tag)
;; -> (values state' service' effect)
```

`service-request` 一次做三件事：分配 job-id、记 pending + job、构造
`query-effect`。completion / docs 不再各写 `state-next-id` +
`job-add` + `pending-add`。

`query-effect` 与 `submit-service-effect` 语义相同，runtime 两者都接；
新代码优先用 `query-effect`。

- cache 的“有没有”用 `service-cache-has?` 判断，结果本身可以是 `#f`；
- pending 是“同一 key 只允许一个在途”；
- jobs 是 `job-id -> tag`，`service-job-take` 返回 `(values tag service')`，
  未知 / 过期 job 的 tag = `#f`；
- 插件只把 `service-state` 放进自己的 store key：

```racket
store['completion] = hash 'session / 'popup-view / 'popup-region / 'service
store['docs]       = hash 'panel / 'state / 'service
```

worker / `submit-service-effect` / `job-done` 仍然在 runtime；本模块只做纯数据。

### 3.2.1 service 声明

`env/service.rkt`：

```racket
(struct service-spec (kind description pure?))
(make-service-spec 'doc #:description "..." #:pure? #t)
```

- `environment.services : kind -> service-spec`；
- `environment-add-service` / `environment-service` / `environment-service-kinds`；
- contribution 新增 `'service`；
- completion 声明 `completion-exports` / `module-paths`，docs 声明 `doc`；
- `startup!` 校验：声明的 kind 必须存在于 `plugins/worker.rkt` 的 `service-kinds`。

worker 的实现仍是静态 `service-run` 分派；env 的声明是能力清单 + 启动期校验。

### 3.3 一帧只投影一次

以前 `run-frame` 先 `project-frame` 拿 placements，`render-frame` 内部又
`project-frame` 一次。现在：

- `projection/render.rkt` 新增 `render-frame* : state engine cache panels -> (frame-cache bytes)`；
- `render-frame` 保留为“自己投影一次”的便捷入口（测试 / 单帧调用）；
- `run-frame` 只调一次 `project-frame`，把 `panels` 交给 `render-frame*`，
  `placements` 交给 `engine-sync-views!`。

`test/projection.rkt` 断言 `render-frame*` 与 `render-frame` 输出一致。

另外 `projection/geometry.rkt` 新增 `layout-snapshot` / `geometry-snapshot`：
`project-frame` 只解一次布局，region-panel / cuts 同时给平铺面板和浮层用，
浮层不再每个都重新 `geometry-solve`。

### 3.4 input session 身份

输入栏原来靠 prompt 正则反查“谁占用了 input”。现在 `State.input` 带
`input-session`：

```racket
(struct input-session (tag data cancel prompt))

(input-show ctx prompt
            #:tag 'save-confirm
            #:data did
            #:cancel (λ (s) (state-set-confirm s #f)))
```

- 新 input 替换旧 input 时，直接调旧 session 的 `cancel`，不再匹配 prompt；
- 没有 session 时仍回退到 `input-command.cancel`（兼容旧调用）；
- `input-finish` / `input-cancel` 清 session；
- `input-show-state` 也支持同样的 tag / data / cancel；
- 提交仍然由 `environment.input-commands` 匹配完整 buffer 字符串。

已带 session 的流程：open-file、save-as、save-confirm、filetree 的
create-file / create-folder / delete-confirm。

### 3.5 panel-spec install 回调

`panel-spec` 现在多四个可选字段：

```racket
(struct panel-spec (name role mode sync install hint owner key))

;; install : (engine state region-id view-id -> state) | #f
;; hint    : #f | dim
;; owner   : symbol | #f      plugin id（与 contribution owner 一致）
;; key     : symbol | #f      同一 owner 下的稳定面板 key
;; placement: 'active | 'inactive
```

`bootstrap/panel.rkt` 的 `panel-spec-install!`：

1. 先用 `panel-install!` 建 doc / view / region；
2. 如果 spec 有 `install`，调用它做插件自己的初始化；
3. 校验返回值是 state，再返回 `(values state' vid)`。

这样插件不再各写一遍“install 后写 store view-id”：

- filetree：写 `store['filetree].view` + 展开 `workspace.root`；
- resource：写 `store['resources].view`；
- docs：写 `store['docs].panel`；
- completion：写 `store['completion].popup-view / popup-region`。

位置仍由宿主给：`install` 拿到的是 region-id / view-id，不知道布局坐标。
`hint` 只在一个 leaf 已经存在时把它的 dim 改成 hint；不会替宿主决定位置。
filetree / resource 用 `(fixed 30)`，docs 用 `(fixed 8)`。

`owner + key` 会登记到 `workspace.panel-index`：

```racket
(struct panel-entry (owner key region view))
```

- `panel-spec-install!` 安装后登记；
- `workspace-panel-view` / `workspace-panel-region` 可按 owner+key 查；
- `plugin-uninstall!` 不传 `#:regions` 时，按 registry 找到该 owner 的 view，
  只卸自己的 view，不会误删共享 region 里的另一个面板；
- 空 region 才会连 region / layout leaf 一起收掉。

filetree / resource / docs / completion 的 spec 都设置了 owner/key。

`placement` 只影响“加入一个已存在的多成员 region 时要不要设为 active”：

- `'active`（默认）：当前行为，新面板成为 active；
- `'inactive`：加入成员表，但保留原 active；没有 active 时才用新 view。
  适合“文件树 + 资源列表共用 sidebar”这类不想抢当前面板的场景。

### 3.6 `toggle-region!`

`bootstrap/commands/layout.rkt` 新增通用原语：

```racket
(toggle-region! state rid #:min 20 #:axis #f)
;; -> (values state' visible? size)
```

- hide：先量当前内容尺寸，把 leaf.dim 写成 `fixed size`，再 `tree-hide`；
- show：直接 `tree-show`，尺寸从 leaf 的 fixed dim 恢复；
- 焦点原本在 region 里（view 或 region-id）→ 退到 region 外的第一个真实文档 view，否则 `#f`；
- region 不存在 → 原 State、`visible? = #f`、`size = #f`；
- `#:min` 保证隐藏尺寸不小于最小值。

filetree 的 `C-b` 已经改成调用它；`store['filetree].width` 不再需要，已删除。
`test/toggle-region.rkt` 覆盖 hide/show / 焦点回退 / 无 view / missing region / min。

### 3.7 `cancel-current` 命令

`bootstrap/commands/cancel.rkt` 的取消 dispatcher：

```racket
(cancel-current-command)
```

- input 占用 -> `input-cancel`（session cancel / 旧 input-command cancel）；
- 否则 interaction 栈顶有 cancel -> 调它；
- 否则兼容直接设置 `workspace.placement` 的路径；
- 否则提示 `nothing to cancel`。

全局键：`C-g` / `Esc`。更高优先级的 layer 仍然先接键：

- input mode 的 `C-g` / `Esc` -> input-cancel；
- completion popup mode 的 `C-g` / `Esc` -> close-popup。

### 3.7.1 effect continuation 数据化（第一步）

`base/effect.rkt`：

```racket
(struct continuation (tag data))
(make-continuation tag data)
```

effect 的 `k` 现在可以是：

- 旧的过程（兼容）；
- `continuation` 数据；interpreter 按 tag 在
  `environment.continuations` 里查 handler：
  ```racket
  handler : (state data . results -> transition)
  ```

已迁移：

- `save-doc-effect`：
  - `'save-current` / `'save-as` / `'save-confirm` / `'save-docs-then`
  - handler 注册在 `core-env` 的 `save-continuation-handlers`；
- filetree 的 `write-file-effect` / `make-directory-effect` / `delete-file-effect`
  - 统一用 `'notice-result` + `notice-result-handler`。

`runtime/run.rkt` 把 `environment.continuations` 传给 interpreter。
`test/effects.rkt` 增加了一个纯数据 continuation 的直接用例。

还没迁移：`read-file-effect`、`open-doc-effect`、`open-view-effect` 的 mount /
open 回调仍是过程。

### 3.8 interaction 栈

`model/interaction.rkt` + `state.interactions`：

```racket
(struct interaction (id kind data))
```

取消函数不在栈里，而在 `environment.interactions`：

```racket
environment.interactions : kind -> (ctx data -> transition)
```

所以 State 里的 interaction 是纯数据，不夹带闭包。栈只记录“当前有哪些交互、
取消时先找谁”，状态仍在原来的地方：

| 交互 | 状态真身 | 栈条目 |
|---|---|---|
| input | `State.input.session-info` | `kind 'input` |
| pending 键序列 | `State.input.pending` | `kind 'pending` |
| placement | `workspace.placement` | `kind 'placement` |
| confirm | `state.confirm` | `kind 'confirm` |

- `input-show` / `input-show-state` push input，`input-finish` pop `'input`；
- dispatch 的 prefix 设置 `state-set-pending` push `'pending`；leaf / unbound / cancel 时 pop；
- `set-placement` / `clear-placement` push / pop `'placement`；
- `save-confirm-start` push `'confirm`，`confirm-finish` pop；
- save-confirm 的 session cancel 会清 confirm 并 pop `'confirm`；
- `cancel-current` 先 input，再栈顶（按 kind 查 `env.interactions`），再兼容 placement。

`core-env` 注册了 `'input` / `'placement` / `'confirm` / `'pending` 四个 handler；
插件也可以贡献 `'interaction` contribution。

pending 的细节：

- `C-x` 等前缀 -> push `'pending`（data = 键序列）；
- 继续前缀 -> pop 再 push，保持栈里只有一条最新 pending；
- leaf / unbound -> pop；
- 带前缀时按 `C-g` / `Esc`：如果完整序列是已绑定命令（如 `C-x C-g`）就执行它；
  否则走 `cancel-current`，由 `'pending` handler 清 pending + pop。

## 4. 校验

`plugins-env` / `plugins-apply` 末尾调用 `validate-environment!`，检查：

1. contribution 的 owner 是 symbol、kind 已知；
2. 所有 keymap 叶子是已注册命令；
3. rule 的 scope 已注册（`always` 或 `env.scopes`）；
4. doc-type 的 mode 已注册；
5. `face-layers` 唯一；
6. decor 的 layer 已在 `face-layers` 声明，decor layer / id 唯一；
7. status-part 名唯一；
8. input-command 名唯一；
9. hook point 是 symbol、priority 是整数；
10. panel-sync 是过程；
11. panel 的 mode / role 已注册，sync 是过程或 `#f`。

失败时装配期直接报错，不再是运行时静默失效。

## 5. 兼容性

- `panel-spec` API 不变：`env/plugin.rkt` re-export `(all-from-out "panel-spec.rkt")`。
- `make-plugin` 的旧关键字参数不变，新增 `#:contributions`。
- `environment` 构造器 / `environment-empty` / `environment-merge` 已同步更新。
- `main.rkt` 增加 `env/hook.rkt`、`env/panel-spec.rkt`、`env/extension.rkt` 的公共导出。
  这样 hook 不再需要“绕过公共面”直接 require，但它仍然只是独立模块，不是扩展总线。

## 6. 验证

```sh
cd edit-tui-rebuild-step2
racket test/extension.rkt
racket test/plugin-uninstall.rkt
racket test/service.rkt
racket test/input-session.rkt
racket test/cancel.rkt
racket test/interaction.rkt
bash test/run.sh   # 先 raco make，再逐个跑
```

本次结果：`edit-tui/test: all clean`。

## 7. 下一步（未做）

- interaction 栈已收 input / pending / placement / confirm；`env.interactions` 已注册。
- effect 的 `k` 数据化：save-doc / filetree IO 已迁移；read-file / open-doc / open-view 仍是过程。
- effect 的 `k` 数据化。
- `layout-snapshot`（`project-frame` 已经一帧只调一次，快照还没做）。
