# edit4 · 11 面板组合 / 槽位 / 布局：把「组合」和「位置」拆开

> 起因：把 tree 和 buffers 拆成两条 region 后，键表语义（C-b / M-b / M-t）对不上，
> 且 root 区域 toggle 会改变嵌套顺序。根因是 `region` 把三件事混在一层。
> 这份文档给出「组合 / 槽位 / 显隐」三轴的拆法和相应的布局改进。

---

## 1. 现状：面板怎么被显示，有四条互不相同的路径

| 路径 | 代码 | 面板 |
|---|---|---|
| **区域成员**（互斥 + 位置 + 显隐） | `content/region.rkt` + `content.regions` | tree / buffers / log |
| **直接绑定**（写死窗口） | `boot.rkt`：`(content-bind c 1 vid-st)` | *status* |
| **临时换 vid**（借状态栏窗口） | `prompt.rkt`：`prompt-open` 把 *input* 绑到 status 窗，`prompt-close` 换回 | *input* |
| **浮窗**（不进平铺树） | `content/float.rkt` + `config/floats.rkt` | tree / buffers / log |

四条路径都在做同一件事——**把某个 panel vid 绑到某个窗口 / 浮窗**——但各自实现了绑定、
显隐、焦点。`region` 只是其中之一。

## 2. 诊断：`region` = 组合 + 位置 + 显隐，三件事混在一起

```
struct region (side size members active anchor wid)
                 │     │      │       │      │      └ 运行时窗口
                 │     │      │       │      └ 锚点（放置）
                 │     │      │       └ 当前成员（组合状态）
                 │     │      └ 成员列表（组合）★
                 │     └ 尺寸（放置）
                 └ 边（放置）
```

- **组合（combination）**：哪些面板共用一个窗口、互斥显示。`members` + `active`。
- **放置（placement）**：这个窗口在哪、多大。`side` / `size` / `anchor`。
- **显隐（visibility）**：这个窗口是否显示。`wid`（#f = 隐藏）。

问题：
1. 配置里写一条 `region` 就同时决定了三件事；把 tree / buffers 写成两条，就同时改了
   **组合**（一个组 → 两个组）和**放置**，而键表 `region-keys` 只认 `region` id、默认语义
   建立在「tree+buffers 同组」上 → 冲突。
2. `region-show` 用 `insert-side` 把新窗口**包住整棵树**，所以 root 区域的嵌套顺序 =
   插入顺序；boot 用声明顺序，hide→show 又变成最外层 → **toggle 不幂等**（见实测）。
3. 同一个概念（放 panel）有四种实现，彼此不知道对方。

## 3. 设计：三轴分离

```
panel-group（组合，内容）      dock（槽位，布局）                    bindings（World）
  (id members active)    →     (id group side size min anchor)  →  wid → vid
```

- **`panel-group`**：只描述「哪些面板互斥共用一槽、默认显示谁」。纯内容，不碰几何。
- **`dock`**：引用一个 group，决定 `side / size / min / anchor / 初始显隐`。布局概念。
- **键表**：只引用 `dock-id`（`region-keys`）。组内怎么组合由 group 决定，键表不管。

已在 `config/layout.rkt` 落地（两表 + 合成）：
```racket
(define panel-groups
  '((sidebar ("*tree*" "*buffers*") "*tree*")   ; tree+buffers 是一个组合
    (status  ("*status*" "*input*") "*status*")
    (log     ("*log*")            "*log*")))

;; (id side size min anchor shown?)
(define docks
  (list (list 'sidebar 'left   'auto sidebar-min-width 'root 'shown)
        (list 'status  'bottom 1    1                 'main 'shown)
        (list 'log     'bottom 6    2                 'main 'hidden)))
```
于是 `C-b` 切的是「sidebar 这个组合整体」，`M-b` 是组内 tree↔buffers 循环，`M-t` 切到组内 tree——
**组合整体操作，与键表一致**；想真正拆成两个面板，必须显式建两个 group + 两个 dock，不再是顺手写单成员 region。

### 四条路径已收敛（已落）
- *status* 是一个 dock（bottom / size 1 / group `(status input)`）——boot 不再直接绑窗口；
- *input* 是 status 组合里的一个成员，`prompt-open` 用 `region-activate!` 切 active，
  `prompt-close` 切回 `*status*`（不再自己换窗口 vid）；
- 浮窗保留（它本来就是「另一处显示同一 vid」）。

现在「放一个 panel」只有一条路径：**选一个 dock，切到某个成员**（浮窗除外）。
状态栏在 mount 顺序上排在 log 之前，所以 log 显示时插在编辑器与状态栏之间，状态栏始终在最底。

## 4. 可折叠 dock（已落）

**显隐 = 尺寸手术，不是布局手术。** boot 时把**所有** dock 的叶子都挂进树（隐藏的 size 0），
之后 show/hide 只改 `child-size`，永不插入/删除：

```racket
mount : 插入常驻叶子（min (0 . 0)）；shown? 决定初始 size
hide  : 叶子 child-size 设 0（记住当前尺寸）—— 折叠
show  : 叶子 child-size 设回记住的尺寸 ── 展开
```

layout 层的「折叠子节点」支持（已落）：

- **约定**：`(size 0 #f)`（固定、basis 0）的子节点 = 折叠；dock 叶子 min `(0 . 0)`。
- **`layout/size.rkt`**：`solve-axis` 带 `actives` 参数；折叠项长度 0、不占缝、不参与增/减，
  返回与 kids 等长（下标对齐）。
- **`layout/tree.rkt`**：`node-min` 忽略折叠子节点；新增 `collapsed-child?` / `visible-ids`
  （`ids` 仍含折叠叶 → id 不复用；焦点/命中/导航用 `visible-ids`）。
- **`layout/geometry.rkt`**：`walk` 只摆可见子节点；缝只出现在相邻可见子节点之间，
  `seg` 记两侧可见下标 `index/index2`（中间可能隔着折叠子节点）。
- **`layout/settle.rkt`** / **`hit.rkt`**：同样按 actives 走；折叠项无 rect/seg → 自动不可命中。
- **`layout/validate.rkt`**：叶子 min 允许 `(0 . 0)`（dock）或 ≥ `(1 . 1)`（普通）。

于是：

- **toggle 幂等**，root 顺序恒 = 挂载（声明）顺序 —— 不需要 `order` 字段 / 重建；
- **dock 的叶子 id 与窗口 id 跨显隐稳定**（`region.leaf` 常驻，`wid` 隐藏时 #f）；
- **最小尺寸**：`docks` 每项带 `min`，mount 时把 dock 叶子的 `min` 设成它 → 拖拽 / 缩屏
  都挤不到 0（折叠靠 basis 0 判定，与叶子 min 无关，所以不影响折叠）；展开时再
  `max(min, 记住的 size)` 兜一层，隐藏时保存的尺寸也向下夹到 min。
- 显隐路径不再用 `insert-side` / `remove-leaf`（保留给真正的新增/删除 dock）。

> 组合与布局正交：组合（group）根本不需要 layout 知道；layout 只需把「一个槽的一个叶子」
> 稳定地展开/折叠。这也是为什么「更好的 layout 设计」能让组合更简单——它把位置/显隐
> 从组合里彻底摘掉。

## 5. 迁移步骤（低风险 → 高收益）

1. ✅ **config 两表**（group / dock，已落）：组合成为一等概念，键表只认 dock id。
2. ✅ **可折叠 dock**（第 4 节，已落）：mount-all + 尺寸手术；显隐不改结构，
   root 顺序恒等于挂载顺序，叶子/窗口 id 跨显隐稳定。
3. ✅ **status / input 收敛为一个 dock**（已落）：去掉 boot 直接绑窗与 prompt 换 vid，
   改走 `region-activate!`；四条显示路径归一（浮窗除外）。
4. 若还想支持「同一 group 放多处」（如侧栏 + 浮窗）：dock 之间共享 group，bindings 允许多绑。

## 6. 不变量（建议写进测试）

- 一个 dock 的 `wid` 在 `hide → show` 后不变（稳定 id）。
- 任意 toggle 序列后，所有 dock 的相对嵌套顺序 = `docks` 声明顺序。
- 组合只由 `panel-groups` 决定；键表只引用 dock id，不含成员名。
