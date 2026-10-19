# edit-tui-rebuild

重建中的编辑器基础设施。目前已完成：

```text
布局模型
命令表
face / 渲染
资源管理
API 层 / 边界约束
```

## 项目结构

```text
edit-tui-rebuild/
  main.rkt                 公共入口

  api.rkt                  统一 API 面（只聚合各领域 api.rkt）

  base/
    api.rkt                几何值：rect

  panel/
    model.rkt              panel 资源
    api.rkt                panel API

  config/
    model.rkt              panel kind 规则
    api.rkt                config API

  face/
    model.rkt              face 值 / 分层合成
    api.rkt                face API

  render/
    theme.rkt              style / theme / 默认主题
    core.rkt               core piece -> tui bytes
    layout.rkt             layout -> panels -> bytes
    api.rkt                render API

  layout/
    model.rkt              split tree / panel 状态 / layout-solve / 接缝
    api.rkt                layout API

  focus/
    model.rkt              焦点导航
    api.rkt                focus API

  command/
    table.rkt              命令表 / stack
    api.rkt                command API

  projection/
    geometry.rkt           layout -> core panel 投影
    api.rkt                projection API

  resource/
    model.rkt              resource / save / quit / prompt
    api.rkt                resource API

  demo/
  test/
```

规则：

- 每个领域目录内部放 `model.rkt`（实现）+ `api.rkt`（对外功能面）；
- 顶层 `api.rkt` 只聚合领域 API；
- `main.rkt` 只再导出 `api.rkt`；
- 非实现层不得 require 领域实现文件。

## API 边界约束

允许：

```text
main.rkt
*/api.rkt
外部 core/*
```

不允许：

```text
layout/model.rkt
panel/model.rkt
command/table.rkt
projection/geometry.rkt
... 任何非 api.rkt 的领域实现文件
```

如果 API 不够：

```text
先补对应领域的 api.rkt，不要在下游绕过 API 直接调实现。
```

`test/api-boundary.rkt` 会扫描所有非领域目录下的 `.rkt`，发现越界 require 直接失败。

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
default-theme
install-default-theme!

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

### 资源管理

```racket
resource-store-empty
resource-open
resource-ref
resource-list
resource-focus
resource-set-focus
resource-pending

resource-id
resource-name
resource-doc-id
resource-views
resource-file-path
resource-binding-stack
resource-version
resource-saved-version
resource-path
resource-dirty?
resource-writable?
resource-view-ids
resource-command-stack
resource-set-command-stack

resource-mark-edited
resource-save
resource-save-as
resource-save-done

resource-request-close
resource-request-quit
resource-prompt
resource-submit
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
resource-submit
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
(command-table-stack-from-tables ts)
(command-table-stack-push stack t)
(command-table-stack-pop stack)
(command-table-stack-remove stack t)
(command-table-stack-lookup stack seq)
```

规则：

- stack 顶层先查；
- 顶层返回 `command` / `prefix` 就停止；
- 只有 `unbound` 才落到下一层；
- 弹窗可以 `push` 临时表，关闭时 `pop` / `remove`。

## 测试

```sh
bash edit-tui-rebuild/test/run.sh
```

测试也统一只 require `../main.rkt`（外部 core panel 访问器除外）。

## demo

```sh
racket edit-tui-rebuild/demo/layout.rkt
racket edit-tui-rebuild/demo/three-panels.rkt
```
