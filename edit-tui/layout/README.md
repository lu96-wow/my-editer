# edit-tui/layout —— 布局树（core 之上，宿主之下）

core 只吃 `(listof panel)`；本层负责**产出**它：把布局树解成带绝对 rect 的面板。
不 require tui，可单测。

```
tree.rkt    布局树（纯）：结构 + 操作（split / close / move / show / hide / resize）
spec.rkt    声明式构造器（启动时定义）：dock → 边框，直接产出 tree
solve.rkt   树 → panels / placements / cuts（纯）+ fixed/flex 分配 + 拖缝
float.rkt   浮窗（正交覆盖，不参与布局）：叠放 + z + 锚点定位
main.rkt    入口
```

## 树

```
node = leaf | split
  (leaf id view borders face weight dim visible? role)
      id      宿主身份（core 的 panel 没有 id）
      view    core 的 view | #f（空面板）
      borders 每边可选；**默认全边**，只有知道位置的特殊面板才自定义缝
      weight  边框 face 权重（→ core panel 的 weight，焦点框抬边框用）
      dim     沿父轴的尺寸（见下）
      visible? 显隐
      role    'panel（默认，固定区域）| 'editor | 'slot | …（见 app/role.rkt）
  (split axis children dim)
      axis    'lr（左右并排，竖缝）| 'tb（上下堆叠，横缝）
      children n 叉

显隐只挂在**叶子**上（可隐藏的只有 panel）；split 是纯分组，一个分组只有在
至少有一个可见叶子时才占空间（叶子全隐藏 → 整组不占额度）。
```

**尺寸 `dim`**（`tree.rkt`）：

```racket
(struct dim (kind value lo hi))
(fixed n)                          ; 固定 n 格**内容**（不含自身边框）
(flex w #:min lo #:max hi)         ; 弹性权重 w；lo/hi = 内容上下限（#f = 不限）
;; 数字 = (flex n)，兼容旧 #:size n
```

- fixed/min/max 都以**内容格**计：solver 自动加上该孩子沿轴的**边框厚度**（leaf 按有效边，split 为 0），
  所以状态栏写 `(fixed 1)` 就永远是 1 行内容，**不管它是末尾还是中间孩子**。
- 分配（`solve.rkt` 的 `alloc-dims`）：fixed 先取，剩余按权重分给 flex（钳制 min/max）；
  没有 flex 时余量给**第一个孩子**（让末尾固定面板贴底）。
- 隐藏的从分配里跳过，但 `dim` 保留 → 再显示按原值回来。

## 操作（全 `tree → tree` 纯函数，用 leaf id 定位）

| 操作 | 作用 |
|---|---|
| `tree-split t target axis id …` | 在 `target` 旁切一刀；同轴则作兄弟插入（不加深），异轴则嵌套 |
| `tree-close t id` | 删叶子；空 split 剪掉、单孩子 split 塌缩 |
| `tree-move t id target axis #:side` | 摘出再插到 `target` 旁（换边 / 换父） |
| `tree-show` / `tree-hide` / `tree-visible?` | 显隐（保留 dim）；`tree-set-visible` 是对称的布尔版 |
| `tree-set-role` | 改叶子 role（`'panel` / `'editor` / `'slot` …）；`pane #:role` 可构造时指定 |
| `tree-set-view` `tree-set-dim` `tree-set-weight` `tree-set-borders` `tree-set-face` `tree-set-visible` | 改叶子字段（按 id） |
| `tree-detach` | 摘出（返回新树 + 被摘节点） |

## 生产者

```racket
(tree->panels     tree area)   ; → (listof panel)，core 直接吃
(tree->placements tree area)   ; → (listof (list id rect))
(tree->cuts       tree area)   ; → (listof cut)
```

- 同层分配：fixed 取固定内容格（+边框），flex 按权重分剩余（钳制 min/max；整数用最大余数法）；
- `leaf` → `make-panel`（`view = #f` 就是空面板）。

### 接缝（相邻面板边界重叠）

相邻面板**共享 1 格接缝**（总格数 = `extent + (可见孩子数-1)`）：接缝两侧各画自己的边，
重叠在同一格 → 由 border-owner（`deep` / `weight` / 列表序）选一个 face = **一条线**。

屏幕边（outer）的框由 dock 决定去不去：叶子有效边框 = **内部边 ∪ (外部边 ∩ 声明的 borders)**。
`outer` 边集随 rect 下推——非最后孩子把「右(`lr`) / 下(`tb`)」变内部，非第一把「左 / 上」变内部。

于是：tree 只留内缝 `right`；editor 全边（左/下是内缝，上/右是外缝）；
status 是 `(up left)`（上缝 + 左接缝）。三块交界处自然收成 `├`，且 dock 去掉屏幕边的框。

> 可用 `tree-resize-seam` 拖缝（吃 `cuts` 的 `cut` + 格数增量）；重叠不影响命中/导航
> （`panel-neighbor` 把“相接 / 重叠 1 格”当作邻接）。

### cut（拖拽缝用）

```racket
(struct cut (axis offset span-lo span-hi path index cells-before cells-after))
```

- `axis 'lr` → 竖缝（`offset` 是列）；`'tb` → 横缝（`offset` 是行）；
- `span-lo/hi`：缝的范围；
- `path` + `index`：缝所属 split 的「孩子下标路径」和左/上**可见**孩子下标；
- `cells-before`/`cells-after`：缝两侧可见孩子当前的 **rect 格数**（tree 里存的是 `dim`）。

拖缝用 `(tree-resize-seam tree cut delta)`：`delta` 是格数增量。
flex+flex 时把两块**总权重**按新格数比例重分（其它兄弟不受影响）；
fixed 侧直接改固定值（**不钉住**，固定面板也能拖）；fixed+flex 时 flex 侧吸收。
底层 `tree-resize-at` 直接改两个可见孩子的 `dim`（数字 = flex 权重）。

命中：`cut-at`（第一条）/ `cuts-at`（全部，交点 = 竖缝 + 横缝 → 角拖）。

## 声明式（`spec.rkt`）

启动时用一小段数据描述布局；`pane` / `lay` **直接产出 tree**，`#:dock` 自动推边框：

```racket
(lay 'lr
  (pane 'tree   #:view tv #:size 1 #:max 30 #:dock 'left)   ; 弹性，最多 30 列
  (lay 'tb
    (pane 'editor #:view ev #:size 1 #:dock 'center)       ; 弹性（吸收剩余）
    (pane 'status #:view #f #:fixed 1 #:dock 'down)))      ; 固定 1 行内容
```

尺寸关键字：

| 写法 | 含义 |
|---|---|
| `#:size n` | 弹性权重 n（默认 1） |
| `#:fixed n` | 固定 n 格**内容**（与 `#:size` 二选一） |
| `#:min n` / `#:max n` | 弹性的内容上下限（配 `#:size`） |
| `#:size (fixed n)` / `(flex w #:min .. #:max ..)` | 直接给 dim |

| dock | 自动边框 |
|---|---|
| `left` | `'(right)` |
| `right` | `'(left)` |
| `up` | `'(down)` |
| `down` | `'(up)` |
| `center` / 不写 | 全边 |

`#:borders` 可显式覆盖。**运行期不再动结构 / 边框，只 `tree-show` / `tree-hide` / `tree-resize-seam`。**

## 浮窗（`float.rkt`）

浮窗用于补全 / 临时信息，**不进布局树**、不参与权重分配，用完即毁：

```racket
;; 锚点 (row,col) + 尺寸 → 夹进屏幕的外框（下方放不下就翻到上方）
(define fr (float-rect-at row col 30 10 area))
(define fs (floats-add fs (make-float 'completion cv fr)))
;; 渲染 / 命中：和平铺 panels 拼一起（浮窗 deep 高，自然在上）
(render-display-patch (append (tree->panels tree area) (floats->panels fs)) focus W H cache)
(panel-at (append tiled (floats->panels fs)) row col)
;; 用完即毁
(set! fs (floats-remove fs 'completion))
```

- 浮窗内容就是 core 的 `view`（和平铺同一套渲染 / 命中）；
- `key` 同名替换并置顶；表头 = 最上；`floats->panels` 分配 `deep > 0`（平铺 = 0）；
- face 默认 `'float-border`（见 `theme/frame.rkt`）。

## 和 core 的边界

- 本层：树 → 绝对 rect 的 `panel`；
- core：命中 / 六向 / 边框合并 / weight / 渲染；
- 宿主：持有树、buffer / view、focus，把两边接起来（见 `temp/20-layout-tree.rkt`、`temp/21-interactive-layout.rkt`）。
