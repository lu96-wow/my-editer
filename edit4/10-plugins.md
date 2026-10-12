# edit4 · 10 插件：对齐 edit2 的接入点 / edit3 的契约

> 把 edit2 的「接入点」与 edit3 的「plugin 数据包」对齐到 edit4：
> 插件 = 一个纯数据包，向若干**能力槽**贡献；`install` 是唯一装配动作（fold 进 Environment）。
> 运行时只从 Environment 取，commands 不反向依赖 env；World 只装可变状态（含插件账本）。

---

## 1. 从 edit2 / edit3 继承什么

edit2 **没有插件层**，它给的是 5 个接入点注册表（op / prompt-kind / panel / key-table /
doc-key-matcher）+ `route`/`step`。edit3 把这些收成一个正式的 `plugin` 数据包：

```
plugin(name ops prompt-kinds panels regions key-tables doc-key-matchers
       faces hooks services boot on-open)
install-* → 基础注册表 / State.features
catalog(名字→实现) + config(只给名字) + extension(白名单门面)
```

edit4 保留同样的**能力槽**，逐项换成 edit4 的落点（见 §3）。

---

## 2. 装配 vs 运行时（edit4 的归属）

| 东西 | 归属 | 说明 |
|---|---|---|
| commands / scopes / keymap / prompt-kinds | Environment | 只读注册表 |
| panels / regions / decor | Environment | 函数/值列表 |
| hooks / services / doc-key-matchers | Environment | 只读配置 |
| boots / on-opens | Environment | 装配时 / 打开文档时跑 |
| 多键前缀、命令序列 | World | 可变（已有） |
| **hook 信号队列 signals** | World | 命令 `emit!` 追加；runtime drain |
| **job 账本 jobs** | World | `job-submit`；runtime 派发/回填 |

> 关键取舍：命令签名不变（`ctx world args -> (values world effects)`）。
> 需要发钩子的命令只 `(emit! w point args)`（core，不需要 env）；runtime 拿 Environment 跑钩子。
> 需要 prompt-kind 的命令由 app 用合并后的注册表**重注册**一个 handler（闭包捕获，见 §5.4）。

---

## 3. 能力槽 → edit4 落点

| plugin 槽 | edit4 落点 | 消费方 |
|---|---|---|
| `commands` | `command-registry` | `run-commands` |
| `scopes` | `scope-registry` | `dispatch` |
| `keymap` | `(listof entry)`，后装覆盖同 slot | `dispatch` |
| `panels` | `(listof (World -> projection))` | `runtime` project/commit |
| `regions` | `(listof region)` | `content/region` |
| `decor` | `(listof (path text cursor -> faces))` | `view/decor` |
| `prompt-kinds` | `prompt-kind-registry` | `make-prompt-submit` |
| `hooks` | `(listof reaction)` | `runtime` run-hooks |
| `services` | `service-registry` | runtime worker 池 |
| `doc-key-matchers` | `(listof (matcher . keytable))` | 打开文档时挂 did |
| `boot` | `(World -> World)` | 装配末尾各跑一次 |
| `on-open` | `(World did path -> World)` | 打开文档时 |

`decor` 保持 edit4 的**裸函数**（07：不加 name/applies? 层）；`syntax/words/brackets`
只是 decor 算法，由插件包声明。

---

## 4. hooks（对齐 edit3 reaction/emit）

```
reaction(point when priority proc)      ; proc : World args -> World
emit!  : World point args -> World      ; 追加到 World.signals（core）
run-hooks : (listof reaction) World -> World   ; drain：按 priority 降序跑，直到无新信号
```

事件点与 args（edit4 已落）：

| point | args | 触发处 |
|---|---|---|
| `after-edit` | `(vid)` | 删除/撤销等编辑命令 |
| `after-insert` | `(vid text)` | 插入 |
| `after-nav` | `(vid)` | 光标移动 |
| `focus-changed` | `(new old)` | runtime dispatch 后焦点变了 |
| `before-render` | `(size)` | runtime 每帧 |
| `document-opened` | `(did path)` | runtime open-file |
| `document-closed` | `(did)` | close-doc |
| `log-appended` | `(msg)` | 写日志 |
| `job` | `(id kind result tag)` | job 结果回注 |

插件可自定义点（如将来的 `complete-selection`）。

---

## 5. jobs / services（对齐 edit3 worker 池）

```
job(id kind payload tag)                ; World.jobs 账本：seq/open/done
service(name handler)                   ; handler : payload -> result（纯，worker 线程）
job-submit : World kind payload tag -> (values World job)
jobs       : World -> (listof job)
job-finish : World id result -> World
```

runtime：每帧取 `jobs`（按已派发集去重）→ 请求通道 → worker 跑 `run-service` →
结果作为 `job-event` 回注事件通道 → runtime `job-finish` + `emit 'job`。

---

## 6. mode / doc-key（对齐 edit2 mode）

```
matcher = (ext "rkt") | (name "Makefile") | (regexp "…") | (any)
match-doc-keys : path matchers -> keytable | #f
```

打开文档时按 matcher 给该 did 挂键表（`content.doc-keys`）。`dispatch` 先试 doc 表、
再落全局（`#:doc-keymap`）。

---

## 7. 装配顺序（`app.rkt` / `install`）

```
install(base, plugins)：
  commands/scopes  merge（后装按名覆盖）
  keymap           compose（后装覆盖同 slot）
  panels/regions/decor/hooks/services/doc-key-matchers/prompt-kinds  追加
  boots/on-opens   收集
boot：World 造好后跑各插件 boot
打开文档：run-on-opens + 按 matcher 挂 doc-key + emit document-opened
```

内置插件（`plugins/`）：`syntax words brackets auto-pair demo async-demo`。
`config/plugins.rkt` 只给名字，`plugins/catalog.rkt` 解析成实现。

---

## 8. 与 edit3 的差异（有意为之）

1. `faces` → `decor`：edit4 每帧按 `handle+cursor` 重算，去掉 name/applies?/增量协议（07 的决定）。
2. hooks 的触发在 **edit4 的命令层**（`content/edit.rkt` 等 `emit!`），不在 runtime 猜。
3. 前端不透明类型（regions/decor/panels）不做注册表，直接列表 append。
