# edit4 · 03 命令核心（抽象模型稿）

> 核心 = 布局 + 命令。布局已定（`01`/`02`）。这里设计命令层：**把「输入」和「命令」彻底分开**。

---

## 0. 一句话

> 命令是**命名意图（数据）**，只依赖 `World + 参数`；输入（键/文本/鼠标）只做两件事：
> **匹配 binding** 和 **提供上下文数据**。适用性（scope）与模式（prefix）都是 `World` 的函数。

```
World   = 布局树 + 焦点 + prefix(模式)
Command = (name . args)                    ; 纯数据
Registry= name -> handler
handler : Ctx × World × args -> (values World [Effect]) | #f   ; #f = 让位
Binding = (key …) | (text …) | (cursor …)  ; 纯数据
Scope   = name -> (World -> Bool)          ; 可注册
Keymap  = 有序 entry：binding × scope × command…
Dispatch= 选第一个「binding 命中且 scope 成立且不decline」的 entry 并求值
```

---

## 1. 相对 edit3 的四处清理

| edit3 | 问题 | edit4 |
|---|---|---|
| op handler 拿 `ev` | 命令与输入耦合 | handler 只拿 `args`；事件数据从 `Ctx` 取 |
| CPS continuation 让位 | 路由复杂 | handler 返回 `#f` = 让位，dispatch 顺序试下一条 |
| scope 硬编码在 step | 加作用域要改核心 | scope 注册成数据 |
| prefix/placing 状态机写死在 executor | 特例 | prefix 是 `World` 普通字段；命令自己改 |

**收益**：命令纯（可单测）、路由声明式、作用域可扩展（插件可加）、执行器不认识特例。

---

## 2. 职责边界

- **命令层**：World 类型、命令数据/注册表、binding/keymap、scope、dispatch。
- **不认识**：文本引擎、文档内容、面板渲染、终端；这些是「其他」，先靠边。
- **布局层**：只认不透明 id；命令层负责「id ↔ 窗口/视图」的绑定（后续）。

---

## 3. 数据模型

```racket
;; event.rkt —— 输入
(struct key-event (key mods))
(struct text-event (text))
(struct cursor-event (kind button x y))
(struct resize-event (w h))

;; world.rkt —— 命令作用的唯一状态
(struct world (layout focus prefix))
;; layout : 布局树（不透明 id）；focus : id | #f；prefix : symbol | #f

;; command.rkt
(struct ctx (event size geometry))     ; 本次输入的派生上下文
(struct command (name args))
(struct command-registry (table))      ; name -> handler

;; keymap.rkt
;; binding 数据： (key k mod…) | (text) | (text "x") | (cursor kind [button])
;; entry = (binding scope command…)
(compose-keymaps tables)               ; 同 (binding scope) 覆盖

;; dispatch.rkt
(struct scope-registry (table))        ; name -> (World -> Bool)
(dispatch registry scopes keymap ctx world) -> (values World [Effect])
```

---

## 4. 求值规则

```
dispatch(world):
  顺序遍历 keymap：
    entry 命中 binding 且 scope 成立？
      → 顺序跑其命令：
          任何一个返回 #f（decline）→ 丢弃本次、继续下一条 entry
          全部成功 → 返回 (World', effects)
  没有命中：
    prefix 若在 → 清掉；返回原 World
  成功跑完且最后一条不是 prefix 命令 → 清 prefix
```

- **decline（`#f`）** 支撑「拦截但可让位」（菜单/插件）：不写 continuation。
- **prefix**：`prefix` 命令设置，其它命令跑完自动清；未命中事件也清。
- **scope**：`always` / `(prefix NAME)` 内置；其余查注册表。

---

## 5. 基础命令（先行）

| 命令 | 参数 | 作用 |
|---|---|---|
| `split` | axis side | 分裂焦点窗，新窗聚焦 |
| `close` | — | 底层布局 op：摘掉焦点叶子（不再默认绑键，见 `close-window`） |
| `focus` | dir / next / prev / id | 焦点导航（dir 用几何 `neighbor`） |
| `prefix` | name | 进入前缀模式 |
| `cancel` | — | 清 prefix |

示例键表：
```
C-s        → (prefix split)
(prefix split) → ←/→/↑/↓ = split
C-d        → (close-window)   ; content 层：关编辑器窗（最后一个只解绑=空占位；不动面板）
M-n/M-p    → focus next/prev
M-←/→/↑/↓  → focus dir
```

---

## 6. 与布局的接合点

- 命令层只调布局的**代数**：`split-leaf / remove-leaf / insert-side / set-sizes / neighbor`。
- `neighbor` 走 `Ctx.geometry`（由布局缓存提供），命令层不自己算空间。
- 拖拽（press/move/release）是**交互层**，后续单独设计：它把 `move-cut` 的结果作为命令应用。

---

## 7. 待定

- 拖拽如何进入命令模型（是命令序列，还是 `World.drag` 字段 + 命令）？
- 模式键表（按文档类型）挂在哪（World 增加 per-id 键表？）。
- 插件如何贡献命令/scope/keymap（注册表叠加，boot 装配）。
- Effect/Job 的具体形状（先留空表 `'()`）。
