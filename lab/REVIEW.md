# 新设计整体审视：端到端装配图与去重

> 对 `DESIGN.md` / `DESIGN-POLICY-EFFECT.md` / `DESIGN-LAYER.md` 三份设计做一次整体审视。
> 目标：一张从 `main` 到一帧画面的端到端管线图；逐条定位隐式契约；消除重复与歧义。

---

## 1. 端到端管线

```
main
 └─ driver/run(runtime)
     ├─ assemble: 加载包 → registry 贡献；建 session（editor / frame / focus / input / cs）
     └─ loop:
         ev = read()
         session' = pipeline/step(ctx, ev)
         ┌──────────────────────────────────────────────────────────────────┐
         │ 1. 特殊事件：resize → effect(Session-size)                          │
         │ 2. resolve(ctx, ev):                                              │
         │      did    = did-of(focus)                                       │
         │      base   = command-set-tables(cs, did)                         │
         │      tables = base ⊕ 层栈（capture 短路 + 字符回退）  ← I10 I11 I20 I24│
         │      → (spec, owner-layer)                                        │
         │ 3. action = (command spec)                          ← I19 upsert      │
         │ 4. perform(ctx, action):                                          │
         │      before-policies（priority 高→低，首个决定者）   ← I5 I6 I14       │
         │         pass / abort / effects / interact                          │
         │      invoke command → effects                                     │
         │      after-policies（全部，变换 effect 列表）        ← I14 I15        │
         │ 5. handle-effects:                                                │
         │      edit/type/backspace/delete → core；notify after-edit/insert ← I16│
         │      open/close → core + 内建 notify(document-opened/closed)     ← I16│
         │      show   → open + ensure-view + place + focus                  │
         │      focus  → focus 值                            ← I1 I4 I8         │
         │      input push/pop → 层栈；入栈自派生 focus/slot  ← I9 I10          │
         │      reload/slot → 视图内容（面板 / 状态行）                        │
         │      job    → runner + 内建版本闸门                ← I13             │
         │      resume → interaction 续做                    ← I5              │
         │      notify → 钩子（产 effects，递归过 after）      ← I16             │
         │      emit   → 逃逸到驱动（写盘 / place / 响铃）                     │
         │ 6. post: 声明式 pop（never/next/handled）            ← I10            │
         │ 7. post: on-blur（焦点离开声明焦点目标的层）          ← I9             │
         │ 8. post: job poll → job-result action              ← I13            │
         │ 9. post: notify post-command                       ← I16            │
         └──────────────────────────────────────────────────────────────────┘
         frame' = render(ctx):
         ┌──────────────────────────────────────────────────────────────────┐
         │ notify before-render                                 ← I22          │
         │ layout(frame, size) → rects + bars（纯派生，按 frame 值 memo）← I7    │
         │ decoration(scope frame) → 浮层 panes                 ← I12          │
         │ decoration(scope slot)  → 状态行内容                 ← I22          │
         │ core render(panes, focus) → screen                                │
         └──────────────────────────────────────────────────────────────────┘
         present(frame')
```

**隐式契约覆盖核对**：I1–I25 在图中都有唯一归属；无「无人认领」的契约。

---

## 2. 去重与定死（16 条）

| # | 重复 / 歧义 | 决议 |
|---|---|---|
| D1 | `frame.active` 与 `focus.target` | **frame 只存结构（root）；focus 存 target + history**。active（编辑叶）由 focus 派生 |
| D2 | `session.panels` 与 frame 里 role=panel 的叶 | panel 贡献只存**模型/状态**；视图与放置归 frame 叶。panel-vid 从 frame 派生 |
| D3 | slot 的三种表示（layer.slot / decoration(scope slot) / reload） | **layer.slot = 选哪个槽位视图（目标选择）**；decoration(scope slot) = 状态行**内容**；reload = 一次性内容写入。分工见 §3 |
| D4 | `prompt` 既是 layer-spec 又是 effect | **prompt 只是一个 layer-spec**，通过 `input push` 入栈；删除独立 prompt effect |
| D5 | `view-new` + `place` + `open` | 保留**复合 effect `show`**（open + ensure-view + place + focus）；`place` 只用于移动已有视图 |
| D6 | effect 无返回值，但 show 需要 did/vid | **复合 effect** 内部完成，不让调用方拿返回值；需要跨 effect 传递时写 `session.temp`（受控） |
| D7 | job.merge 与 decoration(scope document) | **删除 decoration scope=document**；属性写回是 effect `attr!`（O(1) 写 box，不进 history）；job 的 on-result 产 `attr!` |
| D8 | policy 与 hook/notify | hook = 生命周期**通知**（notify effect）；policy = 动作**门控/变换**。互不替代 |
| D9 | layer.focus 字段与 focus effect | layer.focus 是**声明**，入栈时 kernel **自动**产 focus effect；on-enter 不再写 focus |
| D10 | input push/pop 与 layer on-enter/on-exit | push 是操作；on-enter/on-exit 是层的反应（产 effects）。不重复 |
| D11 | `session.meta` 万能袋 | 改为**具名字段**：width/height/sidebar?/sidebar-width/last-focus/temp |
| D12 | `route` struct | 不需要；`routes` 用双向 hash（did↔path）即可 |
| D13 | `emit` 与 `save` | save = 编辑器状态相关（按 did 取内容）；emit = 状态无关副作用。保留两者 |
| D14 | `service` 与 job.runner | job.runner 存**服务名**（`'sync` / `(place name n)`），runtime 解析；不在 registry 里放句柄 |
| D15 | bars 归 frame 还是 decoration | bars 是 frame 的**几何派生**，归 frame layout；不进 decoration |
| D16 | focus 的多处来源（层派生 / 命令 effect / 恢复） | focus 只有**一个写入点**：kernel 施加 focus effect。层派生与恢复都是产 focus effect |

### 2.1 由去重得到的三条「单一来源」原则

1. **状态只有一个写入点**：session 的每个字段只由 kernel 的一处 effect-apply 写。
2. **派生不进 session**：layout / active-edit / slot-vid / panel-vid 都是纯派生，不缓存真身。
3. **选择是字段，内容是 effect**：目标选择（slot/focus/sidebar）是声明字段；具体内容用 effect。

---

## 3. 槽位（底部条）的最终模型

底部条只有**一个叶**，role = `'slot`：

```
叶的视图 = 若某层声明 slot='input' → input-view（持久、可编辑）
           否则                     → status-view（派生、只读）

status-view 的内容 = decoration(scope 'slot) 的最高优先级产出（每帧）
input-view  的内容 = prompt 层 on-enter 写入，之后由用户编辑
```

- **目标选择**：`layer.slot`（字段）；
- **内容**：状态行走 decoration；输入行走真实编辑；
- **无三套 API**：属性写回（D7）已移出，slot 只剩「视图选择 + 内容」。

---

## 4. 控制流三件套 + 输出/状态

| 组合子 | 唯一职责 | 写入 |
|---|---|---|
| **layer** | 事件归属 | 不写 session，产 Action |
| **policy** | 动作门控 / 效果变换 | 不写 session，产 / 改 effects |
| **job** | 异步 + 版本闸门 | 产 effects（on-result） |
| **effect** | 状态变换描述 | kernel 唯一写入 session |
| **decoration** | 每帧输出 | 只读 |

---

## 5. 「无返回值」的代价与边界（D6 补充）

effect 不返回值的唯一痛点：复合流程（打开→显示）需要中间 did/vid。
决议：

- 常见流程做成**复合 effect**（`show` 内部完成 open+view+place+focus）；
- 极少数高级组合用 `session.temp` 作**显式命名槽**（如 `open :as 'x` + `show (ref 'x)`），
  temp 在每次 step 结束清空；
- **绝不**用返回值破坏 effect 列表的顺序语义。

---

## 6. 结论

- 25 条隐式契约全部有唯一归属；
- 16 处重复/歧义全部定死；
- 三件套（layer/policy/job）职责正交，effect 是唯一写入通道，decoration 只读；
- 三条单一来源原则可作实现时的硬约束与测试项。

设计可进入实现。
