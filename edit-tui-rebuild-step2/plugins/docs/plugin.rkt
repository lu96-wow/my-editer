#lang racket

;;; plugins/docs/plugin.rkt —— 标识符文档面板（本地定义 + 标准库文档）
;;;
;;; layer  : plugins/docs
;;; effect : set-text-effect / set-face-layer-effect（写面板）、submit-service-effect（doc 查询）
;;;
;;; 结构：
;;;   面板 *docs*（role 'tool，mode 'docs）—— buffer 支撑的固定高度面板；
;;;   C-c h / M-d -> 取光标处标识符，显示文档；C-c h 再按收起；
;;;   after-nav   -> 面板开着就跟随光标刷新；
;;;   complete-selection -> 补全选中项变化时，如果面板开着就更新。
;;;
;;; 文档来源（与 edit4 对齐）：
;;;   1. 当前文档里的顶层定义（lang/local-docs，纯）；
;;;   2. 标准库 / 已安装包（lang/docs：xref + blueboxes + HTML 兜底，走 worker）；
;;;   3. 内置关键字表（离线兜底）。
;;; xref/bluebox 结果按 (名字, 候选模块) 缓存；同一时刻只允许一个查询在途。
;;;
;;; CONSTRAINT: 与 completion 只通过 complete-selection 配合；xref 查询走 worker（CONSTRAINTS §6）。

(provide docs-plugin
         install-docs-panel!     ; 宿主装配时调用（建 *docs* 文档 + region）
         docs-panel-view         ; 面板 view-id
         docs-open?)             ; 面板当前是否显示

(require racket/list
         racket/string
         "../../command/key.rkt"
         "../../base/keymap.rkt"
         "../../base/transition.rkt"
         "../../base/effect.rkt"
         "../../base/id.rkt"
         "../../model/state.rkt"
         "../../model/workspace.rkt"
         "../../model/layout.rkt"
         "../../model/chrome.rkt"
         "../../model/service.rkt"
         "../../effects/engine.rkt"
         "../../env/command.rkt"
         "../../env/environment.rkt"
         "../../env/mode.rkt"
         "../../env/rule.rkt"
         "../../env/hook.rkt"
         "../../env/plugin.rkt"
         "../../env/service.rkt"
         "../../bootstrap/panel.rkt"
         "../../dispatch/context.rkt"
         "../lang/context.rkt"
         "../lang/pool.rkt"
         "../lang/local-docs.rkt")

(define store-key 'docs)

;; 一个插件的状态只占 store 的一个 key：store['docs] 下再分 panel / state /
;; cache / jobs。这样 plugin-uninstall! 清一个 key 就干净了。
(define (docs-store state)
  (plugin-state state store-key
                (hash 'panel #f
                      'state #f
                      'service (service-empty))))
(define (store-ref state key) (hash-ref (docs-store state) key))
(define (store-set state key value)
  (plugin-state-set state store-key
                    (hash-set (docs-store state) key value)))

;;; ════════════════ 面板 ════════════════

(define (docs-panel-view state) (store-ref state 'panel))

(define (install-docs-panel-state! _engine state _rid vid)
  (store-set state 'panel vid))

(define (docs-panel-spec)
  (make-panel-spec #:name "*docs*"
                   #:role 'tool
                   #:mode 'docs
                   #:sync #f
                   #:install install-docs-panel-state!
                   #:hint (fixed 8)
                   #:owner 'docs
                   #:key 'docs))

(define (install-docs-panel! engine state rid)
  (define-values (s1 _vid) (panel-spec-install! engine state rid (docs-panel-spec)))
  s1)

(define docs-keys
  (keys [(key 'left)  'nav-left]
        [(key 'right) 'nav-right]
        [(key 'up)    'nav-up]
        [(key 'down)  'nav-down]
        [(key 'home)  'nav-home]
        [(key 'end)   'nav-end]))

;;; ════════════════ store：当前文档 / 缓存 / job ════════════════

(define (docs-state state) (store-ref state 'state))
(define (set-docs-state state d) (store-set state 'state d))

(define (service-of state) (store-ref state 'service))
(define (cache-get state key) (service-cache-ref (service-of state) key #f))
(define (cache-has? state key) (service-cache-has? (service-of state) key))
(define (cache-put state key value)
  (store-set state 'service
             (service-cache-set (service-of state) key value)))
(define (pending? state key) (service-pending? (service-of state) key))
(define (pending-del state key)
  (store-set state 'service
             (service-pending-del (service-of state) key)))

(define (job-take state jid)
  (define-values (key service*)
    (service-job-take (service-of state) jid))
  (values key (store-set state 'service service*)))

;;; ════════════════ 光标处标识符 ════════════════

(define (ident-char? c)
  (or (char-alphabetic? c) (char-numeric? c)
      (memv c '(#\- #\_ #\? #\! #\* #\> #\< #\= #\+ #\. #\/ #\% #\& #\:))))

(define (line-at ev vid)
  (define text (or (engine-view-view-text ev vid) ""))
  (define line (or (engine-view-view-point-line ev vid) 0))
  (define lines (string-split text "\n"))
  (if (< line (length lines)) (list-ref lines line) ""))

(define (identifier-at ev vid)
  (define line (line-at ev vid))
  (define n (string-length line))
  (define col (min (or (engine-view-view-point-column ev vid) 0) n))
  (define start (let loop ([i col])
                  (if (and (> i 0) (ident-char? (string-ref line (sub1 i)))) (loop (sub1 i)) i)))
  (define end (let loop ([i col])
                (if (and (< i n) (ident-char? (string-ref line i))) (loop (add1 i)) i)))
  (and (< start end) (substring line start end)))

;;; ════════════════ 内置 / 本地 / 候选模块 ════════════════

(define builtin-docs
  (hash "define"  "(define name value)\n(define (name arg ...) body ...)\n绑定一个值或函数。"
        "lambda"  "(lambda (arg ...) body ...)\n匿名函数。"
        "let"     "(let ([name value] ...) body ...)\n局部绑定；let* 顺序绑定，letrec 递归绑定。"
        "let*"    "(let* ([name value] ...) body ...)\n逐条可见的局部绑定。"
        "letrec"  "(letrec ([name value] ...) body ...)\n互相引用的局部绑定。"
        "if"      "(if test then else)\n条件表达式。"
        "cond"    "(cond [test body ...] ... [else body ...])\n多分支条件。"
        "when"    "(when test body ...)\n为真时依次求值。"
        "unless"  "(unless test body ...)\n为假时依次求值。"
        "match"   "(match value [pattern body ...] ...)\n模式匹配。"
        "for"     "(for ([id seq] ...) body ...)\n遍历。"
        "for/list" "(for/list ([id seq] ...) body ...)\n遍历并收集到列表。"
        "map"     "(map proc lst ...)\n对每个元素应用 proc。"
        "filter"  "(filter pred lst)\n保留 pred 为真的元素。"
        "foldl"   "(foldl proc init lst ...)\n从左到右折叠。"
        "cons"    "(cons a d)\n构造 pair。"
        "car"     "(car p)\npair 的第一个元素。"
        "cdr"     "(cdr p)\npair 的第二个元素。"
        "list"    "(list v ...)\n构造列表。"
        "hash"    "(hash k v ...)\n构造不可变哈希。"
        "struct"  "(struct name (field ...))\n定义结构体类型。"
        "require" "(require module ...)\n导入模块。"
        "provide" "(provide name ...)\n导出名称。"
        "set!"    "(set! id value)\n修改绑定。"
        "begin"   "(begin body ...)\n顺序求值，返回最后一个值。"))

;; 当前标识符的文档上下文：源码上下文 + 绑定 / 候选模块 / 本地定义 / 内置文档。
(define (doc-context state ev vid ident)
  (define ctx (source-context state ev vid))
  (and ctx
       (let* ([specs (hash-ref ctx 'specs)]
              [parsed (hash-ref ctx 'parsed)]
              [mods0 (if (null? parsed) '(racket/base) parsed)]
              [binding
               (with-handlers ([exn:fail? (λ (_) #f)])
                 (spec-binding-of ident specs
                                  (hash-ref ctx 'base-dir)
                                  (hash-ref ctx 'open)))]
              [mods (if binding
                        (cons (car binding) (remove (car binding) mods0))
                        mods0)])
         (define ctx* (hash-set (hash-set (hash-set ctx 'binding binding)
                                          'mods mods)
                               'key (list ident mods)))
         (hash-set (hash-set ctx* 'local (local-def (hash-ref ctx 'text)
                                                    (string->symbol ident)))
                   'builtin (hash-ref builtin-docs ident #f)))))

;;; ════════════════ 生成面板文本 ════════════════

(define (online-docs name)
  (format "https://docs.racket-lang.org/search/index.html?q=~a" name))

(define (origin-text name binding)
  (and binding
       (format "来源: ~a~a"
               (let ([m (car binding)]) (if (symbol? m) m (format "~a" m)))
               (if (equal? (format "~a" (cadr binding)) name)
                   ""
                   (format "  (原 ~a)" (cadr binding))))))

(define (docs-lines name local std binding)
  (append
   (list name)
   (if (origin-text name binding) (list (origin-text name binding)) '())
   (if local (list "── 本地定义 ──" local) '())
   (cond
     [std (cons (if local "── 文档 ──" "") (string-split (string-trim std) "\n"))]
     [(not local) (list "(无本地文档)"
                        (format "在线: ~a" (online-docs name)))]
     [else '()])))

(define (docs-text d)
  (string-join (docs-lines (hash-ref d 'name) (hash-ref d 'local #f)
                           (hash-ref d 'std #f) (hash-ref d 'binding #f))
               "\n"))

(define (docs-fills d)
  (define lines (docs-lines (hash-ref d 'name) (hash-ref d 'local #f)
                            (hash-ref d 'std #f) (hash-ref d 'binding #f)))
  (for/list ([l (in-list lines)] [i (in-naturals)])
    (list i 0 i (string-length l)
          (cond [(zero? i) 'docs]
                [(or (string-prefix? l "来源:") (string-prefix? l "──")) 'docs-dim]
                [else 'docs-dim]))))

;;; ════════════════ 显示 / 收起 ════════════════

(define (docs-region state)
  (define vid (docs-panel-view state))
  (and vid (workspace-view-region (state-workspace state) vid)))

(define (docs-open? state)
  (define reg (docs-region state))
  (and reg (tree-visible? (workspace-layout (state-workspace state)) (region-key reg)) #t))

(define (hide-docs state)
  (define reg (docs-region state))
  (if (not reg)
      state
      (state-workspace* state
                        (λ (ws) (struct-copy workspace ws
                                             [layout (tree-hide (workspace-layout ws)
                                                                (region-key reg))])))))

(define (show-docs state ident)
  (define reg (docs-region state))
  (cond
    [(not reg) state]
    [else
     (state-workspace*
      (state-chrome* state (λ (c) (chrome-set-message c (format "docs: ~a" ident))))
      (λ (ws) (struct-copy workspace ws
                           [layout (tree-show (workspace-layout ws) (region-key reg))])))]))

(define (docs-panel-doc state)
  (define pvid (docs-panel-view state))
  (and pvid (workspace-doc-of-view (state-workspace state) pvid)))

(define (write-docs state d)
  (define pvid (docs-panel-view state))
  (define pdoc (docs-panel-doc state))
  (transition state
              (append
               (list (set-text-effect pvid (docs-text d)))
               (if pdoc
                   (list (set-face-layer-effect pdoc 'docs (docs-fills d)))
                   '()))))

;;; ════════════════ 提交 doc 查询 ════════════════

(define (submit-doc-job state key ident mods)
  (define-values (s1 service* effect)
    (service-request state (service-of state) 'doc (list 'doc ident mods) key))
  (transition (store-set s1 'service service*) (list effect)))

;;; ════════════════ 命令：C-c h / M-d ════════════════

(define (docs-show-impl state ev vid [forced-ident #f])
  (cond
    [(not (view-id? vid))
     (transition-pure (state-chrome* state (λ (c) (chrome-set-message c "docs: no view"))))]
    [else
     (define ident (or forced-ident (identifier-at ev vid)))
     (define ctx* (and ident (doc-context state ev vid ident)))
     (cond
       [(not ident)
        (transition-pure (state-chrome* state (λ (c) (chrome-set-message c "docs: no identifier"))))]
       [(not ctx*)
        (transition-pure (state-chrome* state
                                        (λ (c) (chrome-set-message c (format "docs: no docs for ~a" ident)))))]
       [else
        (define local (hash-ref ctx* 'local #f))
        (define builtin (hash-ref ctx* 'builtin #f))
        (define key (hash-ref ctx* 'key))
        (define cached? (cache-has? state key))
        (define cached (and cached? (cache-get state key)))
        (define pending (pending? state key))
        (define d (hash 'name ident 'local local 'std cached
                        'binding (hash-ref ctx* 'binding #f)
                        'key key 'target vid))
        (cond
          ;; 没有任何本地/内置文档，也没有缓存：先查询，成功后自动打开。
          [(and (not local) (not builtin) (not cached?))
           (cond
             [pending
              (transition-pure (state-chrome* state
                                              (λ (c) (chrome-set-message c (format "docs: querying ~a…" ident)))))]
             [else
              (define s1 (state-chrome* state
                                        (λ (c) (chrome-set-message c (format "docs: querying ~a…" ident)))))
              (transition-bind (submit-doc-job s1 key ident (hash-ref ctx* 'mods))
                               (λ (s2) (transition-pure (set-docs-state s2 d))))])]
          [else
           (define s1 (set-docs-state (show-docs state ident) d))
           (define s2 (write-docs s1 d))
           (if (or cached? pending)
               (transition (transition-state s2) (transition-effects s2))
               (transition-bind (submit-doc-job (transition-state s2) key ident (hash-ref ctx* 'mods))
                                (λ (s3) (transition s3 (transition-effects s2)))))])])]))

(define (docs-show-command ctx)
  (docs-show-impl (ctx-state ctx) (ctx-engine ctx) (ctx-subject ctx)))

;; C-c h：开 / 收；M-d：强制显示当前标识符
(define (docs-toggle-command ctx)
  (define state (ctx-state ctx))
  (cond
    [(docs-open? state) (transition-pure (hide-docs state))]
    [else (docs-show-command ctx)]))

;;; ════════════════ 钩子 ════════════════

(define (docs-on-nav state ev _args)
  (define vid (focused-vid state))
  (cond
    [(not (docs-open? state)) (transition-pure state)]
    [(not vid) (transition-pure state)]
    [(equal? vid (docs-panel-view state)) (transition-pure state)]
    [else
     (docs-show-impl state ev vid)]))

;; completion 选中项变化：面板开着就跟随；不自动改布局。
(define (docs-on-selection state ev args)
  (define vid (car args))
  (define name (cadr args))
  (cond
    [(or (not name) (not (docs-open? state)) (not (view-id? vid))) (transition-pure state)]
    [(string? name) (docs-show-impl state ev vid name)]
    [else (transition-pure state)]))

(define (docs-on-job state ev args)
  (define jid (car args))
  (define result (cadr args))
  (define-values (key s1) (job-take state jid))
  (cond
    [(not key) (transition-pure state)]
    [else
     (define s2 (pending-del s1 key))
     (define s3 (cache-put s2 key (and (string? result) result)))
     (define d (docs-state s3))
     (cond
       [(and d (equal? (hash-ref d 'key #f) key))
        (define d* (hash-set d 'std (and (string? result) result)))
        (define s4 (set-docs-state s3 d*))
        (cond
          [(string? result)
           (write-docs (show-docs s4 (hash-ref d* 'name)) d*)]
          [(or (hash-ref d* 'local #f) (hash-ref d* 'builtin #f))
           (write-docs s4 d*)]
          [else
           (transition-pure
            (state-chrome* s4
                           (λ (c) (chrome-set-message c
                                                      (format "docs: no docs for ~a"
                                                              (hash-ref d* 'name))))))])]
       [else (transition-pure s3)])]))


;;; ════════════════ 插件 ════════════════

(define docs-keys-table
  (keys [(key 'c 'ctrl) (key 'h) 'docs-toggle]
        [(key 'd 'alt) 'docs-show]))

(define (docs-plugin)
  (make-plugin
   'docs
   #:env (make-environment
          #:modes (hash 'docs (make-mode #:keymaps (list docs-keys) #:fallback 'ignore))
          #:services (hash 'doc
                           (make-service-spec 'doc
                                              #:description "xref / blueboxes / HTML 文档查询"))
          #:commands (hash 'docs-toggle (cmd docs-toggle-command)
                           'docs-show (cmd docs-show-command))
          #:rules (list (make-rule 'always docs-keys-table)))
   #:hooks (list (make-hook 'after-nav docs-on-nav)
                 (make-hook 'complete-selection docs-on-selection)
                 (make-hook 'job-done docs-on-job))))
