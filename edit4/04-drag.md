# edit4 · 04 拖拽（鼠标交互）在命令模型里怎么放

> 拖拽是**跨事件的手势**（press → move… → release）。命令是纯函数、单事件。
> 设计要解决的核心问题：**手势状态放哪、怎么和命令模型统一。**

---

## 0. 一句话

> 拖拽 = `World.drag` 里的一个**快照** + 三个命令（press/move/release）。
> move 只依赖「按下时的快照 + 总位移」，所以幂等、不漂；事件与命令仍然分离。

---

## 1. 为什么不能「无状态」

- 移动量必须相对于**按下时的原点**（否则累积误差）。
- 缩放必须相对**按下时的原始尺寸**（否则逐帧漂移）。
- 所以必须存「按下那一刻的捕获」。手势状态 = 数据，放进 World。

---

## 2. 状态模型

```racket
;; World 增加两个字段
(struct world (layout floats focus prefix drag))

;; 手势状态
(struct idle     () #:transparent)
(struct dragging (start-x start-y target) #:transparent)

;; target = 捕获的意图（快照）
;;   (cut xsegs ysegs)                 ; 拖平铺缝：两条线上的全部缝段快照
;;   (float id mode float0 rel-rect0)  ; 拖浮窗：原始 float + 模式(move/resize角) + 参照矩形
```

`float0` 是**按下时**的 `float` 值；`rel-rect0` 是按下时的参照矩形。之后 move 全从快照算。

---

## 3. 三个/四个命令

| 命令 | 绑定 | 行为 |
|---|---|---|
| `pointer-press` | `(cursor press)` | 命中 → 设焦点 + 建 `dragging`；没命中 → 让位 `#f` |
| `pointer-move` | `(cursor move)` | 若 dragging → 按快照+总位移改 layout/floats；否则让位 `#f` |
| `pointer-release` | `(cursor release)` | 若 dragging → `idle`；否则让位 `#f` |
| `pointer-scroll` | `(cursor scroll)` | 滚动（先靠边，可让位） |

**让位（`#f`）是优先级机制**：不在拖拽时 `pointer-move` 让位，插件/其它绑定可以接手；
正在拖拽时它不让位，于是**拖拽天然抢占**（因为 base 条目排在前）。

### 命中 → 捕获

press 时用 `Ctx.geometry` 做命中，按 z 从高到低：

1. **浮窗**（表头最上）：角 → `(float id 'resize角 float0 rel0)`；框内 → `(float id 'move float0 rel0)`。
2. **平铺缝/交点**：`hit` 返回的 cut 列表 → 按轴拆成 `xsegs / ysegs` → `(cut xsegs ysegs)`。
3. **pane 内容**：设焦点 + **放置光标**（屏幕坐标 → 文档点，见 `content/pointer.rkt`）。
4. 都没命中 → `#f`（让位）。

### move → 应用

```
delta = (x - start-x, y - start-y)          ; 总位移，不累积
(cut xs ys)        → moves = (move-cut xs dx) ++ (move-cut ys dy)
                     → 逐条 set-sizes（只改涉及 split，其余走快路径）
(float id 'move f0)    → floats' = set-float (move-float* f0 dx dy)
(float id 'resize f0)  → floats' = set-float (resize-float* f0 edge dx dy rel0 W H)
```

move **不需要**当前 geometry（全用快照）→ 拖拽期间不会因为「几何还没重算」而出错。

---

## 4. 命中统一：tiled 与 float

- 命中必须**一处**决定：`hit : geometry × x × y → target`。
- 因此布局层的 `geometry` 要包含**浮窗矩形**，`hit` 按 z 统一返回 `pane | cuts | float`。
- 好处：渲染/命中仍共用一份几何；z 序只在一处体现。

> 备选：tiled hit 与 float hit 分开，由命令层按 z 合并。能少改 layout，但把 z 序逻辑
> 漏到命令层，容易和渲染不一致。**建议统一**。

---

## 5. 与布局/浮窗的接合

- 平铺：`move-cut`（已有）+ `set-sizes`（已有）。
- 浮窗：需要新增纯函数
  - `move-float* : float dx dy -> float`（改 anchor.dx/dy）
  - `resize-float* : float edge dx dy rel-rect W H -> float`（改 size，**对边不动**）
  - `float-at : rect × point -> (or 'move 'resize-nw … #f)`（角/框内判定）

---

## 6. 备选方案比对

| 维度 | 方案 | 评 |
|---|---|---|
| 手势状态 | **World 字段（现选）** | 单一状态、命令统一、可键盘触发 |
| | 外层 `Session(world, drag)` | World 更纯，但两套状态、命令要拿 Session |
| | 放 `ctx`/dispatch 可变盒 | 破坏纯度，测试难 |
| 事件路由 | **pointer 作为命令（现选）** | 与键盘统一、插件可拦、可测 |
| | runtime 特判 | 简单，但鼠标成二等公民、插件碰不到 |
| 命中 | **统一 hit（现选）** | z 序一处，渲染/命中一致 |
| | tiled/float 分开 | 改动小，z 逻辑外漏 |
| 位移 | **快照 + 总位移（现选）** | 幂等、不漂 |
| | 逐帧增量 | 会漂，除非存原值（等于快照） |
| 命令粒度 | **press/move/release 三条（现选）** | 各自绑定，插件可分拦截 |
| | 单条 `pointer` 看 kind | 命令又认识事件 kind，回到旧问题 |

---

## 7. 附带好处

- 因为拖拽是 `World` 里的数据，**键盘也能造拖拽**：`C-w` 前缀把当前缝的 `xsegs/ysegs`
  捕获进 `dragging`，方向键发 `pointer-move`-等价命令。鼠标/键盘共用一套。
- 拖拽是纯函数，可单测（给 World + 坐标序列，断言 layout 变化）。

---

## 8. 待确认

1. **World 是否收编 floats**？（命中/拖拽/渲染都要它；建议收编）
2. **几何是否统一包含浮窗**（`hit` 一次定序）？还是分开？
3. **press 落在 pane 内容**：✅ 已解决——core 的 `pointer-press` 只设焦点；
   `content/pointer.rkt` **覆盖同名命令**：先调 base 的 `pointer-press`，命中窗格时再把
   `(x,y) - rect` 交给引擎 `screen->point` 换算出文档点并置光标。
   （覆盖而非新增键：命令注册表是 base 在前、插件在后 → 插件同名覆盖。）
4. **scroll** 现在就让位，还是先给个空实现？
5. **拖动阈值**：是否需要「移动超过 1 格才算拖拽」（用于 click vs drag 区分）？
