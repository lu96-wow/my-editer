# edit-rebuild —— 事件 / 作用域骨架（重头设计）

这次重构要解决的核心问题，是旧 `edit/` 的输入模型**只能表达「焦点决定唯一一张键表」**：

- 键表栈是硬编码的（所有 float 键 → 焦点面键 → 焦点文档键表 → 全局）；
- 查找是单命中（first wins）；
- 命令默认作用于焦点视图，跨窗口只能靠 hook 手工转发；
- handler 只能 `session | #f`，不能「替换事件 / 再派发」；
- 「谁接键」这种模态状态散落在可变 box（completion 的 `active`、docs 的 `phase`）。

于是「Tab 进文档」「一个键同时管两个窗」「按键含义随状态替换」都写不出来。

本目录从零搭一层**独立、纯、可测、与编辑器无关**的骨架：

```
    绑定键/输入          作用域              路由              效果            派发
  ┌───────────┐   ┌──────────────┐   ┌────────────┐   ┌────────────┐   ┌──────────┐
  │  key.rkt  │──▶│  scope.rkt   │──▶│ route.rkt  │──▶│ effect.rkt │──▶│dispatch.rkt│
  └───────────┘   └──────────────┘   └────────────┘   └────────────┘   └──────────┘
        ▲                 ▲                 ▲                 ▲                ▲
        │                 │                 │                 │                │
        全纯数据；只通过 host 协议看「状态」，不认识 session / editor / tui
```

## 1. 四层数据

### 1.1 作用域 `scope`（scope.rkt）

作用域是**数据**，不是闭包。判定输入是一个纯 `context`（由宿主从会话投影）：

```racket
(struct context (focus focus-kind visible modes prefix))
;; focus      当前焦点目标（vid / id）
;; focus-kind 'editor | 'dock | 'float | …
;; visible     (hash 目标 -> bool)
;; modes       (hash 名字 -> 值)     交互模式，纯值
;; prefix      活动前缀 id | #f
```

作用域构造子：`scope-always / scope-focus / scope-focus-kind / scope-visible /
scope-mode= / scope-prefix / scope-and / scope-or / scope-not`，判定 `scope-satisfied?`。

### 1.2 键路由 `route`（route.rkt）

`keymap` 升级为「带作用域的路由表」：

```racket
(struct route (key action scope priority policy prefix))
;; key      绑定键
;; action   命令（宿主解释）| 结构化效果 | 载荷型 spec（符号）
;; scope    何时生效
;; priority 大者先（取代“注册顺序”）
;; policy   'stop（接了就停）| 'continue（接了继续往下）
;; prefix   属于哪个前缀（#f = 顶层）
```

`resolve` 只做一件事：把「key 相等 + scope 命中 + prefix 一致」的路由按 priority 降序返回。
**是否停止、是否继续由 policy 在派发时决定**——这就是「一键管两窗 / 广播 / fallthrough」的落点。

### 1.3 效果 / 动作 `effect`（effect.rkt）

```racket
(addressed target cmd)      把 cmd 发往目标（不再默认焦点）
(focus-to target)           改焦点
(set-mode name val)         改模式（纯值）
(begin-prefix id) / (cancel-prefix)   前缀
(forward input)             替换事件，重新派发（“按键事件被替换”）
(broadcast targets cmd)     同一命令发往多个目标
(seq-effect (list e ...))   顺序组合
```

### 1.4 宿主协议 `host`（effect.rkt）

引擎不认识具体状态 / 命令。宿主提供：

```racket
(struct host (make-context   ; st -> context
              run-command    ; st target cmd -> (values st result)
              run-focus      ; st target      -> (values st result)
              run-mode       ; st name val    -> (values st result)
              run-prefix     ; st prefix|#f   -> (values st result)
              spec->action)) ; input spec     -> cmd/effect
;; result : 'pass | 'handled | action/effect
```

`result` 允许 handler **返回效果**（forward / broadcast / seq），这就是旧 `session|#f`
缺的表达力。

## 2. 派发 `dispatch`（dispatch.rkt）

```
input ──▶ context ──▶ resolve(routes, ctx, binding) ──▶ [(route …)] by priority
      ──▶ 依次执行：action ──▶ host.run-command ──▶ result
                          ├─ 'pass      → 继续下一条候选
                          ├─ 'handled   → policy='stop 停；policy='continue 继续
                          └─ effect     → 解释（forward/broadcast/…）
      ──▶ 无候选且 prefix 激活 → cancel-prefix
```

## 3. 这样能表达什么（旧模型写不出的）

```racket
;; Tab 进文档：文档可见时在“补全接键 / 文档接键”间循环
(route* (key 'tab) (set-mode 'interaction 'docs)
        #:when (scope-and (scope-visible 'docs) (scope-mode= 'interaction 'complete))
        #:priority 20)
(route* (key 'tab) (set-mode 'interaction 'complete)
        #:when (scope-and (scope-visible 'docs) (scope-mode= 'interaction 'docs))
        #:priority 20)

;; 一键管两窗：文档可见就一直滚文档（高优先、独立于焦点）
(route* (key 'left) (addressed 'docs (cmd-scroll -1)) #:when (scope-visible 'docs))
(route* (key 'right) (addressed 'docs (cmd-scroll  1)) #:when (scope-visible 'docs))

;; 广播：某些键同时作用于两个目标
(route* (key 'escape) (broadcast '(complete docs) (cmd-close)) #:policy 'continue)

;; 事件替换：把一次键重新解释成另一条输入
(route* (key 'd 'alt) (forward (input (key 'm 'alt) #f #f #f #f #f)))
```

## 4. 模块

| 文件 | 局部问题 |
|---|---|
| `core/key.rkt` | 绑定键 / 输入事件词汇（纯，不碰终端） |
| `core/scope.rkt` | context + 作用域数据 + 判定 |
| `core/route.rkt` | 路由 / 键表 / resolve（命中 + 排序，不执行） |
| `core/effect.rkt` | 效果数据 + 宿主协议 |
| `core/dispatch.rkt` | 事件 → 命中 → 执行（策略 / 前缀 / 效果解释） |

测试在 `test/`，全部用一个假宿主（state = 纯结构）驱动，不需要编辑器。

## 5. 迁移路径（后续）

1. 把 `edit/` 的 session 适配成一个 `host`：`make-context` 读焦点/显隐/模式，`run-command` 落回 `step-base`，`run-focus` 落回 `session-set-focus`。
2. 旧的 `keymap`/`kbd` 编译成 `route*`（scope 默认 `always`、priority 0），行为不变。
3. 把 completion 的 `active`、docs 的 `phase` 提成 `modes`（纯值）。
4. 把 `docs-scroll/-hscroll/-focus` 从 hook 改成 route。
5. hook 只留纯通知（`before-render` / `after-edit` / `document-closed`）。
