# edit4 · 06 结构：分层 / 命名 / 文件地图

> 本文记录这次重构后的目录、命名与依赖方向。目标是把「不够干净」的东西消掉：
> 消除 hash 杂物袋、拆开同名概念、把装配期只读的东西从可变状态里拿出来。
> 与 `05-roadmap.md` 的 L0–L7 分层一一对应。

---

## 1. 分层（依赖只向下）

```
L7 运行时   runtime / backend/tui / main       事件循环、终端后端
L6 装配     env / plugin / app / boot           Environment（只读）+ 内置插件 fold + 初始 World
L4 投影     view/*  decor/*  config/*           State → 显示（纯投影 / 编码器 / 高亮算法）
L3 内容     content/*                           适配器 + 文档/视图/树 + 命令
L2 命令     core/{world,command,keymap,scope,dispatch,window,pointer,base}
L1 布局     layout/*
L0 值       layout/{rect,size} · core/{event,effect,drag}
```

硬规则：

1. **上只能依赖下**。`content` 不 require `view`；`core` 不 require `content`/`view`。
2. **World vs Environment**：可变状态进 `World`；注册表/键表/装饰插件进 `Environment`。
3. **project 纯 / commit 集中**：`view/*project*` 只读 World，写引擎只在 `commit-*`。
4. **core 不 require 插件**：插件贡献数据，`app.rkt` 只做 fold。

---

## 2. 命名规则

- **一个文件一个概念**，名词、单数；实现与装配分开。
- 同名概念按角色加限定，避免跨目录撞名：
  - `content/tree.rkt`（树模型 + IO） vs `view/tree.rkt`（树面板投影）
  - `config/palette.rkt`（调色板数据） vs `view/theme.rkt`（face→ANSI 编码器）
  - `view/face.rkt`（face 值） vs `view/decor.rkt`（装饰插件协议 + 投影）
  - `decor/`（高亮算法：lex/words/syntax/kind）
- 「命令/键表/作用域」是三种数据，各自成文件；装配文件只 fold，不写实现。
- 单数 `command.rkt` = 命令的数据与注册表；复数不再是「实现 + 键表 + 作用域」的杂物袋。

---

## 3. 文件地图

```
edit4/
  main.rkt                 入口（CLI）
  runtime.rkt              事件循环（唯一可变处）
  env.rkt                  Environment：装配期只读注册表集合
  plugin.rkt               插件契约（数据包）+ install fold
  app.rkt                  内置插件 fold → Environment
  boot.rkt                 初始 World（底盘）

  backend/tui.rkt          racket-tui 后端（事件翻译 / ANSI 绘制）

  layout/                  L0/L1
    rect.rkt               矩形
    size.rkt               尺寸意图 + solve-axis（唯一难数学）
    tree.rkt               结构 + min + 手术
    geometry.rkt           树 × 区域 → rects + cuts
    hit.rkt                命中 + move-cut
    float.rkt              浮窗覆盖层
    frame.rkt              平铺 + 浮窗的完整几何 + 统一命中
    settle.rkt             解算写回（规范化）
    validate.rkt           不变量自检
    cache.rkt              几何缓存（按输入身份失效）
  layout.rkt               布局层入口（再导出）

  core/                    L0 值 + L2 命令
    event.rkt              输入事件（含 job-event）
    effect.rkt             一次性 IO（数据）
    drag.rkt               手势状态
    world.rkt              World（布局/内容/信号队列/job 账本/插件 store）
    store.rkt              插件局部状态（命名空间隔离）
    hook.rkt               生命周期钩子 reaction / run-hooks
    job.rkt                异步工作 job / service / 账本
    mode.rkt               路径 → 文档键表的匹配层
    command.rkt            命令数据 + 注册表 + run
    keymap.rkt             绑定 / 键表
    scope.rkt              作用域注册表
    dispatch.rkt           输入求值（先试文档键表再落全局）
    window.rkt             窗口 / 焦点 / 前缀 / 退出命令
    pointer.rkt            指针 / 拖拽命令
    base.rkt               基础命令集装配 + 基础键表 / 作用域
  core.rkt                 命令层入口（再导出）

  content/                 L3
    fs.rkt                 文件系统原语（+ make-file / make-dir / delete）
    adapter.rkt            文本引擎边界（唯一 require core/editor 的模块）
    model.rkt              文档 / 视图 / 面板 / 文件树 + 路径复用与显示
    tree.rkt               文件树模型 + 纯操作 + IO
    tree-cmds.rkt          文件树交互命令（enter/parent/child/new/delete/reload/hidden）
    buffers.rkt            文档管理面板行模型（buffer-rows）
    buffers-cmds.rkt       文档管理面板命令（enter/fold/new-view/close-view/close-doc）
    region.rkt             面板槽（显隐 / 切换 / 聚焦）
    float.rkt              浮窗（开/关/切/提，窗口 + 视图，anchor 几何）
    focus.rkt              聚焦主编辑器窗（具名导航走 region / show-doc!）
    pointer.rkt            指针命令的内容扩展（点击 → 文档光标）
    lifecycle.rkt          文档资源生命周期动词（dirty/save/close/focus）
    prompt.rkt             输入行（*input*）+ kind 注册表 + quit/close-doc 流程
    scopes.rkt             editor / (panel NAME) 作用域
    edit.rkt               编辑 / 导航命令
    files.rkt              文件命令（open/save/reload，走 effect）
    commands.rkt           内容插件的数据装配（命令 + 键表）

  view/                    L4（渲染）
    render.rkt             frame → core rectangle
    border.rkt             缝 / 浮窗框字形
    panel.rkt              面板：World -> 投影 的纯函数 + project/commit
    status.rkt             状态栏面板（含命令序列）
    tree.rkt               文件树面板
    buffers.rkt            文档管理面板
    log.rkt                日志面板
    face.rkt               face 值 + 分层
    decor.rkt              装饰插件协议 + 投影/写回 + 缓存
    theme.rkt              face → ANSI 字节（编码器）

  decor/                   L4（高亮算法）
    lex.rkt  words.rkt  syntax.rkt  bracket.rkt  kind.rkt

  config/                  纯数据
    palette.rkt            命名 face + 调色板
    syntax.rkt             关键字分组
    floats.rkt             浮窗声明（anchor + 尺寸）
    plugins.rkt            本次启用哪些插件（只给名字）

  plugins/                 L5（插件包：数据）
    catalog.rkt            名字 → 实现 + 列表顺序 = 层叠顺序
    syntax.rkt words.rkt brackets.rkt     高亮（decor）
    auto-pair.rkt          括号自动配对（命令 + 键表）
    demo.rkt               契约演示（op/键表/hook/匹配层/boot/on-open）
    async-demo.rkt         异步演示（service + job 钩子）

edit4-test/  layout command content render runtime panels faces plugins edit3-parity
```

---

## 4. 这次消掉的「不干净」

| 之前 | 现在 | 为什么 |
|---|---|---|
| `World.features` hash（tree 塞里面） | 去掉；树状态进 `content.tree` | 值里不该有杂物袋；core 不需要认识树 |
| `core/command.rkt` vs `core/commands.rkt` | `command.rkt`（数据）+ `base/window/pointer.rkt`（实现 + 装配） | 单数/复数含义明确，一文件一概念 |
| scope 写死在 `dispatch.rkt` | `core/scope.rkt` | 作用域是数据，可注册 |
| 命令实现 + 键表 + 作用域挤在 `commands.rkt` | window / pointer / base 分开 | 实现与装配分离 |
| `content/content.rkt`、`content/engine.rkt` | `content/model.rkt`、`content/adapter.rkt` | 消除 content/content；点明「边界」 |
| `content/commands.rkt` 编辑 + 文件 + 键表 | `edit.rkt` + `files.rkt` + `commands.rkt` | 一文件一概念，装配独立 |
| `view/panels.rkt` 协议 + IO + 树模型 + 面板 | `view/panel.rkt` + `view/{status,tree}.rkt` + `content/tree.rkt` | 投影不写 IO；模型不在 view |
| `face/` 与 `view/face*.rkt` 撞名 | `decor/` + `view/face.rkt` + `view/decor.rkt` | 同一概念跨目录撞名 |
| `config/theme.rkt` 与 `view/theme.rkt` 撞名 | `config/palette.rkt` + `view/theme.rkt` | 数据 vs 编码器 |
| 注册表作为多个参数传进 runtime | `Environment` 一个值 | 装配期只读的东西有归属 |
| `app.rkt` 硬编码 `merge` | `plugin` 数据包 + `install` fold | 加功能 = 加一个 plugin 值 |

> 组合原则（功能是 lambda，用 map/fold 组合，但**不得增加层次**）见 `07-composition.md`。

---

## 5. 以后加东西的判据

- 新功能先问：**它是数据、纯函数、投影、命令，还是边界？** 分别落到对应层。
- 想往 `World` 加字段前：它可变吗？可变才进 World；只读进 Environment。
- 想往 `World` 加 hash 前：先给它一个类型（像 `content` 那样不透明也行）。
- 想写引擎前：投影必须是纯函数，写操作集中在 `commit-*`。
