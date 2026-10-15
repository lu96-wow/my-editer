# edit-tui/layout —— 布局树（core 之上，宿主之下）

core 只吃 `(listof panel)`；本层负责**产出**它：把布局树解成带绝对 rect 的面板。
不 require tui，可单测。

```
tree.rkt    布局树（纯）：结构 + 操作（split / close / move / show / hide / resize）
spec.rkt    声明式布局（启动时定义）：dock → 边框规则 + 编译成树
solve.rkt   树 → panels / placements / cuts（纯）
main.rkt    入口
```

## 树

```
node = leaf | split
  (leaf id view borders face weight size visible?)
      id      宿主身份（core 的 panel 没有 id）
      view    core 的 view | #f（空面板）
      borders 每边可选；**默认全边**，只有知道位置的特殊面板才自定义缝
      weight  边框 face 权重（→ core panel 的 weight，焦点框抬边框用）
      size    沿父轴的**权重**
      visible? 显隐
  (split axis children size visible?)
      axis    'lr（左右并排，竖缝）| 'tb（上下堆叠，横缝）
      children n 叉
```

**尺寸是权重**：同层按 `size` 比例分配沿轴额度（窗口 resize 自动按比例）。
隐藏的从分配里跳过，但 `size` 保留 → 再显示按原比例回来。

## 操作（全 `tree → tree` 纯函数，用 leaf id 定位）

| 操作 | 作用 |
|---|---|
| `tree-split t target axis id …` | 在 `target` 旁切一刀；同轴则作兄弟插入（不加深），异轴则嵌套 |
| `tree-close t id` | 删叶子；空 split 剪掉、单孩子 split 塌缩 |
| `tree-move t id target axis #:side` | 摘出再插到 `target` 旁（换边 / 换父） |
| `tree-show` / `tree-hide` / `tree-visible?` | 显隐（保留 size） |
| `tree-set-content` `tree-set-size` `tree-set-weight` `tree-set-borders` `tree-set-face` | 改叶子字段 |
| `tree-detach` | 摘出（返回新树 + 被摘节点） |

## 生产者

```racket
(tree->panels     tree area)   ; → (listof panel)，core 直接吃
(tree->placements tree area)   ; → (listof (list id rect))
(tree->cuts       tree area)   ; → (listof cut)
```

- 同层按权重比例分整数格（余数补给前面几块）；
- `leaf` → `make-panel`（`view = #f` 就是空面板）。

### 接缝（相邻面板边界重叠）

相邻面板**共享 1 格接缝**（总格数 = `extent + (可见孩子数-1)`）：接缝两侧各画自己的边，
重叠在同一格 → 由 border-owner（`deep` / `weight` / 列表序）选一个 face = **一条线**。

屏幕边（outer）的框由 dock 决定去不去：叶子有效边框 = **内部边 ∪ (外部边 ∩ 声明的 borders)**。
`outer` 边集随 rect 下推——非最后孩子把「右(`lr`) / 下(`tb`)」变内部，非第一把「左 / 上」变内部。

于是：tree 只留内缝 `right`；editor 全边（左/下是内缝，上/右是外缝）；
status 是 `(up left)`（上缝 + 左接缝）。三块交界处自然收成 `├`，且 dock 去掉屏幕边的框。

> 可用 `tree-resize-at` 拖缝（cuts 里带 `path` + `index`）；重叠不影响命中/导航
> （`panel-neighbor` 把“相接 / 重叠 1 格”当作邻接）。

### cut（拖拽缝用）

```racket
(struct cut (axis offset span-lo span-hi path index before after))
```

- `axis 'lr` → 竖缝（`offset` 是列）；`'tb` → 横缝（`offset` 是行）；
- `span-lo/hi`：缝的范围；
- `path` + `index`：缝所属 split 的「孩子下标路径」和左/上孩子下标 →
  `(tree-resize-at tree path index s1 s2)` 改这两个孩子的 `size`，嵌套也准；
- `before`/`after`：缝两侧当前格数（拖拽按格数改 size）。

命中：`cut-at`（第一条）/ `cuts-at`（全部，交点 = 竖缝 + 横缝 → 角拖）。

## 声明式（`spec.rkt`）

启动时用一小段数据描述布局；`#:dock` 自动推边框：

```racket
(spec->tree
 (lay 'lr
   (pane 'tree   #:view tv #:size 4 #:dock 'left)      ; 左侧 → 只留内缝 'right
   (lay 'tb
     (pane 'editor #:view ev #:size 3 #:dock 'center)  ; 中 → 全边
     (pane 'status #:view #f #:size 1 #:dock 'bottom)))) ; 底 → 只留 'up
```

| dock | 自动边框 |
|---|---|
| `left` | `'(right)` |
| `right` | `'(left)` |
| `top` | `'(down)` |
| `bottom` | `'(up)` |
| `center` / 不写 | 全边 |

`#:borders` 可显式覆盖。**运行期不再动结构 / 边框，只 `tree-show` / `tree-hide`。**

## 和 core 的边界

- 本层：树 → 绝对 rect 的 `panel`；
- core：命中 / 六向 / 边框合并 / weight / 渲染；
- 宿主：持有树、buffer / view、focus，把两边接起来（见 `temp/20-layout-tree.rkt`、`temp/21-interactive-layout.rkt`）。
