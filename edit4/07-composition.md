# edit4 · 07 组合：功能是 lambda，用数据 + map/fold 组合

> 判据，不是教条。目的是**逻辑清晰、减少不必要的抽象层、架构清晰、组合可维护**。
> 如果一个「函数式」写法反而多出类型/阶段/组合子，就不该做。

---

## 0. 一句话

> **可组合的东西，能是函数就用函数、能 `map`/`fold` 就别查表；
> 但「组合」是为了更少的层次，不是为了更花哨。加层就停手。**

---

## 1. 判据

对每个「可组合」的东西问：

1. 它能不能直接是一个函数？
2. 我加的 `name`/`applies?`/registry 字段，运行时真的被读吗？还是只是贴上去？
3. 改成函数后，**概念/类型/函数的总数是变少还是变多**？
   —— 变多，就说明这是在硬套函数式，收手。

第 3 条是护栏：组合的方向是「更少层」，不是「更多层」。

---

## 2. 改掉的（真正的收益：层次变少）

### 2.1 装饰 —— 去掉 `decor-plugin(name applies? scan)`

`name` 从没被读；`applies?` 与 `scan` 本可以是一个函数。

```racket
;; decor : path text cursor -> (listof (vectorof face))   不适用 → '()
(define (syntax-decor path text _cursor)
  (if (racket-file? path) (scan-lines text) '()))
(define (words-decor _path text cursor) ...)

;; 组合 = map 求值 + 逐格 fold face-compose
(define layers (map (lambda (d) (d path text cursor)) decors))
```

结果：删掉 1 个 struct + 1 个 `name` 字段 + `applies?` 协议，只留函数。层次变少。

> **修正（change / 增量）**：裸 `scan` 无法增量——`syntax` 有跨行块注释/字符串状态、
> `brackets` 有跨行括号栈，必须能“带着状态从脏行接着扫”。所以现在每个 decor 是
> `decor/protocol.rkt` 的 `(decor open change)`（见 `10-plugins.md`），状态/层挂在引擎
> document 槽上。**`name` 仍然没有被读**：entries 与 decor 列表**位置平行**，不做查表；
> `applies?` 仍在插件级烘焙。也就是只加回了「有状态」这一項，不是加回标签层。

### 2.2 面板 —— 去掉 `panel-spec` + 注册表

面板就是 `World -> 投影` 的函数，名字被闭包捕获。

```racket
(define (named-panel name render)
  (lambda (w) (define v (panel-vid w name)) (and v (...))))

(define base-panels (list (named-panel "*status*" status-content)
                          (named-panel "*tree*" tree-content)))
(define (project-panels panels w) (filter values (map (lambda (p) (p w)) panels)))
```

结果：删掉 `panel-spec`、`panel-registry` 及 6 个注册表函数。层次变少。

---

## 3. 没有改的（改了反而加层，所以保留原样）

这两处我一度改成「更函数式」，但它们**多出了阶段/类型/组合子**，于是退回：

### 3.1 命令：名字是配置接口，保留注册表查表

键表要用数据写（`(cmd 'split 'h 'after)`）、插件要能按名覆盖，所以名字必须存在。
`run-commands` 已经是「数据（命令列表）+ 函数（handler）+ fold」的组合：

```racket
(run-commands reg ctx world '(command1 command2 …))   ; 逐条 run-command
```

一度加过 `resolve-keymap` + `bound` struct + 解析阶段：概念更多、热路径没变快，
**加层，退回**。

### 3.2 插件：一个 `plugin` 记录 + `install` fold

```racket
(struct plugin (commands scopes keymap panels decor))
(define (install env plugins) (for/fold ([e env]) ([p plugins]) (p e)))  ; 逐字段 merge/append
```

一度改成「`install` + 5 个 `add-*` lambda 组合子」：概念从 2 个（plugin、install）变成 6 个，
**加层，退回**。`plugin` 是产品类型，被 `install` 直接消费，不是「贴标签再查表」。

---

## 4. 标签什么时候是正当的

1. **配置接口**：键表用数据写、按名覆盖 → 名字保留（查一次注册表，标准做法）。
2. **和类型（ADT）**：`event`/`effect`/`face`/`hit target` 是互斥形态，靠 `match` 分派，
   这是「数据有几种形状」，不是「给功能贴标签」。

反面判据：字段运行时从没被读，或加它只为 `equal?`/查表 → 贴标签，删。

---

## 5. 加一个编辑功能的模板

以「括号匹配高亮」为例：

1. 写纯函数 `bracket-decor : path text cursor -> (listof (vectorof face))`，放 `decor/bracket.rkt`。
2. `app.rkt` 的 `(make-plugin #:decor (list … bracket-decor))` 里加上它。零改核心。
3. 要交互（跳转到配对括号）：写 handler，注册名字，键表 `(cmd 'bracket-match)`。

不需要：新 struct、新 registry 类型、新 tag、改 runtime。**也不该为了「组合」多引入一个阶段。**

---

## 6. 自查清单

- 我加的 `name`/`kind` 字段，运行时读吗？
- 改成函数/`map`/`fold` 后，概念总数是变少还是变多？变多就别改。
- 组合它是 `map`/`fold`/`append`，还是查表？查表如果只是为了按名配置，就正常。
- 我是在「写 lambda + 组合」，还是在「为组合而组合」？
