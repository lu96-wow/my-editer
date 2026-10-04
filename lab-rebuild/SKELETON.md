# lab-rebuild 骨架（布局 / 输入 / 命令）

> 只落**协议与结构**，不落功能细节。`input` 的「转移状态」只在 `dispatch.rkt` 留接缝，
> 暂不实现。跑 `racket lab-rebuild/smoke.rkt` 验证。

## 依赖方向

```
layout/*    （纯几何，只 require core 的 rectangle）
input.rkt   （事件直接用 racket-tui；只加 event->binding）
input-doc.rkt（底部槽位文档：state / input）
mode.rkt    （输入转移状态：prompt + 续延）
command.rkt （纯表，只 require input 的绑定键）
dispatch.rkt ──► command + input        （不含 core / 焦点）
```

`dispatch` 不读全局焦点：did 由上层算好传入 → 本层是纯的。

## 已定的设计

### 布局
- **二叉** split（`node dir size a b`），先不做多栏。
- **分割条**：两段之间留 `split-gap`（默认 1 格），`tree->rectangles` 返回
  `(values 窗格矩形 分割条 尺寸警告)`；`bar` 是分割条的屏幕矩形。
- **空间不足不静默夹紧**：照常铺 + 输出 `size-warning(dir need got)`，由上层提示。
- **左栏 / 底部条是预定义的**：固定宽 / 固定高，不进 split 树，只保留 `#:left-vid`
  `#:bottom-vid` 接缝。split 树只铺主区。

### 输入
- 事件**直接用 racket-tui 的规范事件**（`key / paste / mouse / resize / null / other` + `mods`），
  不再自造事件类型。
- 绑定键用**匿名列表**：
  - `(list 'key 键 规范mods)`，字符键归一为小写 symbol（空格 = `'space`）
  - `(list 'mouse 动作 按钮 规范mods)`
  - `'text`（无 ctrl/alt 的字符键）/ `'paste` / `'resize`
  - `#f`（`null` / 未识别，不参与查表）
- **鼠标坐标**：racket-tui 给的是 **1-based** 终端列/行；lab 内部一律 0-based 屏幕格，
  消费端用 `mouse-col` / `mouse-row`（已减 1），不要直接用 `mouse-event-x/y`。

### 命令
- `command-table`（binding → handler）+ `command-set`（global + 每 did）。
- handler 约定 `(handler event ctx)`，简单优先。
- 转移状态见下（还没定）。

## 输入转移状态的接缝（待讨论）

`dispatch.rkt` 现在规则是「did → 表」。转移状态（提示 / 确认 / 其它模态）要么：
- (a) 也表达成一个 did（切 view / 切文档），天然走这套；或
- (b) 在 did 之外再叠一层「模式表」，`dispatch-tables` 多收一个 mode。
当前签名按 (a) 的形态给，等定了再改。

## 输入转移状态（已落第一版）

底部那条是**共享槽位**，只放两份文档：空闲显示 **state**（应用状态），
有 prompt 时替换成 **input**（可编辑 / 确认都是它）。切换只改一个 `mode` 值
（`#f | prompt`），布局 / 命令表都静态。
state 行内容：`焦点  行:列  view对应 document 的文件名`（如 `edit  1:1  aaa.txt`）。

三个东西分离：
- `input-doc.rkt`：文档（纯，复用）。
- `mode.rkt`：`prompt` + 续延（这次输入是什么、值往哪去）。
- 业务续延：发起方给，模态只管调用。

**值回传（核心）**：命令表是事件驱动、不是调用栈，Enter handler 的返回值没人接。
所以发起时把**续延**放进 prompt，提交时调用：
```
input-begin  → app 存 prompt、挂输入文档、底部切到 input、聚焦
input-commit → 读文档值、app 先退出模态、再 (on-commit value)
input-cancel → app 先退出模态、再 (on-cancel)
```
「先退出再调续延」由 app 保证（续延里可能立刻发起下一个输入）。

**共享槽位**：常驻 `state-vid / input-vid` 两个 view，谁进 `panes` 由
`mode-bottom-vid` 决定（无 prompt → state，有 → input）；焦点用 `mode-focus-vid`，
结束后还原 `prompt-prev-focus`。

**确认型也走 input 文档**（`editable? #f`），不再单独占 view：`app-begin!` 按
prompt 类型用 `command-set-set-doc` 把 input did 的表换成 edit 表 / y-n 表，
退出时换回 edit 表。

当前取：**多 view 争槽 + 闭包续延**（简单优先）。以后可换 kind+effect 或单 view 换文档。

## 可运行的 app（第一版）

```
racket lab-rebuild/main.rkt [根目录]
```

文件布局：左 = 文件树，右 = 当前文件，底 = state / input 共享槽位。

启动时**不预开** `*scratch*`：主编辑区一开始是空的（`edit-vid = #f`，`compute-layout` 接 `#f` 树 → 不铺主区窗格）；
在树里 `Enter` 打开文件才懒建编辑视图。因此 Ctrl+O / Ctrl+方向在打开前不指向编辑格。

新增：
- `tree.rkt`：文件树模型 → core document（整树只读）。
- `buffers.rkt`：打开的文档 / 视图两级列表 → core document（整表只读）。
- `app.rkt`：状态 + 命令 + 事件处理 + 输入转移接线。
- `tui.rkt`：racket-tui 后端（增量渲染 + 主循环）；每帧先 `app-prepare!`（刷新底部 state 槽位 + 取窗格），
  否则状态栏会是空的（曾经踩过：app-draw! 直接 patch、跳过了 state 刷新）。
- `main.rkt`：入口。
- `smoke-app.rkt`：无终端集成冒烟（模拟 racket-tui 事件）。

左侧栏有两个面板，`Tab` 切换：文件树 / 文档列表（`left = 'tree | 'bufs`）。

键位（第一版）：
- `Ctrl+←/→/↑/↓` 移焦点；`Ctrl+O` 树↔编辑格
- 树：`↑/↓/←/→` 光标移动、`Enter` 打开文件 / 展开折叠目录、`Tab` 切左侧面板、`Ctrl+N` 新建文件、`Ctrl+M` 新建目录、`Backspace` 删除（y/n 确认）
  - `Enter` 打开文件只把内容换到编辑格，**焦点留在树**（可连续预览），用 `Ctrl+O` 跳到编辑格。
  - 删除磁盘路径时 `app-close-path!` **同步关闭**它（及目录下子路径）已打开的文档 / 视图；
    若编辑格正显示被关的文档，自动改显下一个还开着的 view（没有则主区空）。
- 文档列表：`Tab` 切左侧面板、`Enter` 文档行展开/收起视图行、选视图行 `Enter` 打开到编辑格
- 输入行：`Enter` 提交、`Esc` 取消；字符 / 退格直接编辑
- 编辑格：常规编辑（方向 / 选择 / 剪贴板 / 撤销）
- `Ctrl+S` 保存、`Ctrl+Q` 退出

鼠标：
- 输入激活时：点输入行 → 落光标；按在任何其它地方 → 取消输入。
- 通常模式：按下 / 滚轮 → 聚焦并作用（落光标 / 滚动）；空闲状态栏不是交互区。

## 还没定（先留白）

- split 的 `size` 语义（当前「第一段格数」，`#f` = 均分）；空间不足时的兜底铺法。
- 分割条交互（拖拽 → `tree-resize`）。
- `pane-dir` 的邻居度量（当前中心曼哈顿距离）。
- 命令是否需要名字 / 回落（`text` 自插入）是否纳入命令层。
- 输入：单槽（当前）vs 栈式嵌套；确认型是否单独 `on-answer`（当前复用 on-commit 收 bool）。
