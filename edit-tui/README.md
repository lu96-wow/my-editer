# edit-tui-rebuild

重建中的编辑器基础设施：纯 State + action，布局 / 编辑 / 文件树 / 渲染都在
`*/api.rkt` 之后，core 只做 buffer / view / 几何 / 渲染。

## 约束

```text
1. State 是纯值：不存 engine 句柄、不存 IO 结果，只存 id / 数据 / 纯迁移结果。
2. 所有副作用都经 action：step 产出 action，runtime 解释；命令只返回
   (values state actions)。
3. core buffer / view 只有一个拥有者：engine/store.rkt（骨架层）。
4. 跨领域只经 */api.rkt；领域实现文件是私有的。上层可以 require 下层 api，
   下层永远不 require 上层。
5. 渲染是纯投影：state/layout -> core panel -> bytes；渲染不改 view 尺寸以外的状态。
6. 键位用 (tag . bytes)，不用 M- 前缀（窗口管理器会吞）；终端不能区分的组合
   共用 token（C-i = Tab）。
7. 主题是 require 安装的；颜色 / 样式只在 config/theme/ 里。
```

## 分层

```text
层           目录                                         纯?        可以 require
------------------------------------------------------------------------------
骨架-值      base  command  face  panel                 纯         core 的纯值
骨架-布局    layout(config/tree/solve/ops)                纯         骨架-值
骨架-资源    resource                                    纯         骨架-值
骨架-引擎    engine(action/model)                         有 core 句柄  core
                                           （engine 是 core buffer/view 的唯一拥有者，
                                             但对插件只暴露查询 + 写 UI view 的入口）
骨架-投影    projection  render                          纯         布局 / 值 / core render
骨架入口     skeleton.rkt                            纯聚合     上面所有骨架 api.rkt
------------------------------------------------------------------------------
插件         edit  chrome  filetree                      纯         skeleton.rkt + app/state
App 基础     app/state  app/event  app/action             纯         skeleton.rkt
App 交互     app/placement                              纯         skeleton.rkt + app/state
App 编排     app/step                                   纯         skeleton + 插件 api + app 基础
Runtime      runtime(actions/render/sync/tui/loop)        有副作用    全部 + tui
入口         main.rkt                                  纯聚合     skeleton + 插件 + app + runtime
```

依赖方向（单向）：

```text
core (buffer / view / rect / text / render)
        ↑
骨架：base / command / panel / face
        ├─ layout（config 模型 + tree/solve/ops）──→ projection ──→ render
        ├─ resource
        └─ engine (core buffer/view 的唯一拥有者)
                ↑
          skeleton.rkt          ← 插件唯一能 require 的骨架入口
        ┌───────┴────────┐
      edit      chrome   filetree   ← 插件：只组合骨架 + app/state
        └───────┬────────┘
             app/step ──→ runtime ──→ tui
```

规则：

- **插件只 require `skeleton.rkt`**，不直接 require core、runtime、骨架实现模块
  （`layout/tree.rkt`、`engine/store.rkt` … 都不行）；
- 插件之间只经对方 `api.rkt`（filetree 只用 `edit/api.rkt` 的导航表）；
- 插件可以 require `app/state.rkt` / `app/event.rkt` / `app/action.rkt`
  （根 State 与 action 词汇）来做纯状态迁移；
- `engine` 不认识 app：`view-action` 词汇在 `engine/action.rkt`（骨架），
  `app/action.rkt` 只是再导出它并补 `open-file` / `quit`；
- `app/step.rkt` 是唯一编排插件的地方，且只 require 插件 `api.rkt`；
- `runtime` 是唯一有副作用的层。

## 逻辑拆分

```text
骨架：
  layout/    tree.rkt   结构 + panel 资源 + 可见性 + 固定尺寸查询（不求解）
             solve.rkt  layout-solve：rect / split / seam（纯几何）
             ops.rkt    结构编辑：split / attach / remove / hide / drag / 校验
  resource/  model.rkt  资源状态 + 保存/退出/prompt 状态机 + 路径规范化/查找
  engine/    action.rkt 骨架的 view 操作 action（insert / nav / select / …）
             store.rkt  core buffer/view 的持有 + 写 UI view + 唯一查询入口
  projection/borders.rkt  共享边框 + 焦点框
             geometry.rkt layout -> core panel（渲染 / 命中 / 内容命中）
  render/    core.rkt    core piece -> tui bytes
             layout.rkt  layout -> panels -> bytes
  skeleton.rkt  骨架入口（插件只 require 这个）（插件只 require 这个）

插件：
  edit/      insert.rkt  自插入判读
             commands.rkt navigation-command-table / edit-command-table
  chrome/    status.rkt  状态栏投影
             input.rkt   输入栏（单行编辑 + prompt + readonly 前缀）
  filetree/  model.rkt   行结构 / 展开集合 / 投影缓存键
             lines.rkt   纯行投影
             scan.rkt    唯一 IO 点：读目录
             slice.rkt   app-state.store['filetree'] 切片存取
             sync.rkt    每帧同步到 core view
             commands.rkt Enter / C-r / 安装

App：
  event/action/state/placement/step：事件、动作、状态、放置交互、编排
```

## 项目结构

```text
edit-tui-rebuild/
  main.rkt                 唯一聚合入口（skeleton + 插件 + app + runtime 的 api.rkt）
                           —— 没有顶层 api.rkt；api 不是一层

  skeleton.rkt         骨架 API（布局 / 资源 / 焦点 / face / 命令 / 投影 / engine）

  base/api.rkt             基础值：rect / point / range / selection / 显示列

  command/  table.rkt      命令表 / 栈 / keys DSL
            key.rkt        键 token = 标签 + 原始字节
            api.rkt

  config/   layout/default.rkt  布局配置（纯数据；require 选择）
            theme/default.rkt   主题（require 即安装）

  face/ model.rkt          face 值 / 分层合成
        api.rkt

  panel/ model.rkt         panel 资源
         api.rkt

  layout/ config.rkt       布局配置模型（类型 / 构造 / 查询 / 通用 rule）
          tree.rkt         split tree + panel 资源 + 可见性
          solve.rkt        layout-solve（rect / seam）
          ops.rkt          split / attach / remove / hide / show / drag / validate
          api.rkt

  resource/ model.rkt      resource / save / quit / prompt / 路径
            api.rkt

  engine/ action.rkt       骨架的 view 操作 action
          store.rkt        core buffer/view 的持有 + 写 UI view
          api.rkt

  projection/ borders.rkt  共享边框 + 焦点框
              geometry.rkt layout -> core panel（渲染 / 命中 / 内容命中）
              api.rkt

  render/ theme.rkt        style / theme
          core.rkt         core piece -> tui bytes
          layout.rkt       layout -> panels -> bytes
          api.rkt

  edit/  insert.rkt        自插入判读
         commands.rkt      导航表 + 编辑表
         api.rkt

  app/ event.rkt           key / mouse / resize / paste / internal
       state.rkt           app-state + 查询 / 焦点迁移 / 消息
       action.rkt          open-file-action / quit-action（view-action 在骨架）
       placement.rkt       放置交互（临时 keymap）
       step.rkt            event -> (values state actions)
       api.rkt

  chrome/ status.rkt       状态栏投影
          input.rkt        输入栏
          api.rkt

  filetree/ model.rkt      文件树状态 / 行结构
            lines.rkt      纯行投影
            scan.rkt       读目录（唯一 IO）
            store.rkt      store 切片存取
            panel.rkt      同步到 core view
            commands.rkt   Enter / C-r / 安装
            api.rkt

  focus/ model.rkt         焦点导航（基于命中投影）
         api.rkt

  runtime/ actions.rkt     action 解释（唯一副作用入口）
           frame.rkt       state + cache -> bytes（每帧渲染入口）
           sync.rkt        UI panel 同步
           tui-adapter.rkt tui raw 事件 -> app 事件
           loop.rkt        render / read-event / step / run-actions
           api.rkt

  demo/  test/
```

## API 边界

**允许**（非实现层只能 require）：

```text
main.rkt
*/api.rkt              （含 skeleton.rkt —— 插件的唯一骨架入口）
外部 core/*（只读、纯）
```

**不允许**：

```text
core 的实现模块（插件里）
layout/tree.rkt  layout/solve.rkt  layout/ops.rkt
panel/model.rkt  command/table.rkt  projection/geometry.rkt
engine/store.rkt  engine/action.rkt
... 任何非 api.rkt 的领域实现文件
```

领域内部文件之间可以互相 require（`tree` ← `solve` ← `ops`，
`model` ← `lines` ← `panel` …），但这属于实现细节，不对外。

API 不够时：先补对应领域的 `api.rkt`，不要在下游绕过 API 直接调实现。

### API 文件放哪

`api` **不是一层**，只是每个领域的「对外面」。

- 每个领域自己带 `api.rkt`（和实现放在一起）：谁提供能力，谁维护面；
- 不建顶层 `api/` 镜像树：两棵树要同步、重命名要改两处，还会让插件
  看到所有领域的面，层级就糊了；
- 顶层只有 `main.rkt` 一个聚合入口（宿主 / demo / test 用）；
- 插件之间只经对方 `api.rkt`；插件不 require `main.rkt`（会成环）；
- `app/api.rkt` 是「整个 app 域」的面对（包含编排 `step`），所以插件不用它，
  插件只用 `app/state.rkt` / `app/event.rkt` / `app/action.rkt` 这些 app 基础值。

约束是可执行的：

- `test/api-boundary.rkt` 扫描所有非骨架 / 插件目录下的 `.rkt`，越界 require 直接失败；
- `test/layers.rkt` 读各模块的 require，检查：
  - 骨架不认识 app / 插件 / runtime；
  - 插件只 require `skeleton.rkt`，不摸 core / runtime / 骨架实现；
  - 插件之间只经对方 `api.rkt`；
  - `app/step` 只编排插件 `api.rkt`；`app/state` 只依赖骨架；
  - `engine` 不 require app。

## 命名约定

```text
xxx!             修改参数 / 产生副作用（engine-*、sync-*!、run-actions）
xxx?             谓词（layout? panel? key? resource-dirty?）
xxx->xxx         纯转换（layout->render-panels、key->string、raw-key-token）
make-xxx         构造值（make-panel、make-layout、make-engine）
app-state-*      State 查询 / 纯迁移（app-state-set-focus-panel、
                 app-state-with-message、app-state-refresh-focus-resource）
layout-*         布局几何 / 查询（layout-panel、layout-solve、layout-seam-at）
panel-*          panel 资源（panel-view、panel-kind、panel-fixed-h）
filetree-*       文件树（filetree-lines、filetree-current-line）
engine-*         core buffer / view 的唯一入口（engine-view-object、
                 engine-set-view-lines!、engine-apply-view-action!）
input-* / status-*  chrome 的输入栏 / 状态栏
render-*         渲染投影（render-frame、render-layout、render-pieces）
dispatch-*       step 内部按事件类型分流
```

## API 面（概要）

```text
main.rkt                  唯一聚合入口：skeleton + render + 插件 + app + runtime
                          （没有顶层 api.rkt；纯配置不聚合，直接 require）
skeleton.rkt          骨架：base / panel / layout / focus / face /
                          resource / command / projection / engine
                            - base/api.rkt               rect / point / range / selection / 显示列
                            - layout/api.rkt             配置模型 / split tree / solve / ops / seam / drag
                            - resource/api.rkt           store / resource / save / prompt / 路径
                            - focus/api.rkt              焦点导航
                            - command/api.rkt            command-table / keys / key token
                            - engine/api.rkt             buffer/view 持有 + view action 词汇
                            - projection/api.rkt         layout->render-panels / hit / content-hit
render/api.rkt            render-layout / layout-sync!
edit/api.rkt              navigation-command-table / edit-command-table / self-insert
chrome/api.rkt            status / input（含 input-start / input-result 服务 API）
filetree/api.rkt          model / lines / scan / commands / panel
app/api.rkt               event / state / action / placement / step
runtime/api.rkt           actions / render / sync / tui-adapter / loop
```

### core 能力面对应关系

core 不整包导出——按能力拆开，而且各自的形式不同：

```text
能力                                         导出位置                  形式
--------------------------------------------------------------------------------
纯值：rect / point / range / selection /       base/api.rkt            直接 re-export
      selections / 显示列                                               （只 require core 值模块）
buffer / view：读 + 写 UI view + 编辑 action   engine/api.rkt          包装（engine-* +
                                                                        view-action），不导 core 构造器
渲染：layout -> panels -> bytes                render/api.rkt          包装（render-layout /
                                                                        layout-sync! / render-pieces）
layout -> core panel / 命中投影                projection/api.rkt      包装（layout->render-panels /
                                                                        layout->hit-panels / layout-content-hit）
布局几何（rect / panel）                       layout/api.rkt         骨架自己的面
                                              panel/api.rkt           （内部用 core 值）
```

- 插件只看到 `skeleton.rkt`（含 base / engine / projection，**不含** render）；
- 编辑能力以 `view-action` 词汇暴露（`engine/action.rkt`），插件发 action，
  只有 `runtime/actions.rkt` 解释成 core 调用；
- 直接 require core 的只有骨架内部：`base/api`、`engine/store`、
  `layout/{tree,solve,ops}`、`projection/{borders,geometry}`、
  `render/{core,layout}`、`focus/model`。插件 / app / runtime 都不 require core。

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
(require "edit-tui-rebuild/main.rkt")
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

`layout/config.rkt` 是**布局配置模型**（骨架的一部分）：只有规则的数据形状、
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
(require "edit-tui-rebuild/config/layout/default.rkt")
default-config    ; editor / sidebar / status 的 split / hide / min / max
```

- `config/` 只放纯配置，没有 `api.rkt` / `model.rkt`；选择配置 = require 那个模块；
- `main.rkt` 不聚合纯配置（和主题一样由宿主直接 require）；
- `skeleton.rkt` 和 `layout/ops.rkt` 都不认识 `config/layout/`；
- layout 结构操作把 config 当**必填参数**：
  `layout-split` / `layout-panel-remove` / `layout-panel-hide` /
  `layout-seam-resize` / `layout-seam-drag-*`；
- app 把配置放进 state：`(app-state-layout-config state)`；
  demo / 宿主构造 state 时传 `#:layout-config default-config`；
- 换一套规则 = 换一个 config 值（或换 require 的配置模块），layout 骨架不动。

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
(layout-set-focus l id)
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
(layout-seam-drag-start l area row col #:config config)   ; -> drag | #f
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
compose-layers
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

主题和布局配置都放在 `config/`，都是纯配置、直接 require；区别是主题
require 即全局安装，布局配置是值（传给 layout API / 放进 app-state）。

主题放在 `config/theme/`：

```racket
(require "edit-tui-rebuild/config/theme/default.rkt")
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
(require "edit-tui-rebuild/config/theme/dark.rkt")
```

### 输入：标签 + 字节

输入的中间状态不转成 char / symbol，token 就是终端给的那一份：

```racket
(struct key-token (tag bytes))
```

- `tag`：`'key`（单字节）| `'ctrl` | `'alt` | `'utf8` | `'mod-seq`（CSI 带修饰）
  | 命名键 `'up 'down 'left 'right 'home 'end 'insert 'del 'pageup 'pagedown 'backtab`
- `bytes`：原始字节

runtime 用 `tui:read-event/raw` 取 `(values type data mods)`，适配层直接
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

(make-app-state #:layout #:layout-config #:resources #:focus-resource
                #:overlays #:editor-tables
                #:pending #:area #:quit? #:message)

;; 编辑 / 导航 / 鼠标落点都是 view-action，runtime 解释成 core 调用
(view-action kind view-id data)
;;;   kind : insert | paste | backspace | delete | kill-line
;;        | nav | point | select | scroll | ensure | undo | redo
;;   insert/paste data = 原始 UTF-8 bytes（engine 写 buffer 时解码一次）
;;   nav   data = dir | (list dir extend?)
;;   point data = (list row col)   ; 内容区相对坐标（0 基）
(quit-action)

(step state event)  ; -> (values state' actions)
```

命令值约定：

```text
command-table 叶子是 (state -> (values state' actions))
```

按键序列 / 动态遮蔽沿用：

```text
overlay tables ++ focused resource command-stack
```

### runtime

```racket
(make-engine)
(engine-create-buffer! engine did name text)
(engine-create-view! engine vid did)
(engine-view-object engine vid)
(engine-view-text engine vid)
(engine-doc-text engine did)
(engine-doc-version engine did)
(engine-apply-view-action! engine action)   ; view-action 在 engine/action.rkt

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

没有 hook / settle / 通用 effect。action 是数据，runtime 同步解释。  
view-id -> core view 在 runtime engine 里解析；State 不存 core 句柄。

### 文件树

```racket
(empty-filetree)
(make-filetree #:view #:line #:cursor-dirty? #:expanded #:rows)
(filetree-toggle-expand f path)
(filetree-set-view / set-cursor / sync-cursor)
;;   set-cursor  : 程序化设光标（cursor-dirty? = #t，下一次 sync 推给 view）
;;   sync-cursor : sync 从 view 读回镜像（cursor-dirty? = #f）

(filetree-lines root expanded opened dir-lister)   ; 纯行投影
(filetree-line-at rows line)
(dir-entries path)                                 ; 唯一 IO 点

;; 路径规范化 / 查找在 resource 层（filetree 只是使用者）
(resource-normalize-path path)
(resource-find-by-path store path)

(sync-filetree! state engine)  ; -> state'
;;   rows 按 (root, expanded, opened) 缓存
;;   光标归 core view（它就是普通 buffer）：
;;     键盘移动 -> state 改 cursor 并置 cursor-dirty?，sync 推给 view；
;;     鼠标点击 -> 普通 point action 改 view，sync 直接读回来当镜像。

(filetree-command-table)   ; 通用导航表 + Enter / C-r
(filetree-install-state state view root #:panel-id)
(filetree-enter-command state)
(filetree-refresh-command state)   ; C-r：丢弃行投影缓存
;; 没有文件树专用的点击/光标逻辑：走通用 point action
```

行为：

- root / dir：Enter 展开 / 折叠；
- file：Enter 打开；
  - 已打开且已挂 panel：聚焦已有 panel；
  - 已打开但 detached：进入 placement；
  - 未打开：read-file -> resource-open -> placement；
- placement（临时表，完毕自动解除）：
  - 开始时就压入 `placement-table`，焦点不在 editor 上会自动落到第一个 editor；
  - ↑←→↓ 在 editor 之间改焦点（跳过 filetree / status）；
  - Enter 放入当前焦点 editor；鼠标点目标 editor 也可；
  - Esc 取消；
  - 放入 / 取消后 `clear-placement` 把临时表从 overlays 摘掉，普通键位恢复。
- 光标就是 core view 的 point：方向键四个方向 / Home / End / PageUp/Down 都用
  和 editor 同一张导航表（`navigation-command-table`），**不限制在行首**，
  列可以自由移动（长路径会横向滚动）；state 里的 cursor 只是 point line 的镜像。
- 鼠标点 filetree 行：就是普通 buffer 的 point action —— 点哪行、哪列，光标就到哪
  （滚动、行尾、空白处的行为与编辑器完全一致）。

### 状态栏 / 输入栏

```racket
(status-install-state state view-id)
(sync-status! state engine)

(input-install-state state panel-id status-view input-view)
(input-active? state)
(input-reconcile state)         ; -> (values state' actions)  prompt/request <-> 输入栏
(input-sync! state engine)      ; 只把文本 / 光标投影到 core view

;; 输入态命令表（step 在输入激活时独占使用，不与 overlays 合并）
(input-command-table)           ; 单键绑定：Esc/C-g Enter C-h/C-t 编辑/移动
(input-command-stack)           ; 只含 input-command-table 的 stack
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
message
```

输入栏（单行编辑，文本 / 光标归 State，每帧投影到 view；按键走命令表）：

```text
可打印键 / 粘贴     在光标处插入（粘贴只取单行可打印内容）
Backspace / Delete  删光标前 / 后
← → Home End        移动光标（C-b/C-f 逐字符，C-a/C-e 行首/行尾）
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
  input-start，prompt 存在     -> message "input busy"，不打开
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

- 输入激活时，**key** 走 `input-command-stack`（独占，见下），**paste** 直接
  交给输入栏；**其他事件**（mouse / resize / quit / internal）先
  `input-interrupt` 取消本次输入，再照常处理该事件；
- 新的插件请求挤占旧插件请求：旧请求 on-done 收到 `'preempted`；
- 系统 prompt 优先：出现时挤占插件请求（`'preempted`），并从空文本开始；
- 关闭 / 取消 / 挤占都会回调 on-done，插件不需要轮询。

输入栏的键和其他面板一样走命令表，但**独占**：`current-command-stack` 在
`input-active?` 时直接返回 `input-command-stack`，不拼 `overlays`。原因是
`command-table-stack-lookup` 遇到 unbound 会继续查下一张表——如果叠了
overlay，输入栏里未绑定的 `C-q` / `C-w` 就会穿透成全局命令。可打印字符
不建表项，由 `input-self-insert` 兜底（和 editor 的 `edit-self-insert` 对称）。

打开输入栏时 `input-open` 会清空 `pending`，避免半截序列（如先按了 `C-w`）
把输入栏的第一键拼成 `(C-w key)` 去查表。

`app/step.rkt` 在入口 / 出口做 reconcile + 抢占，`runtime/sync.rkt` 在每帧同步前
也 reconcile 一次（挤占回调可能产生 action，先跑掉再写 view）。

同步顺序（`runtime/sync.rkt`）：

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
resource-open
resource-ref
resource-list
resource-focus
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

resource-mark-edited
resource-sync-version      ; engine 文档版本变了才记 dirty
resource-save
resource-save-as
resource-save-done

resource-request-close
resource-request-quit
resource-prompt
resource-submit
resource-submit-text
resource-cancel

resource-action?
resource-action-kind
resource-action-data
resource-event?
resource-event-kind
resource-event-data

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

dirty 的同步：runtime 每解释完一个 `view-action` 就调用
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
                  例：输入栏 input-command-stack；未绑定键不穿透
```

`app-state` 里三种来源统一成 stack：

```text
overlays        command-table-stack（全局表，顶层在前）
panel-stacks    panel-id -> command-table-stack（filetree 等）
resource        per-doc command-table-stack（编辑器）
```

`app/step.rkt` 的 `current-command-stack`：

```text
输入激活  -> input-command-stack              ; 替换
否则      -> (stack-over overlays base-stack) ; 叠加
```

## 性能

每帧固定成本只和「可见格数」有关，和文档 / 目录行数无关：

- **行投影有缓存**：filetree 按 `(root, expanded 集合, opened 集合)` 缓存 rows。
  三者不变就不重扫目录（`dir-entries` 每个 entry 要 3 次 stat，3000 行 ≈ 30ms）。
  外部文件变了用 `C-r` 手动刷新。
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
bash edit-tui-rebuild/test/run.sh
```

- `test/api-boundary.rkt`：API 边界（非实现层只能 require main / api / core）
- `test/layers.rkt`：依赖方向（分层约束的可执行版本）
- 其余按领域：layout / focus / geometry / render / key / edit / filetree /
  chrome / input-service（请求 / 打断 / 挤占 / 回调）/ resource / placement /
  event-loop / theme / face / config

功能测试也统一只 require `../main.rkt`（外部 core 访问器除外）。

## demo

```sh
racket edit-tui-rebuild/demo/layout.rkt
racket edit-tui-rebuild/demo/three-panels.rkt
racket edit-tui-rebuild/demo/interactive.rkt
```

交互 demo：

```text
C-w ←→↑↓   拆分当前 editor
C-b        显隐 filetree
C-x ←→↑↓   焦点移动
C-s        保存当前 resource（无 path -> Save as 输入栏）
C-q        退出（dirty -> 确认输入栏）
鼠标拖接缝  resize
鼠标点面板  聚焦
鼠标点 buffer 内容区 -> 主光标落到点击处（filetree 也一样，它就是普通 buffer）

焦点窗口的边框用主题里的 `focused-border` 高亮（`config/theme/default.rkt` 换颜色）。
```

编辑（`edit/commands.rkt`：`navigation-command-table` + 插入 / 删除 / 历史；
导航表被 editor 和 filetree 共用，因为文件树也只是普通 buffer）：

```text
直接打字                插入（任意可打印字符，含大写 / 中文）
Enter / Tab             换行 / 插入两个空格
Backspace / Delete / C-d 删前 / 删后一个字符
←→↑↓ Home End           导航
Shift+方向 / Shift+Home End  扩展选区
C-a / C-e               行首 / 行尾（C-f / C-b 逐字符）
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
```

placement（打开文件后自动进入）：

```text
↑←→↓  在 editor 之间改焦点（跳过 filetree / status）
Enter 放入当前焦点 editor
鼠标点 editor 放入
Esc   取消
```
