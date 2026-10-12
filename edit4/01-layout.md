# edit4 · 01 布局核心（抽象模型稿）

> 目标：把「布局」从窗口/文档/插件里剥出来，变成一个**自洽的纯代数**。
> 命令层将来只是「对布局代数求值」；其余全部靠边。
> 本文件只谈布局，不引入 vid / document / plugin / face。

---

## 0. 布局问题的一句话

> 一个矩形区域，按**树形**（guillotine）切给若干 pane；相邻 pane 之间留固定厚度
> 的**缝**；每段有自己的**最小尺寸**和**弹性意图**。求：每个 pane 的矩形、
> 每条缝的坐标，以及「拖动一条缝」如何改尺寸。

布局 = **1-D 分配** + **树结构** + **几何投影** + **缝的拖拽代数**。四件事必须分开。

---

## 1. edit3 现状的不干净处（精确）

| # | 问题 | 后果 |
|---|---|---|
| 1 | `layout/solve/hit/surgery/float` 全在 `layout.rkt`（460 行） | 无法单独理解/测试 |
| 2 | `handle` 携带求解器内部量 `(pos,index,lens,mins,bases)` | 几何不是「树×尺寸」的纯函数，烘进了求解器状态 |
| 3 | `boundary` 与 `junction` 两套 handle；junction 靠 O(area) 扫格 + 共线聚合 | 特例补丁，十字/T 字要分别照顾 |
| 4 | 叶子 `min` 存两份（`tile.min` 2-D + `item.min` 1-D） | 冗余、易不一致 |
| 5 | resize 分散在 `layout.rkt` / `interaction.rkt` / `resize.rkt` | 平铺与浮窗两套 |
| 6 | 6+ 个树手术各自递归 | 重复、易错 |
| 7 | `layout` 认识 `vid`/`border` | 布局耦合到视图/主题 |

---

## 2. 目标：三件独立的事

```
(1) 求解器 solve-axis   ：1-D，轴无关，唯一的「难数学」
(2) 结构 tree + 代数     ：树、min、增删/改尺寸（不碰几何）
(3) 几何 geometry        ：树 × 区域 → pane 矩形 + 缝（纯投影）
```

外加两个薄层：
```
(4) 命中 hit            ：几何上的查表
(5) 浮窗 float          ：正交覆盖层（不参与切分）
```

---

## 3. 最小模型

### 3.1 尺寸意图（1-D，轴无关）

```racket
(struct size (basis flex min) #:transparent)
;; basis : 基准格数（固定部分）
;; flex  : 弹性权重，0 = 固定；>0 = 按权重分余量（伸缩同权）
;; min   : 硬下限（≥1）
```

**简化 1**：把 edit3 的 `grow/shrink` 两个权重合成一个 `flex`。
理由：min 是硬不变量，shrink 只在 min 之上有意义，用同一个权重足够，且少一个自由度。

### 3.2 结构（2-D）

```racket
(struct leaf  (id min))                ; id 不透明；min = (cons min-w min-h) ≥ (1 . 1)
(struct split (axis gutter kids))      ; axis = 'h | 'v；kids = (listof child)
(struct child (size node))             ; 边上的尺寸意图

;; 不变量
;;  · leaf.min ≥ (1 . 1)
;;  · split 至少 2 个 kid
;;  · split 的 min 是**导出**的，不存：
;;      h: (Σ kid.min-w + (k-1)*gutter ,  max kid.min-h)
;;      v: (max kid.min-w ,  Σ kid.min-h + (k-1)*gutter)
```

**简化 2**：`min` 只存叶子，split 的 min 现算（可 memo）。
**简化 3**：`gutter` 是 split 的属性（可全局默认），不是散落的 `n-1` 魔法数。
**简化 4**：布局**只认 `id`**。id→vid、id→border、id→document 全在外面绑定。

### 3.3 布局是一个纯值

```racket
;; 一个布局就是 (leaf|split)；没有隐藏状态、没有可变盒子。
;; 焦点也是外面的概念（布局只暴露 id 集合 + 空间查询）。
```

---

## 4. 求解器（唯一难点，单独成文件）

```racket
;; solve-axis : extent gutter items -> (listof Nat)
;;   items : (listof size)  （k 个）
;;   content = max 0 (extent - (k-1)*gutter)
```

策略（明确、可测、确定）：

1. `content ≤ Σmin` → 返回各 `min`（**溢出也不压塌**；min 是硬不变量）。
2. 否则 `free = content - Σbasis`：
   - `free > 0`：多出的按 `flex` 权重分（全 0 → 全给第一段），**用最大余数法**避免抖动。
   - `free < 0`：按 `flex` 权重削；**先削到 min 为止**，削不动的把缺口转给还能削的。
3. 结果逐个 `max min`。

**关键**：剩格分配用**最大余数法**（largest remainder），而不是 edit3 的
「余数全丢最后一个 grow」——消除随顺序/段数的抖动。

---

## 5. 几何（纯投影：树 × 区域 → 矩形 + 缝）

```racket
;; geometry : node area -> (values (hash id rect) (listof cut))
;;   area : (rect x y w h)
```

递归：对 split 沿轴 `solve-axis` 得到各 kid 长度，依次放置，间隔放 `gutter` 格。

```racket
(struct cut (axis offset segs) #:transparent)
;; offset : 全局坐标（h 缝的 x / v 缝的 y）
;; segs   : (listof seg)，同一条直线上的**所有**缝段
(struct seg (path index len-i len-j min-i min-j basis-i basis-j) #:transparent)
```

**这里的核心简化（本设计最重要的一点）**：

> **缝不是「两个 pane 之间的一段」，而是「一条全局直线」。**

同一坐标 `offset` 上的所有竖直缝段合并成**一条 cut**；横向同理。
于是：

- 一条普通缝 = 只有 1 段的 cut；
- **整条线**（多列布局）= 同坐标多段的 cut；
- **十字/T 字交点 = 同时落在一条 h-cut 和一条 v-cut 上**。

不需要 `boundary`/`junction` 两种 handle，不需要共线聚合的特例。

---

## 6. 命中

```racket
;; hit : geometry x y -> (or pane-id (listof cut) #f)
;;   · 点在 pane 内容 → id
;;   · 点在某条缝 → 该 cut（1 条）
;;   · 点在两缝交叉 → 两条 cut（(cut-h cut-v)）
```

拖拽时：`dx → 所有 v-cut`（竖直位移不动竖缝？见 §7），`dy → 所有 h-cut`。
十字 / T / 整条线三种情况自动统一。

---

## 7. 编辑代数（命令层的接口）

布局对外只暴露**纯函数代数**；命令层 = 求值这些 op。

```racket
;; ---- 尺寸 ----
;; 拖动一条 cut（快照式，不漂）：从按下时快照算，Σbasis 每 split 恒定。
(move-cut : (listof seg) delta -> (listof (list path index bi bj)))
;;   先求所有 seg 允许区间的**交集**（min 约束），clamp 后再写回各 split 的 basis。

;; ---- 结构 ----
(split-leaf  n id axis side new-node) -> n     ; 把一个 leaf 换成 (原 leaf | new)
(remove-leaf n id) -> n                        ; 摘 leaf；空 split 收拢
(insert-side n side size new-node) -> n        ; 贴根/贴主区插一段（区域用）
```

实现上只留**一个通用递归 walker** + 一个 path 定位：

```racket
(path-of n id) -> path | #f
(modify-path n path f) -> n        ; 其余手术都用它写
```

去掉 edit3 那 6 个各自递归的 `layout-*`。

---

## 8. 浮窗（正交层，不参与切分）

```racket
(struct float (id anchor size) #:transparent)
;; anchor : (screen | wid, h, v, dx, dy)
;; solve : screen + 已布好的 pane 矩形 → float 矩形（顺序 = z）
```

浮窗**不进树**。布局先解树，再用树的结果解浮窗。浮窗不互为锚（或后续单独扩展）。
浮窗的拖拽复用同一个「rect 变换」思路（move / resize 角），但与 cut 无关。

---

## 9. 布局**不该**知道什么（硬边界）

- 不认识 vid / document / cursor / face / border / 主题；
- 不认识 keymap / command / plugin / hook；
- 不认识「面板」「区域」「焦点」——这些是上层对 id 的**标注**；
- 不做 IO、不碰 State、不做副作用。

> 判断标准：`layout/*` 的任何函数签名里不应出现以上词汇。

---

## 10. 模块划分（建议）

```
edit4/layout/
  size.rkt        ; size + solve-axis（+ 最大余数分配）
  tree.rkt        ; leaf/split/child + min + path/modify + 三个手术
  geometry.rkt    ; geometry -> (rects, cuts)
  hit.rkt         ; hit + move-cut
  float.rkt       ; anchor -> rect
```
四个文件、每个一个概念；`layout.rkt` 只做 re-export（或不存在）。

命令侧（下一步再设计）：
```
edit4/command/
  op.rkt          ; op 数据 + 解释器（split/close/move-cut/insert-side/focus）
  keymap.rkt      ; binding -> op 序列
```

---

## 11. 待确认的决策（需要你拍板）

1. **`flex` 单权重**够用吗？（还是要保留 grow/shrink 两个权重）
2. **`min` 存叶子 + split 现算**，还是每个节点都存 2-D min？
3. **缝的厚度**：全局常量，还是每个 split 可配？
4. **cut 按坐标相等合并**：确认「同坐标 = 同一条线，拖动一起动」符合预期？
5. **id 是否需要稳定跨手术**？（决定用 path 还是显式 node id）
6. 浮窗是否允许锚到浮窗？（现在只锚 screen / pane）

> 先不写实现。确认模型后，再从 `size.rkt` + `tree.rkt` 落代码。
