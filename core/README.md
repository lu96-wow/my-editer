# core —— 设计与分层

文本引擎 + 显示（buffer / view / panel）+ 渲染值（screen / piece）。

## 设计决策

1. **无 did/vid、无中央 `editor`**：`buffer` / `view` / `panel` 对象本身就是身份；宿主直接持有对象，core 不集中管理多个文档。
2. **操作 = 纯函数 + `compose`/`map`**；状态对象（buffer / view / document / history）可以不纯（functional core / imperative shell）。
3. **多 view 共享一份 document + history**：`buffer` 持 `history`（含当前 document）与 `views`；`view` 指回 `buffer`。
4. **显示单位是 `panel`**：`panel = (view rect borders deep face)`。几何（位置 + 大小 + 四条边 + 深度 + 边框 face）在 panel 上，渲染只吃 `(listof panel)`。
5. **尺寸真相在 `panel.rect`**：view 的 viewport 尺寸是派生量，只能由 `editor/sync.rkt` 的 `panels-sync!` 从 `panel-content` 写进去。换 view 后再 sync。
6. **panel 无身份**：view 可替换，不能拿 view 当身份。命中 / 布局树 / 增删去重由宿主自己记 id。
7. **focus 在宿主**：core 不存 focus；渲染时作为参数传入（`#f | view | (listof view)`）。绘制支持多焦点；取焦点光标位置按单焦点模型。
8. **history 是纯文档版本栈**：不含 who / selections，撤销不回发起视图。
9. **合并完全显式**：编辑本身不含合并策略；一组操作合成一步用事务（程序）或会话（交互）。
10. **写回只有一条路径**：`buffer` / `view` 的裸 setter 不外露，改状态一律走提交壳。

## 分层

| 层 | 模块 | 性质 |
|---|---|---|
| 值 | `text/base/*`、`view/base/*` | 纯值（含 `view/base/rect.rkt` 几何） |
| 文档 | `text/document.rkt`、`text/command.rkt`、`text/rebase.rkt`、`text/slots*.rkt` | 文本编辑纯；端口 / 槽可含盒；`document` 带渲染 revision |
| 历史 | `editor/history.rkt` | 纯文档版本栈（record / merge / set-current） |
| 对象 | `editor/state-data.rkt`、`editor/state.rkt` | buffer / view 可变数据；生命周期与访问器（写只经壳） |
| 提交 | `editor/ops.rkt` | 纯算子构造 + 提交壳 + 显式事务（undo-scope） |
| 读 | `editor/query.rkt` | 按对象读 |
| 写回 | `editor/attributes.rkt` | 端口 / 槽写回（就地改盒，不进 history） |
| 面板 | `view/panel.rkt` | `panel` 值 + `panel-content` + `panel-at`（命中）+ `panel-move`（六向：4 同层 + 2 跨层）+ 屏幕↔内容坐标（都纯） |
| 边框 | `view/border.rkt` | panel 边 → run（owner-first + 同向延续，固定 Unicode 框线） |
| 布局骨架 | `view/layout.rkt` | panels → placements + border-runs（纯；注意与 `view/base/layout.rkt` 的文本折行无关） |
| 渲染 | `view/compose.rkt` `view/patch.rkt` `editor/render.rkt` | pane 合成 → screen → 增量 piece；含分层缓存 / 脏区 |
| 同步 | `editor/sync.rkt` | `panel.rect` → view 尺寸（唯一的尺寸写入口）+ `buffer-add-panel!` |
| 会话 | `editor/session.rkt` | 显式合并的交互封装（镜像导航 / 程序写） |
| 使用层 | `editor.rkt` | 意图名再导出（`rename-out` + 精选） |

**依赖方向**：`text ← view ← editor ← editor.rkt`；`view/*` 不依赖 `editor/*`。

## panel（显示单位）

```racket
(struct panel (view rect borders deep face))
;; view    : 显示槽，可替换（换 view = 造新 panel 值）
;; rect    : 外框矩形（尺寸真相）；内容区 = 按存在的边各内缩 1 = panel-content
;; borders : (listof 'up 'down 'left 'right)，每边可选
;; deep    : 越大越在上；浮窗 = deep 高的 panel
;; face    : 边框 face 符号（#f | symbol | face），宿主设，core 不解释颜色
```

宿主操作：

| 想干什么 | 怎么做 |
|---|---|
| 移动 / 改大小 | 造新 panel（同 view，新 rect），调 `panels-sync!` |
| 加 / 删 | 往 `panels` 列表里加 / 去掉 |
| 换 view | 造新 panel（新 view），调 `panels-sync!` |
| 改边框 / 深度 / face | 造新 panel |
| 分屏 / 切分 / 拖分隔条 | **在 core 外**：算 rect → 产出 `(listof panel)`（core 只吃结果） |
| 命中（鼠标/拖拽） | `(panel-at panels row col)` → panel \| #f（和渲染同一份 panels、同一套 deep 规则） |
| 方向导航（焦点） | `(panel-move panels from dir)`，`dir ∈ left/right/up/down`（同层平铺，`panel-neighbor`）+ `front/back`（跨层前后，`panel-depth-neighbor`）→ panel \| #f |
| 屏坐标 → 文档 point（鼠标） | `(panel-screen-position->point panel row col)`；反向 `(panel-point->screen-position panel pt)`（editor 层，要解包 panel.view） |
| 身份 / 增删去重 | **在 core 外**：panel 是值，宿主持有 id ↔ panel 映射 |

## 存在集 vs 可见集（分工）

| | 在哪 | 含义 | 谁维护 |
|---|---|---|---|
| **存在集** | `buffer.views` | 这个文档一共有哪些 view（含未显示的） | core |
| **可见集 / 位置** | 宿主的 `(listof panel)` | 现在屏幕上显示哪些 view、在哪、多深 | 宿主 |

一条不变量：**一个 view 至多属于一个 panel**（不会同时出现在两处），所以 viewport 的 w / h 就是它那个 panel 的内容尺寸，渲染无歧义。

渲染只认可见集（panels），**完全不看 `buffer.views`**。

## 渲染与增量

```
view → screen（文本层 project + overlay 光标/选区）
panels → layout（placements + 边框 run）
       → 逐行合成（按 deep 遮挡）
       → screen
screen-patch(old, new) → piece（render / selection）
```

- `render-display panels focus w h` → screen（全量）
- `render-display-patch panels focus w h cache` → `(values cache render selection)`
  - 缓存是**值**、宿主持有、core 无状态；`#f` = 冷启动
  - 分层：布局层（panels 不变就复用）、内容层（`(document-revision, viewport)` 命中就复用）、合成屏
  - 脏区：只重合成「文本变化行」+ 只 patch 变化行；整帧无变化直接空差量
- 定位（单焦点）：`panel-cursor-position`（几何）/ `panel-cursor-position/visible`（几何 ∩ 已画光标）/ `screen-primary-cursor`
- 坐标：`panel-screen->content` / `panel-content->screen`（纯几何，`view/panel.rkt`）；`panel-screen-position->point` / `panel-point->screen-position`（要解包 view，`editor/query.rkt`）

## 合并与写入口

- 文本提交返回 `#f | (listof change)`（`#f` = 拒绝，`'()` = 无变更）；`buffer-edit!` 每次调用 = 一个新撤销步。
- 合成一步：程序用 `buffer-with-undo-step`，交互用 `session-edit!`（见 `temp/README.md` 与 `temp/COVERAGE.md`）。
- 视图尺寸只经 `panels-sync!`（不要直接 `view-resize!`，那是内部写口）。
