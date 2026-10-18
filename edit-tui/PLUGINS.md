# edit-tui 的插件：三个例子与上一代的取舍

> 目标是把“语法高亮 / 补全 / 文档”做成**纯数据插件**，框架侧不加 if。
> 这里先记录从 `history/edit4` 提取出来的功能核心与取舍，再说明本仓库的实现。

## 1. 从 edit4 提取的功能核心

edit4 的插件系统（`plugin.rkt` / `core/hook.rkt` / `decor/protocol.rkt`）值得保留的只有四件事：

| 机制 | 是什么 | 为什么重要 |
|---|---|---|
| **信号 + 钩子** | 命令用 `emit!` 把 `(point . args)` 追加到 `World.signals`；runtime 反复“取信号 → 按 priority 跑匹配的 reaction → 直到没有新信号” | 让“文本改了之后重算高亮 / 重算补全候选 / 刷新文档”变成**旁观者**逻辑，命令不需要认识它们 |
| **decor 协议** | `decor { open: path text -> (state layer); change: state layer ctx -> (state layer dirty) }`，layer 是“每行一个 face 向量”，dirty 是“哪几行脏” | 上色是一个可以增量、可以分层（括号底色 / 同词着色 / 语法前景）的**纯函数**，与渲染解耦 |
| **补全菜单** | 不抢焦点的浮窗；Up/Down/Tab/Enter/Esc 用“有菜单就操作菜单”的命令接住；打字走基础 insert，`after-insert` 钩子重筛 | 补全的难点不是候选，而是**菜单与会话**（谁持有、谁刷新、谁取消） |
| **文档服务** | `C-c h` / `M-d`；本地定义走纯函数，stdlib 走 `#:services 'doc` 的异步 worker，结果按 key 缓存、同一时刻只允许一个在途；也订阅 `complete-selection` | 文档查询是慢操作，必须**防抖 + 缓存**，而且不能阻塞输入 |

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

### 2.3 语法高亮（`plugins/highlight/`）—— 四个增量 face decor

四个插件、四层，互不覆盖；它们不是 hook，而是每个文档一份持续状态：

| 文件 | 层 | 写什么 |
|---|---|---|
| `plugins/highlight/depth-decor.rkt` | `'depth-bg` | 括号深度背景（`face-set-bg`） |
| `plugins/highlight/word-color-decor.rkt` | `'word-color` | 同词同色前景（djb2 → 12 色） |
| `plugins/highlight/syntax-decor.rkt` | `'syntax-fg` | 语法前景（关键字 / 字符串 / 注释 / 数字） |
| `plugins/highlight/words-decor.rkt` | `'words` | 光标当前 token 的背景（`bg-word-mark`） |
| `lex.rkt` / `depth.rkt` / `kind.rkt` | — | 纯行级扫描 / 适用范围判断：`state × line -> (state', 行 face 向量)` |

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
- **每层只写自己的分量**：合成在 `effects/paint.rkt` 按 `env.face-layers`
  的层序做，同分量后层覆盖，attrs 并集（与 edit4 的 bracket → word-color → syntax → words 一致）。
- **没有后台 worker 路径**：高亮不再 `submit-service-effect` / `job-done`；
  worker 只保留给一次性纯计算。同步 decor 的正确性由 core 的版本顺序保证。
- `set-face-layer-effect` 仍然存在，但只用于一次性静态层（例如补全选中行）。

高亮只对 Racket 文件生效：`face-decor` 的 `applies?` 看 doc-meta（mode / path 后缀），
由 `runtime/run.rkt` 在文档打开后过滤并挂到 engine。

### 2.4 补全（`plugins/completion/`，浮层菜单 + 异步候选池）

**输入词前缀后自动弹出**浮层菜单（不再需要 `C-c /` / `M-/`）；与 edit4 对齐：

- 候选 = 关键字 + 当前文档顶层定义 + 打开文档里的标识符；
  标识符切分与词高亮/当前词高亮共用 `plugins/lang/word.rkt` 的 `line-tokens`，
  因此 `let` 绑定 / lambda 参数 / 普通局部变量也能补；
  顶层定义扫描覆盖 `define` / `define/contract` / `define-values` / `define-syntax(es)` /
  `define/match` / `struct`（含谓词、访问器、mutable setter）/ `define-struct` 等常见形式；
- 前缀用 `plugins/lang/word.rkt` 的 `word-before`（与 docs 同一个“光标前词”原语）；
  输入第一个词字符就弹；删除 / 导航不主动弹，但菜单开着时照常重筛；
- 候选包含与当前前缀完全相同的**已知名字**（关键字 / 顶层定义 / require 导入名），
  所以输入完整的 `define` 也能看到候选；接受一个等于前缀的候选只关菜单，不发替换；
- 当前文档里刚敲出的普通词不会把自己变成候选（否则任意 `sqx` 都会弹）；
- 接受候选本身会发 `after-edit`（replace-range），用 store 里的 `suppress-auto?`
  抑制“刚替换完又弹开”；
- Racket 文档再解析 `require`，把 `only-in` / `except-in` / `prefix-in` / `rename-in`
  之后的**真正绑定名**作为候选（`plugins/lang/context.rkt` + `pool.rkt`）；
- 同一个本地模块如果**已经在内存里打开**，`pool.rkt` 先用当前 buffer 的 `(provide …)`；
  没有打开才退回磁盘模块。模块缓存 key 也包含打开的本地文本，所以未保存的编辑立刻生效；
  路径统一走 `module-path-key`（绝对 + 消掉 `.` / `..`），`a/../b.rkt` 和 `b.rkt` 是同一个 key；
- 本地候选（关键字 / 顶层定义 / 已打开文档词）**立刻开菜单**；`module->exports`
  同时走 worker（`completion-exports`），结果回来后再并进当前菜单的 pool，不阻塞输入；
  结果按 `(specs, base-dir, 打开的本地文本)` 缓存；同一 key 只允许一个在途；
- `(require …)` / `#lang ` 光标处补**模块路径**（worker 的 `module-paths`）；
- 选中候选广播 `complete-selection`，docs 插件可跟随。

| 键 | 作用 |
|---|---|
| `↑` / `↓` | 移动候选（不移动光标） |
| `Enter` / `Tab` | 接受：把前缀换成选中的候选 |
| `Esc` / `C-g` | 取消 |
| 其它可打印键 | 照常插入，`after-edit` 按新前缀重筛（不是关掉弹窗） |

浮层仍然是 document：候选行 = 文档文本，选中行 = 文档光标行 + `complete` /
`complete-selected` face。窗口只显示选中项附近的 8 行（`popup-window`），
选中行用空格补齐到浮窗内容宽，所以底色盖满整行。

### 2.5 文档（`plugins/docs/`）

- 面板 `*docs*`（`panel-spec` + `store`），放在 status 行下面，固定高度；
- `C-c h` 打开 / 再按收起；`M-d` 强制显示当前词；`after-nav` 跟随光标刷新；
- 查的是**光标前的词**（`word-before`），不是光标所在格上的词：光标停在词尾时得到
  完整词；在词中输入时得到已输入前缀。因此不要求光标恰好落在标识符字符上；
- `prefix-in` / `rename-in` 后显示的是新名字，但查询用 binding 里的**原名**
  （例如 `head` -> `first`）；
- 本地模块（path 来源）的文档优先从**已打开 buffer** 里取 `local-def`，不再拿本地
  模块去 xref（xref 对 `(file ...)` 不生效）；
- 没有 `#lang` / 没有 path 的 scratch buffer 也按 `racket/base` 上下文显示内置文档和
  当前 buffer 的本地定义；
- 内置关键字文档是离线兜底：worker 没回来 / 查询失败时也会显示 `define` 等定义，
  不会只剩“来源 / 无本地文档”。
- **文档来源（与 edit4 对齐）**：
  1. 当前文档顶层定义（`plugins/lang/local-docs.rkt`，纯）；
  2. 标准库 / 已安装包（`plugins/lang/docs.rkt`：`setup/xref` + `scribble/blueboxes`，
     bluebox 缺失时用 `doc-html.rkt` 抽 HTML 正文），走 worker 的 `doc` 服务；
  3. 内置关键字表（离线兜底）；
- 查询按 `(名字, 候选模块)` 缓存；同一时刻只允许一个 doc 查询在途；
- 补全选中项变化时：面板如果没开，会**自动打开**并显示该候选的文档；
  面板原本是 C-c h 手动打开的，则保持跟随、不自动收起。
- 补全菜单关闭时，只有“由补全自动打开”的 docs 面板才自动收起（`store['docs].auto?`）。
- 打开面板改变布局时，同一 transition 发 `ensure-view-effect`，把焦点 view 的光标夹回窗口。

## 3. 插件的“零框架改动”清单

| 需求 | 用到的框架能力 | 是否改框架 |
|---|---|---|
| 语法高亮 | `face-decor`（open/change）+ `effects/paint` 的 document slot + 脏行写回 | 加了“每文档 decor slot”和 change 透传；不再用 hook / worker |
| 补全 | `replace-range-effect` + `store` + `env.rules` + `submit-service-effect`（模块导出）+ `complete-selection` 信号 | 用了已有 effect / hook，没有新增框架表 |
| 文档面板 | `panel-spec` + `store` + `after-nav`/`complete-selection`/`job-done` 钩子 + `submit-service-effect`（xref） | 用了已有 effect / hook |

## 4. 验收

```
racket edit-tui/test/plugins.rkt   # 高亮 / 补全 / 文档
racket edit-tui/test/hooks.rkt     # 信号 / 钩子 / 顺序 / 自激保护
racket edit-tui/demo/lab.rkt       # 三个插件一起跑
```
