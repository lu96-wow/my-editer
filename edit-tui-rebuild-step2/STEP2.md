# step2：统一贡献清单 + 装配期校验

> 承接 `edit-tui-rebuild/ANALYSIS.md` 的第 1 步：
> **先加描述和校验，不改执行路径。**
>
> 本目录是 `edit-tui-rebuild` 的副本，只做这一步；原有分层 / 副作用白名单 / 测试保持不变。

## 1. 新增模块

| 模块 | 作用 |
|---|---|
| `env/extension.rkt` | `contribution{owner,kind,payload}`；把 contribution 落到已有 env 字段；`validate-environment` / `validate-environment!` |
| `env/panel-spec.rkt` | `panel-spec` 从 `env/plugin.rkt` 拆出，避免 `plugin ↔ extension` 循环依赖 |
| `test/extension.rkt` | contribution / provenance / 校验 / 内置 env / `#:contributions` 的回归测试 |

## 2. 数据结构

```racket
(struct contribution (owner kind payload) #:transparent)

;; kind 初始集合：
;;   status-parts status-part
;;   command keymap rule mode scope role doc-type input-command
;;   panel panel-sync hook decor face-layer
```

`environment` 新增两个字段：

```racket
(environment roles modes scopes commands keymaps rules status
             doc-types input-commands panel-syncs hooks face-layers
             decors contributions base)
```

`contributions` 只记录来源，不替代执行字段：

- `environment-add-contribution` 仍然调用 `environment-add-command` / `add-hook` / `add-decor` …；
- 执行器完全不变：`dispatch/hooks.rkt`、`effects/paint.rkt`、`runtime/run-frame`、`dispatch/rules.rkt`；
- `environment-merge` 追加两边的 `contributions`（不重新编译）；
- `base` 是“第一次加 plugin contribution 前的快照”，供 `environment-remove-owner` 重建。

`plugin.env` 的字段也会被分解成 contribution（owner = 插件 id），所以
`environment-remove-owner` 不只删 status-parts / hooks / decors，也能删
commands / modes / rules / face-layers / doc-types / input-commands。

重放顺序：

- rules / input-commands 是 cons 表，`environment->contributions` 反向生成，
  重建时再 cons 回原顺序；
- status 用 `'status`（替换语义）和 `'status-parts`（加法语义）分开；
- panel-syncs / hooks / decors / face-layers 是 append 表，保持正序。

`plugin` 新增可选字段：

```racket
(make-plugin 'demo
             #:contributions
             (list (make-contribution 'demo 'command (cons 'demo-hi cmd))))
```

旧字段 `env / status-parts / panels / hooks / decors` 保留，装配时也会转成 contribution
（owner = plugin id），所以 `environment.contributions` 能看到完整来源。
`make-plugin` 要求 `contribution-owner` 等于插件 id。

## 3. 按 owner 移除

```racket
(environment-remove-owner env 'plugin-id)
```

- 要求 `env.base` 存在（`plugins-env` 会在第一个插件贡献前写入）；
- 从 `base` 重建，只保留其他 owner 的 contributions；
- 环境没有 base（例如 `environment-empty`）时抛错，避免“删了清单但字段还在”的假卸载；
- 不存在的 owner 原样返回；
- 面板 / 插件 store 仍由宿主处理：env 只负责“贡献清单”，`panel-uninstall!` 负责 region / engine。

## 4. 校验

`plugins-env` / `plugins-apply` 末尾调用 `validate-environment!`，检查：

1. contribution 的 owner 是 symbol、kind 已知；
2. 所有 keymap 叶子是已注册命令；
3. rule 的 scope 已注册（`always` 或 `env.scopes`）；
4. doc-type 的 mode 已注册；
5. `face-layers` 唯一；
6. decor 的 layer 已在 `face-layers` 声明，decor layer / id 唯一；
7. status-part 名唯一；
8. input-command 名唯一；
9. hook point 是 symbol、priority 是整数；
10. panel-sync 是过程；
11. panel 的 mode / role 已注册，sync 是过程或 `#f`。

失败时装配期直接报错，不再是运行时静默失效。

## 5. 兼容性

- `panel-spec` API 不变：`env/plugin.rkt` re-export `(all-from-out "panel-spec.rkt")`。
- `make-plugin` 的旧关键字参数不变，新增 `#:contributions`。
- `environment` 构造器 / `environment-empty` / `environment-merge` 已同步更新。
- `main.rkt` 增加 `env/hook.rkt`、`env/panel-spec.rkt`、`env/extension.rkt` 的公共导出。
  这样 hook 不再需要“绕过公共面”直接 require，但它仍然只是独立模块，不是扩展总线。

## 6. 验证

```sh
cd edit-tui-rebuild-step2
racket test/extension.rkt
bash test/run.sh
```

本次结果：`edit-tui/test: all clean`。

## 7. 下一步（未做）

- `plugin-uninstall!` 的高层封装：env 已有 `environment-remove-owner`；还需要把
  panel / store / region 的清理串起来。
- input session 身份 + interaction 栈。
- 通用 service / job 管理器（去掉 completion / docs 重复的 cache / pending / jobs）。
- `panel-spec` 加 `install` / `hint`；抽 `toggle-region!`。
- `project-frame` 一帧只调一次。
