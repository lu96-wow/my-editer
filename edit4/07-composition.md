# edit4 · 07 组合：功能是 lambda，用数据 + map/fold 组合

> 这条是设计判据，不是实现细节。它纠正一种很容易犯的毛病：
> **先把功能实现出来，再贴个标签（name/kind/spec），然后靠查表去用它。**
> 函数式的做法是：可组合的功能本身就是 lambda，一组功能就是 list，
> 组合就是 `map` / `fold`。标签只在「配置接口」这一处出现，且装配期就解析掉。

---

## 0. 一句话

> **流水线里流动的是函数和数据，不是标签。**
> 需要名字时，名字只在装配期用一次（解析成函数），之后不再查表。

---

## 1. 判据

对每个「可组合」的东西问三句：

1. 它能不能直接是一个函数？（能不能 `map` 到一组数据上？）
2. 我写的 `name` / `applies?` / registry 字段，**运行时真的被读吗**？还是只是贴上去？
3. 组合它是 `append`/`map`/`fold` 就够，还是必须查表？

只要 (1) 成立且 (2) 读不到/只是识别，就该改成函数。

---

## 2. 已经在 edit4 里改掉的

### 2.1 装饰（高亮）—— 从「标签记录」到「函数列表」

之前：每种高亮实现成 `scan`，再包成 `(decor-plugin 'syntax applies? scan)`；
`name` 从头到尾没被读过，`applies?` 与 `scan` 本可以是一个函数。

现在：装饰就是函数，能否应用由函数自己决定。

```racket
;; decor : path text cursor -> (listof (vectorof face))   ; 不适用 → '()
(define (syntax-decor path text _cursor)
  (if (racket-file? path) (scan-lines text) '()))
(define (words-decor _path text cursor) ...)

;; 组合 = map 求值 + 逐格 fold face-compose
(map (lambda (d) (d path text cursor)) decors)

;; 加一种高亮 = 往列表里加一个 lambda
(add-decor (list syntax-decor words-decor))
```

### 2.2 面板 —— 从「name 注册表 + 查 vid」到「闭包 + map」

之前：`(panel-spec name render)` 注册成表，`project` 再按 name 查 vid。

现在：面板就是 `World -> 投影` 的函数，名字被闭包捕获。

```racket
(define (named-panel name render)          ; render : World × vid -> (values text faces)
  (lambda (w) (define v (panel-vid w name)) (and v (...))))

(define base-panels (list (named-panel "*status*" status-content)
                          (named-panel "*tree*" tree-content)))

(define (project-panels panels w) (filter values (map (lambda (p) (p w)) panels)))
```

### 2.3 命令 —— 名字只在装配期出现，运行时是函数组合

之前：`(command name args)` 每次事件都按 name 查 handler 表。

现在：装配期 `resolve-keymap` 把 name 解析成 handler 闭包；运行时把一串 handler
`fold` 掉。流水线里不再有 tag。

```racket
;; 名字 → 函数（装配期一次）
(resolve-keymap reg keymap)   ; -> (listof bound[binding scope enters-prefix? handlers])

;; 运行时：函数组合
(define (run-handlers ctx world hs)
  (for/fold ...))             ; 任一 handler 让位(#f) → 整体让位
```

### 2.4 插件 / 装配 —— 从「带槽位的记录」到「lambda fold」

之前：`(plugin #:commands ... #:panels ...)` 记录，再写解释器把它塞进 Environment。

现在：插件就是 `environment -> environment` 的 lambda，`install` 就是 `fold`。

```racket
(define (install env plugins) (for/fold ([e env]) ([p plugins]) (p e)))

(define (add-decor ds) (lambda (e) (struct-copy environment e [decor (append ...)])))

(install (base-environment)
         (list (add-commands base-commands) (add-keymap base-keymap) ...))
```

---

## 3. 保留标签的地方（以及为什么）

不是所有名字都要去掉。两类是正当的：

1. **配置接口**：键表要能用数据写（`(cmd 'split 'h 'after)`），插件要能按名覆盖。
   → 名字保留，但只在装配期解析一次（§2.3）。
2. **和类型（ADT）**：`event` / `effect` / `face` / `hit target` 是若干互斥形态，
   靠 `match` 分派——这是「数据有几种形状」，不是「给功能贴标签」。

反面判据：一个 struct 的字段在运行时**从未被读**，或加它只是为了让某处能 `equal?`/查表，
那就是贴标签。

---

## 4. 加一个编辑功能的模板

以「括号匹配高亮」为例：

1. **算法**：写一个纯函数 `bracket-decor : path text cursor -> (listof (vectorof face))`
   放在 `decor/bracket.rkt`。不适用就返回 `'()`。
2. **挂载**：在 `app.rkt` 的 `(add-decor (list ...))` 里加 `bracket-decor`。零改动核心。
3. **要交互**（比如跳转配对括号）：写一个 handler
   `(lambda (ctx world) (cons world' effs))`，用 `(add-commands (make-command-registry (list (cons 'bracket-match h))))`
   注册名字，并在键表里 `(cmd 'bracket-match)`。
   —— 名字是给键表用的配置接口；运行时它已被解析成函数。

不需要：新 struct、新 registry 类型、新 tag、改 runtime 主循环。

---

## 5. 自查清单

- 我新加的 `name`/`kind` 字段，运行时读吗？
- 这个功能能不能写成一个函数，直接 `map` 到一组数据上？
- 组合它是 `map`/`fold`/`append`，还是查表？
- 如果必须查表（配置接口），能不能在装配期一次解析成函数？
- 我是在「实现功能 + 贴标签」，还是「写 lambda + 组合」？
