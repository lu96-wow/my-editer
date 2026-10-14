# LAYOUT —— 盒子树布局设计稿

> 目标：固定区域（文件树 / 状态栏 / 其他）+ 可切分编辑区，声明式、可拖、可显隐、
> 可整布局切换、焦点清晰。只有**一个**数据结构、**一个**求解器、**一套**大小策略。

---

## 0. 一句话

> 布局 = 一棵盒子树；每个孩子带 `size(basis flex min)` 与 `visible?`；
> 一个纯函数把「树 × 矩形」解成「各槽矩形 + 缝」。
> 固定区域 = `flex 0`；编辑区 = `flex > 0`；显隐 = `visible?`；切换布局 = 换一棵树。

---

## 1. 数据

```racket
(struct box   (axis children))            ; axis = 'h（左右切）| 'v（上下切）
(struct slot  (id))                       ; 叶子；id 不透明（将来绑 view）
(struct child (size node visible?))       ; visible? = 这棵子树参与布局吗
(struct size  (basis flex min))
;;   basis : 首选绝对尺寸（列 / 行），exact-nonnegative-integer
;;   flex  : 0 = 固定；>0 = 弹性，按权重分余量
;;   min   : 硬下限，exact-nonnegative-integer，>= 0
```

约定：
- `slot` 的 `id` 是用户给的任意值（将来就是 `view` 对象；布局层不解释）。
- `visible? #f` 的子树：**不占位置、不占缝、不产 rect**（显隐）。
- `size` 是意图，不因求解而改写（**不需要 settle**）。

---

## 2. 不变量

| # | 不变量 |
|---|---|
| I1 | 求解后 `Σ 可见孩子长度 + (k-1)·gutter = extent`（k = 可见孩子数） |
| I2 | 任何解出长度 `≥ min`；放不下就**溢出**，绝不压塌 |
| I3 | `flex = 0` 的项在有余量/亏空时**一格不动**（先由弹性项吸收） |
| I4 | 无浮点；取整用最大余数，**同输入同输出**（确定） |
| I5 | 隐藏项不影响其它项的长度（等于从盒子里移除后重解） |
| I6 | `layout` 纯：不依赖焦点/文本/插件，不写状态 |
| I7 | 缝是**全局直线**：同坐标的缝合并，画一次 |

---

## 3. 求解器

```racket
layout : node × rect → (values (listof (slot-id . rect)) (listof seam))
;; seam = (axis offset start end)   ; 一条缝段（axis='h → 竖缝 x=offset；'v → 横缝 y=offset）
```

盒子沿轴：

```
k       = 可见孩子数
content = extent − (k−1)·gutter
lengths = solve-1d(content, [可见孩子的 size])
依次摆放：pos 起，每个占 length，之间留 gutter；交叉轴 = 整个 extent
```

### 3.1 `solve-1d`

```racket
solve-1d : content × (listof size) → (listof length)
```

规则，按顺序：

```
mins = map size-min
Σmin = Σ mins
(1) content ≤ Σmin          → 返回 mins            ; I2 溢出，min 硬底
bases = map size-basis
Σbase = Σ bases
(2) content = Σbase          → 返回 bases           ; 精确快路径
(3) content > Σbase:
      free    = content − Σbase
      weights = map (λ s) (size-flex s)             ; 弹性项按 flex；固定项 0
      weights 全 0 → 全 1                            ; 没有弹性项：余量均分
      extra   = distribute(free, weights, caps = ∞)
      → bases + extra
(4) content < Σbase:
      deficit = Σbase − content
      caps    = map (λ b m) (b − m)                  ; 每项最多能收多少
      ;; 第一轮：弹性项按 flex 权重收
      weights = map (λ s) (size-flex s)
      weights 全 0 → 全 1
      take1   = distribute(deficit, weights, caps)
      rem     = deficit − Σ take1
      ;; 第二轮：还有亏空，再收固定项（此时弹性项已到 min）
      take2   = if rem>0 then distribute(rem, 均权, caps − take1) else 0
      → bases − take1 − take2
```

### 3.2 `distribute`（按权重分配，带上限，取整）

```racket
distribute : amount × weights × caps → (listof allocated)
;;   0 ≤ allocated[i] ≤ caps[i]；Σ allocated = min(amount, Σcaps)；
;;   weights 全 0 → 均分；精确有理数比较，最后**最大余数**落整。
```

实现：蓄水 + 最大余数。
- 按 `share_i = amount · w_i / Σw` 算份额；
- 超过 `cap_i` 的先钉到 cap，余量重分（蓄水）；
- 都没超时取 floor，剩下的整数按「小数部分降序、同位按下标升序」逐个 +1。

性质：确定、无偏、不依赖顺序、无浮点。

---

## 4. 缝 & 全局线

求解时，每个盒子在相邻可见孩子之间产出一条缝段：
- `axis='h`：竖缝 `(h offset=r.start start=box.y end=box.y+box.h)`
- `axis='v`：横缝 `(v offset=r.start start=box.x end=box.x+box.w)`

`merge-seams : (listof seam) → (listof line)`：
- 同 `(axis, offset)` 的段合并成一条 `line`；
- 重叠/相接的 `[start,end)` 合并成最长段；
- 结果即**全局直线**：普通缝 / 十字 / T / 整线统一，`line.rkt` 只做这一步。

画线：一条 `line` 在屏幕对应位置铺一个字形的 run（`─` 或 `│`，交点由上层按字形表处理，或先只画直线、交点后补）。

---

## 5. 声明式 DSL（config 用）

```racket
(hbox child …)                    ; 左→右
(vbox child …)                    ; 上→下
(child node basis flex min)       ; 通用：给一个子树配尺寸
(fixed node basis [min])          ; = (child node basis 0 min)
(flex  node weight [min])         ; = (child node 0 weight min)
(slot  id)                        ; 叶子
(panel id basis [min])            ; = (fixed (slot id) basis min)，语义更清楚
```

内置：`gutter` 默认 1（常量，可写进 box 或全局参数）。

示例：

```racket
;; 左树、右编辑、底部状态栏
(define body
  (hbox (fixed (slot 'tree)   24 10)
        (flex  (slot 'editor)  1)))

(define main
  (vbox (flex  body 1)                ; 主体（box）弹性
        (fixed (slot 'status) 1 1)))
```

编辑区切分 = 把 `(flex (slot 'editor) 1)` 换成 `(hbox (flex (slot 'a) 1) (flex (slot 'b) 1))`（见 §7）。

---

## 6. 显隐 & 动态切换

### 6.1 显隐（面板开/关）

- 显隐是 `child` 上的一个 `visible?`，**不改结构**。
- `set-visible : node × slot-id × bool → node`：找到「直接含该 slot 的孩子」，改 `visible?`。
- 隐藏 = §3 里被跳过：不占位置、不占缝、不产 rect；`node-min` 也不计它。
- **toggle 幂等**：隐藏再显示回到原尺寸意图（`size` 从未被改写）。
- id 稳定：slot 一直在树里，`id`/未来 `view` 的绑定跨显隐不变。

```racket
;; 命令层
(toggle-panel 'tree)   ; = set-visible(layout, 'tree, (not 当前))
```

### 6.2 动态切换布局

- 布局是 **World 里的一个值**；切换 = 用另一棵树替换。
- 支持**具名预设**（config）：

```racket
(define layouts
  '((default . <tree A>)     ; 左树 + 底状态
    (zen     . <tree B>)     ; 只留编辑区
    (top     . <tree C>)))   ; 树在顶
```
- `switch-layout name`：查表 → 替换。切换是 O(1) 换值，无需迁移任何 view（view 绑定在 slot id 上，新树里同名 slot 自动接上）。

> 显隐（局部、频繁）和切换（整体、少）分开：前者翻一个 bool，后者换一棵树。

---

## 7. 拖动

命中一条缝 → 定位「哪个盒子的第 i / i+1 个可见孩子」。把缝拖到绝对位置 `p`：

```
该盒子在轴上的 rect 已知；两个孩子的长度和为 L（含中间那次 gutter 外）。
l_i'      = p − 该盒子起点 − 前面所有孩子与 gutter
l_{i+1}'  = L − l_i'
把 l_i', l_{i+1}' 用 min 夹住（不够则另一边让）
写回：两个孩子的 basis ← l_i', l_{i+1}'（flex 保持）
```

- 固定区域：`flex=0`，只改 `basis`（就是一个数）。
- 编辑 pane：`basis ← 新长度`，`flex` 不变；之后窗口 resize 仍按 flex 分配余量。
- **无 settle**：改动只落在被拖的两个 `basis` 上，其余格不动（I3）。

---

## 8. 焦点移动

叶子 slot 映射到 view。每帧收集可见 slot 的 `(view . rect)`，方向移动 = 纯几何最近邻：

```
neighbor(rects, from, dir) → view | #f
  候选：在 dir 方向上（如 'right：cand.x ≥ from.x+from.w），
        先取与 from 的交叉轴区间**有重叠**的；
  在这些里选「轴间距最小，其次中心距最小」的那个。
```
跨区域、跨 pane、跨显隐边界**同一套规则**，不特判。

---

## 9. 注入点（编辑区自定义摆放）

默认：编辑区就是一个 `box` 子树，走 `layout`。
需要别的摆法时，把它换成一个 `custom` 节点：

```racket
(struct custom (id place panes))     ; place : (listof pane) × rect → (values rects seams)
```

- `place` 由编辑器注入（网格 / 堆叠 / 黄金比 / …），**布局核心不认识它**；
- `place` 必须遵守与 `layout` 相同的契约：返回各 pane 的 rect + seam，且落在给定 rect 内。
- 焦点/边框/显隐对它一视同仁（都吃 rects/seams）。

---

## 10. 模块与接口

```
layout/
  node.rkt     box / slot / child / size + DSL（hbox vbox fixed flex）
               + 查询：ids, visible-ids, path-of, set-visible, replace-slot
  solve.rkt    layout : node × rect → (slot . rect)s + seams
               distribute（蓄水 + 最大余数）
  drag.rkt     hit-seam : node × rect × point → (path . i) | #f
               drag-seam : node × path × i × point × rect → node
  line.rkt     merge-seams : (listof seam) → (listof line)
  neighbor.rkt neighbor : (listof (view . rect)) × view × dir → view | #f
```

对外纯函数就五个：`layout`、`hit-seam`、`drag-seam`、`merge-seams`、`neighbor`。
`node.rkt` 的 `set-visible` / `replace-slot` 是结构手术（也是纯的）。

---

## 11. 测试用例（不变量）

1. **求和守恒**：任意树 × 任意 rect，`Σ可见长度 + (k−1)·gutter = extent`（沿每个盒子）。
2. **min 硬底**：把 rect 缩到 `Σmin` 以下，各段 = min，不崩。
3. **固定不动**：只改 rect 的 extent，`flex=0` 项长度恒定。
4. **隐藏等价**：`set-visible #f` 后解，等于把该孩子删掉再解。
5. **toggle 幂等**：`set-visible #f` 再 `#t`，得到的树 `equal?` 原树。
6. **切换保留**：`switch-layout` 后，新树里同名 slot 的 view 绑定不变。
7. **拖动局部**：拖一条缝，只有被拖的两个 `basis` 变。
8. **确定**：同一输入解两次 `equal?`（含取整）。
9. **缝合并**：三列并排的相邻列 → 两条竖缝；若它们 y 范围相同且 x 不同 → 两条线；若上下堆叠对齐 → 合并成一条整线。
10. **邻居**：2×2 网格，从左上 `down` → 左下，`right` → 右上。
