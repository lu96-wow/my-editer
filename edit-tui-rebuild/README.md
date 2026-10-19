# edit-tui-rebuild

重建台。当前先落地布局：

```text
模型：
  layout = split tree + panel 资源
  渲染：layout-solve -> rects -> (listof core panel)

节点：
  leaf(panel-id)
  split(id, axis, left, right, ratio)

panel 资源：
  id / kind / views / active
  fixed-w / fixed-h
  hidden? / restore
  borders / face / weight
```

## API 边界约束

- 非实现层（`main.rkt` / `demo/` / `test/` / 未来 `app/`）只能 require：
  - `main.rkt`
  - `api/*`
  - 外部 `core/*`
- 不得直接 require `model/*`、`projection/*`、`command/*`；
- `api/*` 可以 require 实现模块；
- 实现模块之间可以互相 require；
- 如果 API 不够，先改 API，不要在下游绕过 API 直接调实现；
- `test/api-boundary.rkt` 机器检查这条约束。

## 关键约定

- `rect` 不进树，由 `layout-solve` 计算；
- 渲染列表 `(listof core panel)` 是投影，不是结构真相；
- 只有 `kind = 'editor` 的 panel 能 split；
- split 出来的新 editor 是空 panel，不抢焦点；
- 固定尺寸 `fixed-w` / `fixed-h` 是 panel 资源上的实际值（`#f` = flex）；
- 隐藏 = `hidden? = #t`，leaf 仍在树里，兄弟吸收父 rect；
- 显示 = 按隐藏时记录的 `rect / parent-rect` 比例恢复；
- 删除 = 从树里摘 leaf，父 split 塌缩到兄弟；
- 最后一个 editor 的关闭用 `layout-panel-clear-content`，保留 slot；
- 接缝属于 split 节点；拖动 = 改 split 的 ratio，再重新 layout-solve；
- 固定轴阻止接缝拖动；
- min / max 不进状态，由 `config` 提供，在接缝拖动 / 启动校验里使用；
- 删除 / 隐藏焦点 panel 时，焦点按“兄弟子树 → 逐层向上 → 第一个可聚焦 panel”回退；
- 不可聚焦的 panel 会被回退跳过；
- 一个 panel 槽可以挂多个 view（`views` + `active`），顺序切换用 `layout-panel-cycle-active-view`；
  文件树 / 资源列表共用区域就是同一个 panel 的两个 view。

## 文件

| 文件 | 内容 |
|---|---|
| `main.rkt` | 公共入口，只再导出 `api/main.rkt` |
| `api/base.rkt` | 几何值：rect |
| `api/panel.rkt` | panel 资源 API |
| `api/config.rkt` | config 规则 API |
| `api/layout.rkt` | layout 状态 / solve / 接缝 API |
| `api/focus.rkt` | 焦点导航 API |
| `api/geometry.rkt` | 渲染 / 命中投影 API |
| `api/command.rkt` | 命令表 / stack API |
| `api/main.rkt` | 统一 API 面 |
| `model/panel.rkt` | panel 资源实现 |
| `model/config.rkt` | config 规则实现 |
| `command/table.rkt` | 命令表实现 |
| `model/layout.rkt` | split tree、layout-solve、split / attach / remove / clear / hide / show / seam resize / focus fallback |
| `projection/geometry.rkt` | layout-solve → 渲染 core panel / 命中 core panel |
| `projection/focus.rkt` | 焦点导航：方向邻居 / 鼠标命中 / focusable 过滤 |
| `demo/layout.rkt` | 新布局渲染 80x24 三块 panel 的 demo |
| `demo/three-panels.rkt` | 直接用 core panel 写出的三块 panel 对照 demo |
| `test/layout.rkt` | 结构 / 固定尺寸 / 隐藏恢复 / 删除 / split 测试 |
| `test/geometry.rkt` | rect / 渲染投影 / 命中投影测试 |
| `test/focus.rkt` | 方向焦点 / 鼠标命中 / focusable 过滤测试 |
| `test/switch.rkt` | 同一 panel 区域多 view 的顺序切换测试 |
| `test/command-table.rkt` | 命令表 / 键序列 / 合并 / stack 遮蔽测试 |
| `test/api.rkt` | 只 require `main.rkt` 的统一 API 冒烟测试 |
| `test/api-boundary.rkt` | 检查非实现层没有越过 API 直接 require 实现模块 |

## API

公共入口：

```racket
(require "edit-tui-rebuild/main.rkt")
```

实现模块仍在 `model/` / `projection/` / `command/`；对外只从 `api/*` 导出功能面。

### config

```racket
(make-panel-rule #:splittable? #:hideable? #:deletable? #:focusable?
                 #:min-w #:max-w #:min-h #:max-h)
(make-layout-config #:rules #:default)
default-config
(config-panel-rule config kind)
(config-panel-splittable? config kind)
(config-panel-hideable? config kind)
(config-panel-deletable? config kind)
(config-panel-focusable? config kind)
(panel-rule-min-size rule axis)
(panel-rule-max-size rule axis)
```

### panel 资源

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

### layout 状态

```racket
(make-layout #:root #:panels #:focus #:next-split-id)
empty-layout
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

### panel 内 view 顺序切换

```racket
(layout-panel-view-ids l id)
(layout-panel-active-view l id)
(layout-panel-set-active-view l id view-id)
(layout-panel-cycle-active-view l id [step])  ; 1 = 下一个，-1 = 上一个
```

### 结构操作

```racket
(layout-split l target-id dir new-panel-id #:ratio #:config)
(layout-panel-attach l target-id dir panel #:ratio)
(layout-panel-remove l id #:config)
(layout-panel-clear-content l id)
(layout-panel-set-fixed l id axis value)
(layout-split-set-ratio l split-id ratio)
```

### 隐藏 / 显示

```racket
(layout-panel-hide l area id #:config)
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

(layout-seam-resize l area split-id delta #:config)
(layout-seam-drag-start l area row col #:config)   ; -> drag | #f
(layout-seam-drag-move l area drag row col #:config)
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
(layout->render-panels l area)  ; view = active
(layout->hit-panels l area)     ; view = panel-id
```

## 命令表

两层：

```text
command-table        一张表：key-sequence -> command
command-table-stack  (listof command-table)：动态遮蔽
```

```racket
(keys [key ... value] ...)          ; 构造一张表
(command-table-add t seq value)
(command-table-from-bindings binds)
(command-table-bindings t)
(command-table-merge t ...)         ; 多张合成一张，左边优先
(command-table-lookup t seq)        ; 'command / 'prefix / 'unbound

command-table-stack-empty
(command-table-stack-from-tables ts)
(command-table-stack-push stack t)
(command-table-stack-pop stack)
(command-table-stack-remove stack t)
(command-table-stack-lookup stack seq)
```

查找规则：

- stack 顶层先查；
- 顶层返回 `command` / `prefix` 就停止；
- 只有 `unbound` 才落到下一层；
- 所以弹窗可以 `push` 一张临时表，关闭时 `pop` / `remove`。

绑定对象按约定是 **当前焦点 buffer**；命令表本身不存 buffer，宿主为焦点 buffer 选择对应的 stack。

后续“资源打开时匹配”会在这层之上加表选择 / 安装规则，不改表实现。

## 测试

```sh
bash edit-tui-rebuild/test/run.sh
```

## demo

```sh
racket edit-tui-rebuild/demo/layout.rkt
racket edit-tui-rebuild/demo/three-panels.rkt
```
