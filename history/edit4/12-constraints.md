# edit4 · 12 主要逻辑与设计约束

> 一页速查：**骨架逻辑 + 必须守住的不变量**。改代码前先对一遍这张表。
> 结构/文件地图见 `06-structure.md`；dock 设计见 `11-docks.md`。

---

## 1. 分层与依赖方向（只向下 require）

```
L6 装配   app.rkt  plugin.rkt  env.rkt           把插件 fold 成 Environment
L5 内容   content/*                               文档/视图/面板/文件树/dock/输入行
L4 投影   view/*  decor/*  config/*               State → 文本/faces（纯）
L3 运行时 runtime.rkt（唯一可变处）               事件循环 + 后端 + worker
L2 核心   core/*                                  布局/命令/作用域/World，不认识内容
L1 布局   layout/*（唯一“难数学”）                rect/size/tree/geometry/hit/float
L0 值     core/event core/effect、layout/rect ...
```

- **core 不 require 内容层**；只有 `content/adapter.rkt` require `core/editor`（引擎边界）。
- **layout 不认识 vid / 文档 / 面板 / 命令**（窗口 id 不透明）。
- 配置是纯数据（`config/*` 不 require 实现）。

## 2. 状态与执行模型

- **World = 唯一可变领域状态的值**（layout / floats / focus / prefix / keys / drag / content /
  signals / jobs / store）。**Environment = 装配期只读**（命令/键表/作用域/面板/decor/hooks/services）。
- **只有 runtime 持有可变状态**（几何缓存、上一帧屏幕、后端、线程）。
- **命令**：`handler : Ctx World args -> (values World effects) | #f`；`#f` = 让位，dispatch 试下一条。
- **dispatch 顺序**：文档键表 → keymap；「binding 命中 + scope 成立 + 不 decline」第一条生效。
- **scope 是数据**（`always` / `(prefix X)` / `editor` / `(panel "N")` / `(region ID)` …）；
  未注册的 scope 视为成立。
- World 里没有「杂物袋 hash」——每个字段有类型、有来源。

## 3. 布局不变量（`layout/`）

- `size = (basis elastic?)`：`basis >= min`（新 split 以当前长度/最小值初始化；拖拽只改两个
  basis 且由 min 夹住）。
- **min 只存叶子**；split 的 min 是导出的（`node-min`）。`leaf` min 要么 `(0 . 0)`
  （可折叠 dock），要么 `>= (1 . 1)`。
- `settle` 后满足 `Σbasis == content` → 之后任何 `layout` 走**精确快路径**（其它项完全不动，
  比例不漂）。
- **折叠子节点**：固定且 basis 0（`collapsed-child?`）。折叠项长度恒 0、**不占缝**、不参与
  增减、不产生 rect/seg（不可命中/拖拽）。`node-min` / `solve-axis`（actives）/ `settle` /
  `geometry` 一致忽略它。
- `seg` 的 `i/j` 是**相邻可见**子节点下标（中间可隔折叠项）；`move-cut` 只动这两个 basis。
- 一条 cut = 同坐标的所有缝段；普通缝/十字/T/整线在命中与拖拽里是同一种东西。

## 4. Dock / 面板显示模型（`content/region.rkt`）

三轴分离（见 `11-docks.md`）：

| 轴 | 谁定义 | 说明 |
|---|---|---|
| 组合 group | `config/layout.rkt` `panel-groups` | 哪些面板互斥共一槽；操作整体（C-b/M-b/M-t 语义一致） |
| 位置/显隐 dock | `config/layout.rkt` `docks` | side / size / min / anchor / shown? |
| 显示 | `region.leaf→vid`（bindings） | 一个 dock = 一个常驻叶子 |

- **mount-all**：boot 把所有 dock 的叶子都插进树（隐藏的 size 0）。
- **显隐 = 尺寸手术**：`show` 把叶子 size 设回记住值；`hide` 设 0。不改结构 ⇒ **toggle 幂等、
  root 顺序恒 = 挂载顺序、叶子/窗口 id 跨显隐稳定**。
- **最小尺寸**：叶子 min = dock 的 `min`（拖拽/缩屏挤不到 0）；折叠靠 basis 0 判定，与 min 无关。
- `ids` 含折叠叶（id 不复用）；`visible-ids` 排除折叠子树 —— **焦点/命中/导航/编辑器窗判定只用
  `visible-ids`**。
- dock 的 active 成员可切换（`region-activate!`）；隐藏时也绑 active 面板 vid，保证叶子永远是
  「面板窗」。

## 5. 面板显示只有一条路径

**选一个 dock，切到某个成员**（`region-show` / `region-activate!`）。浮窗是「同一 vid 的另一处
显示」，走 `content/float.rkt`。没有「直接绑窗口」「临时换 vid」这些旁路。

## 6. 打开 / 放置文档

- 文件树 `tree-enter` 与 buffers `buffers-enter` 都走 `content/placing.rkt`：
  **0 个编辑器窗 → 新开；恰好 1 个 → 直放；≥2 个 → 进 placing 让用户选**。
- 文档已显示 → 聚焦那个窗（reveal）；否则 `place-vid!`。
- 关闭文档统一走 `request-close-doc*`（脏则询问）；关闭视图不询问。

## 7. 每个模块的主要逻辑（一句话）

```
runtime        每帧：before-render → commit-panels! → 算 frame → 渲染 → 派发 jobs → 读事件 → dispatch → 跑 hooks → 解释 effect
core/command   命名意图 (name args) + 注册表；run-command 返回 world/effects 或 #f
core/dispatch  文档键表→keymap，第一条命中且 scope 成立且不让位者生效；维护 prefix/keys
core/window    窗口 split/close/focus（纯布局代数 + 焦点）
core/pointer   鼠标 press/move/release → 拖拽（缝用 set-sizes；浮窗用 move/resize-float）
content/model  文档/视图/面板/文件树/dock 的值操作 + 路径复用
content/region dock 的 mount/show/hide/cycle/activate/focus（尺寸手术）
content/placing 打开时的目标窗选择
content/prompt  *input* 面板（status dock 的一个成员）+ kind→handler + quit/close-doc 流程
content/tree   文件树模型 + 纯操作 + IO（tree-ensure 只在 boot/reload）
content/float  浮窗开/关/提/循环（另一处显示同一 vid）
view/panel     面板投影 + commit-panels!（集中写回引擎）
view/render    frame → 屏幕 piece（deep 分层：平铺 0，浮窗 2·z）
layout/size    一维求解器（本模块唯一“难数学”）
layout/tree    布局树 + min + 手术（split/remove/insert/set-sizes）
layout/geometry 树×区域 → rects + cuts
layout/hit     命中 + 拖拽（cut/seg）
config/layout  panel-groups + docks + region-keys（布局配置）
config/sidebar dock 尺寸策略（横向宽度 / 纵向高度）
```

## 8. 不变量清单（建议测试覆盖）

- `settle` 后 `layout` 走精确快路径；resize 后**比例不漂**。
- `validate`：每个 pane 在区域内、不小于自身 min、两两不重叠。
- dock：`hide → show` 后 `leaf` 与窗 id 不变；任意 toggle 序列后嵌套顺序 = 声明顺序。
- 命令未命中 / 让位 → 清 prefix 与已按序列，不产生状态垃圾。
- 面板写回只在 `commit-panels!`；投影纯读 World。
