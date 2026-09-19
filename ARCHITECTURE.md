# ARCHITECTURE —— 编辑器的架构与契约

纯函数式、持久化、后端无关的编辑器核心。所有值是**不可变数据**，所有操作是
**`data -> lambda -> data`** 的纯函数；没有隐藏状态，没有副作用。

---

## 0. 目录结构

```
edit/
├── core/                     # 编辑器核心
│   ├── api.rkt               #   原子全量面：text/view 的显式白名单转发（零逻辑）
│   ├── editor.rkt            #   消费者标准入口 = api + editor 平台
│   ├── text/                 #   文本层（无光标、无视图）
│   │   ├── point.rkt         #     位置 (line,col)，唯一位置表示
│   │   ├── content.rkt       #     行存储 + edit-desc 代数
│   │   ├── properties.rkt    #     行内区间标注 + 约束槽
│   │   ├── marker.rkt        #     区间端点标记（随编辑移动）
│   │   ├── overlay.rkt       #     装饰（marker 对 + presentation）
│   │   ├── buffer.rkt        #     文档装配根：文本+属性+标记+装饰，无光标
│   │   ├── patch.rkt         #     插件 delta（按 key 清旧写新）
│   │   └── edit.rkt          #     批量施加 / 点映射 / 变更行区间
│   ├── view/                 #   视口层（后端无关）
│   │   ├── width.rkt         #     字符 ↔ 显示列
│   │   ├── render.rkt        #     行 → glyph
│   │   ├── screen.rkt        #     输出契约：run 序列
│   │   ├── window.rkt        #     视口：buffer 引用 + 光标 + 滚动 + 尺寸
│   │   ├── view.rkt          #     vrow 布局 / 光标映射 / ensure（clip|wrap）
│   │   ├── project.rkt       #     window -> screen
│   │   ├── rebase.rkt        #     编辑后重基准（free / follow）
│   │   └── events.rkt        #     类型化输入事件
│   ├── tool/
│   │   └── history.rkt       #   撤销/重放账本（纯数据）
│   └── compose/              #   组合层
│       ├── mechanism.rkt     #     机制：editor 数据 + 不变量 + 无策略写原语（内部）
│       ├── editor.rkt        #     中性接口：构造/查询/解析/标注读/投影（公开）
│       ├── reaction.rkt      #     显示语义：none / map / leader / follow（内部）
│       ├── program.rkt       #     程序面（公开）
│       ├── command.rkt       #     用户面（公开）
│       └── example.rkt       #     使用方示范（多 buffer / 侧边栏 / 高亮）
├── io/                       #   后端示范：racket-tui 接线（core 只产 screen、只收 events）
└── tools/reconcile.rkt       #   文档 ↔ 可达面对账
```

依赖方向：

```
text  ←  view  ←  compose(mechanism ← editor ← {reaction, program, command})
api   ←  text, view                      # api 只转发原子，不依赖 compose
editor(入口)  ←  api, compose(editor, program, command)
```

`api` **不反向依赖** `compose`；`compose` 各模块直接 `require` 它们需要的原子模块。

---

## 1. 两个平面的划分

一切操作先问一句：**它改的是内容，还是视图？**

| 平面 | 谁调用 | 改什么 | 入口 |
|---|---|---|---|
| 内容面 | 程序 | 只改 buffer（文本 / 标注） | `editor-edit-at` |
| 视图面 | 程序 | 只改指定的一个 view | `editor-set-point` |
| 用户面 | 输入 | 焦点 view 的光标 + 视口 + 账本 | `editor-edit` |
| 中性面 | 任何人 | 读、解析、投影、构造 | `editor-buffer->string` |

- **程序默认不动视图**：`editor-edit-at` 的 `#:reaction` 默认 `none`——只换 buffer
  值，任何 view 的光标/滚动字面不动（只做合法性夹紧）。
- **用户操作才动视图**：`editor-edit` / 导航走 `leader` 语义。
- 中性面没有显示决策，放在 `compose/editor.rkt`。

---

## 2. 数据 → lambda → data

- **数据**：`editor` = `{ buffers, views, focus, next-* }`，全部 `#:transparent`、不可变。
  - `buffer-entry` = `{ id, name, buffer, history }`：一个打开的缓冲。
  - `view` = `{ id, buffer-id, window, sync }`：一个窗口，`window` 指向 buffer。
  - 不变量：任一 view 的 `window` 里的 buffer 必 **`eq?`** 于其 `buffer-id` 对应 entry 的 buffer。
- **lambda**：编辑动作是值（`buffer point -> edit-desc`），由 `edit-insert-char`、
  `edit-insert`、`edit-newline`、`edit-backspace`、`edit-delete`、`edit-splice` 构造。
- **apply**：唯一算子把 desc 施加到 buffer（`buffer-apply-edit`），内容变更唯一漏斗
  是 `editor-edit-at`。

内容变更漏斗（机制层）：

```
editor-apply-desc ed bid desc
  = buffer-apply-edit  →  editor-swap-buffer
```

`editor-swap-buffer` 只换 entries 与同 buffer view 的 `window.buffer`，**不映射光标**。

---

## 3. 显示语义（内容变更后视图怎么反应）

`compose/reaction.rkt` 是唯一的显示语义层，全部是 `editor -> editor`：

| 策略 | 行为 | 谁用 |
|---|---|---|
| `none` | 字面不动，只把光标/视口夹回合法域 | 程序默认 |
| `map` | 每个同 buffer view 各自把光标映射过这次编辑（不滚屏） | `editor-edit-at #:reaction 'map` |
| `leader` | 指定 view 推进到插入后 + ensure；其余 free 映射 / follow 镜像 | 用户编辑 |
| `follow` | 复制 leader 的最终视口，再按自己几何 ensure | `sync = follow` 的 view |

契约：

- 同步**只在同一 buffer 的 view 之间**发生；跨 buffer 无耦合。
- `leader` 必须**先 ensure 定稿**，`follow` 再复制（否则差一行）。
- 用户导航走 `editor-leader-window`：被更新的 view 成为 leader，同 buffer 的
  `follow` 镜像它。

---

## 4. 位置契约

**`point` 是唯一的位置表示**（`line`, `col`，0-based，`col` 是**字符索引**）。

- 任何「要位置」的函数收 `point`，不收散着的两个数字。
- 位置解析只取决于 buffer，与 view/光标无关：
  - `editor-buffer-clamp-point`：把任意输入夹到合法域。
  - `editor-buffer-point->offset` / `editor-buffer-offset->point`：行列 ↔ 绝对偏移。
  - `editor-buffer-line-length`：行长度。
- **三套列不许混**：`point` 的 `col` 是字符索引；`window` 的 `left-col`/`vrow` 是
  显示列；偏移是 `content->string` 坐标。换算只经 `index->column` / `column->index`。

---

## 5. `modified?` 约定（不是机制）

`buffer-modified?` 是「有没有未保存改动」的长期事实：

- **文本编辑置位**。
- **写标注 / patch 不置位**（`buffer-put-property`、`buffer-apply-patches` …）。
- `buffer-tick` 则回答「有没有变」，编辑/标注/patch **都涨**。

---

## 6. 撤销 / 重放

- 一步必须自含正反两向：`step` = `(replay-descs undo-descs pre-point)`，账本 = `(undo redo)`。
- 逆必须由**编辑前**的 `buffer` 导出（`buffer-edit-desc-inverse`）；用编辑后的 buffer
  求逆会静默写坏历史。
- 合并规则是**结构判定**（打字连续段 / 退格段 / 前向删除段），无时钟无状态。
- 撤销/重放走 **trusted**：当年过了守卫（被拒的 `desc` 不入栈），不该被事后约束挡住。

---

## 7. 守卫抑制：显式 trusted 入口

`read-only` 守卫默认开；绕行**只**有显式入口 `buffer-apply-edit-trusted` 与
`editor-edit-at #:trusted?`。没有全局开关、没有 `inhibit` 参数。

---

## 8. 增量信息归操作，不归文档

「这次改了哪几行」随操作返回（`edit-desc` / `change-report`），不存进 `buffer`：
`edits-span` 给出应用顺序的一组 desc 影响的行区间并集；`change-report` 是命令的第二个返回值。

---

## 9. API 可达面：显式白名单

- 消费者白名单 = **`core/editor.rkt`**（原子 + editor 平台）。
- 内部机制可达但不进白名单：`compose/mechanism.rkt`、`compose/reaction.rkt`、
  `text/*`、`view/*`、`tool/*`。
- `tools/reconcile.rkt` 对账 `ARCHITECTURE.md` / `MANUAL.md` 的表格名字与白名单，
  有「项目里不存在的名字」即漂移（`raco test .` 会失败）。

---

## 10. 违约行为

违约分两类，判据是「最近合法解释」是否存在：

- **有唯一合法解释 → 夹紧/归一**（越界位置夹到合法域；见 `point-clamp`）。
- **没有合法解释 → 报错**（反向编辑区间、跨行标注区间、未知 `sync`、过期 patch 行范围）。

例如：`buffer-apply-edit` 的端点先夹紧；夹紧后仍 `start > end` ⇒ 报错。
