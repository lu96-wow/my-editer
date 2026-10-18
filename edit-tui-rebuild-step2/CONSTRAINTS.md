# 特殊约束与依赖配合

> 这份文档只列**容易被代码结构掩盖、又不一定被类型系统抓住**的约束。
> 分层 / 副作用白名单由 `test/layers.rkt` 机器检查；设计背景见
> `ARCHITECTURE.md`、`INCREMENTAL.md`、`PLUGINS.md`。
>
> 新加 hook / effect / 插件 / 后台服务前，先看第 10 节的检查清单。
> 代码里以 `;;; CONSTRAINT:` 开头的注释，是本文对应条款的就地提示。

---

## 1. 全局不可破的边界

| 边界 | 约束 | 违反后的典型症状 |
|---|---|---|
| core 所有权 | core buffer / view 只由 `effects/engine.rkt` 和 `effects/paint.rkt` 写 | 后台线程、hook、projection 直接改 core → undo / 多实例 / 测试失真 |
| State | State 只存 id、元数据、纯数据；不存 core 句柄、线程、cache、inbox | headless 重放失败；State 不可比较；多实例污染 |
| 纯投影 | `projection/*` 只读 state + engine-view，不写 core、不 put-bytes | 渲染帧有副作用；diff / cache 不可预测 |
| 输出 | `put-bytes` / `flush!` 只在 `runtime/run.rkt` | 多处输出互相插队；测试无法截获字节 |
| 层序 | 依赖只能按 `ARCHITECTURE.md` §2 往下 | 循环依赖；`test/layers.rkt` 红 |
| 副作用 | 文件 / 线程 / terminal 只在白名单模块 | 纯层带上 IO；测试不稳定 |

`core/text/base/*` 是**纯值词汇**（track / change / point / range / line），
`model/face-decor.rkt` 可以 require；`core/editor*` / `core/text/document.rkt`
（含可变盒）仍只允许 engine / paint / projection 等白名单模块。

---

## 2. 外部依赖配合点

`edit-tui` 现在是**自包含**的：旧 `edit-tui` 里的 face / command / core-render / theme
已经迁进本目录，对应层：

| 本目录 | 层 | 用途 |
|---|---|---|
| `base/face.rkt` | base | face 值（`#:prefab`） |
| `command/{key,mouse,command,keymap}.rkt` | command | 输入 token / command 值 |
| `command/tui.rkt` | command | terminal event → token（唯一碰 `tui` 的 command 模块） |
| `core-render/` | core-render | piece → tui bytes |
| `theme/` | theme | face 符号 → ANSI style；`main.rkt` require 即安装 |

仍然在仓库外 / 其他目录的依赖：

| 依赖 | 使用者 | 约束 |
|---|---|---|
| 仓库根 `core/` | engine / paint / projection / core-render | core 公共面变更先看 `core/README.md` 的“写回只有一条路径” |
| `racket-tui` | command/tui、core-render、theme、runtime | terminal IO 只通过这些边缘模块 |
| `history/` | 参考 / 历史实现 | 运行时不 require |

`test/layers.rkt` 负责检查本目录内 `command` / `core-render` / `theme` 的层序和
`tui` 使用白名单。

---

## 3. 事件 / effect / hook 的顺序

```
event
  → dispatch（纯）
  → transition{state, effects}
  → settle:
      1. 解释 effect（写 engine / IO / emit 信号）
      2. ensure-doc-decors!（新文档挂 decor）
      3. 排空信号 → 跑 hook
      4. hook 产生新 effect → 回到 1（最多 8 轮）
```

必须是这个顺序：

| 约束 | 原因 |
|---|---|
| **hook 在 effect 解释之后跑** | hook 读的是新文本；在 dispatch 里跑会拿到旧文本 |
| hook 的 `proc` 只拿**只读 engine-view** | 写 core 必须发 effect；hook 不能绕过 engine |
| hook 可以 emit / 加 effect | 但会再走一轮 settle；不要自激 |
| `after-edit` 只在文本真的变了时发 | 参数是 `(doc-id changes)`；无变化不发 |
| `set-text-effect` 不算用户编辑 | 状态栏 / 面板 / 浮层整篇替换；发了会让补全把自己关掉 |
| effect 顺序 = 书写顺序 | `transition-bind` 保留顺序；不要依赖“先所有 state 再所有 effect” |

相关代码：`dispatch/hooks.rkt`、`runtime/run.rkt` 的 `settle`、`effects/interpreter.rkt`。

---

## 4. face decor / paint 的约束

这是目前最容易被误改的一块。

### 4.1 document slot 是唯一增量状态载体

| 约束 | 说明 |
|---|---|
| 每个 document 一个 `face-paint` slot | 不按插件拆 slot；合成顺序 / dirty / 写回必须同处 |
| `change` 必须是纯函数 | 不能原地改 state / layer / 向量；旧 document 还在 history 里 |
| layer 必须与 new-text 逐行对齐 | 行数相同、每行向量长度 = 字符数；否则写回会错位 |
| 一个编辑只重扫 dirty 行 | 用 `refresh-layer` / `stateful-advance`；不要整篇 open |
| 跨行状态要收敛 | 块注释 / 字符串 / 括号栈用 `stateful-advance`，不是只看 change 行 |
| 多光标是多次 fork | `paint-fork` 必须并上旧 dirty，否则前面 span 的脏行会丢 |
| undo / redo 靠 document 版本恢复 | 不要另存一份不带版本的状态；旧 slot / 旧 face port 一起回来 |

相关代码：`model/face-decor.rkt`、`effects/paint.rkt`。

### 4.2 静态层（`set-face-layer-effect`）

- 静态层存在 `paint-state.static`，不是 engine 外部 hash。
- 文本编辑时用 `fork-ctx-edit` 自动平移；编辑后仍与文本对齐。
- 它**不是**增量 decor：写一次会 `dirty-all`；适合补全选中行这种一次性高亮。
- `set-text-effect` 会重置 paint slot，静态层丢失；调用方需要重新发
  `set-face-layer-effect`（补全 / docs 每次写文本后都会重发）。

### 4.3 光标相关 decor

- 编辑期 fork 的 `face-ctx.cursor = #f`；decor 在这一步**只标脏**，不要读光标。
- 光标 / 导航后由 `engine-paint-advance!` 再调一次 `change`，这次 `changes = '()`
  且带 `(line . col)`。
- 一个 document 只有一份 decor 状态，所以光标装饰只跟**主视图主光标**走。
  多视图各自光标高亮不在当前实现范围内。

### 4.4 写回

- `paint-write!` 只写 dirty 行：先清该行，再写合成后的 runs。
- 文本编辑已经由 core 把 face port 平移过；不要整篇 `buffer-face-all!`。
- `buffer-face-batch!` 是唯一写 face 的调用点；不要从 decor / hook 直接写。
- 层序来自 `env.face-layers`；decor 的 `layer` 名应唯一。未声明的层按名字追加。

### 4.5 decor 适用范围

- `face-decor.applies?` 接收 `doc-meta`，不是完整 State。
- `runtime/run.rkt` 的 `ensure-doc-decors!` 只给**非 internal** 文档挂 decor。
- internal 文档（状态栏 / 输入栏 / 面板 / 浮层）没有 decor；补全 / docs 的
  一次性 face 走静态层，不依赖 decor。

---

## 5. 异步 / worker 的约束

### 5.1 worker 只做一次性纯计算 / 只读查询

`plugins/worker.rkt` 在独立 place 里跑：

- 不持有 core 句柄、不读 State、不写 UI；
- 可以调用只读的模块查询 / xref / 文档 HTML；
- 返回结果必须能跨 place：list / vector / string / symbol / number / prefab struct；
- **不要传** `track` / `change` / `buffer` / `view` / State；它们不是跨 place 的稳定载荷。

### 5.2 job 对账

| 约束 | 说明 |
|---|---|
| job-id 唯一 | `state-next-id` 分配；父进程按 id 找回调 |
| 一个 worker 一条队列 | 提交顺序 = 执行顺序；不要假设并行 |
| 结果只发 `job-done` | `(job-id value)`；父进程再改 State |
| 无 worker 时内联 | `runtime/run.rkt` 同步调用同一个 `service-run`；语义必须一致 |
| worker 错误也走 `done` | 子进程把异常包成 `(vector 'error msg)` 作为 result，父进程仍发 `job-done`；补全 / docs 看到非 list / 非 string 就清 pending，不能留 loading |
| 缓存 key 要含输入身份 | 补全：specs + base-dir + 打开的本地文本；文档：名字 + 候选模块 |

### 5.3 服务表

`plugins/worker.rkt` 的 `service-kinds` 是唯一分派表：

```
syntax-fills / depth-fills   旧的全量 fills（高亮已不走这里，测试保留）
completion-exports           require 导出 / 模块路径
doc                          xref + blueboxes + HTML
module-paths                 已安装模块路径索引
```

新增服务 = 一个 case + 一个能在 place 里加载的纯模块；不要在插件里直接
`dynamic-require` 一堆实现。

---

## 6. 补全 ↔ 文档的配合

两者通过信号解耦，**互不 require**：

```
completion  --complete-selection (vid name binding)-->  docs
docs        <-- 面板开着时更新；不自动改布局
```

| 约束 | 说明 |
|---|---|
| 补全弹窗是 document | `*completion*` 是真实 region + view；不在 layout 树里 |
| 临时键表 | 打开时把 `completion-popup` 模式压入 `state.input.modes`；关闭时弹出 |
| 弹窗不抢焦点 | role = `'panel`；焦点始终在编辑器 |
| `set-text-effect` 不发 after-edit | 否则弹窗写自己会触发自己的 after-edit / 关闭 |
| 弹窗选中行 | 静态 `'completion` / `'complete-selected` 层；文本更新后要重发 face |
| 文档跟随 | docs 只在面板已经打开时跟随；不会因为补全自动改布局 |
| 补全 job | `completion-exports` 结果按 key 缓存；`job-done` 回来后才打开菜单 |
| 文档 job | `doc` 结果按 key 缓存；unknown 首次查询成功后自动打开 |

补充：补全的 `filter-pool` **排除与 prefix 完全相同的候选**，避免 Enter 接受
一个无变化的词；模块路径补全同样如此（要继续输入才能选中更具体路径）。

---

## 7. runtime 事件循环 / resize

| 约束 | 说明 |
|---|---|
| `on-source inbox` | 后台结果并入 `read-event` 等待集合；回调里处理 + 重绘 |
| 回调不嵌套 `read-event` | 会重入等待；只做 `handle!` |
| `handle!` 必须处理完整批次 | `drain-and-process` 排空 inbox，防忙循环 / 丢 job-done |
| state / cache 用 box 共享 | `read-event` 源回调与主循环同一线程；不引入锁 |
| resize | 丢掉 frame cache，让 `render-frame` 先 `render-clear` 一次再全量重画 |
| 首帧 | `startup!` 先补 `document-opened` 并 settle；decor 在 settle 里挂 |
| quit | 退出前 `worker-stop!`；不要从回调直接退出而跳过清理 |

`runtime/run.rkt` 是唯一允许 `read-event` / `put-bytes` / 线程 / `on-source` 的模块。

---

## 8. 显示 / 浮层 / 布局

- **所有显示都是 document**：没有额外绘制层；浮层也是 region + view + panel。
- 浮层在 `workspace.floats`，不进 layout 树；每帧由 `projection/float.rkt` 算矩形。
- 浮层的 role 是 `'panel`（不可聚焦），按键靠临时 keymap 接管。
- `projection` 不写 core；尺寸同步在 `run-frame`：
  - `sync-chrome!`
  - `environment.panel-syncs`
  - `engine-paint-advance!`
  - `project-frame` → `engine-sync-views!` → `render-frame`
- 面板同步（`panel-syncs`）是**每帧、可能写 core 的**回调，和 hook 不是一类；
  不要把它塞进 `env.hooks`。
- 焦点变化 / 面板开关改变尺寸后，`engine-sync-view!` 才会 `view-ensure!`；
  需要立刻夹光标时发 `ensure-view-effect`。

---

## 9. 主题 / face 符号

| 约束 | 说明 |
|---|---|
| core / 插件只产 face 符号 | 不产 RGB；颜色只在 `edit-tui/theme/` |
| 主题必须覆盖所有被写的符号 | decor / 静态层 / 面板 face 没有对应 style 会静默无色 |
| face 值按分量合成 | fg / bg / attrs；插件只写自己负责的分量 |
| 同名层唯一 | `word-color` / `syntax-fg` / `depth-bg` / `words` / `docs` / `completion` |
| 颜色对齐 edit4 | `edit-tui/theme/core.rkt`、`frame.rkt` 与 `history/edit4/config/palette.rkt` 同步 |

新增 face 符号时，同时更新主题；`edit-tui/theme/main.rkt` 是 require 即安装。

---

## 10. 新加 hook / 扩展前的检查清单

1. **它是“发生了一件事”的旁观者，还是“每个文档一份持续状态”？**
   - 旁观者 → `env.hooks`；
   - 每文档 face 状态 / 增量 → `face-decor`，不要用 `after-edit` + 全量 `set-face` 硬凑。
2. **它需要写 core 吗？**
   - 需要 → 发 effect，由 engine / paint 写；
   - 不需要 → 只读 engine-view / state。
3. **它需要异步吗？**
   - 一次性纯计算 → `submit-service-effect` + worker + `job-done`；
   - 需要顺序 / 版本对账 → 先想清楚 cache / pending / job-id；不要后台写 core。
4. **跨 place 的 payload 可序列化吗？**
   - 去掉 track / change / buffer / view / State / 闭包。
5. **和谁配合？**
   - 补全 ↔ docs：`complete-selection`；
   - 补全 / docs ↔ worker：`completion-exports` / `doc`；
   - decor ↔ core：document slot fork；
   - runtime ↔ worker：inbox + on-source。
6. **会不会破坏 undo / 多光标 / resize / 首帧？**
   - decor：旧 dirty 合并 + document 版本；
   - 多光标：多次 fork；
   - resize：cache 清一次；
   - 首帧：`startup!` settle。
7. **加完以后 `test/layers.rkt` / 全量测试还能过吗？**

---

## 11. 已知限制（有意保留）

- `face-decor.change` 在 core 编辑的 slot fork 里同步执行：重 decor 会阻塞输入；
  异步增量是第二阶段，不能后台写 core。
- 光标相关 decor 只跟主视图主光标；多视图各自光标未做。
- 补全 / 文档的异步结果按 key 缓存；上下文变化时旧结果不会自动 rebase，
  只会按新 key 重新查。
- 文档面板是固定高度底部面板；edit4 的文档浮窗 / 自动跟随尚未完全复刻。
- `auto-pair` / `sync`（双文档同步）尚未迁移。
