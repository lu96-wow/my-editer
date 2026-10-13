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
panel-group（组合，内容）      dock（槽位，布局）              bindings（World）
  (id members active)    →     (id group side size anchor)  →  wid → vid
```

- **`panel-group`**：只描述「哪些面板互斥共用一槽、默认显示谁」。纯内容，不碰几何。
- **`dock`**：引用一个 group，决定 `side / size / anchor / 初始显隐`。布局概念。
- **键表**：只引用 `dock-id`（`region-keys`）。组内怎么组合由 group 决定，键表不管。

已在 `config/layout.rkt` 落地（两表 + 合成）：
```racket
(define panel-groups
  '((sidebar ("*tree*" "*buffers*") "*tree*")   ; tree+buffers 是一个组合
    (log     ("*log*")              "*log*")))

(define docks
  '((sidebar left   auto root shown)
    (log     bottom 6    main hidden)))
```
于是 `C-b` 切的是「sidebar 这个组合整体」，`M-b` 是组内 tree↔buffers 循环，`M-t` 切到组内 tree——
**组合整体操作，与键表一致**；想真正拆成两个面板，必须显式建两个 group + 两个 dock，不再是顺手写单成员 region。

### 顺带统一那四条路径
理想终局（分步做）：
- *status* 也变成一个 dock（bottom / size 1 / group `(status)`），不再在 boot 里直接绑窗口；
- *input* 就是 status 组合里的一个成员，`prompt-open` 用 `region-activate` 切换 active，而不是自己换 vid；
- 浮窗保留（它本来就是「另一处显示同一 vid」），但复用同一套 `content-bind`。

这样「放一个 panel」只有一条路径：**选一个 dock，切到某个成员**。

## 4. root 区域顺序稳定（已落）→ 可折叠 dock（进阶）

### 4.1 已落：root 链按 order 重建

给 `region` 加了 `order`（在 `docks` 里的声明次序）。`region-show` 对 `anchor=root` 的区域，
插入后调 `rebuild-root-docks`：把所有已显示的 root 区域按 `order` 从内到外重新嵌套
（先摘掉、再按序 `insert-side`，尺寸取当前 basis / 记住的 size）。于是：

- **任意 toggle 序列后，root 区域嵌套顺序 = `docks` 声明顺序**（toggle 幂等）；
- 树内其它结构（编辑器比例、main 区域）不动（只重包 root 链）；
- `edit4-test/sidebar.rkt` 已写了顺序稳定的回归。

局限：重建时 root 窗口会重新分配 id（≥ 2 个 root 区域时），想 id 也跨显隐稳定就上 4.2。

### 4.2 进阶：可折叠 dock（尺寸手术，id 也稳定）

现在显隐是**布局手术**（`insert-side` / `remove-leaf`），4.1 把顺序钉死了但还是会换 id。
要连 id 都稳定，改成 **尺寸手术**：dock 的叶子一直在树里，隐藏 = 把它的 `child-size` 设成 `(size 0 #f)`。

需要 layout 支持「折叠子节点」：

- **约定**：`(size 0 #f)`（basis 0、固定）且叶子 min `(0 . 0)` 的子节点 = 折叠，不占位置、不占缝。
- **`layout/size.rkt`**：`solve-axis` 前先把 kids 过滤成「活动」子集（去掉折叠），对活动子集算
  gutter 与分配，折叠的分配 0。或给 solve-axis 加一个 `active?` 参数。
- **`layout/tree.rkt`**：
  - `leaf` 允许 `min = (0 . 0)`（dock 叶子用）；
  - `node-min` / `axis-min` 忽略折叠子节点；
  - `ids` 仍包含折叠叶（id 不复用），另给 `visible-ids`（`has-id?` / 焦点 / `content-editor-windows` 用）。
- **`layout/geometry.rkt`**：`walk` 跳过折叠子节点 → 不产生 rect、不产生 seg（缝自然消失）。
- **`layout/hit.rkt` / 拖拽**：折叠节点没有 rect/seg，自动不可命中，无需改动。

`region-hide` / `region-show` 就退化成：
```racket
hide: 把 wid 的 child-size 设 0，记住原尺寸；焦点若在此窗则回退。
show: 把 child-size 设回记住的尺寸；不插入、不删除 → 顺序永远不变。
```
收益：
- **toggle 幂等**、root 区域顺序稳定（不再依赖声明顺序 / 是否 toggle 过）；
- dock 的窗口 id 跨显隐保持（focus 记忆、`has-id?` 更稳）；
- 少了 `insert-side` / `insert-adjacent` / `remove-leaf` 三套手术在显隐路径上的使用（保留给
  「新增/删除 dock」这种真正的结构变更）。

> 组合与布局正交：组合（group）根本不需要 layout 知道；layout 只需把「一个槽的一个叶子」
> 稳定地显示/折叠。这也是为什么「更好的 layout 设计」能让组合更简单——它把位置/显隐
> 从组合里彻底摘掉。

## 5. 迁移步骤（低风险 → 高收益）

1. ✅ **config 两表**（group / dock，已落）：组合成为一等概念，键表只认 dock id。
2. ✅ **root 区域顺序稳定**（第 4.1 节，已落）：root 链按 `order` 重建，toggle 不漂。
3. **status / input 收敛为一个 dock**：去掉 boot 的直接绑定与 prompt 的换 vid，改走 dock。
4. **可折叠 dock**（第 4.2 节）：改 size / tree / geometry 三处，`region-show/hide` 退化为改尺寸，id 跨显隐稳定。
5. 若还想支持「同一 group 放多处」（如侧栏 + 浮窗）：dock 之间共享 group，bindings 允许多绑。

## 6. 不变量（建议写进测试）

- 一个 dock 的 `wid` 在 `hide → show` 后不变（稳定 id）。
- 任意 toggle 序列后，所有 dock 的相对嵌套顺序 = `docks` 声明顺序。
- 组合只由 `panel-groups` 决定；键表只引用 dock id，不含成员名。
