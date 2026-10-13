# edit4 · 05 路线图：edit3 剩余逻辑 + 更干净的切分

> 目标：把 edit3 的全部功能盘出来，逐项判断「edit4 是否已有 / 能否拆得更干净」，
> 用**局部化**（每块一个类型 + 一组纯函数 + 一个投影 + 一组命令）倒推实现顺序。

---

## 1. edit3 全量功能清单

| # | 功能 | edit3 落点 | edit4 |
|---|---|---|---|
| D | 窗口：分裂/关闭/焦点/拖缝/浮窗 | layout/resize/interaction/window | ✅ 已做（更干净） |
| O | 命令：键表/前缀/作用域/路由 | keymap/command/op/route/mode/step | ✅ 已做（更干净） |
| A | 文本编辑：插入/删除/撤销/复制/导航/选区 | core 引擎 + session/adapter | ⬜ |
| B | 文档：打开/保存/脏标记/关闭询问 | session/fs/doc-meta | ⬜ |
| C | 视图：同文档多视图、视图游标 | core 引擎 + session | ⬜ |
| E | 面板：树/缓冲区/状态/输入行/日志 | panels + session | ⬜ |
| F | 区域：侧栏成员互斥、日志贴主区 | region + session | ⬜ |
| G | 输入行：kind 语义、提交/取消 | prompt + session | ⬜ |
| H | 文件树：展开/导航/新建/删除/刷新 | panels(tree) + fs | ⬜ |
| I | 装饰：语法/当前词/括号配对+深度底色 | face/face-plugin/kind/lex/bracket* | ⬜ |
| J | 主题：调色板 + face 分层 + ANSI 编码 | config/theme + core/theme | ⬜ |
| K | 插件：syntax/words/brackets/completion/docs/auto-pair | plugins/* | ⬜ |
| L | 异步：jobs/services/worker 池 | job + runtime | ⬜ |
| M | 钩子：生命周期反应 | hook | ⬜ |
| N | 装配：插件契约/目录/白名单门面 | plugin/extension/catalog | ⬜ |
| P | 效果：open/save/quit/log | effect + runtime | ⬜ |
| Q | 运行时：事件循环/后端协议 | runtime + backend/tui | ⬜ |
| R | 渲染：geometry→pieces、边框、ANSI | render/border/adapter/theme | ⬜ |
| S | 脚本匹配：路径 → 文档键表 | mode | ⬜ |

---

## 2. 目标切面（依赖向下，越上越"业务"）

```
L7 运行时    事件循环 / 后端 / worker        （唯一可变处）
L6 边界      effects / jobs / hooks           （数据 + 边缘解释）
L5 装配      plugin 契约 + 注册表 + boot       （只 fold 数据）
L4 投影      panels / regions / faces / theme （纯 State→显示）
L3 内容      documents / views / adapter       （文本引擎边界）
L2 命令      world / command / keymap / dispatch  ✅
L1 布局      layout core                        ✅
L0 值        纯工具                              ✅
```

**四条硬边界（局部化的关键）：**

1. **World（值） vs Environment（装配期只读）**：注册表/路由/钩子/服务放 Environment，
   不进 World；插件状态按 `(plugin, key)` 命名空间。
2. **project（纯） vs commit（写引擎）**：所有"把 State 变成屏幕/文本"是纯函数；
   写引擎集中在 commit。
3. **内容引擎在 World 之外**：World 只存 handle + version；文本真身外部。
4. **core 不 require 插件**：插件贡献**数据**，装配 fold 进 Environment。

---

## 3. 每个待做子系统的"局部切法"

### 3.1 内容（A/B/C）—— `content/`
- **Adapters**：`edit4/content/engine.rkt`（薄封装根 `core/` 引擎：insert/nav/face/render）。
- **Documents**：`did → {path?, saved-handle, version}`；`views : vid → {did, point, scroll, faces}`。
- **命令**：`insert/delete/undo/nav/select` 等，作用于焦点 vid。
- **干净点**：脏 = `saved-handle ≠ current-handle`（身份），不再散落在 session。
- **接口**：`content-*` 纯函数读 World；写引擎只在 commit。

### 3.2 面板 / 区域 / 输入行（E/F/G/H）
- **面板 = 纯投影**：`panel-spec(name, prep?, render)`；`render : World × vid → (text, faces)`。
  一切皆 document（面板就是文档，游标就是选择）。
- **区域**：`region(id, side, size, members, anchor)`；成员互斥靠命令改 layout。
- **输入行**：`prompt = {wid, label, kind, data}`；kind→handler 注册表（纯）。
- **文件树**：一个面板 + `fs` 纯原语；树状态 `{root, expanded, cache}` 是 World 的一小块。
- **干净点**：**project 不写引擎**；内容变了才由 commit 写。edit3 的"投影里 assign!"是这个

### 3.3 装饰与主题（I/J）
- **faces**：`face-plugin(name, applies?, scan)`；`scan : path × text × cursor → 每行 face 向量`。
- **主题**：`theme` 是**纯编码器**（face → style → ANSI 字节）+ 调色板数据；不认识 State。
- **干净点**：主题从 core 移出，只被"渲染"调用；faces 只是值。
- **性能**：face 按 `(did, line-version)` 做**按行增量**，不是整篇重扫。

### 3.4 边界（L/M/P）—— `runtime/`
- **effects**：数据（open/save/quit/log），边缘解释。
- **jobs**：`job-submit` 登记；`jobs` 从 World 纯取；worker 跑 service；结果回注事件。
- **hooks**：`(point, when, priority, proc)`；emit 从 Environment 取。
- **干净点**：这些都不进 World 语义，只在边缘。

### 3.5 模式 + 插件装配（K/N/S）
- **mode**：路径 matcher → 文档键表；只影响 dispatch 读哪张表。
- **plugin**：纯数据包（ops/scopes/key-tables/panels/regions/faces/hooks/services/boot）。
- **装配**：`fold` 到基础注册表 → Environment；`boot` 只解释。
- **干净点**：插件经 `extension` 白名单用核心；core 不反向依赖（edit3 已做到）。

### 3.6 渲染（R）—— `view/`
- **frame → pieces**：cuts（`┼┬┴`）、浮窗框、面板文本、face 区间。
- **干净点**：渲染只吃 `frame + World`，不改 World；与命中共用 `frame`。

---

## 4. 倒推路径（依赖顺序）

倒推：要"能编辑文本并看到"，最小闭环 =
**内容（World 有文档/视图）+ 渲染（frame→屏幕）+ 运行时（事件循环）**。

```
① 内容骨架   adapter + documents + views（World 扩展）
② 渲染骨架   frame→pieces + border/cuts + ANSI（theme 最小）
③ 运行时     backend + 事件循环（键盘/鼠标 → dispatch → commit/render）
④ effects    open/save/quit
⑤ 面板/区域   status + file tree + buffers（纯投影）
⑥ 输入行     prompt kinds
⑦ 装饰/主题    faces + theme + 增量
⑧ 边界       jobs/hooks/services
⑨ 插件装配   contract + registry + boot + 内置插件
⑩ 高级插件   completion/docs/auto-pair
```

**每一步都可独立测试**；依赖只向下。

---

## 5. 局部化清单：每个子系统必须自洽

| 子系统 | 数据 | 纯函数 | 投影 | 命令 | 边界 |
|---|---|---|---|---|---|
| 布局 | tree/floats | solve/geometry/hit | — | split/close/resize/drag | — |
| 命令 | world | dispatch/run | — | — | — |
| 内容 | docs/views | edit/nav | — | insert/save/open | effects |
| 面板 | panel-registry | panel-render | text+faces | region-toggle | — |
| 装饰 | face-plugins | scan | face 区间 | — | hooks/jobs |
| 主题 | palette | encode | bytes | — | — |
| 运行时 | cache/threads | — | — | — | effects/jobs |

> 判据：任一子系统的模块**只依赖它下面的层**；跨子系统只经 World 的对应切片 + Environment。

---

## 6. 相对 edit3 的"更干净"要点（复述）

1. `session.rkt`（990 行）→ 拆成 documents/windows/panels/regions/prompts/files。
2. 单一 `features` hash → World 的**类型化切片** + 插件命名空间。
3. 投影里写引擎 → **project/commit 分离**。
4. theme 在 core → 移到 view 层。
5. mode/doc-key 混在 session → 独立 mode 层。
6. 注册表/钩子/服务进 State → 移到 **Environment**。

---

## 7. 建议下一步

先做 **① 内容骨架**（documents/views + adapter + 最小渲染 + 运行时），得到一个
"能打字、能看到、能开关" 的最小闭环；它把②③也带出来，之后所有子系统都往上挂。
