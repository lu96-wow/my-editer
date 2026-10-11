# edit3

布局/指针交互重构版（见 `DESIGN.md`）。文本引擎复用根目录 `core/`。
在 edit3 的布局/指针内核之上，已把 edit2 的**协调层**（命令系统 / 区域 / 文件 / 面板）平移进来。

```
racket edit3/main.rkt [file]
```

## 现在能做什么

| 输入 | 作用 |
|---|---|
| 可打印字符 / Enter / BS / Del | 编辑焦点窗 |
| ↑↓←→ / Home / End | 移动光标 |
| `C-s` 后接方向 | 分屏前缀：↑新窗在上 / ↓在下 / ←在左 / →在右 |
| `C-d` | 关焦点窗（浮窗则关浮窗；编辑器只摘窗口，不丢缓冲） |
| `M-j` / `M-k` | 浮起日志 / 文件树浮窗（已在则提到最上） |
| `M-g` | 开 / 关日志浮窗 |
| `M-b` | 侧栏区域循环成员：文件树 ↔ 缓冲区 |
| `C-b` / `C-l` | 显示 / 隐藏侧栏 / 日志区域 |
| `M-e` | 焦点回编辑器 |
| `M-n` / `M-p` | 焦点在窗口间循环 |
| 文件树上 ↑↓←→ / Enter | 选择、展开/收起、打开文件 |
| 文件树 `C-n` 后 `f` | 新建文件（`C-n C-n f` 新建目录） |
| 文件树 `C-d` / `C-h` | 删除（确认）/ 显隐隐藏项 |
| `C-u` | 重读磁盘刷新文件树 |
| 缓冲区面板 ↑↓←→ / Space / n | 选择、展开收起、新建视图 |
| `M-s` | 保存焦点文档（写盘 effect） |
| `C-q` | 退出（脏文档走输入行逐个询问保存） |
| 鼠标拖平铺缝 | 改两侧尺寸（只改相邻 basis，其余精确不动） |
| 鼠标拖浮窗边框 / 角 | 移动 / 缩放浮窗（对边不动） |
| 鼠标滚轮 | 滚动命中窗口 |

启动布局：左侧固定 28 列的**文件树**侧栏 + 右上编辑区 + 右下固定 2 行**状态栏**（面板 = 文档，
每帧由 State 纯投影写回；面板不可编辑）。平铺窗最小尺寸**由叶子自己决定**（编辑窗 2×2，面板/
状态条 1×1）；相邻窗之间预留 **1 格分隔线**
（不占内容），交点取 `┌┐└┘├┤┬┴┼`；浮窗有框。

## 结构

```
main.rkt
core/
  state.rkt        值类型 + State（ed/docs/views/tiling/floats/focus/drag）
  layout.rkt       纯求解器（basis/grow/shrink/min）+ 几何/命中 + 树手术 + 区域贴边
  resize.rkt       浮窗移动 / 缩放手术
  interaction.rkt  指针状态机（press/move/release）
  border.rkt       纯装饰（分隔线 + 浮窗框）
  render.rkt       geometry → core rectangle → piece
  window.rkt       wid ↔ vid（平铺/浮窗统一）
  runtime.rkt      backend 协议 + 事件循环
  step.rkt         转移 + op 注册表 + 路由
  panels.rkt       面板 = 文档（状态栏 / 文件树 / 缓冲区 / 输入行 / 日志）
  adapter.rkt      core/editor 边界（唯一 require core/editor）
  route.rkt        CPS 声明式路由
  op.rkt           op 注册表（纯值）
  prompt.rkt       输入行 kind 注册表（纯值）
  keymap.rkt       键表组合
  command.rkt      binding/entry → route 编译
  mode.rkt         路径 → document 键表匹配
  theme.rkt        face → ANSI
  backend/tui.rkt  racket-tui 后端
  event.rkt effect.rkt fs.rkt
config/
  theme.rkt keys.rkt layout.rkt floats.rkt app.rkt
test/           （本目录无；测试在 ../edit3-test/core/）
```

## 还没做

- 每窗口独立边框开关（edit2 的 `border-toggle`；edit3 的框是求解器产出的分隔线 + 浮窗框）。
- 浮窗框会压掉浮窗内容外圈 1 格（未做 inset）。
- jobs / 后台任务（`jobs` 恒为空）。
- `*.rkt` 等模式键表（`config/keys.rkt` 的 `rkt-keys` 还是占位）。
