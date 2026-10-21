# edit-tui

重建中的编辑器基础设施：纯 State + action，布局 / 编辑 / 文件树 / 渲染都在
`*/api.rkt` 之后，core 只做 buffer / view / 几何 / 渲染。

## 约束

```text
1. State 是纯值：不存 engine 句柄、不存 IO 结果，只存 id / 数据 / 纯迁移结果。
2. 所有副作用都经 action：step 产出 action，boot 解释；命令只返回
   (values state actions)。
3. core buffer / view 只有一个拥有者：engine/store.rkt（骨架层）。
4. 跨领域只经 */api.rkt；领域实现文件是私有的。上层可以 require 下层 api，
   下层永远不 require 上层。
5. 渲染是纯投影：state/layout -> core panel -> bytes；渲染不改 view 尺寸以外的状态。
6. 键位用 (tag . bytes)，不用 M- 前缀（窗口管理器会吞）；终端不能区分的组合
   共用 token（C-i = Tab）。
7. 主题是 require 安装的；颜色 / 样式只在 config/theme/ 里。
```

## 边界入口（不要绕过）

```text
view -> resource      resource-of-view           O(1) 索引 + 存在性检查
focus -> resource     app-state-focus-resource   现算，不缓存
鼠标命中              layout-hit                 一次 solve 得到 panel / seam / content
保存起点              start-save                 有 path -> write-file；无 path -> save-path
关闭 / 退出确认       begin-pending              设置 pending + 开第一项 confirm
prompt id 匹配        active-prompt?             submit / cancel 的唯一入口
close-resource action close-resource-action      action 数据的唯一构造点
```

这些函数是边界：其余代码只调用它们，不重复判断 `#f` / 过期 id / 索引维护。

## 分层

```text
层           目录                                          纯?         可以 require
------------------------------------------------------------------------------
骨架-值      core/base  core/command  core/face  core/panel  纯       repo core 的纯值
骨架-布局    core/layout(config/tree/solve/ops)              纯       骨架-值
骨架-资源    core/resource                                 纯       骨架-值
骨架-引擎    core/engine(action/store)                      有句柄   repo core
骨架-投影    core/projection  render                        纯       布局 / 值 / core render
骨架入口     core/skeleton.rkt                              纯聚合   上面所有 core api.rkt
------------------------------------------------------------------------------
插件         edit  chrome  filetree  resources             纯       core/skeleton.rkt + app/state
App 基础     app/state app/keymap app/event app/action        纯       core/skeleton.rkt
App 交互     app/placement                                  纯       core/skeleton + app/state
App 编排     app/step                                        纯       core/skeleton + 插件 api + app 基础
Boot         boot(actions/frame/sync/tui-adapter/loop)      有副作用  全部 + tui
入口         main.rkt                                        纯聚合   core/skeleton + 插件 + app + boot
```

依赖方向（单向）：

```text
repo core (buffer / view / rect / text / render)
        ↑
edit-tui/core: base / command / panel / face
        ├─ layout（config 模型 + tree/solve/ops）──→ projection ──→ render
        ├─ resource
        └─ engine（core buffer/view 的唯一拥有者）
                ↑
      core/skeleton.rkt      ← 插件唯一能 require 的骨架入口
        ┌───────┴────────┐
      edit      chrome   filetree   resources   ← 插件：只组合骨架 + app/state
        └───────┬────────┘
             app/step ──→ boot ──→ tui
```

规则：

- **插件只 require `core/skeleton.rkt`**，不直接 require `core` 实现模块、`boot` 或渲染；
- 插件之间只经对方 `api.rkt`；
- 插件可以 require `app/state.rkt` / `app/keymap.rkt` / `app/event.rkt` /
  `app/action.rkt` 这些 app 基础值；
- `core/engine` 不认识 app：`view-action` 词汇在 `core/engine/action.rkt`；
- `app/step.rkt` 是唯一编排插件的地方，且只 require 插件 `api.rkt`；
- `boot` 是唯一有副作用的启动 / 运行时层。

## 项目结构

当前只做了第一步拆分：**core / boot 是明确分类的；插件、config、app、render、
demo 先留在根目录**，等 boot 和插件插入方式定下来再继续迁移。

```text
edit-tui/
  main.rkt                 唯一聚合入口：core/skeleton + render + 插件 + app + boot

  core/                    核心数据表示 / 实现
    skeleton.rkt           骨架入口（插件只 require 这个）
    base/api.rkt           rect / point / range / selection / 显示列
    command/               table / key / api
    layout/                config / tree / solve / ops / api
    focus/                 model / api
    face/                  model / api
    resource/              model / api
    projection/            borders / geometry / api
    engine/                action / store / api

  boot/                    启动 / 运行时流程
    actions.rkt            action 解释（唯一副作用入口）
    frame.rkt              state + cache -> bytes
    sync.rkt               UI panel 同步
    tui-adapter.rkt        tui raw 事件 -> app 事件
    loop.rkt               render / read-event / step / run-actions
    api.rkt

  config/                  纯配置 / 绑定
    layout/default.rkt
    keymap/default.rkt   全局 / 输入 / placement 表
    keymap/buffer.rkt    buffer 创建时匹配 per-doc 键表
    theme/default.rkt

  edit/  chrome/  filetree/  resources/   插件（暂时留在根目录）

  app/                     应用状态 / 命令 / 编排（暂时留在根目录）
  render/                  输出渲染（暂时留在根目录）
  demo/  test/
```

## API 边界

**允许**（非实现层只能 require）：

```text
main.rkt
*/api.rkt
config/*（配置 / 键位绑定）
core/skeleton.rkt（骨架公共入口）
外部 repo/core/*（只读、纯）
```

**不允许**：

```text
core 的实现模块（插件 / app 里）
core/layout/tree.rkt  core/layout/solve.rkt  core/layout/ops.rkt
core/panel/model.rkt  core/command/table.rkt  core/projection/geometry.rkt
core/engine/store.rkt  core/engine/action.rkt
boot/*.rkt  app/*.rkt  edit/*.rkt  chrome/*.rkt  filetree/*.rkt
... 任何非 api.rkt 的实现文件
```

`boot` 是唯一允许 require 所有层的副作用 / 启动层。

## API 面（概要）

```text
main.rkt                  唯一聚合入口：core/skeleton + render + 插件 + app + boot
                          （没有顶层 api.rkt；纯配置不聚合，直接 require）
core/skeleton.rkt     骨架：base / panel / layout / focus / face /
                          resource / command / projection / engine
                            - core/base/api.rkt          rect / point / range / selection / 显示列
                            - core/layout/api.rkt        配置模型 / split tree / solve / ops / seam / drag
                            - core/resource/api.rkt      store / resource / save / prompt / 路径
                            - core/focus/api.rkt         焦点导航
                            - core/command/api.rkt       command-table / keys / key token
                            - core/engine/api.rkt        buffer/view 持有 + view action 词汇
                            - core/projection/api.rkt    layout->render-panels / hit / content-hit
render/api.rkt            render-layout / layout-sync!
edit/api.rkt              nav / scroll / insert / edit-action commands / self-insert
chrome/api.rkt            status / input（含 input-start / input-result 服务 API）
filetree/api.rkt          model / lines / scan / commands / install
resources/api.rkt         model / lines / sync / commands / install
app/api.rkt               event / state / keymap / action / commands / placement / step
boot/api.rkt              plugin / host / start / actions / frame / sync / tui-adapter / loop
```

### core 能力面对应关系

core 不整包导出——按能力拆开，而且各自的形式不同：

```text
能力                                         导出位置                  形式
--------------------------------------------------------------------------------
纯值：rect / point / range / selection /       core/base/api.rkt       直接 re-export
      selections / 显示列                                               （只 require repo core 值模块）
buffer / view：读 + 写 UI view + 编辑 action   core/engine/api.rkt     包装（engine-* +
                                                                        view-action），不导 core 构造器
渲染：layout -> panels -> bytes                render/api.rkt          包装（render-layout /
                                                                        layout-sync! / render-pieces）
layout -> core panel / 命中投影                core/projection/api.rkt 包装（layout->render-panels /
                                                                        layout->hit-panels / layout-hit /
                                                                        layout-content-hit /
                                                                        layout-content-rect）
布局几何（rect / panel）                       core/layout/api.rkt     骨架自己的面
                                              core/panel/api.rkt      （内部用 core 值）
```

- 插件只看到 `core/skeleton.rkt`（含 base / engine / projection，**不含** render）；
- 编辑能力以 `view-action` 词汇暴露（`core/engine/action.rkt`），插件发 action，
  只有 `boot/actions.rkt` 解释成 core 调用；
- 直接 require repo core 的只有骨架内部：`core/base/api`、`core/engine/store`、
  `core/layout/{tree,solve,ops}`、`core/projection/{borders,geometry}`、
  `render/{core,layout}`、`core/focus/model`。插件 / app / boot 都不直接摸 repo core。

## 布局模型

```text
layout = split tree + panel 资源

node  = leaf(panel-id)
      | split(id, axis, left, right, ratio)

panel = id / kind / views / active
        fixed-w / fixed-h
        hidden? / restore
        borders / face / weight
```

关键约定：

- `rect` 不进树，由 `layout-solve` 计算；
- 渲染列表 `(listof core panel)` 是投影，不是结构真相；
- 只有 `kind = 'editor` 的 panel 默认能 split（由 config 决定）；
- split 新 panel 是空 panel，不抢焦点；
- 固定尺寸是 `fixed-w` / `fixed-h` 实际值，`#f` = flex；
- 隐藏 leaf 仍在树里，兄弟吸收父 rect；
- 显示按隐藏时记录的 `rect / parent-rect` 比例恢复；
- 删除 leaf 时父 split 塌缩到兄弟；
- 最后一个 editor 用 `layout-panel-clear-content` 保留 slot；
- 接缝属于 split 节点；拖动改 ratio，再重新 `layout-solve`；
- 固定轴阻止接缝拖动；
- min / max 不进状态，由 config 在 API 边界使用；
- 焦点回退顺序：兄弟子树 → 逐层向上 → 第一个可聚焦 panel；
- 一个 panel 槽可挂多个 view，顺序切换用 `layout-panel-cycle-active-view`。

## 统一 API

```racket
(require "edit-tui/main.rkt")
```

### base

```racket
rect rect?
rect-x rect-y rect-w rect-h
rect-right rect-bottom
rect-inset rect-inset-sides
rect-contains?
```

### panel

```racket
(make-panel id kind #:views #:active #:fixed-w #:fixed-h
            #:hidden? #:restore #:borders #:face #:weight)
(make-empty-editor-panel id)
(panel-view p)
(panel-visible? p)
(panel-set-views p views [active])
(panel-set-active p view-id)
(panel-set-fixed p axis value)
(panel-set-hidden p hidden? [restore])
(panel-set-restore p restore)
```

### config

`core/layout/config.rkt` 是**布局配置模型**（骨架的一部分）：只有规则的数据形状、
构造 / 查询、通用 default rule，不知道 `editor` / `sidebar` / `status` 这些具体 kind。

```racket
(make-panel-rule #:splittable? #:hideable? #:deletable? #:focusable?
                 #:min-w #:max-w #:min-h #:max-h)
(make-layout-config #:rules #:default)
default-panel-rule      ; 未知 kind 的通用 rule
empty-layout-config     ; 没有任何 per-kind 规则
(config-panel-rule config kind)
(config-panel-splittable? config kind)
(config-panel-hideable? config kind)
(config-panel-deletable? config kind)
(config-panel-focusable? config kind)
(panel-rule-min-size rule axis)
(panel-rule-max-size rule axis)
```

具体 app 的 kind 规则是 **configuration**（纯数据），在 `config/layout/`：

```racket
(require "edit-tui/config/layout/default.rkt")
default-config    ; editor / sidebar / status 的 split / hide / min / max
```

- `config/` 只放配置（布局 / 键位 / 主题），没有 `api.rkt` / `model.rkt`；选择配置 = require 那个模块；
- `main.rkt` 不聚合纯配置（和主题一样由宿主直接 require）；
- `core/skeleton.rkt` 和 `core/layout/ops.rkt` 都不认识 `config/layout/`；
- layout 结构操作把 config 当**必填参数**：
  `layout-split` / `layout-panel-remove` / `layout-panel-hide` /
  `layout-seam-resize` / `layout-seam-drag-*`；
- app 把配置放进 state：`(app-state-layout-config state)`；
  demo / 宿主构造 state 时传 `#:layout-config default-config`；
- 换一套规则 = 换一个 config 值（或换 require 的配置模块），layout 骨架不动。

### keymap 配置

所有 `key-sequence -> command` 绑定都在 `config/keymap/default.rkt`：

```racket
(require "edit-tui/config/keymap/default.rkt")
default-keymap
```

per-document 键表在 **buffer 创建时**匹配：

```racket
(require "edit-tui/config/keymap/buffer.rkt")
(buffer-key-table path text)   ; -> command-table
```

`resource-open` 的 `#:key-table` 是**必填**参数（没有可选默认表）：

```racket
(resource-open store ... #:key-table (buffer-key-table path text))
```

表存进 resource，`app/step` 通过 `resource-command-stack` 查表。

`keymap` 是 `app/keymap.rkt` 的纯值（不在骨架），只保留应用级槽位：

```text
overlays         全局 fallback stack：
                   app-command-table    C-b filetree / C-s save / C-q quit
                   global-command-table 光标移动 + C-x focus / sidebar tab + C-w split
input-stack      输入栏独占 stack（Esc/C-g Enter C-h/C-t …）
placement-table  placement 临时表（Enter/Esc/方向）
```

表按类别拆再组合：

```text
cursor-command-table    方向 / Home / End / 翻页 / C-a / C-e / C-f
focus-command-table     C-x 方向 / C-x b 切换 sidebar tab
layout-command-table    C-w 方向 / C-d close-panel（删除/清空当前 editor panel）
global-command-table    cursor + focus + layout
app-command-table       filetree 显隐 / save / quit
edit-command-table      cursor + 插入 / 删除 / 历史（buffer 局部）
filetree-command-table  cursor + Enter / C-r / C-h
resource-panel-command-table  cursor + Enter / C-r
```

非输入态查表顺序：

```text
动态 overlays（placement 等模态）
  > 焦点 resource / panel 的局部表
    > keymap.overlays 全局表
```

**局部优先**：同一按键同时出现在局部表和全局表时，局部表胜出。
输入态仍然直接替换成 input-stack，不与全局/局部表合并。

- 命令实现仍在 edit / chrome / filetree / app；config 只做绑定；
- `app-state` 持有全局 keymap：`(app-state-keymap state)`；
- `app/step` 从这里取 overlays / input-stack；placement 取临时表；
- 编辑 / 文档键表不再在 app-state，而是在 resource 上；
- filetree 安装通过 `#:panel-stack` 接收 `filetree-panel-stack`；
- 换键位 = 换 `config/keymap/` 的模块，插件与 step 不动。

### layout 状态

```racket
(make-layout #:root #:panels #:focus #:next-split-id)
empty-layout
(make-leaf panel-id)

(layout-panel-add l p)
(layout-panel l id)
(layout-panel-resources l)
(layout-panel-ids l)
(layout-visible-panel-ids l)
(layout-panel-update l id f)
(layout-panel-visible? l id)
(layout-panel-fixed-size l id axis)
(layout-subtree-visible? l node)

(layout-focus l)
(layout-set-focus l id)   ; id 可以为 #f：焦点置空
(layout-solve-key l)      ; (root . panel-map)：只描述 solve 依赖的结构
```

### panel 内 view 切换

```racket
(layout-panel-view-ids l id)
(layout-panel-active-view l id)
(layout-panel-set-active-view l id view-id)
(layout-panel-cycle-active-view l id [step])  ; 1 下一个，-1 上一个
```

### 结构操作

```racket
(layout-split l target-id dir new-panel-id #:ratio #:config config)
(layout-panel-attach l target-id dir panel #:ratio)
(layout-panel-remove l id #:config config)
(layout-panel-clear-content l id)
(layout-panel-set-fixed l id axis value)
(layout-split-set-ratio l split-id ratio)
```

### 隐藏 / 显示

```racket
(layout-panel-hide l area id #:config config)
(layout-panel-show l area id)
(layout-focus-fallback l config id)
```

### layout-solve / 接缝 / 拖动

```racket
(layout-solve l area)                  ; -> layout-solution
(layout-solution-panel-rects s)        ; panel-id -> rect
(layout-solution-split-rects s)        ; split-id -> rect
(layout-solution-seams s)              ; (listof seam)
(layout-panel-rects l area)            ; panel-id -> rect
(layout-split-rects l area)            ; split-id -> rect
(layout-seams l area)                  ; (listof seam)
(layout-seam-at l area row col)        ; seam | #f
(layout-panel-id-at l area row col)    ; panel-id | #f

(layout-seam-resize l area split-id delta #:config config)
(layout-seam-drag-start l area row col #:config config   ; -> drag | #f
                        #:seam seam #:solution solution)  ; 可选：复用 layout-hit
(layout-seam-drag-move l area drag row col #:config config)
```

### 焦点导航

```racket
(layout-panel-focusable? l config id)
(layout-focusable-panels l area config)       ; view = panel-id
(layout-focus-panel-at l area config row col) ; panel-id | #f
(layout-focus-neighbor l area config from-id dir)
```

### 校验

```racket
(layout-validate l area config)  ; (listof violations)
(layout-valid? l area config)
```

### 投影

```racket
(layout->render-panels l area)                     ; view = active
(layout->render-panels l area #:focus-panel 'editor) ; + 焦点框（见下）
(layout->hit-panels l area)                        ; view = panel-id
(layout-hit l area row col)                        ; 一次 solve：panel-id / content / seam
(layout-content-rect l area panel-id)               ; 该 panel 的内容区 rect（拖选换算用）
```

#### 焦点窗高亮

焦点框不改布局、不改内容、也不进命中投影，做法是利用 core 的边框合成：

- 在焦点 panel 的边框格上再叠一个**空 core panel**（`view = #f`），
  `face = 'focused-border`，`weight` 比所有 panel 大；
- core 对同一格按 `weight` 取边框 face（`core/view/border.rkt`：
  “weight 大的边框格赢，焦点框抬边框用”），于是焦点框的 face 赢；
- 边框格位置要算对：
  - 自己画的边 → 就在 rect 边上；
  - 被邻居共享的边（共享边框时这条边是邻居画的）→ 缝在 rect 外一格，框外扩 1；
  - 谁都没画的边（屏幕外沿 / 没边框）→ 不画，避免盖内容；
- 焦点框只出现在 `layout->render-panels`，`layout->hit-panels` 不含它；
  隐藏的焦点 panel 不出框。

`weight` / `face` 都从 layout 的焦点 + panel 模型推出来，
渲染层只认 core panel；换颜色 = 换主题里的 `focused-border`。

### face

```racket
face?
face-fg face-bg face-attrs
face-empty
face-set-fg face-set-bg face-set-attrs
face-add-attr face-remove-attr face-has-attr?
compose-face
```

### render

```racket
rgb?
style?
define-theme!

render-piece
render-pieces
render-clear
face-fragment

(layout-sync! layout area)  ; panels + panels-sync!（尺寸写回 core view）
(render-layout layout area #:focus-panel #:cache #:sync?)
```

`render-layout` 默认 `#:sync? #t`，先把 panel 内容尺寸写回 view，再渲染。

`render-layout`：

```text
layout -> core panels
       -> render-display-patch
       -> render-pieces
       -> (values cache' bytes)
```

### theme 配置

布局 / 主题是纯数据，键位是绑定配置（含命令闭包）。它们都放在 `config/`、
直接 require；区别是主题 require 即全局安装，布局配置和 keymap 都是值
（分别放进 app-state 的 `#:layout-config` / `#:keymap`）。

主题放在 `config/theme/`：

```racket
(require "edit-tui/config/theme/default.rkt")
```

配置层是小表：

```racket
base-theme
frame-theme
chrome-theme
overlay-theme
```

安装层 append 成扁平表：

```racket
default-theme
(define-theme! default-theme)
```

require 即安装，换主题 = 换 require：

```racket
(require "edit-tui/config/theme/dark.rkt")
```

### 输入：标签 + 字节

输入的中间状态不转成 char / symbol，token 就是终端给的那一份：

```racket
(struct key-token (tag bytes))
```

- `tag`：`'key`（单字节）| `'ctrl` | `'alt` | `'utf8` | `'mod-seq`（CSI 带修饰）
  | 命名键 `'up 'down 'left 'right 'home 'end 'insert 'del 'pageup 'pagedown 'backtab`
- `bytes`：原始字节

boot 用 `tui:read-event/raw` 取 `(values type data mods)`，适配层直接
`(key-token type data)` 往下传；mouse / paste / resize 也保留原始载荷
（paste 是 bytes，写 buffer 时才解一次 UTF-8）。

绑定和事件是同一种表示，`key` 把可读写法编码成 ANSI 字节：

```text
(key 'a 'ctrl)      -> ('ctrl    . #"\x01")
(key 'A)            -> ('key     . #"A")
(key 'left)         -> ('left    . #"\e[D")
(key 'left 'shift)  -> ('mod-seq . #"\e[1;2D")
(key #\中)          -> ('utf8    . "中" 的 UTF-8)
```

命名键的多种终端写法（CSI `ESC[A` / SS3 `ESC OA` / 老式 `ESC[1~`）由
`raw-key-token` 按 tag 归一成一种规范字节，表里每个绑定只存一条。

终端不能区分的组合自然共用 token，所以不存在「死绑定」：

```text
C-i = Tab        C-m = Enter      C-[ = Escape     C-j = Enter（LF 归一成 CR）
```

**C-h 例外**：字节 8 传统上等同 Backspace，但多数终端的 Backspace 键发
127（DEL）。这里不把 8 归一成 127，`C-h` 保留成独立 token（`(key 'h 'ctrl)`），
输入栏用它做 head；Backspace 绑定用 127。若你的终端 Backspace 发 8，它会被
当成 C-h，把终端改成发 DEL 即可。

想真正区分 C-i / C-m / C-[ / C-j 得开 kitty keyboard protocol 或 modifyOtherKeys。

### app / 事件循环

```racket
(key-event token)
(mouse-event token row col)
(resize-event rows cols)
(paste-event bytes)
(internal-event kind data)
(quit-event)

(make-app-state #:layout #:layout-config #:keymap #:resources
                #:overlays #:pending #:area #:quit? #:flash
                #:drag #:select-drag #:pending-doc-changes
                #:key-owner #:key-owner-stack)

;; 显式键盘 owner：owner-stack 顶层 + layout stack，未绑定键仍可回落。
(app-state-set-key-owner state 'completion-menu stack)
(app-state-clear-key-owner state)

;; 鼠标拖动中的状态都是纯值：
;;   drag        layout seam drag | #f
;;   select-drag (select-drag panel-id view-id) | #f
;;               press 内容区时记下，move 只对同一个 view 扩展选区，
;;               release / 非鼠标事件清除（选区本身留在 view 里）

;; 焦点 resource 是派生查询：layout.focus -> panel.active -> resource-of-view
(app-state-focus-resource state)

;; flash：一次性状态栏文本，下一次 step 入口自动清空
(app-state-with-flash state text)
(app-state-flash state)

;; 编辑 / 导航 / 鼠标落点都是 view-action，boot 解释成 core 调用
(view-action kind view-id data)
;;;   kind : insert | paste | backspace | delete | kill-line
;;        | nav | point | select | scroll | ensure | undo | redo
;;   insert/paste data = 原始 UTF-8 bytes（engine 写 buffer 时解码一次）
;;   nav   data = dir | (list dir extend?)
;;   point data = (list row col) | (list row col extend?)
;;                 ; 内容区相对坐标（0 基）；extend? = #t 只移 head，保留 anchor（鼠标拖选）
(quit-action)

(step state event)  ; -> (values state' actions)

;; 文档变更：engine 返回 change，boot/actions 记到 app-state
(engine-apply-view-action! engine action)
;; → #f | '() | (listof change)
;;   #f      = 拒绝（只读）
;;   '()     = 成功但无文本变化（含 undo/redo）
;;   changes = 精确变更（change.after 是当前坐标）

(change? ch)
(change-before ch) (change-after ch)
(change-kind ch) (change-post-range ch)

(struct doc-change (doc-id version changes))
(app-state-pending-doc-changes state) ; (listof doc-change)，按发生顺序
(app-state-note-doc-change state did version changes)
(app-state-take-doc-changes state)    ; -> (values changes state')
```

说明：

- `insert / paste / backspace / delete` 返回 core 的精确 `change`；
- `kill-line` 也返回 `buffer-replace-range!` 的 `change`；
- `nav / point / select / scroll / ensure` 返回 `'()`；
- `undo / redo` 不产生 change：它们恢复的是旧 document，face / document slot /
  分析缓存随 document 一起回来，不是一次新的文本提交，因此不触发解析。
- UI 面板（filetree / status / input）没有 resource，产生的 change 不入队；
  只有编辑器 resource 的文档变更会进入 `pending-doc-changes`。

命令值约定：

```text
command-table 叶子是 (state -> (values state' actions))
```

按键序列 / 动态遮蔽沿用：

```text
overlay tables ++ focused resource command-stack
```

### boot

```racket
;; 最小插件值：install / teardown；列表顺序 = 安装顺序
(make-plugin #:id #:install #:teardown)

;; 启动上下文
(make-host #:engine #:layout-config #:keymap #:plugins
           #:first-view-id #:first-panel-id)
(host-alloc-view-id! host)
(host-alloc-panel-id! host)
(start-app host state)        ; install 所有插件
(host-teardown host state engine) ; 逆序 teardown

(make-engine)
(engine-create-buffer! engine did name text)
(engine-create-view! engine vid did)
(engine-view-object engine vid)
(engine-view-text engine vid)
(engine-doc-text engine did)
(engine-doc-version engine did)

;; 普通投影 view：内容 / 光标分开写
(engine-set-view-content! engine vid lines faces) ; -> changed?
(engine-set-view-cursor! engine vid line #:column col)
(engine-set-view-lines! engine vid lines faces line ...) ; 兼容：内容 + 光标

(engine-apply-view-action! engine action)   ; -> #f | '() | (listof change)

(run-actions state engine actions)  ; -> state'

(render-frame state engine cache)   ; -> (values cache' bytes)

(run-loop state engine
          #:read-event ...
          #:write-bytes ...)
```

`run-loop`：

```text
render
read-event
step
run-actions
quit? -> exit
```

没有 hook / settle / 通用 effect。action 是数据，boot 同步解释。  
view-id -> core view 在 core engine 里解析；State 不存 core 句柄。

插件不是框架：一个 `plugin` 值 + host 里的字面量列表就够了。
`boot/start` 只做 install / teardown；每帧的 sync / analysis / projection
由 boot 显式写死，不做插件回调。没有 registry / discovery / 依赖解析。

未来的语法高亮、bracket 深度、补全、异步任务会作为**显式的派生/投影阶段**
插入循环，而不是通过 `sync` hook 或回调挂进去。

### 文件树

```racket
(empty-filetree)
(make-filetree #:view #:line #:cursor-dirty? #:expanded #:rows)
(filetree-toggle-expand f path)
(filetree-set-view / set-cursor / sync-cursor)
;;   set-cursor  : 程序化设光标（cursor-dirty? = #t，下一次 sync 推给 view）
;;   sync-cursor : sync 从 view 读回镜像（cursor-dirty? = #f）

(filetree-lines root expanded opened dir-lister)  ; 纯行投影；根显示绝对路径
(filetree-line-at rows line)
(dir-entries path)                                 ; 唯一 IO 点

;; 根路径 / 路径显示都在 resource 层（filetree 只是使用者）
(resource-root store)
(resource-display-path store path)  ; 状态栏 / 保存提示用；根内相对
(resource-normalize-path path)
(resource-find-by-path store path)

(sync-filetree! state engine)  ; -> state'
;;   rows 按 (root, expanded, opened, show-hidden?) 缓存
;;   光标归 core view（它就是普通 buffer）：
;;     键盘移动 -> state 改 cursor 并置 cursor-dirty?，sync 推给 view；
;;     鼠标点击 -> 普通 point action 改 view，sync 直接读回来当镜像。

;; 键位表在 config/keymap：filetree-command-table / filetree-panel-stack
(filetree-install-state state view root #:panel-id #:panel-stack
                        #:show-hidden? #:hidden-entry?)
(filetree-enter-command state)
(filetree-refresh-command state)        ; C-r：丢弃行投影缓存
(filetree-toggle-hidden-command state)  ; C-h：显 / 隐 . 开头条目
;; 没有文件树专用的点击/光标逻辑：走通用 point action
```

行为：

- root / dir：Enter 展开 / 折叠；
- file：Enter 打开；
  - 已打开且已挂 panel：聚焦已有 panel；
  - 已打开但 detached：进入 placement；
  - 未打开：read-file -> resource-open -> placement；
- placement（临时表，完毕自动解除）：
  - 开始时就压入 keymap 的 `placement-table`，焦点不在 editor 上会自动落到第一个 editor；
  - ↑←→↓ 在 editor 之间改焦点（跳过 filetree / status）；
  - Enter 放入当前焦点 editor；鼠标点目标 editor 也可；
  - Esc 取消；
  - 放入 / 取消后 `clear-placement` 把临时表从 overlays 摘掉，普通键位恢复。
- 光标就是 core view 的 point：方向键四个方向 / Home / End / PageUp/Down 都用
  和 editor 同一张导航表（config/keymap 的 `navigation-command-table`），**不限制在行首**，
  列可以自由移动（长路径会横向滚动）；state 里的 cursor 只是 point line 的镜像。
- 鼠标点 filetree 行：就是普通 buffer 的 point action —— 点哪行、哪列，光标就到哪
  （滚动、行尾、空白处的行为与编辑器完全一致）。
- 鼠标拖动也一视同仁：press 落 caret 并记下 `select-drag`（panel + view），
  move 对同一个 view 发 `(point row col #t)` 扩展选区，release 结束；
  选择始终留在按下的 panel 里，指针移到别的 panel 也不换目标。

### 资源管理面板

和 filetree 共用同一个 sidebar panel，通过 `C-x b` 切换 tab；view-id 不同，但 position 相同。

```racket
;; 键位表在 config/keymap：resource-panel-command-table / resource-panel-stack
(resource-panel-install-state state view #:panel-stack panel-stack)
(sync-resource-panel! state engine)
(resource-panel-enter-command state)   ; Enter
(resource-panel-refresh-command state) ; C-r
```

行投影：

```text
buffer 行
  view 行
  view 行
buffer 行
  view 行
```

- buffer / view 的 face 分开：`resource-document` / `resource-view`；
- dirty 的 buffer 用 `resource-pending`，并显示 `*`；
- Enter buffer 行 -> 该 resource 的第一个 view；
- Enter view 行 -> 该 view；
- 已挂 panel -> 聚焦 panel 并切 active view；detached -> placement。

### 状态栏 / 输入栏

```racket
(status-install-state state view-id)
(sync-status! state engine)

(input-install-state state panel-id status-view input-view)
(input-active? state)
(input-reconcile state)         ; -> (values state' actions)  prompt/request <-> 输入栏
(input-sync! state engine)      ; 只把文本 / 光标投影到 core view

;; 输入态键位在 config/keymap：input-command-table / input-command-stack
;; step 输入激活时独占使用 keymap 的 input-stack，不与 overlays 合并
(input-self-insert state token) ; 表未命中：可打印 -> 插入，其余吞掉
(input-handle-paste state event)

;; 插件请求输入（服务 API）
(struct input-request (id label kind choices default on-done))
(input-start state request)     ; -> (values state' actions)
(struct input-result (id status value))   ; status = submitted / cancelled / preempted
```

状态栏：

```text
focus resource path/name
line:col
dirty *
pending keys
flash（一次性；下一次 step 入口清空）
```

输入栏（单行编辑，文本 / 光标归 State，每帧投影到 view；按键走命令表）：

```text
可打印键 / 粘贴     在光标处插入（粘贴只取单行可打印内容）
Backspace / Delete  删光标前 / 后
← → Home End        移动光标（C-f 逐字符，C-a/C-e 行首/行尾）
C-h / C-t           跳到整行行首 / 行尾（只有输入栏有）
Enter               提交
Esc / C-g           取消（resource-cancel）
```

输入栏状态（`app-state.store['input]`）：

```text
input-state
  panel-id    status panel（输入栏 view 挂在这里）
  status-view / input-view   两个 core view id
  active?     是否打开
  source      'resource | 'plugin | #f
  request     input-request | #f（source = 'plugin）
  prompt-id   resource prompt id | #f（source = 'resource）
  text        前缀之后的文本
  cursor      整行绝对位置（0 .. 前缀长 + 文本长）
  prev-focus  打开前的焦点 panel
```

和命令表 / 调度相关的 app-state 字段：

```text
pending        已按下的半截键序列；input-open 清空
overlays       全局表；输入态不参与组合
panel-stacks   非 resource 面板的表（filetree）
store['input'] 上面那个 input-state
resources      resource prompt（系统 prompt 的唯一真相）
```

状态迁移由 `input-reconcile` 保证：`prompt 存在 <=> source = 'resource`；
插件请求 `source = 'plugin`；两者都没有则 `active? = #f`。

```text
打开 / 切换：
  prompt 出现，无输入          -> open-resource-input
  prompt 出现，plugin 输入中   -> finish 'preempted'，open-resource-input
  prompt 变化 / 消失           -> close 或重开
  input-start，无 prompt       -> open-request-input
  input-start，旧 plugin       -> finish 旧 'preempted'，open 新
  input-start，prompt 存在     -> flash "input busy"，不打开
打断 / 结束：
  Enter                        -> submit（非法则保持打开）
  Esc / C-g                    -> resource-cancel 或 finish 'cancelled'
  mouse / resize / quit / internal -> input-interrupt 'cancelled'，再处理事件
```

- prompt 来自 `resource-prompt`，前缀 = label；confirm 还会显示可选值，
  并且 **label 里有文件路径**（没有 path 时用 resource name）：
  `Save /home/me/a.txt? (y/n/all/nall) `；
- confirm 的可选值：`y`（保存）/ `n`（跳过）/ `all`（剩下都保存）/
  `nall`（剩下都跳过）；Esc 取消。大小写不敏感，也接受旧写法
  `save/skip/save-all/skip-all/cancel`；
- Enter -> **`resource-submit-text`**：文本 -> 值的转换和校验都在 resource 层，
  按 prompt kind 分派（输入栏本身不判断 kind）；
  - confirm：接受 y/n/all/nall（映射到 save/skip/save-all/skip-all），
    必须是 prompt 支持的答案；
  - save-path：trim 后不能为空；
  - 不合法时返回 `ok? = #f`，prompt 保持打开，状态栏提示可选值 / `path required`；
- 提示前缀**完整**写进 core buffer（不裁剪、不省略），并标成 **readonly**
  （`#:readonly-prefix`，face `input-prompt`）——buffer 本身就是输出，
  不需要额外的格式化/裁剪层；
- 窗口装不下时靠光标滚动查看：←/→ 可以走进前缀，Home 到整行行首（看到
  `Save ...`），End 到行尾（看到可选值）；前缀里 Backspace/Delete 不生效，
  在里面输入会落到可编辑文本的起点；
- 提交成功才 `input-close`（恢复打开前的焦点）。

### 输入来源与抢占规范

输入栏是**服务插件**（chrome）：插件通过 `chrome/api.rkt` 的 `input-start`
发起请求，不需要自己画面板；它依赖 `app/state` 和 resource prompt，所以不做进
骨架（否则骨架要依赖 app）。

```text
两种来源：
  resource prompt（骨架资源管理产生）   save-path / confirm
  插件请求 input-request                id / label / kind / choices / default
                                        on-done : state input-result -> values

结果：
  submitted   Enter 提交（text -> string，confirm -> symbol）
  cancelled   Esc / C-g，或被其他事件打断
  preempted   被新的插件请求 / 系统 prompt 挤占
```

规范（输入是抢占式的）：

- 输入激活时，**key** 走 keymap 的 `input-command-stack`（独占，见下），**paste** 直接
  交给输入栏；**其他事件**（mouse / resize / quit / internal）先
  `input-interrupt` 取消本次输入，再照常处理该事件；
- 新的插件请求挤占旧插件请求：旧请求 on-done 收到 `'preempted`；
- 系统 prompt 优先：出现时挤占插件请求（`'preempted`），并从空文本开始；
- 关闭 / 取消 / 挤占都会回调 on-done，插件不需要轮询。

输入栏的键和其他面板一样走命令表，但**独占**：`current-command-stack` 在
`input-active?` 时直接返回 keymap 的 `input-command-stack`，不拼 `overlays`。原因是
`command-table-stack-lookup` 遇到 unbound 会继续查下一张表——如果叠了
overlay，输入栏里未绑定的 `C-q` / `C-w` 就会穿透成全局命令。可打印字符
不建表项，由 `input-self-insert` 兜底（和 editor 的 `edit-self-insert` 对称）。

打开输入栏时 `input-open` 会清空 `pending`，避免半截序列（如先按了 `C-w`）
把输入栏的第一键拼成 `(C-w key)` 去查表。

`app/step.rkt` 在入口 / 出口做 reconcile + 抢占，`boot/sync.rkt` 在每帧同步前
也 reconcile 一次（挤占回调可能产生 action，先跑掉再写 view）。

同步顺序（`boot/sync.rkt`）：

```text
input-reconcile    先落实 prompt <-> 输入栏 view
sync-panel-sizes!  再按布局把 active view 的 viewport 尺寸写好
sync-filetree! / input-sync! / sync-status!   最后才写内容
```

尺寸必须先于内容：否则输入栏还在 1x1 viewport 时就把光标设到行尾，
横向滚动会把整行推到左边，提示就"看不见"了。

打开 / 关闭输入栏是 **状态迁移**，不是渲染副作用：

```text
prompt 存在 <=> 输入栏 active
```

`step` 在入口和出口都会 `input-reconcile`（纯），`run-loop` 在 `run-actions`
之后再 reconcile 一次（action 也可能产生新 prompt，比如写完文件继续下一个确认）。
所以只驱动 `step`、不跑 `sync` / `render` 的测试里，Enter 一样能提交；
`input-sync!` 只负责把文本 / 光标投影到 view。

输入栏和状态栏共用同一个 panel 的 views：

```racket
(make-panel 'status 'status
            #:views '(status-view input-view)
            #:active status-view
            #:fixed-h 1)
```

### 资源管理

```racket
resource-store-empty
(resource-open store ... #:key-table key-table ...)  ; key-table 必填，buffer 创建时匹配

resource-ref
resource-list
resource-pending

resource-id
resource-name
resource-doc-id
resource-views
resource-version
resource-saved-version
resource-path
resource-dirty?
resource-writable?
resource-view-ids
resource-command-stack
resource-set-command-stack
resource-normalize-path
resource-find-by-path

;; 启动根路径由 resource 管理；数据仍用绝对路径
resource-root
resource-set-root
resource-display-path      ; 根内 -> 相对路径；根外 -> 绝对路径（只用于显示）
resource-opened-revision   ; 打开路径集合的版本；成员 / path 变化才 +1

resource-mark-edited
resource-sync-version      ; engine 文档版本变了才记 dirty
resource-save
resource-save-as
resource-save-done

resource-request-close  ; 关闭 resource：删 store + engine view/doc；不是 panel
resource-request-quit
resource-prompt
resource-submit
resource-submit-text
resource-cancel

resource-action?
resource-action-kind
resource-action-data

prompt?
prompt-id
prompt-kind
prompt-resource-id
prompt-label
prompt-value
prompt-choices
pending?
pending-kind
pending-ids
pending-index
pending-mode
```

规则：

```text
path 有值   -> 能落文件
path = #f   -> 不能落文件，保存前先要路径
dirty       -> version != saved-version
```

dirty 的同步：boot 每解释完一个 `view-action` 就调用
`resource-sync-version`（只有 engine 里的文档版本真的变了才记 edited），
所以插入 / 删除会让 `dirty?` 变真，导航 / 滚动不会。

退出 / 关闭保存流程：

```text
C-q -> resource-request-quit
  dirty 列表为空        -> quit-action（直接退出）
  否则逐项 confirm      -> y / n / all / nall（Esc 取消）
    y    = 保存当前（无 path 先 Save as）
    n    = 跳过当前
    all  = 当前 + 剩下都保存
    nall = 剩下都跳过
    有 path 直接 write-file；无 path 先出 save-path prompt
  全部处理完            -> quit-action
```

`test/quit-save.rkt` 覆盖 dirty -> confirm -> save-as -> 写文件 -> quit，
以及 skip / cancel / 无效回答。

文件树根直接显示 `resource-root` 的规范化绝对路径，不使用
`resource-display-path`。状态栏 / 保存提示仍然走 `resource-display-path`
（根内相对、根外绝对）；resource / filetree / 保存的数据仍然全部使用绝对路径。

`resource-open` 返回 action 数据：

```text
create-buffer / create-view
```

保存返回：

```text
write-file
```

关闭 / 退出完成后返回：

```text
close-resource / quit
```

输入面板只调用：

```text
resource-prompt
resource-submit-text   ; 文本 -> 值（内部再走 resource-submit）
resource-cancel
```

### 命令表

两层：

```text
command-table        一张表：key-sequence -> command
command-table-stack  (listof command-table)：动态遮蔽
```

```racket
(keys [key ... value] ...)
(command-table-add t seq value)
(command-table-from-bindings binds)
(command-table-bindings t)
(command-table-merge t ...)         ; 多张合成一张，左边优先
(command-table-lookup t seq)        ; 'command / 'prefix / 'unbound

command-table-stack-empty
(command-table-stack-from-tables ts)   ; 第一个 = top
(command-table-stack-tables stack)
(command-table-stack-over top bottom)  ; 两层叠加：top 优先
(command-table-stack-push stack t)     ; 单表压顶
(command-table-stack-pop stack)
(command-table-stack-remove stack t)
(command-table-stack-lookup stack seq)
```

规则：

- stack 顶层先查；
- 顶层返回 `command` / `prefix` 就停止；
- 只有 `unbound` 才落到下一层；
- 弹窗可以 `push` 临时表，关闭时 `pop` / `remove`。

切换命令有两种方式，对应两个原语：

```text
叠加（additive）  command-table-stack-over / push
                  例：overlays、placement 临时表；未绑定键继续往下查
替换（modal）      直接持有另一张 stack
                  例：输入栏 keymap 的 input-command-stack；未绑定键不穿透
```

`app-state` 里三种来源统一成 stack：

```text
overlays        command-table-stack（全局表，顶层在前）
panel-stacks    panel-id -> command-table-stack（filetree 等）
resource        per-doc command-table-stack（编辑器）
```

`app/step.rkt` 的 `current-command-stack`：

```text
输入激活  -> keymap 的 input-command-stack    ; 替换
否则      -> (stack-over overlays base-stack) ; 叠加
```

## 性能

每帧固定成本只和「可见格数」有关，和文档 / 目录行数无关：

- **行投影有缓存**：filetree 按 `(root, expanded 集合, opened 集合)` 缓存 rows。
  三者不变就不重扫目录（`dir-entries` 每个 entry 要 3 次 stat，3000 行 ≈ 30ms）。
  外部文件变了用 `C-r` 手动刷新。
- **opened 集合有版本**：resource store 的 `opened-revision` 只在 resource 成员 / path
  变化时 +1；filetree 版本没变就复用缓存的 opened 集合，不扫 resource-list。
- **filetree sync 有完整 key**：`(view, projection-key, line, col)` 与上一帧相同就直接
  返回原 state，不 map rows、不调用 `engine-set-view-lines!`。
- **布局求解有缓存**：`boot/loop` 以 `(layout-solve-key, area)` 为键复用
  `layout-solution`；key 只含 root + panel-map，焦点 / active view 变化不会让 solve 失效。
  只有结构变化或窗口 resize 才重新 solve。
- **布局投影每帧只做一次**：`sync-ui/panels!` 生成 panels 并写回 viewport 尺寸，
  `render-frame` 直接复用同一份 panels，不再重复 `layout->render-panels` / `panels-sync!`。
- **UI 写回幂等**：`engine-set-view-lines!` 记住上次写进 view 的
  `(lines faces)`；内容没变就不重建 document、不推历史、不动 selections。
  core 的 render cache 以 document 版本为键 —— 不换 document 就命中增量渲染。
- **按键路径不绕圈**：token 就是 `(tag . bytes)`，事件原样往下传；
  自插入的 bytes 直接进 `insert` action，只在写 buffer 时解一次 UTF-8。
  没有 char / symbol 互转，也不把整张表展开成 Unicode 绑定。

参考数字（80×24、filetree 3000 行、内容不变的一帧）：

```text
旧：每帧 filetree-lines（重扫目录）≈ 42ms + engine-set-view-lines!（重建 document）≈ 32ms
新：每帧 sync + render ≈ 0.5ms
```

## 测试

```sh
bash edit-tui/test/run.sh
```

- `test/api-boundary.rkt`：API 边界（非实现层只能 require main / api / core）
- `test/layers.rkt`：依赖方向（分层约束的可执行版本）
- 其余按领域：layout / focus / geometry / render / key / keymap / edit /
  mouse-select（点 / 拖选 / 越界夹边）/ filetree / chrome /
  input-service（请求 / 打断 / 挤占 / 回调）/ resource /
  placement / event-loop / theme / face / config

功能测试也统一只 require `../main.rkt`（外部 core 访问器除外）。

## demo

```sh
racket edit-tui/demo/layout.rkt
racket edit-tui/demo/three-panels.rkt
racket edit-tui/demo/interactive.rkt
racket edit-tui/demo/completion-docs.rkt
```

### completion + docs demo

```sh
racket edit-tui/demo/completion-docs.rkt
```

布局：`editor` / `docs` / `status`，`docs` 是编辑区与状态栏之间的独立可显隐面板。
补全弹窗按整个编辑区的包围盒定位，不进入 layout 树；不覆盖光标行，
宽度/高度按候选与可用空间计算；选中候选只用 face，不加 `>` 前缀。
选择候选会更新 docs。

```text
C-o       光标处补全（库函数 + 本文件/工作区本地词）
Up/Down   菜单：移动候选；docs：移动 docs 光标
Tab       下一个候选
Enter     接受
Esc/C-g   关闭
M-d       光标处标识符文档
C-x d     显 / 隐 docs 面板
C-x o     补全菜单 <-> docs 焦点切换；切到 docs 时补全不关闭
```

交互 demo 启动时 editor 为空，不预打开任何 buffer；先在 filetree 里 Enter 打开文件。

```text
C-w ←→↑↓   拆分当前 editor
C-d        close-panel：删除当前 editor panel；最后一个只清 view
C-b        显隐 sidebar（filetree / resources）
C-x ←→↑↓   焦点移动
C-x b      切换 sidebar tab（filetree / resources）
C-s        保存当前 resource（无 path -> Save as 输入栏）
C-q        退出（dirty -> 确认输入栏）
鼠标拖接缝  resize
鼠标点面板  聚焦
鼠标滚轮    滚动指针下的 panel（不改焦点 / 光标）
鼠标点 buffer 内容区 -> 主光标落到点击处（filetree 也一样，它就是普通 buffer）
鼠标在内容区拖动 -> 扩展选区：press 落 caret，move 只移 head（anchor 留在 view 里），
                    release 结束；指针拖出面板时夹到最近有效行 / 列，上下越界每次 move 滚一行

焦点窗口的边框用主题里的 `focused-border` 高亮（`config/theme/default.rkt` 换颜色）。
```

编辑（命令在 `edit/commands.rkt`；键位在 `config/keymap/default.rkt`：
`navigation-command-table` + 插入 / 删除 / 历史；导航表被 editor 和 filetree 共用，
因为文件树也只是普通 buffer）：

```text
直接打字                插入（任意可打印字符，含大写 / 中文）
Enter / Tab             换行 / 插入两个空格
Backspace / Delete 删前 / 删后一个字符
←→↑↓ Home End           导航
Shift+方向 / Shift+Home End  扩展选区
C-a / C-e               行首 / 行尾（C-f 逐字符）
PageUp / PageDown       滚一屏（光标跟着走一屏）
C-k                     删到行尾
C-z / C-y               撤销 / 重做
```

表里匹配不到的键由 `edit-self-insert` 兜底：可打印字符 -> 插入焦点
editor view；非 editor 面板 / 有前缀未完成 / placement 中则回 `unbound`。
所以命令表不必把 Unicode 全集写进去。

> 关于 C-i：终端里 Ctrl-I 和 Tab 是同一个字节 0x09，所以它们本来就是
> **同一个 token**（`(key 'i 'ctrl)` ≡ `(key 'tab)`），绑 Tab 就能收到 C-i。
> C-m / C-j / C-[ 同理；C-h 是例外（见上一节「输入：标签 + 字节」）。
> 想真正区分这些键需要 kitty keyboard protocol / xterm modifyOtherKeys。

文件树（普通 buffer：光标有行列，可自由移动）：

```text
C-x ← 聚焦 filetree
鼠标点行       光标落到点击处（行 + 列）
←→↑↓           自由移动（长行会横向滚动）
Home / End     行首 / 行尾        Shift+方向  扩展选区
PageUp/Down    滚一屏（光标跟着走）
Enter          展开目录 / 打开文件（文件 -> 进入 placement）
C-r            重扫目录（行投影有缓存，外部文件变化不会自动反映）
C-h            显 / 隐以 . 开头的条目（默认隐藏；过滤规则可经 #:hidden-entry? 扩展，
               它负责“算 hidden”，show-hidden? 负责“是否显示 hidden”）
```

placement（打开文件后自动进入）：

```text
↑←→↓  在 editor 之间改焦点（跳过 filetree / status）
Enter 放入当前焦点 editor
鼠标点 editor 放入
Esc   取消
```
