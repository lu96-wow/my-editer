# 增量 face / decor 架构（提案）

> 状态：**已实现**。实际模块：`model/face-decor.rkt`、`effects/paint.rkt`、
> `plugins/highlight/{syntax-decor,depth-decor}.rkt`。本文保留为设计与取舍记录。
>
> 目标：让语法高亮 / 括号深度这类 face 插件真正做到“只重算脏行、只写脏行”，
> 同时不破坏 core 的 document / history 语义，不把副作用塞回后台线程。

---

## 1. 结论

采用：

```
core document slot（每文档一份 decor 状态 + 各层 face track）
        +
change 透传（after-edit / fork-ctx）
        +
脏行重算 + 脏行写回
```

不采用：

- **后台线程直接写 core 的 face 轨**（上一版 `face-runner`）：绕过了 engine 唯一写入口，
  要引入锁、版本、回调重绘，undo / 多 app 实例 / 测试都说不清。
- **engine 外部维护 fills，文本一变就清空所有层**（当前实现）：坐标和文本脱节，
  只能整篇重算、整层替换。
- **每个插件一个 document slot**：slot 数量随插件增长，且插件顺序 / 合成仍要另存。
- **把高亮继续塞进 `after-edit` + `submit-service-effect`**：hook 是“发生了一件事”的旁观者，
  不是“每个文档一份持续状态”的装饰器。增量高亮需要的是后者。

第一版只做**同步增量**。worker 继续保留给“一次性纯计算”（文档查询、补全候选等）；
高亮不再走 worker。异步增量是第二阶段，且只能“后台算、主线程应用”，不能后台写 core。

---

## 2. 判断依据

### 2.1 core 已经提供了什么

core 的 document 是：

```
text track（不可变）
+ face port（可变盒里的 track，渲染读）
+ readonly port
+ slots（特性声明的 opaque 存储，随版本 fork）
```

关键事实：

1. **文本编辑会 fork slots**：`core/text/document.rkt` 的 `document-edit-tracks` 把
   同一次编辑同时作用到 text / face / readonly，并把 `fork-ctx` 传给每个 slot 的 transform。
2. `fork-ctx` 里有 `edit` / `changes` / `old-text` / `new-text`
   （`core/text/slots.rkt`）。
3. face port 本身就是一条与文本对齐的 track；`buffer-face-batch!` 可以只写指定区间。
4. `document-revision` 会在 face 写回后换 token，core 的渲染缓存自然失效。
5. history 保存的是**整个 document 版本**，undo 回到旧 document 时，
   旧 document 的 slots / face port 也一起回来。

这意味着：**层状态如果放在 document slot 里，文本编辑的对齐和 undo 是 core 免费给的。**
当前 rebuild 把层放在 engine 的 hash 里，等于把这部分能力丢了，才需要“文本一变清空所有层”。

### 2.2 edit4 已经验证过的形状

`history/edit4` 的 decor 协议：

```
open   : path text -> (values state layer)                 整篇初次扫描
change : state layer ctx -> (values state layer dirty)     一次编辑 / 一次光标推进
```

- `layer` 是行 track，行 payload = 每格一个 face 的向量；
- `dirty` 是“全脏”或“行集合”；
- `history/edit4/decor/dirty.rkt` 里有：
  - `changes->dirty-lines`
  - `refresh-layer`（按 change 的行区间 splice 旧层，其余行结构共享）
  - `stateful-advance`（带跨行词法状态从脏行重扫，直到状态收敛）
- `history/edit4/view/decor.rkt` 把 decor 状态挂在 document slot 上：
  文本编辑时由 slot fork 推进；undo 回放旧 document 即得旧层。

这就是“可增量、可 undo、只写脏行”的完整证据链。

### 2.3 rebuild 的设计约束

`ARCHITECTURE.md` 已经定下的边界不能破：

- State 纯；core 句柄只在 engine；
- `effects/engine.rkt` 是 core buffer / view 的唯一可变拥有者；
- 投影纯，不写 core；渲染输出只在 runtime；
- 插件是数据，装配是 fold；
- hook 只在 effect 解释之后跑，拿只读 engine-view。

因此新的 face 架构必须满足：

1. **所有 core 写都在主线程、都经过 engine**；
2. **增量状态跟着 document 版本走**（undo 能恢复）；
3. **插件只提供纯函数 + 数据**；
4. **写回只写 dirty 行**；
5. **change 从 core 透传出来**，不是插件自己 diff 全文。

---

## 3. 数据模型

### 3.1 插件协议（纯值）

放在 `model/face-decor.rkt`（model 层，纯）：

```racket
(struct face-decor (id layer applies? open change) #:transparent)
;; id      : symbol
;; layer   : symbol                       写哪一层 face
;; applies?: doc-meta -> boolean          该文档要不要挂这个 decor
;; open    : path track -> (values state layer)
;; change  : state layer face-ctx -> (values state layer dirty)
;;
;; state   : 插件自己的纯数据（词法状态 / 上次光标 / #f）
;; layer   : track，行 payload = (vectorof (or/c face? #f))，与 text 逐行对齐
```

```racket
(struct face-ctx (old-text new-text changes dirty path cursor) #:transparent)
;; old-text / new-text : track
;; changes : (listof change)          core 的变更描述（空 = 纯光标推进）
;; dirty   : dirty                    changes 直接波及的整行（新坐标）
;; path    : path | #f
;; cursor  : (cons line col) | #f     当前主光标；编辑期 fork 时是 #f
```

```racket
(struct dirty (all? lines) #:transparent)
(define (dirty-all) ...)
(define (dirty-lines lines) ...)
(define (dirty-union a b) ...)
(define (dirty->lines d n) ...)
```

约束：

- `layer` 必须始终与 `new-text` 逐行对齐（行数相同，行向量长度 = 该行字符数）。
- `change` 必须是**纯函数**：不能原地改传入的 state / layer / 向量。
  旧版本可能还在 history 里，原地改会污染 undo。
- `change` 可以返回 `dirty-all` 表示“这次我放弃增量，整篇重来”。
  简单 decor 用 `pure-decor` 包装即可，不必强写增量。

### 3.2 文档内的合成状态

放在 `effects/paint.rkt` 的 document slot：

```racket
(struct paint-state (decors entries static path dirty) #:transparent)
;; decors  : (listof face-decor)          打开时固定（已按 applies? 过滤）
;; entries : (listof (cons state layer))  与 decors 平行
;; static  : (hash/c symbol track)         set-face-layer-effect 的一次性层
;; path    : path | #f
;; dirty   : dirty                         待写回 core face port 的行
```

一个 slot 管完：

- 增量 decor 层（每层一条 track）；
- 一次性静态层（补全选中行等）；
- 脏行集合。

不按插件拆 slot，原因是：合成顺序、脏行合并、写回都必须在同一处做；
拆 slot 只会让 fork 顺序和合成顺序分离。

### 3.3 层顺序

仍然用 `env.face-layers`（先低后高）。`paint-write!` 按这个顺序合成；
没在顺序里出现的层按名字追加（与当前 `model/face-layer.rkt` 的 `compose-layers` 一致）。

decor 的 `layer` 名必须在环境里唯一；静态层名也不应与 decor 层重名。

---

## 4. 流程

### 4.1 打开文档

```
engine-create-doc!（core document，默认 slots）
  ↓
interpreter 按 doc-meta 过滤 env.decors
  ↓
engine-attach-decors! engine did decors path
  ↓
paint-open!：
  for each decor: (open path text) -> (state layer)
  static = {}
  dirty = all
  ↓
paint-write!：合成所有层，只写 dirty 行（首次 = 全篇）
```

`engine` 另存一份 `did -> (list decors path)`，用于 `set-text-effect` 整篇替换后重新 open；
document slot 本身仍然是状态的唯一载体。

### 4.2 文本编辑

```
engine-apply!
  ↓
buffer-edit! / buffer-replace-range!
  ↓
core document-edit-tracks
  ↓
fork-slots
  ↓
paint slot transform：
  dirty0 = changes->dirty-lines changes
  for each decor entry:
     (change state layer face-ctx{old,new,changes,dirty0,path,cursor=#f})
       -> state' layer' dirty'
  static layers: 用 (fork-ctx-edit ctx) 自动做同样的结构平移
  dirty = dirty0 ∪ 所有 decor 的 dirty'
  ↓
engine 拿到 changes
  ↓
paint-write!：只写 dirty 行到 core face port
  ↓
interpreter 发 after-edit (doc-id changes)
```

注意：

- decor 的结构平移由 decor 自己负责（`refresh-layer` / `stateful-advance`），
  不是 engine 再替它 `fork-ctx-edit` 一次，否则会双重 splice。
- 静态层没有 change 函数，所以 engine 用 `fork-ctx-edit` 替它做结构平移。
- 编辑期 cursor = `#f`：光标相关 decor（同词高亮）只标脏，不在这里读光标。

### 4.3 光标 / 导航

```
engine-paint-advance! engine vid
  ↓
取当前 view 的主光标 (line . col)
  ↓
paint 对每个 decor 调 change，changes = '()，old-text = new-text = 当前 text
  ↓
得到 dirty（通常只有旧光标行 / 新光标行）
  ↓
paint-write!
```

调用点：

- `engine-apply!` 处理 `nav-effect` / `select-effect` 后；
- `run-frame` 投影前，对当前焦点 view 再推进一次（兜底焦点切换 / 面板切换）。

一个文档只维护一份 decor 状态，所以光标相关 decor 只跟**主视图主光标**走。
多视图各自的光标高亮不在第一版范围内（旧 edit4 也是这个取舍）。

### 4.4 undo / redo

```
buffer-undo! / buffer-redo!
  ↓
history 换 current document
  ↓
旧 document 的 paint slot / face port 一起回来
```

- decor 的 state / layer 不需要重算；
- 对恢复后的 slot 再跑一次 `paint-write!`（dirty 通常为空，是 no-op）；
- 光标相关 decor 由 4.3 的光标推进处理。

这正是“状态放 document slot”而不是“放 engine hash”的核心收益。

### 4.5 整篇设置文本（`set-text-effect`）

`buffer-set-document!` 不走 `document-edit-tracks`，新 document 的 slots 是默认值。
处理：

- 如果该 did 没有 decor：清掉 face 层即可（面板 / 状态栏 / 浮层都是 internal）；
- 如果有 decor：用 engine 里存的 decors 重新 `paint-open!`（从新文本整篇 open），
  再 `paint-write! dirty-all`。

`set-text-effect` 仍然**不发 after-edit**（它不是用户编辑）。

### 4.6 `set-face-layer-effect`（一次性静态层）

保留这个 effect，但改成写 `paint-state.static`：

```
fills -> 一条与当前文本对齐的 layer track
static[layer] = track
dirty = all（第一版；以后可按 fills 行做 diff）
paint-write!
```

用途：补全浮层的选中行这类“一次性、非增量”的高亮。
文本编辑时静态层由 `fork-ctx-edit` 自动平移，不再像现在这样“文本一变清空所有层”。
调用方要清层就发空 fills。

---

## 5. change 透传

### 5.1 engine 不再吞掉 changes

`engine-apply!` 改为返回本次 changes：

```racket
;; -> (listof change)
```

- `edit` / `insert-text`：`buffer-edit!` 的返回值；
- `replace-range`：`buffer-replace-range!` 的返回值；
- `undo` / `redo`：构造整篇 change（old doc whole-range -> new doc whole-range）。
  这样 callers 拿到的是一个合法的“大脏区”，不需要 `#f` 哨兵；
- `set-text` / nav / select / scroll：`'()`。

`interpret-replace-range!` 不再直接 require core 写 buffer，而是走 engine 的
`engine-replace-range!`，保证“core 写只有 engine 一个入口”。

### 5.2 信号参数

`after-edit` 从：

```racket
after-edit  (doc-id)
```

改成：

```racket
after-edit  (doc-id changes)
```

规则：

- `changes` 非空才发；
- `set-text-effect` / `set-face-layer-effect` 不发；
- `after-nav` / `focus-changed` / `document-opened` 不变。

补全、文档面板等 hook 如果不需要 changes，继续只读 `(car args)`；需要的拿 `(cadr args)`。
高亮 decor 不依赖这个信号，它在 slot fork 里直接拿到 change。

### 5.3 为什么不在插件里自己 diff

插件自己缓存上一版全文再 diff 也能“猜”出脏区，但：

- 要自己处理多光标 change、undo、程序写入；
- 主线程做一次全量 diff；
- 仍然拿不到 core 的 before/after 结构；
- 与 core 已经算好的 `change` 重复。

所以 change 必须从 core 出来，插件不自己造。

---

## 6. 模块与边界

新增：

| 模块 | 层 | 职责 |
|---|---|---|
| `model/face-decor.rkt` | model | decor 协议；`dirty`；`changes->dirty-lines`；`refresh-layer`；`stateful-advance`；`scan-track`；`face-runs`；重导出插件需要的 track / change / face 词汇 |
| `effects/paint.rkt` | effects | document slot、open / fork / advance / static layer / 写回；纯合成 |
| `test/face-decor.rkt` | test | 增量、收敛、undo、静止不写、多光标 |

修改：

| 模块 | 改动 |
|---|---|
| `effects/engine.rkt` | 去掉外部 `face-layers` hash；改用 paint slot；`engine-apply!` 返回 changes；`engine-replace-range!`；attach decors；advance cursor |
| `effects/interpreter.rkt` | `after-edit (doc-id changes)`；replace-range 走 engine |
| `base/signal.rkt` | 更新信号词表注释 |
| `env/environment.rkt` | 增加 `decors` 字段 / 访问器 / merge |
| `env/plugin.rkt` | plugin 增加 `#:decors` |
| `plugins/highlight/*` | 改成 `face-decor`；删除 job / latest-job / job-done hook |
| `runtime/run.rkt` | startup 时 attach decors；每帧对焦点 view `engine-paint-advance!` |
| `test/layers.rkt` | core 白名单允许 `model/face-decor.rkt`、`effects/paint.rkt`（只允许 pure `core/text/base/*` 和 slot DSL） |

### 6.1 关于 core 白名单

`model/face-decor.rkt` 需要 `core/text/base/{track,change,point,range,line}.rkt`
这些**纯值词汇**。它们不碰 buffer / view / history，和 `edit-tui/base/face.rkt` 同级。
建议把白名单规则明确成：

- `core/editor*`、`core/text/document.rkt`（含可变盒）只在 engine / effects；
- `core/text/base/*` 的纯值模块允许被 `model/face-decor.rkt` 和 `effects/paint.rkt` 使用；
- 插件仍然只 require `model/face-decor.rkt`，不直接 require core。

这样既保住“插件不碰 core”，又不用把 track 逻辑复制一份到 plugin 层。

### 6.2 为什么不是 `env/decor.rkt`

`env` 只存 `(listof face-decor)`，`applies?` 在 interpreter / startup 过滤。
协议和算法必须在 model（纯值），因为 plugins 和 env 都要用，而 effects 不能反向被 env 依赖。

---

## 7. 增量算法

### 7.1 脏行

```racket
(change-post-range ch) -> after range
changes->dirty-lines changes -> 排序去重的行号
```

一条 change 的 after 区间覆盖的整行（含端点）都算脏。删除操作的 after 是零宽，
仍然重扫所在行。

### 7.2 无跨行状态（syntax 关键字 / 同词着色）

```racket
(refresh-layer layer new-text changes extra scan)
```

- 每个 change：旧层 `[before 行区间]` 换成对新文本 `[after 行区间]` 的重扫结果；
- 从右到左 splice，右侧不影响左侧行号；
- 其余行由 `track-splice` 结构共享；
- `extra` 处理光标行这类“不在 change 里但内容脏”的行。

### 7.3 有跨行状态（块注释 / 字符串 / 括号栈）

```racket
(stateful-advance states layer new-text changes scan init-state)
```

- 先按 change 把 states / layer 结构 splice 对齐（新行填 `#f`）；
- 从首个脏行开始，带着上一行的出状态重扫；
- 某一行算出的出状态与旧缓存相同 → 后面不可能再变，停；
- 返回新的 states / layer / dirty。

这是增量词法的正确性关键：**只重扫变化行是不够的**，`#|` 插入会让后面所有行变色。

### 7.4 多光标

`changes` 的 before 坐标是编辑前坐标、两两不重叠。`refresh-layer` / `stateful-advance`
按 before 行区间从右到左处理，不能假设 after 是全局新坐标。
加一个多光标回归测试（两个选区同时插入 / 删除）。

---

## 8. 写回

对每个 dirty 行：

1. 取该行所有层的行向量（decor entries + static layers，按层序）；
2. 逐格 `compose-face`；
3. 转成 runs；
4. 一条 batch 里先清该行（`(ln 0 ln len #f)`），再写非 `#f` 的 runs。

整篇无脏行 → 一个格都不写。这样：

- 编辑只影响少数行时，face 写回是 O(脏行)；
- 光标移动只影响旧/新光标行；
- 帧间静止时零写回、零 `document-revision` 变化。

---

## 9. 异步策略

第一版：同步。

理由：

- `decor-change` 在 core 的 slot fork 里跑，天然按文档版本顺序执行；
- undo / redo / 多光标 / 程序写入都不需要额外对账；
- 旧 edit4 已经证明这个模型能跑；
- 上一版异步 `face-runner` 的问题不是“线程不够快”，而是**状态所有权和版本对账**没定义。

如果以后高亮成为瓶颈，第二阶段只允许下面这种形态：

```
主线程：编辑 -> core fork（只平移 layer、记录 change + base-version）
        -> 提交 job（纯数据）
worker：decor-change(state, layer-slice, changes, text) -> (new-state, patch)
主线程：收到 job-done
        - base-version 不等于当前版本 -> 丢弃，用累积 changes 重新提交
        - 等于 -> 应用 patch 到 core face port（仍然只在主线程写）
```

约束：

- worker 只返回数据，不持有 core 句柄；
- 不共享锁、不在后台写 face port；
- 过期结果不能简单丢（增量 patch 丢了就少一段），必须保留“自 base 以来的 changes”重新提交；
- undo 让 base-version 失效，在途 job 自然被丢弃；
- **跨 place 前要转成 plain 数据**：`change` / `track` / `face` 是透明 struct，不是 prefab，
  不能直接塞进 `place-channel`。job payload 里只放 list / vector / string / symbol / number，
  或者显式加 `prop:serializable`；不要在 worker 里传 core track。

在这个协议定清楚之前，不把高亮搬回 worker。

---

## 10. 迁移顺序

1. **独立算法**
   - `model/face-decor.rkt`：dirty / `changes->dirty-lines` / `refresh-layer` /
     `stateful-advance` / `scan-track` / `face-runs`。
   - 从 `history/edit4/decor/dirty.rkt` 移植，先写纯测试。
2. **paint slot**
   - `effects/paint.rkt`：slot、open、fork、advance、static layer、write。
   - 先用一个假 decor 测：编辑只写脏行、undo 恢复。
3. **engine 切换**
   - 去掉外部 `face-layers` hash / 全清逻辑；
   - `set-face-layer-effect` 改走 static layer；
   - 现有 `test/face-layer.rkt` 全绿。
4. **change 透传**
   - `engine-apply!` 返回 changes；
   - `after-edit (doc-id changes)`；
   - 更新 hooks / effects / signal 测试。
5. **高亮 decor**
   - `syntax` / `bracket-depth` 改成 `face-decor`；
   - 删除 `submit-service-effect` / `job-done` / `latest-job` 的高亮路径；
   - `test/plugins.rkt` 的端到端高亮用新路径跑通。
6. **光标推进**
   - `run-frame` / nav / select 调 `engine-paint-advance!`；
   - 如果暂时没有光标相关 decor，这一步可以后置。
7. **文档**
   - 更新 `ARCHITECTURE.md` 的扩展点表和 `PLUGINS.md` 的高亮说明；
   - 把本文件从“提案”改成“已实现”。

---

## 11. 验收

必须有的测试：

1. open：整篇扫描，face port 与期望一致。
2. 单行编辑：layer 行数不变，只重扫 / 只写脏行；非脏行 face 不变。
3. 跨行编辑：插入 / 删除换行后 layer 与文本仍对齐，不越界。
4. 跨行状态收敛：在文件头插入 `#|`，后面块注释变色；再删掉，颜色恢复；
   并验证扫描在状态收敛处停止（不是整篇重扫）。
5. 多光标：两个选区同时编辑，dirty 行正确。
6. undo / redo：face 与 decor state 跟着 document 版本恢复，不靠整篇重算。
7. 光标移动：只动旧/新光标行；静止帧不写 face。
8. 两个 decor 合成：前景 / 背景互不覆盖。
9. static layer + decor 合成；文本编辑后静态层仍对齐。
10. `after-edit` 参数是 `(doc-id changes)`；`set-text` / face 不发 `after-edit`。
11. `test/layers.rkt` 层序 / core 白名单 / 线程白名单仍然通过。

---

## 12. 待确认

- 同步 decor 在超大文件上的延迟是否需要更早做异步第二阶段；先测量再决定。
- 光标相关 decor 多视图：第一版只跟主视图主光标，是否需要 per-view decor 状态。
- 静态层的生命周期：`set-face-layer-effect` 目前是“替换该层”，是否需要显式
  `clear-face-layer-effect`（还是空 fills 就够）。
- 高亮的 `applies?` 是否只看 doc-meta（路径 / mode），还是允许 state（当前实现用
  `racket-doc?` 查 state）。第一版在 interpreter 过滤，够用。
