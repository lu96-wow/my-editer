# lab-rebuild 布局设计：主区 + 停靠区（dock）

> 目标：修两个问题——
> 1. **编辑区焦点记忆**：不再「回退到第一个编辑叶」，而是记住上一次正在编辑的视图（连同光标）。
> 2. **底栏 / 左栏彻底拆开**：通用停靠机制共用，状态栏逻辑与文件树逻辑分别独立成模块。

---

## 1. 两种「焦点」分离

| 概念 | 含义 | 存在哪 |
|---|---|---|
| `focus` | **输入焦点**：谁的键表生效、字符往哪打。可以是主区编辑叶，也可以是某个 dock。 | `focus = target + stack` |
| `edit-vid` | **活动编辑视图（粘性）**：主区里「上一次正在编辑的文档视图」。 | `session.edit-vid` |

规则（不变量）：

- `edit-vid` 恒为**主区 frame 的某个 leaf**（或 `#f`）。
- 只有 `focus` 落在主区 leaf 时才更新 `edit-vid`；focus 进 dock **不改** `edit-vid`。
- `focus-restore` 后若落回主区 leaf，同样更新。
- 光标/选区本来就在 core 的 view 里（每个 view 自带 box），所以「记住光标」= 记住 vid，不必另存坐标。

命令取值：

- 需要「当前文档」的（save / 补全 / 文档查询 / 状态行 / 对照翻译）→ 读 `session-edit-vid`。
- 直接输入/导航的（type / nav / 撤销…）→ 读 `session-focus-vid`，且要求它是主区 leaf；focus 在 dock 时由 dock 自己的键表处理。

---

## 2. workspace = 主区 + 停靠区

```
frame      主区：leaf(vid) | split(dir,size,a,b)
dock       side('left|'right|'top|'bottom) + size + visible? + vid + keys
workspace  main(frame) + docks(listof dock)
```

- **dock 是通用停靠条**：一块屏幕条 + 一个视图 + 自己的键表。
- **布局纯派生**：按 side 依次从可用区域取条带，剩余给 main。
  `workspace-areas ws w h → (values main-area (listof (dock . rect)))`
- **焦点几何**：main leaf 的 rect + 各 dock 的 rect 统一参与方向导航，所以能 `focus` 进/出 dock。
- **开关 / 尺寸**是 dock 的通用属性，由通用 effect 改：
  `e-dock-visible id flag` / `e-dock-toggle id` / `e-dock-resize id delta`。

> 这就是「实现可以共用」的部分：布局、命中、方向、显隐、尺寸、聚焦进出、键表选择，全在 kernel。

---

## 3. 「逻辑必须分开」

kernel 只认 dock 这个**机制**，不认状态行 / 文件树。具体逻辑各自一个 `builtin/`：

- `builtin/status.rkt`：注册一个 **bottom dock**；自己的刷新逻辑（显示 `edit-vid` 的行:列/文档名）；无键表。
- `builtin/tree.rkt`：注册一个 **left dock**；自己的刷新逻辑（目录树）；自己的键表（方向 / Enter / 开关命令）。
- `prompt` 的输入行将来单独设计（见 §6），不与上面两者耦合。

dock 贡献协议（组装期，和 command/hook 一样的 registry 贡献）：

```racket
(struct dock-spec (id side size visible? make keys) #:transparent)
;; make : Ctx ed w h -> (values ed vid)     ; 建承载视图
;; keys : (listof keytable)                 ; focus 在该 dock 时生效
```

`app-init` 折叠 `reg-kind 'dock`：调 `make` 建视图、登记 dock 实例。
**状态行文本、目录内容这类逻辑不进 kernel。**

---

## 4. 与旧 `lab` 的差异

| 旧 lab | lab-rebuild |
|---|---|
| `session.status-vid / input-vid / sidebar? / panels / active-panel` | `session.workspace` + `session.edit-vid` |
| `layout-info` 里硬编码「左栏 + 底栏 slot」 | 统一 `workspace-areas`：dock 条带 |
| `effective-slot-vid`（status/input 二选一） | 拆开：status 是 dock；input/prompt 单独机制 |
| `session-edit-vid` 回退「第一个 leaf」 | 粘性 `edit-vid`，只在 focus ∈ 主区时更新 |
| panel 与 status 是两套东西 | 都是 dock，只是 side / 逻辑不同 |

---

## 5. 实现顺序

1. **kernel/frame.rkt**（最小：leaf/split + `frame->rectangles` + resize/swap/remove）。
2. **kernel/dock.rkt + kernel/workspace.rkt**（dock-spec / dock；`workspace-areas` + 方向几何）。
3. **session / pipeline**：`workspace` + `edit-vid`；effect：`e-focus`（含方向）/`e-split`/`e-pane-close`/`e-dock-*`；粘性规则。
4. **builtin/status.rkt**（bottom dock，验证「逻辑独立」）。
5. **builtin/tree.rkt**（left dock，目录 + 键；打开文件下一步）。
6. **render + smoke**。

---

## 6. 已定（本轮）

1. **prompt/input**：做成**独立 dock**（`'input`，bottom，layer 激活时显示）。
2. **tree 范围**：本轮只做「列目录 + 导航 + `C-b` 开关」；**打开/保存文件下一步**。
3. **dock 尺寸**：固定初始尺寸 + 提供 `e-dock-resize`；`M-s` 式前缀缩放下一批再接。

## 7. 已实现对照

- kernel：`frame.rkt` / `dock.rkt` / `workspace.rkt` / `hooks.rkt`；`session` 改为
  `editor + workspace + focus + edit-vid + keys + global`；effect 加了
  `e-focus-dir / e-split / e-pane-close / e-pane-swap / e-pane-resize / e-dock-visible/-toggle/-resize/-cycle`。
- builtin：`status.rkt`（bottom dock）、`tree.rkt`（left dock）——各自注册 dock + before-render hook + 键。
- 焦点几何：主区叶 + dock 统一参与方向导航，同排/同列优先（避免「向左」跳到下方状态栏）。
