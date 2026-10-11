# 迁移进度（edit → edit-rebuild）

做法：**分层替换**，每层都可测、可回退。`edit-rebuild/` 现已是完整应用 + 新骨架。

## 已完成的阶段

### Stage 0 —— 骨架 + 审计（done）
- `core/{key,scope,route,effect,dispatch}.rkt`：独立事件/作用域骨架（67 测试）。
- `AUDIT.md`：逐条把旧行为映射到新模型，结论 **100% 可表达，无必须保留的旧机制**。
- 扩展：`context.focus-id`（面身份）、`event`+`emit`（生命周期事件）、`execute`（命令路由）。

### Stage 1 —— 键路由迁移（done）
- 把整个 `edit/` 复制成 `edit-rebuild/` 基线（3321 测试全绿）。
- `core/command/engine.rkt`（迁移桥）：
  - 旧 `keymap`（binding→spec，含前缀）→ 新 `route`（scope/priority/prefix）；
  - 旧 binding/spec/input ↔ 新型别互转；
  - `host`：`run-command` 暂回旧 `step`，`run-focus`→`session-set-focus`，`run-prefix`→会话前缀；
  - 优先级复刻旧 context 栈：float 1000-i → 焦点面 500 → 焦点文档 400 → session.keys 100-i。
- `core/test/engine-test.rkt`：断言**旧 dispatch ≡ 新引擎**（文本/导航/前缀/面板/未知键），8 项。
- 后端 `core/backend/tui.rkt` 改用 `engine-dispatch` —— **实际运行的键路由已在新引擎上**。

结果：`raco test core/test plugins/test test` → **3329 通过**。

## 待做阶段（逐层替换，逐步删旧）

### Stage 2 —— handler → command 路由（done）
- 新增 `command-pred`（参数化命令触发谓词）+ `handler-effect`（动作收到触发命令）；`trigger` 贯穿派发。
- `execute`：命令先查 command 路由，全部 `'pass` / 无命中才落宿主原语（`step-base`）。
- **全部插件 handler 已迁成 command 路由**：document / tree / buffers / lifecycle / prompt / docs / completion / auto-pair / log。
- `step` 变为**晚绑定**到引擎（`command-runner` 参数，`engine.rkt` 加载时设置），插件内部 `(step s cmd)` 自动走新引擎，又避免模块循环依赖。
- **删除了 `handlers` 机制**：`session` 去掉 `handlers` 字段 + `session-add-handler`；`step` 不再跑 opaque handler 链。

### Stage 3 —— hook → 显式作用域 + 优先级（done）
- `hook` → `reaction`（事件 tag + **scope** + **priority** + proc）；`session-run-hooks` 按 scope 过滤、priority 排序。
- `input-state` 加纯值 `modes`；`session-mode` / `session-set-mode`；`hook.rkt` 提供 `session-context`（引擎/事件共用）。
- 已显式化：
  - `docs-cancel-hook` 限定 `(scope-focus-kind 'editor)`（不再“焦点一变就关文档”）；
  - docs poll `priority 40`、docs tick `30`、completion resync `20`、completion poll `10`（取代脆弱注册顺序）；
  - **`docs-scroll` / `docs-hscroll` / `docs-focus` 三个 hook 已删除**，改成 docs 的声明式路由（见 Stage 4）。

### Stage 4 —— 模式 + Tab 进文档（done）
- `modes 'interaction` = `'complete | 'docs` 取代 completion 的 `active` box；复用正文亮/暗也从模式派生。
- 文档交互路由（`plugins/docs/main.rkt`）：
  - `Tab`（文档可见）→ 切换 interaction（priority 1300）；
  - `up/down`（interaction='docs）→ 滚文档（1200）；
  - `left/right`（文档可见）→ 滚文档（1100）。
- 补全交互路由（`plugins/completion/main.rkt`）：`up/down`（interaction='complete）→ 移候选（1200）；左右在补全接键时“吞掉”（1050）。
- `complete-keys` 只留 Enter/Esc；其余上下左右/Tab 全走路由。
- 测试：`core/test/engine-docs-test.rkt`（M-d 开窗 → 模式 'docs → Tab 切换 → 上下/左右滚文档）。

### Stage 2 —— 其余 handler → command 路由（剩余）
- document / tree / buffers / lifecycle / prompt / auto-pair / completion / docs 的 handler。

### Stage 5 —— 删除旧机制（基本完成）
- ✅ `session` 去掉 `handlers` 字段 + `session-add-handler`（命令已全在路由）。
- ✅ `step` 不再跑 handler 链（晚绑定到引擎）。
- ✅ **删除旧解析层**：`core/command/dispatch.rkt`（旧 `resolve`/`dispatch`）与 `core/session/context.rkt`（`session-context-keys`）已删。
- ✅ `input` 结构移到 `core/command/input.rkt`；后端 / 引擎 / 测试均改用它。
- ✅ 所有测试切到新引擎（`command-test` / `tui-input-test` / `engine-test` / `feature-test` / `interaction-test` 重写）。
- **仅剩**：旧 `keymap`（`core/keymap.rkt` + `tables.rkt`/`keys.rkt` + 插件 `*-keys`）仍是数据，由桥 `engine.rkt` 编译成 route。
  下一步可把它们直接写成 `route*`（插件用 `session-add-route`），然后删掉桥的型别互转（`old-binding->new` / `old-spec->action` / `compile-km`）。这是纯机械重写，不影响已完成的语义。
- 删 `core/session/context.rkt`、旧 `core/command/dispatch.rkt` 的 resolve、
  `core/session/hook.rkt`（或降级为事件队列）；
- `engine.rkt` 收敛成正式的 `core/input.rkt`（不再做型别互转）。

## 设计约定（迁移期遵守）

1. 同名同 scope 的键冲突由 `priority` 决定（旧是注册顺序）。
2. command 路由的动作若是同一条命令会自递归 —— 动作用效果或原语。
3. 异步传输 / 文本编辑 / I/O / 布局 / 渲染**不进引擎**，留在宿主（见 AUDIT §6）。
