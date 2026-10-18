# edit-tui-rebuild 的插件：三个例子与上一代的取舍

> 目标是把“语法高亮 / 补全 / 文档”做成**纯数据插件**，框架侧不加 if。
> 这里先记录从 `history/edit4` 提取出来的功能核心与取舍，再说明本仓库的实现。

## 1. 从 edit4 提取的功能核心

edit4 的插件系统（`plugin.rkt` / `core/hook.rkt` / `decor/protocol.rkt`）值得保留的只有四件事：

| 机制 | 是什么 | 为什么重要 |
|---|---|---|
| **信号 + 钩子** | 命令用 `emit!` 把 `(point . args)` 追加到 `World.signals`；runtime 反复“取信号 → 按 priority 跑匹配的 reaction → 直到没有新信号” | 让“文本改了之后重算高亮 / 重算补全候选 / 刷新文档”变成**旁观者**逻辑，命令不需要认识它们 |
| **decor 协议** | `decor { open: path text -> (state layer); change: state layer ctx -> (state layer dirty) }`，layer 是“每行一个 face 向量”，dirty 是“哪几行脏” | 上色是一个可以增量、可以分层（括号底色 / 同词着色 / 语法前景）的**纯函数**，与渲染解耦 |
| **补全菜单** | 不抢焦点的浮窗；Up/Down/Tab/Enter/Esc 用“有菜单就操作菜单”的命令接住；打字走基础 insert，`after-insert` 钩子重筛 | 补全的难点不是候选，而是**菜单与会话**（谁持有、谁刷新、谁取消） |
| **文档服务** | `M-h` 订阅 `complete-selection`；本地定义走纯函数，stdlib 走 `#:services 'doc` 的异步 worker，结果按 key 缓存、同一时刻只允许一个在途 | 文档查询是慢操作，必须**防抖 + 缓存 + 可取消**，而且不能阻塞输入 |

**没有照搬的**（不是功能核心，或者属于它们那套 World 的管道）：

- `World` / `content` / `layout` 的整套可变搬运，`service` 注册表，`sync` 插件（多 view 同步渲染），
  `doc-key-matchers`（按文档类型再套一层键表），`prompt-kind` 注册表；
- `decor` 的增量状态机：**这一版已经补上**（见 `INCREMENTAL.md`）；语法高亮 / 括号深度现在就是 face-decor。

## 2. 本仓库的实现

### 2.1 信号与钩子（框架）

| 文件 | 内容 |
|---|---|
| `base/signal.rkt` | `signal { point, args }` + `signals` FIFO 队列 |
| `env/hook.rkt` | `hook { point, when, priority, proc }`，`proc : (state engine-view args -> transition)` |
| `dispatch/hooks.rkt` | `run-hooks`：排空信号、按 priority 降序跑、hook 可再 emit（轮数上限防自激） |
| `runtime/run.rkt` | `settle`：**先解释 effect，再跑 hook**（hook 读到的是写完之后的文本），hook 加的 effect 再解释一轮 |

信号词表：`document-opened`、`after-edit`、`after-nav`、`focus-changed`
（发出点：`effects/interpreter.rkt` 知道文本真的变了；`dispatch` 比较焦点前后）。

> 顺序是这条链最容易被写错的地方：hook 在 dispatch 里跑会拿到**编辑前**的文本。
> 所以 hook 一律在 `settle` 里跑。`test/plugins.rkt` 的高亮用例守着它。

### 2.2 两个新的 effect

| effect | 用途 | 解释（`effects/interpreter.rkt`） |
|---|---|---|
| `set-face-layer-effect doc layer fills` | 一次性静态层（补全选中行等） | `effects/paint` 的 `paint-state.static`；文本编辑时自动平移 |
| `replace-range-effect view range text` | 替换一段（补全） | `buffer-replace-range!` |

`fills` 用 core 的 fill 形状 `(l0 c0 l1 c1 face)`，插件侧用 `plugins/highlight/lex.rkt` 生成。

### 2.3 语法高亮（`plugins/highlight/`）—— 两个增量 face decor

两个插件、两层，互不覆盖；它们不是 hook，而是每个文档一份持续状态：

| 文件 | 层 | 写什么 |
|---|---|---|
| `plugins/highlight/syntax-decor.rkt` | `'syntax-fg` | 每格只写**前景**分量（`face-set-fg`） |
| `plugins/highlight/depth-decor.rkt` | `'depth-bg` | 每格只写**背景**分量（`face-set-bg`），括号深度 |
| `lex.rkt` / `depth.rkt` | — | 纯行级扫描：`state × line -> (state', 行 face 向量)` |

流程（同步、增量）：

```
document-opened / 文本编辑
        │
        ▼
core document-edit-tracks
        │  fork slots
        ▼
effects/paint.rkt 的 face-paint slot
        │  每个 decor 调 change(state, layer, ctx)
        │    changes -> dirty 行
        │    refresh-layer / stateful-advance 只重扫脏行
        ▼
paint-write!  只把 dirty 行写回 core face port
```

- **状态在 document slot 里**：undo / redo 回到旧 document 时，decor 的 state / layer
  和 face port 一起回来，不需要重算。
- **一个文本编辑只重扫脏行**；跨行状态（块注释 / 字符串 / 括号栈）用
  `stateful-advance` 从首个脏行重扫到状态收敛。
- **两个插件仍然各写一个分量**：合成在 `effects/paint.rkt` 按 `env.face-layers`
  的层序做，同分量后层覆盖，attrs 并集。
- **没有后台 worker 路径**：高亮不再 `submit-service-effect` / `job-done`；
  worker 只保留给一次性纯计算。同步 decor 的正确性由 core 的版本顺序保证。
- `set-face-layer-effect` 仍然存在，但只用于一次性静态层（例如补全选中行）。

高亮只对 Racket 文件生效：`face-decor` 的 `applies?` 看 doc-meta（mode / path 后缀），
由 `runtime/run.rkt` 在文档打开后过滤并挂到 engine。

### 2.4 补全（`plugins/completion/`，浮层菜单）

`C-c /` 打开**浮层菜单**（不插入文本）：

| 键 | 作用 |
|---|---|
| `↑` / `↓` | 在候选里移动选择（此时**不移动光标**） |
| `Enter` / `Tab` | 接受：把前缀换成选中的候选 |
| `Esc` / `C-g` | 取消 |
| 其它可打印键 | 关掉弹窗、照常输入（`after-edit` 钩子关弹窗） |

用到的两个框架能力：

- **浮层 = document**（`workspace.floats` + `projection/float.rkt`）：
  弹窗是一块**不在 layout 树里**的 region（真实 document + view），
  绘制时作为 `deep` 更高的 panel 交给 core 合成。于是：

  | 需求 | 手段 |
  |---|---|
  | 候选列表 | 浮层文档的文本（`set-text-effect`） |
  | 选中行 | 浮层文档的光标行（`select-effect`）+ 一条 `'selection` face（`set-face-layer-effect`） |
  | 位置 | `projection/float.rkt` 每帧按“锚点 view 的光标”算矩形（下方优先，放不下翻上面，水平夹在面板内） |
  | 出现 / 移动 / 消失 | core 的增量 diff（浮层就在 core 的 screen 里） |

  因为它是真的 panel，**擦除和“底下正文画回来”全部由 core 负责**，框架不记任何矩形
  —— 之前把它当“叠加 piece”画在 core 之后，core 的 diff 看不见它，关掉就会留残影。
  `test/float.rkt` 用 `render-frame` 的字节做回归（关掉后浮层文本消失、底下正文回来）。

  配套的一条规则：`set-text-effect` **不**发 `after-edit` 信号（它是“整篇展示内容替换”，
  状态栏 / 面板 / 浮层都用它）；否则补全一写自己的浮层文档就会被自己的 after-edit 钩子关掉。
- **临时键表**：打开弹窗时把 `'completion-popup` 这张 keymap 挂到 `state.input.modes`
  （`dispatch/rules.rkt` 的 `input-mode-rules` 是最高一层），关掉时摘掉。
  于是 `↑↓` 只在弹窗开着时改变含义，弹窗一关就还给编辑器。

会话记在 `store['completion]`（view / line / start / end / last / cands），
**用缓冲内容而不是版本号判断是否还有效**：光标仍在 `[start,end)` 末尾，且该区间就是上次的候选。

还没做：异步候选源（module exports / 模糊匹配）、输入即过滤（现在打字会关掉弹窗）。

### 2.5 文档（`plugins/docs/`）

- 面板 `*docs*`（`panel-spec` + `store['docs]`，和文件树/资源列表同构），
  放在 **status 行下面**，`(fixed 8)` 固定高度；
- `C-c h` 打开 / 再按收起 —— **只手动关闭**：`after-nav` 只刷新内容，
  焦点变化不会把它收起来（看着文档改代码不会被焦点移动打断）；
- 打开时会改变布局（编辑区变矮），所以同一个 transition 里发一个 `ensure-view-effect`，
  由 core 的 `view-ensure!` 把焦点 view 的光标夹回窗口；平时任何面板尺寸变化也由
  `engine-sync-view!`（尺寸真的变了才）自动 ensure；
- 文档来源：内置关键字表 + 当前文档的顶层 `(define …)` 行（纯函数）。

还没做：stdlib/网络文档（要 `spawn-effect` + 缓存 + 防抖）、多来源合并。

## 3. 三个插件的“零框架改动”清单

| 需求 | 用到的框架能力 | 是否改框架 |
|---|---|---|
| 语法高亮 | `face-decor`（open/change）+ `effects/paint` 的 document slot + 脏行写回 | 加了“每文档 decor slot”和 change 透传；不再用 hook / worker |
| 补全 | `replace-range-effect` + `store` + `env.rules` 绑定 `M-/` | 只加了一个 effect |
| 文档面板 | `panel-spec` + `store` + `after-nav`/`focus-changed` 钩子 | 不需要 |

## 4. 验收

```
racket edit-tui-rebuild/test/plugins.rkt   # 高亮 / 补全 / 文档
racket edit-tui-rebuild/test/hooks.rkt     # 信号 / 钩子 / 顺序 / 自激保护
racket edit-tui-rebuild/demo/lab.rkt       # 三个插件一起跑
```
