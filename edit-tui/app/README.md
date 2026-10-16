# edit-tui/app —— 数据驱动编辑器骨架（事件循环）

`layout` / `command` / `panel` / `view` 之上的一层胶水：把「事件 → 纯状态转移 →
效果解释 → 重绘」串起来。目标是**扩展性拉满**：新功能首选加数据 + 加 intent，
而不是改循环。

```
                       ┌─────────────── loop.rkt（唯一不纯）───────────────┐
 read-event ──┐        │  read → batch(终端事件 + inbox) → step* → 执行 intent → draw │
              │        └──────────────────────────────────────────────────┘
              ▼                          ▲                    ▲
        world-step ──(world, intents)────┘            render.rkt：world → bytes
     （纯：world × event → world + intents）
```

## 文件

| 文件 | 职责 | 纯? |
|---|---|---|
| `intent.rkt` | 效果即数据：`update`（状态意图）+ `edit/select/scroll/spawn/post/invoke/open-doc`（效果意图） | 纯，无依赖 |
| `world.rkt` | `world` / `ctx` / `mode` / `app-event` / `drag` + 派生助手（`world-panels` / `world-panels+refs` / `world-ref->view` 等） | 纯数据 |
| `panel-ref.rkt` | **panel 稳定身份** `panel-ref`（leaf id / float key）+ 解析成当帧 view / panel | 纯 |
| `doc-kind.rkt` | **document 类型 → 命令表** 绑定：类型注册表 + per-document 表层（插拔 / 覆盖 / 还原） | 纯 + eq 哈希 |
| `base-keys.rkt` | 基础小表：`edit-keys`（编辑）/ `motion-keys`（移动）/ `pointer-keys`（指针）/ `focus-keys`（面板间焦点） | 纯命令 |
| `role.rkt` | **leaf 角色注册表**：`role → 行为`（`splittable?` / `close` 策略） | 纯 |
| `ops.rkt` | **操作根对象的原语层**：`layout-op`/`mount-view`/`clear-view`/`show-hide-toggle-delete-pane`/`split-pane`/`focus-on`/`focus-leaf`/`focus-move`/`focus-insert`/`focus-cursor-*`/`focus-select*` … | 纯构造器 |
| `resource.rkt` | **资源管理**：`open-document!` 造 buffer+view 并绑类型；`view-into` 替换进布局 | 不纯（造 core 对象） |
| `step.rkt` | `world-step` / `world-step*`：事件 → 新 world + intent 列表 | **纯** |
| `render.rkt` | `world` → bytes（布局→panel→patch）+ **焦点边框配色投影** `world-display-panels`；cache 由 loop 持有 | 只读 core + 输出 |
| `loop.rkt` | `run-app`：查真实终端尺寸 → 画首帧 → 循环（读事件 / 折 inbox / 执行 intent / 合并重绘） | **不纯（唯一）** |
| `main.rkt` | 入口：再导出公共 API 面 `api/main.rkt` | — |
| `api/` | **公共 API 面**：每个实现模块一个同名功能转发模块 + 聚合 `api/main.rkt`（见 `api/README.md`） | 只转发 |

## 最小用法

```racket
(require "../edit-tui/app/api/main.rkt")   ; 公共面（推荐）；app/main.rkt 同样可用

(define my-keys
  (keys
   [(key 'left)  focus-cursor-left]   ; ops 的状态模型函数：吃 ctx，内部解析主体 view
   [(key 'b 'ctrl) (λ (ctx) (quit))]))

(run-app (make-world #:area (rect 0 0 80 24)
                     #:layout my-layout
                     #:focus my-view
                     #:keytable (make-keytable my-keys)))
```

## 命令约定

- 命令是**纯的**：`(λ (ctx) (listof intent))`。
- 需要改 world → 返回 `(modify f)`（`f : world → world`）；
- 需要动 core → 返回对应效果意图（`edit` / `select` / `scroll`），
  没有专用意图的用 `(invoke thunk)` 兜底；
- 文档编辑优先用 `ops.rkt` 的 `focus-*`（吃 `ctx`，内部解析主体 view：键盘 = focus，
  鼠标 = 命中 / 拖动主体；无主体 → no-op）。命令表**只引用这些名字**，
  不手写 `(edit (ctx-view ctx) …)`、不 require core（见 `base-keys.rkt`）。
- 改 world 字段走 `world.rkt` 的**原子转换**（`world-focus-on` / `world-resize` /
  `world-set-status` / `world-set-pending` / `world-set-drag` / `world-set-layout` /
  `world-set-floats` / `world-stop`）；step / ops 不裸 `(struct-copy world …)`。
- 命令**不直接改 core**，所以能 headless 重放（见 `temp/23-app-loop.rkt`）。

## 焦点边框配色（render 投影，不新增状态）

core 的每个边框格只能有一个 face；**相邻面板共享的 1 格接缝**上靠 `panel.weight` 争色
（同 `deep` 时 weight 大者赢，见 `core/view/border.rkt`）。所以 app 只用两步：

1. 主题给两个 face：`'window-border`（普通）/ `'focused-border`（焦点）（见 `theme/frame.rkt`）；
2. `render.rkt` 每帧把**焦点 ref** 对应的 panel 投影成 `face='focused-border` + `weight=1`，
   其余保持各自声明的 face（默认 `'window-border`）= 同一个普通色。

```racket
;; world.rkt：一次 solve，panels 与 refs 严格同序
(world-panels+refs w)      ; → (values (listof panel) (listof panel-ref))
;; render.rkt：纯投影，不改 world / layout
(world-display-panels w)   ; 焦点那块 → focused-border + weight 1
```

`weight` 是关键：只改 face 的话，焦点框在与邻居的共享接缝上会被邻居的普通色盖掉；
抬高 weight 后它的整圈（含接缝）都是焦点色。焦点切换 → 投影变 → `same-frame?` 为假 →
自动重绘，不需要额外的“换边框色”状态或命令；浮窗/普通面板的 face 也各按自己声明。

## 浮层：浮窗 + 临时操作表（`open-overlay` / `close-overlay`）

语法补全这类场景：输入 → 浮窗弹出 + 挂一张临时表 → 选中 / 取消 → 关窗 + 拆表，
且**浮窗永不占焦点**。

- **浮窗**：`add-float` / `remove-float`（`layout/float.rkt`）；不进布局树、deep 高、`float-ref` 身份。
- **临时表**：`push-mode` / `pop-mode` 压进 `world.modes` 栈；它在 `active-tables` 里是**最高层**，
  所以能遮蔽 / 新增操作。
- **成对**：`(open-overlay key float table)` = 弹窗 + 挂表；`(close-overlay key)` = 关窗 + 拆表。
  同一把 `key` 命名浮窗与模式（mode 名 = float key）。
- **不占焦点**：`world-focus-on` 只收 leaf（`focusable-ref?`）；点浮窗的默认行为 no-op。
- **画选中项**：`world-overlay-views` = 焦点 view + **拥有活动模式的浮窗 view**，交给 core 画 overlay。
  注意：浮窗 view 在 `panels-sync!` 前是 1×1，设选区要 `#:ensure? #f`，否则会被 `ensure`
  水平滚走（`temp/31-completion.rkt` 有示例）。

示例：`temp/31-completion.rkt`。

## 异步模型（暂定：下一事件时处理）

- `(spawn id thunk)`：loop 起线程算，完成后把 `(app-event 'task-done (list id v))`
  放进 **inbox**（`async-channel`，loop 的成员，不是 world 字段）。
- inbox 在**下一个终端事件到达时**与它一起折叠（`world-step*`）。
- 要「立即处理」：只改 `loop.rkt` 里 `(read-event)` 那一句，让等待集合也含 inbox
  （或走 `on-source`）；`world-step` / `world-step*` 一行不动。
- 任何内部事件都是**数据**（`app-event`），可打日志、可测、可重放。

## 扩展点

| 想加 | 加在哪 | 不动什么 |
|---|---|---|
| 新 document 类型 | `define-doc-kind!` + 小表；`open-document! #:kind` | step / loop |
| 新命令 / 键位 | `keytable-merge!` 或 `keys` 表 | loop / step |
| 某文档临时覆盖 / 插件插拔 | `buffer-add-table!` / `buffer-remove-table!` | 类型表 / 全局表 |
| 新编辑算子 | 在 `ops.rkt` 加一个 `focus-*`（吃 ctx，内部 `focus-edit` / `invoke`）；命令表只引名字 | step / loop |
| 新布局 / 焦点操作 | 加进 `ops.rkt`（`layout-op` 包 tree→tree；`focus-on` 包 world-focus-on） | step / loop |
| 运行期开文档 | 返回 `(open-doc make f)`（make 造、f 装进布局） | step |
| 新 world 字段 | `world` 加字段 + `modify` | 语义不变 |
| 新内部事件 | `world` 的 `internal` 注册表：`kind → (world payload → world + intents)`；或 `app-event` + `step-internal` | 其它 kind |
| 新面板 / 布局 | `layout` 的 tree / float | loop |
| 新模式（minibuffer / which-key） | `world-modes` 栈（暂定最小） | 命令表 |
| 新效果类型 | 加效果 struct + `loop.rkt` 的 `run-intents!` 一个 `match` 分支 | step |

`internal` 是「不改 `step.rkt` 就能加内部事件」的口子；`invoke` 是「不改 intent 集
就能接 core 新操作」的逃生舱。两者都刻意保留。

## 操作原语层（`ops.rkt`）

命令里不再手写 `(modify (λ (w) (struct-copy world w [layout …])))`，而是调用命名原语。
所有原语都是**纯构造器**，返回 `(listof intent)`（正是命令的返回类型）：

```racket
(define global-keys
  (keys
   [(key 'b 'ctrl) (λ (ctx) (toggle-pane 'tree))]
   [(key 's 'ctrl) (λ (ctx) (split-pane (focused-leaf-id ctx) 'lr 'new))]
   [(key 'm 'ctrl) (λ (ctx) (mount-view 'tree some-view))]
   [(key 'p 'ctrl) (λ (ctx) (add-float (make-float 'pop #f rect)))]))
```

| 类 | 原语 |
|---|---|
| layout | `layout-op`（通用 tree→tree）· `mount-view` `clear-view` · `show-pane` `hide-pane` `toggle-pane` `delete-pane` · `split-pane` `move-pane` `resize-seam` |
| **切分 / 关闭** | `split-left` `split-right` `split-up` `split-down`（只对 splittable role 生效）· `split-focused` · `splittable-leaf?` · `close-focused`（按 role 的 close-policy） |
| floats | `floats-op` · `add-float` `remove-float` |
| modes / overlays | `push-mode` `pop-mode` · `open-overlay` `close-overlay`（浮窗 + 临时表，成对；见下“浮层”） |
| focus | `focus-on`（指定 ref）· `focus-leaf`（指定 leaf id）· `focus-move`（面板间方向，ctx 感知） |
| **focus（文档）** | `focus-edit`（通用）· `focus-insert` · `focus-delete-backward` `focus-delete-forward` · `focus-undo` `focus-redo` · `focus-cursor-left/right/up/down/home/end` · `focus-select` `focus-select-range` `focus-select-begin` `focus-select-update` · `focus-scroll` |
| session | `show-status`（写状态行）· `quit`（退出） |

单操作命令直接 `(λ (ctx) (hide-pane 'tree))`；多操作 `(append (hide-pane 'tree) (focus-leaf 'editor))`。
它只是“命名 + 集中”，**不新增状态、不改 world 字段**；底层仍是 `modify` / `edit` / `invoke`。

### leaf role 注册表（`role.rkt`）

leaf 有一个自由符号 `role`（`pane #:role`，默认 `'panel`）。app **不写死** role 名，
而是查注册表决定行为：

```racket
(define-role! 'editor  #:splittable? #t #:close 'keep-last)   ; 内置
(define-role! 'panel   #:splittable? #f #:close 'hide)        ; 内置
(define-role! 'tool    #:splittable? #t #:close 'delete)      ; 自定义
```

| 字段 | 含义 |
|---|---|
| `splittable?` | `split-left/right/up/down` 是否作用于该 role 的 leaf（新块**继承原 role**） |
| `close` | `'hide` 只隐不删 · `'delete` 直接删 · `'keep-last` 删，除非是该 role 最后一块 → 清 view 保留占位 |

- 未注册的 role → 保守默认：不 splittable、`close='hide'`。
- `role-of`（名→行为）· `role-known?`；在 `role.rkt` 内置注册 `'editor` / `'panel`，可覆盖。
- `close-focused` 按 `(role-close-policy (role-of (leaf-role l)))` 分派；`split-focused` 按
  `(role-splittable? (role-of (leaf-role l)))` 判断。不再有硬编码的 `'editor`。

编辑区初始可以是**空 panel**：`(pane 'editor #:view #f #:role 'editor)`；之后 `mount-view` / `open-doc` 装内容。
`keep-last` 的不变量：该 role 永远至少有一块 leaf，所以关空后仍能 split / open。
普通面板之所以只隐不删：面板是声明式 `spec` 的固定区域，删了就丢了 view/边框/dock，
要恢复得另存一套“面板规格”状态；隐藏天然保留。

## 能力评估（加新功能前先看这张表）

**骨架现在够用：**

- 事件规范化 → token → 命令（含前缀序列 / 冲突报错 / 运行时并表）；
- world 上的纯变换：布局、焦点、pending、drag；
- 键盘 / 鼠标统一派发路径（鼠标也能绑 `(mouse …)` 命令）；
- 拖缝 / 拖选 / 滚轮 / 点击落点；
- 批量折叠 + 单次合并重绘；
- 异步 spawn + 内部事件回投（下一事件时处理）。

**骨架暂不管（要加就先扩这里）：**

- **minibuffer / 输入模式**：`command-input` spec 已随命令表存着，但 `step` 目前只
  把 prompt 写进 status；接法是在 `run-command` 的 `command-needs-input?` 分支 push
  一个 mode（`world-modes`），mode 收字符、回车后回调 —— 不需要动 loop。
- **前缀超时 / which-key**：`world-pending` 是数据，接法 = 在 loop 的等待集合里加
  `alarm-evt`（走 `on-source`），超时向 inbox 投 `(app-event 'prefix-timeout '())`；
  which-key 用现成的 `keytable-hints` + `world-pending` 渲染成一个 float。
- **idle / 动画 / 光标闪烁**：用 `async-channel` + `alarm-evt` 注册进 inbox 即可；
  非阻塞模式的 `loop-input-noblock` 不在此骨架内（本骨架统一阻塞等待）。
- **多窗口 / 多 focus**：world 目前是单 `focus`；要改成 focus 栈或 per-panel 状态。
- **状态栏富渲染**：`status` 现在是字符串；要富内容就换成数据 + 一个
  `world → (listof pane|piece)` 的装饰注册器，在 `draw-world` 里 append。

## 不冗余审计（为什么是这些类型）

刻意**没有**的东西，和它们被什么替代：

| 没有 | 替代 |
|---|---|
| `redraw` intent | world 的 `dirty?`（`modify` / 视觉效果自动置位），loop 统一重绘 |
| `quit` intent | `ops.rkt` 的 `(quit)` op（命名构造器，仍不引入 quit intent 类型） |
| `message` intent | world 的 `status` 字段 |
| `set-point` 效果 | `(select view (selections-one (caret pt)))`（core 已有 `caret`） |
| `focus` 效果 | world 的 `focus` 字段（纯变换） |
| `ctx` 里重复的 row/col/mods | 从 `ctx-event` 派生（`(mouse-position …)` / `key-event-mods`） |

命名冲突提醒：core 已导出 `change` 与 `run`，所以状态意图构造糖叫 `modify`、
效果意图叫 `invoke`。别改回去。

## 暂定清单（改代码时同步本清单）

1. `area` 用 core `rect`；`status` 是字符串。
2. `modes` 是 `world.modes` 栈（栈顶优先，可覆盖全局）；`push-mode`/`pop-mode` + `open-overlay`/
   `close-overlay` 已实现；`on-event/on-exit/state` 未加。
3. `drag` 是**结构化纯数据** `(drag kind subject data)`：`kind='seam` 由 step 解释，
   其余（如 `'select`）由类型命令解释；`subject` 是 **panel-ref**；`data='select` 存 `(ref anchor)`。
4. `internal` 注册表是内部事件扩展点；默认只认 `'task-done`。
5. `edit/select/scroll` 覆盖了现有 core 操作；其余用 `invoke`。
6. `panels-sync!` 放在 `render.rkt`（它是“本帧布局”的副作用）；要更纯可挪进 loop。
7. 异步只在“下一终端事件”时处理（已确认可接受）；接口已为“立即处理”留好。
8. 命令约定 `(λ (ctx) (listof intent))`；旧式 0 参过程需改写。
9. **document 类型绑定已实现**：类型注册表 + per-buffer 表层，解析在 `step.rkt` 的
   `active-tables`；类型元数据存 eq 哈希（不放 core 的 document 槽，因为槽随版本 fork）。
10. 层序已实现：`mode > document 自己的层 > kind 默认表 > 全局表`。
    “插件全局层”尚未单独建模（可加在 document 层与 kind 层之间）。
11. `open-doc` intent 采用 `(make f)`：`make` 不纯造对象，`f` 纯变换 world；
    所以 `run-intents!` 现在把 world 当折叠值穿下去。
12. 切焦点统一走 `world-focus-on`（收 **panel-ref**，会清 `pending`）；不要裸改 `focus` 字段。
13. **引用稳定（④）已实现**：`world.focus` / `drag.subject` / `ctx.ref` 都是 `panel-ref`；
    view / panel 由 `world-ref->view` / `world-ref->panel` **当帧解析**。所以 `tree-set-view`
    替换 view、布局重排，引用都不悬空。鼠标表按主体 ref 解析；键盘按 focus ref 解析。

## 面向未来：焦点状态机 + 可插拔命令（部分已实现）

目标模型：**焦点指向「文档」，文档类型决定用哪套命令表；表是有序层，插件可随时插拔 /
覆盖 / 还原；面板 + 编辑区；document 表示一切（文件树 / state 树也是 document）。**

### 已实现（见 `doc-kind.rkt` / `base-keys.rkt` / `resource.rkt`）
① **document 类型 → 命令表 的绑定（穿透 focus）**

- `(define-doc-kind! 'text #:keymaps (list edit-keys motion-keys))`：类型 → 默认表，
  小表分开定义、`make-keytable` 合并（冲突作者期报错）。
- `(open-document! res name text #:kind 'text)`：资源管理在 document 创建时绑类型。
- 解析在 `step.rkt` 的 `active-tables`，按 **subject ref**：键盘 = focus，鼠标 = 命中 panel / 拖动主体。
  `ref → view-buffer → buffer-kind → kind 表`。自定义 document（文件树 / state 树）只注册
  自己的 kind + 小表，不改 app。
- 已验证：`temp/24-doc-kinds.rkt`（换焦点就换表）。

② **per-document 表层（插件覆盖 / 还原）**

- `(buffer-add-table! b kt)` / `(buffer-remove-table! b kt)`：document 自己的层，优先于 kind 默认表。
- 层序：`mode > document 自己的层 > kind 默认表 > 全局表`；查表本就是“第一个非 unbound 胜出”，
  所以覆盖 / 还原天然成立，无需改 `keytable` 的冲突语义。
- 尚未做的：把“插件全局层”作为独立一层建模（现在插件要么加到全局表，要么 per-document 加）。

③ **行为即命令：鼠标默认行为已下放**

- `step-mouse` 现在只做：拖缝（布局 chrome，优先）+ 通用路由（查 active-tables）+ 极简兜底（点面板只聚焦）。
- 「点击落点 + 起选 + 拖选」成为 `base-keys.rkt` 的 `pointer-keys` 表，合并进需要的类型：
  `(define-doc-kind! 'text #:keymaps (list edit-keys motion-keys pointer-keys))`。
- 非编辑器类型（file-tree）给自己的表加 `(mouse 'press 'left)` 即可，行为完全自己定。
- 关键：鼠标命令按**主体 ref 的类型表**解析（点哪个 panel 取哪个 panel 的 ref；
  拖动中用拖动主体），所以点未聚焦的编辑器也能直接落点，指针移出面板也不断表。
- 已验证：`temp/24-doc-kinds.rkt`（tree 点击→树命令；editor 点击→落点+起选）。

④ **引用稳定 / 操作对象统一（`panel-ref.rkt`）**

- 「焦点 / 拖动主体 / ctx 主体」不再是 view 值或每帧 panel，而是**稳定的 panel 身份**：
  `(struct panel-ref (kind id))`，`kind ∈ 'leaf | 'float`；`(leaf-ref id)` / `(float-ref key)`。
- view / panel 由 ref 按**当前** tree / floats 解析：`world-ref->view` / `world-ref->panel`。
  所以 `tree-set-view` 替换 view、布局重排，ref 都不悬空。
- `world.focus` 现在是 `panel-ref`；`world-focus-view` 解析出当帧 view（render / 编辑用）。
  `world-focus-on` 接受 ref 并清 `pending`。
- `drag = (drag kind subject data)`：`subject` 是 ref；`data` 存 ref（而非 panel 值）。
- `ctx` 同时给 `ref`（稳定）+ `view`/`panel`（当帧解析，便利）。
- 已验证：`temp/24-doc-kinds.rkt`（替换聚焦 leaf 的 view → 焦点 ref 不变，命令表随新 document 类型切换）。

### 未实现 / 可继续做的小尾巴

### 不需要改的（已足够承载）

- `world-step` / `world-step*` 签名、intent 集、`modify`/`invoke`、inbox + `internal` 注册表：
  后续扩展都能在不改这些的前提下实现。
- 布局：`world.layout`(tree) + `world.floats` 已是纯数据，动态替换 / 显隐 / 重排都有原语；事件层不关心
  document 是什么，只关心「panel 命中」和「类型表」。
- 未做的小尾巴：隐藏 leaf 的 ref 仍能解析出 view（只影响编辑语义）；
  “插件全局层”尚未作为独立一层建模。
- **`focus-keys` 已拆出**：面板间焦点移动（`C-w ←/→/↑/↓`，用 core 的 `panel-neighbor`），
  与文档类型无关，通常合并进全局表 `(make-keytable global-keys focus-keys)`。
  因为焦点是 ref，它只改 `world.focus`，反查邻居 panel → ref 即可。

## 迁移旧 demo

`temp/18`、`temp/21` 的 `run-tui!` 把 dispatch / draw / 状态糊在一起。迁移到本骨架：

1. 把状态搬进 `world`（含 drag / pending / focus）；
2. 把每个 `dispatch-*` 分支改写成 `step` 里的一支，产出 intent；
3. 把 `(draw!)` 删掉（loop 统一重绘）；
4. 把命令从 `(λ () …)` 改成 `(λ (ctx) …)` 并返回 intent。

对照实现见 `temp/23-app-loop.rkt`。
