# edit4 · 00 改造思路总纲（哪些是好设计）

> edit4 的目标：把 edit3 的功能，用**更干净的切分**重做一遍——先定骨架（命令 + 布局），
> 再让内容/面板/装饰/边界/插件往上挂。本文是总纲：目标、准则、逐层对照、好设计、隐患。
> 细节见 `01-layout.md` … `05-roadmap.md`。

---

## 0. 一句话

> **State 是值，显示是纯投影，副作用在边缘；核心只有「布局」和「命令」两件事，
> 其余都是可拔插的投影或边缘。**

---

## 1. 改造目标（从 edit3 出发）

edit3 能用，但骨架有几处结构性别扭：

1. 布局把「求解 / 几何 / 命中 / 手术 / 浮窗」揉在一个模块，且 handle 反带求解器内部量。
2. 缝分 `boundary` / `junction` 两套，十字/T 靠特例补丁。
3. 命令的执行器里硬编码了 scope、prefix、placing 状态机；路由用 CPS 让位。
4. 面板「纯投影」却直接写引擎；注册表/钩子/服务全塞进一个 `features` hash。
5. 主题、词法、括号这些**编辑器域算法**混在 core。
6. `session.rkt` 近千行，领域全挤在一起。

edit4 逐条拆开，并把每块做成「一个类型 + 一组纯函数 + 一个投影 + 一组命令 + 可选边界」。

---

## 2. 五条贯穿性准则

1. **按依赖方向分层，不按功能分层。**
   `值 → 布局 → 命令 → 内容 → 投影 → 装配 → 边界 → 运行时`；上层只依赖下层。
2. **单一真值 + 纯投影。**
   State（值）是一切的来源；几何、面板、face 都是它的纯投影；结果可缓存。
3. **把「何时失效 / 何时让位」显式化。**
   缓存按**输入身份**（`eq?` 持久化根）失效；命令用返回值 `#f` 表示让位。
4. **可扩展点做成数据注册表。**
   命令 / 作用域 / 面板 / face 插件 / 键表都是数据；装配只是 fold。
5. **副作用推到边缘，且可产出新状态。**
   Effect/Job 是数据，在 runtime 解释；open/reload 这类 IO 由边缘产出新 World。

---

## 3. 逐层对照：edit3 → edit4

| 层 | edit3 | edit4 | 好在哪 |
|---|---|---|---|
| 布局·尺寸 | `basis/grow/shrink/min` | `basis/elastic?` + **比例不漂** | 少一个自由度；resize 等比不漂 |
| 布局·最小 | `item.min` + `tile.min` 两份 | 叶子存 min，split **导出** | 无冗余、无不一致 |
| 布局·缝 | boundary/junction 两套 handle | **cut = 全局直线** | 普通缝/十字/T/整线压成一种 |
| 布局·几何 | placement + 重算边界 | geometry + cuts + **frame 统一命中** | 渲染/命中/z 只在一处 |
| 布局·缓存 | 无 | **按输入身份缓存 + settle** | 输入不变零计算；树=已解布局 |
| 布局·手术 | 6 个各自递归 | `modify-path` 一个 walker | 少重复、易测 |
| 命令·执行器 | op handler 拿 ev；CPS 让位 | handler 只拿 args；**返回 `#f` 让位** | 命令与输入解耦；路由简单 |
| 命令·作用域 | 硬编码 | **注册成数据** | 插件可加作用域 |
| 命令·模式 | prefix/placing 写死 | **prefix 是 World 字段** | 特例消失 |
| 拖拽 | feature'drag 无类型 | **World.drag 快照 + 三命令** | 幂等不漂；可键盘化；抢占靠让位 |
| 内容 | State 混 ed/docs/features | **content 不透明字段**；脏=handle 身份 | 文本在值语义之外；core 不依赖内容 |
| 面板 | 投影里写引擎 | **project 纯 / commit 集中** | 投影可纯可缓存 |
| 装饰 | theme 在 core；整篇重扫 | **theme 纯编码器**；face 投影带缓存 | 主题与业务解耦；重算可跳过 |
| 注册表 | 塞进 State.features | **Environment 与 World 分离** | 状态更纯；装配期只读 |
| 依赖 | core 不 require 插件 | 延续 | 无环、可单测 |

---

## 4. 我认为的「好设计」（清单 + 理由）

**布局**

1. **min 是求解器里的硬不变量**，不在拖拽代码里 clamp。→ 任何调用都不可能压塌窗格。
2. **`basis` + 等比缩放**：容器 resize 时弹性项乘同一因子 ⇒ **比例永不漂**；拖缝只改两段 ⇒ **局部精确**。
3. **缝 = 一条全局直线（cut）**：同一坐标的缝段聚成一条线。→ `boundary`/`junction`/T/整线**四态归一**，拖拽就是把位移施加到命中线上，min 约束取交集。
4. **几何带来源**：`geometry`（矩形+cuts）与 `frame`（+浮窗矩形）是唯一几何，`hit` 是纯查表。→ 渲染与命中天然一致，z 序只在一处。
5. **按输入身份缓存**：`(tiling, floats, size)` 用 `eq?` + `equal?` 判失效。→ 没动窗口的事件**零计算**；持久化结构让判定 O(1)。
6. **settle（解算写回）**：resize 时把解出的尺寸写回 basis。→ 树即布局的规范表示；之后恒走精确快路径。
7. **布局只认不透明 `id`**。→ 布局层不认识 vid/document/border/theme，能独立测、独立换。

**命令 / 交互**

8. **命令 = 数据 + 注册表**：`(name . args)`，handler 只依赖 Ctx/World/args。→ 可列、可测、可被插件覆盖。
9. **让位（`#f`）当一等返回值**，取代 CPS continuation。→ 「拦截但可放行」简单直白；拖拽靠 base 条目优先 + 不decline 天然抢占。
10. **作用域可注册、prefix 是普通字段**。→ 执行器不认识任何特例；插件能加 `editor`/`float` 等作用域。
11. **拖拽是 World 里的数据（快照）**：move 只依赖「按下快照 + 总位移」。→ 幂等不漂；**键盘也能造拖拽**。

**内容 / 投影 / 边缘**

12. **内容引擎在 World 之外**：只存 handle + 元数据；脏 = `saved-handle ≠ current-handle`（身份，不 diff 文本）。
13. **project 纯 / commit 集中**：面板与 face 的投影是纯函数；只有 commit 写引擎。→ 可缓存、可测、可整体替换。
14. **face 缓存键 = `(handle, cursor)`**：引擎的不可变 handle 当版本号。→ 未变则跳过整篇重扫。
15. **theme / face 是值 + 纯编码器**。→ 主题只被渲染调用，业务与配色彻底分开。
16. **Effect/Job 是数据，在边缘解释**；open/reload 由边缘产出新 World。→ IO 可替换、可测（脚本化后端）。

**工程**

17. **高度可测**：布局、命令、内容、渲染、运行时各有测试；还有 **edit3 布局等价性对照**（能力保证）。
18. **「缺口」显式**：`#f`（让位）、缓存失效、settle 触发点，全是显式规则，不藏在副作用里。

---

## 5. 仍不确定 / 需要警惕

1. **整数抖动**：比例在「整格」上有 ±1 跳变（最大余数）。未上 carry（累积余数）。
2. **World 里有可变盒**（content.ed）：值语义的已知漏洞，靠「文本不进值」约束兜着。
3. **面板/face 的刷新时机**：面板每帧投影（有 diff 才写）；face 整篇重算但被 handle 缓存挡住。大文件仍可能慢（未做按行增量）。
4. **插件装配尚未落地**：`app-*` 目前把命令/键表/面板/faces 硬编码拼在一起，还没做成注册表 + 目录。
5. **文件树交互 / 输入行 prompt / 模式键表**未做，`open` 还没键入口。
6. **Effect 产出 World** 是否长期合适，待观察（也许该是「命令 + 请求」两段式）。
7. **浮窗不做**锚浮窗；内容无内缩（浮窗框会盖住内容边缘 1 行）。

---

## 6. 文件地图（当前进度）

> 目录 / 命名 / 依赖方向的完整说明见 `06-structure.md`。

```
edit4/
  main.rkt runtime.rkt                 入口 / 事件循环
  env.rkt plugin.rkt app.rkt boot.rkt  Environment + 插件 fold + 初始 World
  layout/  rect size tree geometry hit float frame settle validate cache
  core/    event effect drag world command keymap scope dispatch window pointer base
  content/ fs adapter model tree edit files commands
  view/    render border panel status tree face decor theme
  decor/   lex kind dirty protocol syntax words word-color
  config/  palette syntax
  backend/ tui
edit4-test/  layout command content render runtime panels faces edit3-parity
```

已达成：**能打字、看、开关/分裂/拖拽窗口、打开/保存文件、状态栏 + 文件树、语法/当前词高亮、退出**；
布局与 edit3 **逐窗等价**（`edit3-parity`）。

后续路线见 `05-roadmap.md`。

---

## 7. 一句话总结好设计的共同点

> **能拆成纯函数就拆；拆不掉的（IO/引擎/线程）推到唯一边缘；可扩展点做成数据；
> 失效与让位都显式化。** 于是系统可缓存、可测试、可替换，且 edit3 的能力一个不少。
