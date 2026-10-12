#lang racket

;;; edit3/plugins/docs.rkt —— 标识符文档弹窗（与补全用事件解耦）
;;;
;;; 订阅 complete-selection（args = (vid name binding) | (vid #f #f #f)）：
;;;   · 本地片段：当前编辑器文档里的顶层定义（lang/local-docs，纯，主线程）；
;;;   · 标准库/已安装包：走 `#:services 'doc` 的异步 worker（lang/docs：setup/xref 找 tag →
;;;     scribble/blueboxes 取签名 → 兜底抽 HTML 正文）。
;;;
;;; 防抖 / 防卡：**同一时刻只允许一个 doc 查询在途**（结果按 key 缓存）。上下快速切换时
;;; 中间选择不重复发请求；在途结果回来后 docs-kick 按当前选择补查。lang/docs 内部还用
;;; 信号量串行化（xref / bluebox 缓存不是线程安全的）。
;;; 与补全插件互不 require：补全只 emit 'complete-selection。

(require racket/list racket/string racket/path
         "../core/extension.rkt"
         "../core/lex.rkt"
         "lang/source.rkt"
         "lang/pool.rkt"
         "lang/local-docs.rkt"
         "lang/docs.rkt")

(provide docs-spec)

(define max-rows 16)

(define (docs-vid st) (panel-vid st "*docs*"))
(define (docs-float st)
  (define v (docs-vid st))
  (and v (for/first ([f (in-list (state-floats st))] #:when (eqv? v (float-vid f))) (float-wid f))))

(define (local-binding? binding)
  (and binding (let ([m (car binding)]) (or (path? m) (string? m)))))

;;; ---------- 结果缓存 + 在途（防抖 / 防卡） ----------

(define (docs-cache st) (feature-ref st 'docs-cache (hash 'done (hash) 'pending (hash))))
(define (cache-done st) (hash-ref (docs-cache st) 'done))
(define (cache-pending st) (hash-ref (docs-cache st) 'pending))
(define (cached? st k) (hash-has-key? (cache-done st) k))
(define (cached st k) (hash-ref (cache-done st) k #f))
(define (any-pending? st) (positive? (hash-count (cache-pending st))))
(define (mark-pending! st k) (hash-set! (cache-pending st) k #t))
(define (clear-pending! st k) (hash-remove! (cache-pending st) k))
(define (cache-put! st k v) (hash-set! (cache-done st) k v))

;;; ---------- 标准库文档（worker service） ----------

;; payload = (list 'doc name mods) → doc 文本 | #f
(define (docs-service payload)
  (match payload
    [(list 'doc name mods)
     (define d (docs-for name #:modules mods))
     (and d
          (let ([sig (doc-signature d)] [body (doc-body d)])
            (string-append (or sig "")
                           (if body (string-append (if sig "\n\n" "") body) "")
                           "\n")))]
    [_ #f]))

;; 查标准库要用的候选模块：binding 优先，否则从文档的 #lang + require 取。
(define (doc-mods st vid binding)
  (cond
    [binding (list (car binding))]
    [else
     (define ed (state-ed st))
     (define did (and vid (view-did ed vid)))
     (define text (if did (document-string ed did) ""))
     (define path (and did (let ([m (hash-ref (state-docs st) did #f)]) (and m (doc-meta-path m)))))
     (define base-dir (or (and path (let-values ([(d _f _n) (split-path path)]) (and (path? d) d)))
                          (current-directory)))
     (define-values (lang forms) (requires-context text))
     (define mods (requires-of-forms lang forms #:base-dir base-dir))
     (if (null? mods) '(racket/base) mods)]))

;;; ---------- 正文 ----------

(define (origin-text name binding)
  (and binding
       (format "来源: ~a~a"
               (let ([m (car binding)]) (if (symbol? m) m (format "~a" m)))
               (if (equal? (format "~a" (cadr binding)) (format "~a" name))
                   ""
                   (format "  (原 ~a)" (cadr binding))))))

(define (docs-lines st d)
  (define name (hash-ref d 'name))
  (define binding (hash-ref d 'binding #f))
  (define local (hash-ref d 'local #f))
  (define std (hash-ref d 'std #f))
  (append
   (list (format "~a" name))
   (if (origin-text name binding) (list (origin-text name binding)) '())
   (if local (list "── 本地定义 ──" local) '())
   (if std (cons (if local "── 文档 ──" "") (string-split (string-trim std) "\n")) '())))

(define (docs-content st _v)
  (define d (feature-ref st 'docs #f))
  (cond
    [(not d) (values "" '())]
    [else
     (define lines (docs-lines st d))
     (values
      (string-join lines "\n")
      (for/list ([i (in-range (length lines))])
        (define l (list-ref lines i))
        (cons i (cond [(zero? i) 'docs]
                      [(or (string-prefix? l "来源:") (string-prefix? l "──")) 'docs-dim]
                      [else 'docs-dim]))))]))

;;; ---------- 开 / 关 / 落位 ----------

(define (docs-close st)
  (define w (docs-float st))
  (feature-set (if w (remove-wid* st w) st) 'docs #f))

(define (open-docs st)
  (define d (feature-ref st 'docs #f))
  (cond
    [(not d) st]
    [(docs-float st) st]
    ;; 有本地定义 / 来源 / 文档任一时就弹（不干等异步）
    [(not (or (hash-ref d 'local #f) (hash-ref d 'std #f)
              (hash-ref d 'binding #f))) st]
    [else
     (define dv (docs-vid st))
     (if dv
         (open-float-overlay* st dv
                              (anchor (or (hash-ref d 'target-w #f) (state-focus st)) 'left 'bottom 0 0)
                              (cons 40 4) 'window-border)
         st)]))

;; 写入标准库段（拿到就刷新窗口）。
(define (docs-set-std st std)
  (define d (feature-ref st 'docs #f))
  (cond
    [(not d) st]
    [else
     (define st1 (feature-set st 'docs (hash-set d 'std std)))
     (if (or std (hash-ref d 'local #f)) (open-docs st1) st1)]))

;; 按**当前选择**推进查询：命中缓存直接显示；无在途才发新请求（最多一个在途）。
(define (docs-kick st)
  (define d (feature-ref st 'docs #f))
  (cond
    [(not d) st]
    [(hash-ref d 'local-binding? #f) st]
    [(cached? st (hash-ref d 'key)) (docs-set-std st (cached st (hash-ref d 'key)))]
    [(any-pending? st) st]
    [else
     (define key (hash-ref d 'key))
     (mark-pending! st key)
     (define-values (st* _j)
       (job-submit st 'doc (list 'doc (format "~a" (hash-ref d 'orig)) (hash-ref d 'mods)) key))
     st*]))

;; 开/更新一个查询（selection 或 M-d）。
(define (docs-show st vid name binding)
  (define ed (state-ed st))
  (define did (view-did ed vid))
  (define text (if did (document-string ed did) ""))
  (define orig (if binding (cadr binding) name))
  (define local (and (string? orig) (local-def text (string->symbol orig))))
  (define lb? (local-binding? binding))
  (define mods (if lb? '() (doc-mods st vid binding)))
  (define key (list (format "~a" orig) mods))
  (define tw (wid-of-vid st vid))
  (define d (hash 'name name 'binding binding 'orig orig
                  'local local 'std #f 'key key 'mods mods 'local-binding? lb?
                  'target-w tw 'target-vid vid))
  (define st1 (feature-set st 'docs d))
  (cond
    [lb? (if local (open-docs st1) (docs-close st1))]
    [(cached? st1 key) (docs-set-std st1 (cached st1 key))]
    [else
     ;; 有本地定义 / 来源就立即弹（标准库段到了再补）；否则等 worker 回来再弹
     (define st2 (docs-kick st1))
     (if (or local (hash-ref d 'binding #f)) (open-docs st2) st2)]))

(define (on-selection st args)
  (match args
    [(list vid name binding)
     (cond
       [(or (not vid) (not name)) (docs-close st)]
       [else (docs-show st vid name binding)])]
    [_ st]))

;; 'job：doc 结果回来 → 按 key 缓存；再按当前选择推进（可能在途时用户已切到别的名字）。
(define (docs-on-job st args)
  (match args
    [(list _id kind result tag)
     (cond
       [(not (eq? kind 'doc)) st]
       [else
        (clear-pending! st tag)
        (cache-put! st tag (and (string? result) result))
        (docs-kick st)])]
    [_ st]))

;; 每帧：贴源窗格，避开正在输入的行（光标在下半 / 底部放不下 → 贴顶；否则贴底）。
(define (reposition st size)
  (define d (feature-ref st 'docs #f))
  (define w (docs-float st))
  (cond
    [(or (not d) (not w) (not size)) st]
    [else
     (define tw (hash-ref d 'target-w #f))
     (define g (layout (state-tiling st) (state-floats st) size))
     (define p (and tw (for/first ([pl (in-list (geometry-placements g))]
                                   #:when (eqv? tw (placement-wid pl))) pl)))
     (cond
       [(not p) st]
       [else
        (define r (placement-rect p))
        (define lines (docs-lines st d))
        (define rows (min (length lines) max-rows))
        (define W (car size)) (define H (cdr size))
        (define width (max 3 (min (rect-w r) (- W (rect-x r)))))
        (define height (max 3 (min (+ rows 2) (rect-h r) H)))
        (define tv (hash-ref d 'target-vid #f))
        (define ed (state-ed st))
        (define pos (and tv (memv tv (view-id-list ed))
                         (point->screen ed tv (view-line ed tv) (view-col ed tv))))
        (define crow (+ (rect-y r) (if pos (car pos) 0)))
        (define pane-bottom (+ (rect-y r) (rect-h r)))
        ;; 底部放不下（会盖住光标行）→ 贴顶，否则贴底
        (define place-top? (>= (+ crow height 1) pane-bottom))
        (define a (anchor tw 'left (if place-top? 'top 'bottom) 0 0))
        (define f (float w (docs-vid st) a (cons width height) 'window-border))
        (struct-copy state st [floats (set-float (state-floats st) w f)])])]))

;;; ---------- M-d：光标处标识符查文档 ----------

(define (identifier-at text line col)
  (define lines (string-split text "\n"))
  (cond
    [(>= line (length lines)) #f]
    [else
     (define s (list-ref lines line))
     (define c (min col (string-length s)))
     (or (for/first ([m (in-list (line-tokens s))]
                     #:when (and (<= (car m) c) (<= c (cdr m))))
           (substring s (car m) (cdr m)))
         (for/first ([m (in-list (line-tokens s))] #:when (= (cdr m) c))
           (substring s (car m) (cdr m))))]))

(define (cmd-show-docs _ctx st _ev _args)
  (define vid (focused-vid st))
  (cond
    [(not vid) (values st '())]
    [else
     (define ed (state-ed st))
     (define did (view-did ed vid))
     (define m (hash-ref (state-docs st) did #f))
     (define path (and m (doc-meta-path m)))
     (cond
       [(not (racket-file? path)) (values st '())]
       [else
        (define text (view-string ed vid))
        (define id (identifier-at text (view-line ed vid) (view-col ed vid)))
        (cond
          [(not id) (values (docs-close st) '())]
          [else
           (define base-dir (let-values ([(d _f _n) (split-path path)]) (if (path? d) d (current-directory))))
           (define-values (lang forms) (requires-context text))
           (define binding (with-handlers ([exn:fail? (lambda (_) #f)])
                             (spec-binding-of id (require-specs-of-forms lang forms) base-dir)))
           (values (docs-show st vid id binding) '())])])]))

(define docs-spec
  (make-plugin
   #:name 'docs
   #:panels (list (panel-spec "*docs*" #f docs-content))
   #:ops (list (cons 'docs-show cmd-show-docs))
   #:key-tables (list '(((key d alt) editor (docs-show))))
   #:services (list (service 'doc docs-service))
   #:boot (lambda (st) (feature-set st 'docs-cache (hash 'done (make-hash) 'pending (make-hash))))
   #:hooks (list (reaction* 'complete-selection on-selection)
                 (reaction* 'job docs-on-job)
                 (reaction* 'after-nav (lambda (s _a) (if (docs-float s) (docs-close s) s)))
                 (reaction* 'focus-changed (lambda (s _a) (if (docs-float s) (docs-close s) s)))
                 (reaction* 'before-render
                            (lambda (s args)
                              (if (and (pair? args) (car args)) (reposition s (car args)) s))))))
