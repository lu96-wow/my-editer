# edit-tui-rebuild

重建台。当前先落地布局：

```text
模型：
  layout = split tree + panel 资源
  渲染：layout-pass -> rects -> (listof core panel)

节点：
  leaf(panel-id)
  split(id, axis, left, right, ratio)

panel 资源：
  id / kind / views / active
  fixed-w / fixed-h
  hidden? / restore
  borders / face / weight
```

## 关键约定

- `rect` 不进树，由 `layout-pass` 计算；
- 渲染列表 `(listof core panel)` 是投影，不是结构真相；
- 只有 `kind = 'editor` 的 panel 能 split；
- split 出来的新 editor 是空 panel，不抢焦点；
- 固定尺寸 `fixed-w` / `fixed-h` 是 panel 资源上的实际值（`#f` = flex）；
- 隐藏 = `hidden? = #t`，leaf 仍在树里，兄弟吸收父 rect；
- 显示 = 按隐藏时记录的 `rect / parent-rect` 比例恢复；
- 删除 = 从树里摘 leaf，父 split 塌缩到兄弟；
- 最后一个 editor 的关闭用 `layout-clear-panel`，保留 slot；
- 接缝属于 split 节点；拖动 = 改 split 的 ratio，再重新 layout-pass；
- 固定轴阻止接缝拖动；
- min / max 不进状态，由 `config` 提供，在接缝拖动 / 启动校验里使用；
- 删除 / 隐藏焦点 panel 时，焦点按“兄弟子树 → 逐层向上 → 第一个可聚焦 panel”回退；
- 不可聚焦的 panel 会被回退跳过；
- 一个 panel 槽可以挂多个 view（`views` + `active`），顺序切换用 `layout-cycle-active`；
  文件树 / 资源列表共用区域就是同一个 panel 的两个 view。

## 文件

| 文件 | 内容 |
|---|---|
| `model/panel.rkt` | panel 资源：views / active / fixed / hidden / restore / borders |
| `model/config.rkt` | panel kind 规则：splittable / hideable / deletable / focusable / min-max |
| `model/layout.rkt` | split tree、layout-pass、split / attach / remove / clear / hide / show / seam resize / focus fallback |
| `projection/geometry.rkt` | layout-pass → 渲染 core panel / 命中 core panel |
| `projection/focus.rkt` | 焦点导航：方向邻居 / 鼠标命中 / focusable 过滤 |
| `demo/layout.rkt` | 新布局渲染 80x24 三块 panel 的 demo |
| `demo/three-panels.rkt` | 直接用 core panel 写出的三块 panel 对照 demo |
| `test/layout.rkt` | 结构 / 固定尺寸 / 隐藏恢复 / 删除 / split 测试 |
| `test/geometry.rkt` | rect / 渲染投影 / 命中投影测试 |
| `test/focus.rkt` | 方向焦点 / 鼠标命中 / focusable 过滤测试 |
| `test/switch.rkt` | 同一 panel 区域多 view 的顺序切换测试 |

## 按 panel 的入口

```racket
;; config
(make-panel-rule #:splittable? #:hideable? #:deletable? #:focusable?
                 #:min-w #:max-w #:min-h #:max-h)
(make-layout-config #:rules #:default)
default-config
(config-rule config kind)
(config-splittable? config kind)
(config-hideable? config kind)
(config-deletable? config kind)
(config-focusable? config kind)

;; panel 资源
(make-panel id kind #:views #:active #:fixed-w #:fixed-h
            #:hidden? #:restore #:borders #:face #:weight)
(make-empty-editor-panel id)
(panel-view p)
(panel-visible? p)

;; layout 状态
(make-layout #:root #:panels #:focus #:next-split-id)
(layout-add-panel l p)
(layout-panel l id)
(layout-panels l)
(layout-focus l)
(layout-set-focus l id)
(layout-update-panel l id f)
(layout-panel-views l id)
(layout-panel-active l id)
(layout-set-active l id view-id)
(layout-cycle-active l id [step])   ; 1 = 下一个，-1 = 上一个

;; 结构
(layout-attach l target-id dir panel #:ratio)
(layout-split l target-id dir new-panel-id #:ratio #:config)
(layout-remove l id #:config)
(layout-clear-panel l id)
(layout-set-fixed l id axis value)

;; 隐藏 / 显示（都受 config 限制）
(layout-hide l area id #:config)
(layout-show l area id)

;; 焦点回退 / 导航 / 校验
(layout-focus-fallback l config id)
(layout-focusable? l config id)
(layout-focus-panels l area config)
(layout-focus-at l area config row col)
(layout-neighbor l area config from-id dir)
(layout-focus-move l area config from-id dir)
(layout-validate l area config)
(layout-valid? l area config)

;; 接缝 / 拖动
(layout-pass l area)
(layout-seams l area)
(layout-seam-at l area row col)
(layout-resize-seam l area split-id delta #:config)
(layout-drag-start l area row col #:config)       ; -> drag | #f
(layout-drag-move l area drag row col #:config)   ; -> (values layout' ok?)

;; 投影
(layout->panels l area)       ; view = active
(layout->hit-panels l area)   ; view = panel-id
(layout->rects l area)
```

## 测试

```sh
bash edit-tui-rebuild/test/run.sh
```

## demo

```sh
racket edit-tui-rebuild/demo/layout.rkt
racket edit-tui-rebuild/demo/three-panels.rkt
```
