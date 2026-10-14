# edit-tui/layout —— 布局逻辑（设计草案）

`layout-base/` 是**几何原语**（rect / panel / 内容区 / 命中）。
本目录是**布局逻辑**：编辑器级的窗口组织 —— 拆分、停靠、浮窗、拖动改大小、焦点。

先列要做的编辑器功能，再倒推逻辑。

## 1. 我们要的编辑器功能

| 功能 | 说明 |
|---|---|
| 编辑窗拆分 | 左右 / 上下，可嵌套；每个窗显示一个 view |
| 边缘停靠 dock | 文件树（左/右）、状态栏（下）、日志（下）；固定尺寸、可显隐、可拖宽 |
| dock 多面板 | 一个 dock 在多个面板间切换（互斥，如 tree ↔ buffers） |
| 浮窗 | 补全 / 弹窗 / prompt；锚定、可移动、可缩放、置顶 |
| 鼠标 | 点聚焦；**拖边框改尺寸**；拖浮窗移动 / 改尺寸 |
| 键盘 | 方向移焦点；拆分 / 关闭；显隐 dock |
| 约束 | 每个窗有最小尺寸 |

## 2. 布局逻辑要回答什么（核心）

### A. 投影：state + 屏幕尺寸 → 几何
1. 每个窗的**外框矩形**在哪？
2. 每个窗的**内容区**在哪、多大？（给 viewport、给点击换算）
3. 有哪些**可拖动的缝**？各自的位置 / 方向 / 跨度 / 两侧是谁？
4. z 序：谁盖谁？
5. 整体最小可放下尺寸？

### B. 命中：state + (x,y) → 目标
6. 点在哪个窗的内容区？（→ 聚焦 / 点击）
7. 点在不在某条缝上？（→ 拖动改尺寸）
8. 点在不在浮窗上？哪个部位（移动 / 四角 / 四边缩放）？
9. 点 → 文档坐标（内容区 + view 坐标）

### C. 操作：state × op → state
10. 拆分一个窗（左右 / 上下）：两块怎么分、min 约束
11. 关掉一个窗：腾出的空间给谁
12. **拖一条缝 delta**：两侧尺寸怎么变、min 约束、保持对齐
13. 显示 / 隐藏一个 dock
14. 移动 / 缩放一个浮窗
15. 设焦点 / 方向移焦点（下一个是谁）
16. 交换两个窗的内容

### D. 不变量
17. min 尺寸；不越界（Σ ≤ 屏宽 / 屏高）
18. **对齐**：同一条缝两侧的边缘一致（拖一条缝不能让别的窗错位）
19. 浮窗不进平铺、不参与缝

> 其中 **6/7/8/12/15/18** 是最吃设计的：命中要区分「内容 / 缝 / 浮窗部位」，拖动既要改尺寸又要保对齐、还受 min 约束。

## 3. 数据模型：两个选项

**共同点**：窗 = `layout-base` 的 `panel`（rect + 四边可选边框 + deep + face）+ 一个 id；浮窗 = deep 高的 panel，独立层。焦点 = 一个 id。

分歧在「平铺窗的 rect 谁维护 / 缝从哪来」：

### 选项 A：显式 rect，缝从 rect 派生
- state 只存每个 tiled pane 的 rect；缝 = 两条相邻 pane 共享的边界。
- 拖动：命中的边界 → 找出**共享该边界的全部 pane**（同一列/行跨度），一起平移边界。
- 优点：和「布局就是一堆面板」一致；无求解器。
- 难点：缝的**跨度**要算对（T/十字处只动该跨度内的）；对齐靠「一起动」。

### 选项 B：嵌套拆分树（极简版）
```racket
node = leaf(id) | split(axis, kids)      ; kids 沿 axis 排，(size . node)
```
- rect 由结构 + 尺寸算出；一条缝就是一个 split 的分隔。
- 拖动：命中的分隔 → `kids[i] ± delta / kids[i+1] ∓ delta`（夹 min）；对齐天然成立。
- 优点：拖动/对齐/嵌套都最直接；命中就是「找到那条分隔」。
- 代价：需要一个 resize 尺寸策略（屏幕变化时怎么分），但可以极简：
  「精确相等就原样；否则把差额补给弹性项、夹 min」——不需要 edit4 的“不漂 + 快路径 + settle”。

> 你上次否掉的是 edit4 那套**求解器**（basis/elastic/settle/cuts），不是「树」这个概念。
> 就 “拖动 + 对齐” 这个需求看，**B 反而更简单、更不容易出 bug**；A 要把“缝的跨度 / 一起动”重写一遍，等于把树重造。

**我的建议：B（极简树）**；`layout-base` 的 `panel` 降级为「树 → 渲染数据」的投影产物（`layout -> (listof panel)`），边框照旧走 `core-render/border.rkt`。

## 4. API 草图（按 B）

```racket
;; state
(struct layout (root focus floats) ...)   ; root : node | #f；floats : (listof float)
;; node = leaf(id) | split(axis gutter kids)（kids : (listof (cons size node))）

;; 投影
(layout-panels  layout size)        ; -> (listof panel)，喂 core-render
(layout-seams   layout size)        ; -> (listof seam)，给命中 / 拖动
(layout-hit     layout size x y)    ; -> pane-id | seam | float-part | #f

;; 操作（纯，state -> state）
(split   layout id axis)            ; 拆分
(close   layout id)                 ; 关闭
(resize  layout seam delta)         ; 拖缝
(show/hide layout region-id)
(float-move/resize layout id delta)
(focus-set layout id)
(focus-move layout dir)             ; 方向移焦点

;; 命中目标
(struct seam (axis pos lo hi path i j))     ; 拖动回写用
;; float-part = 'move | 'nw | 'ne | 'sw | 'se
```

## 5. 待定（要拍板）

1. **模型**：A（显式 rect + 派生缝）还是 **B（极简树）**？我倾向 B。
2. **dock 尺寸**：dock 固定（拖只改 dock 自身宽度）/ 编辑区弹性；用不用「固定 vs 弹性」标记（不用则屏变时按比例）。
3. **缝的宽度**：两 pane 共享 1 格（重叠 1）还是中间留 1 格 gutter？影响拖动命中区与边框画法。
4. **浮窗**：锚定到屏幕 / 某个 pane？移动存绝对矩形还是锚点+偏移？
5. **拆分新窗的尺寸**：对半？继承比例？
6. **关闭窗**：空间给相邻窗还是留空？
7. **焦点方向移动**：按几何邻接（左/右/上/下最近）算。
