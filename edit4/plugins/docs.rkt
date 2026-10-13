#lang racket

;;; edit4/plugins/docs.rkt —— 标识符文档弹窗（与补全用 complete-selection 事件解耦）
;;;
;;; 订阅 complete-selection（args = (vid name binding) | (vid #f #f #f)）：
;;;   · 本地片段：当前编辑器文档里的顶层定义（lang/local-docs，纯，主线程）；
;;;   · 标准库/已安装包：走 `#:services 'doc` 的异步 worker。
;;; 防抖：同一时刻只允许一个 doc 查询在途（结果按 key 缓存）。
;;;
;;; 与补全插件互不 require：补全只 emit 'complete-selection。

(provide docs-plugin)

(require racket/list racket/string racket/path racket/match
         net/uri-codec
         "../plugin.rkt"
         "../core/world.rkt" "../core/store.rkt" "../core/command.rkt" "../core/hook.rkt"
         "../core/job.rkt" "../core/keymap.rkt"
         "../content/model.rkt" "../content/adapter.rkt" "../content/float.rkt"
         "../view/panel.rkt"
         "../decor/kind.rkt" "../decor/lex.rkt"
         "../layout.rkt"
         "lang/source.rkt" "lang/pool.rkt" "lang/local-docs.rkt" "lang/docs.rkt")

;;; ---------- 访问器 ----------

(define (c-of w) (world-content w))
(define (ed-of w) (content-ed (c-of w)))
(define (focused-vid w) (define c (c-of w)) (and c (content-vid-of c (world-focus w))))
(define (sref w k [d #f]) (store-ref (world-store w) k d))
(define (sset w k v) (world-set-store w (store-set (world-store w) k v)))
(define (panel-vid w name) (define c (c-of w)) (and c (content-panel-vid c name)))
(define (doc-meta w did) (content-doc-meta (c-of w) did))
(define (wid-of-vid w vid) (content-wid-of-vid (c-of w) vid))
(define (wid-float? w id) (and (float-by-id (world-floats w) id) #t))

(define max-rows 16)

(define (docs-vid w) (panel-vid w "*docs*"))
(define (docs-float w)
  (define v (docs-vid w))
  (and v (for/first ([f (in-list (world-floats w))]
                     #:when (eqv? v (content-vid-of (c-of w) (float-id f))))
           (float-id f))))

(define (local-binding? binding)
  (and binding (let ([m (car binding)]) (or (path? m) (string? m)))))

;;; ---------- 结果缓存 + 在途 ----------

(define (docs-cache w) (sref w 'docs-cache (hash 'done (make-hash) 'pending (make-hash))))
(define (cache-done w) (hash-ref (docs-cache w) 'done))
(define (cache-pending w) (hash-ref (docs-cache w) 'pending))
(define (cached? w k) (hash-has-key? (cache-done w) k))
(define (cached w k) (hash-ref (cache-done w) k #f))
(define (any-pending? w) (positive? (hash-count (cache-pending w))))
(define (mark-pending! w k) (hash-set! (cache-pending w) k #t))
(define (clear-pending! w k) (hash-remove! (cache-pending w) k))
(define (cache-put! w k v) (hash-set! (cache-done w) k v))

;;; ---------- 标准库文档（worker service） ----------

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

;; 候选模块：解析源码得到「语言 + requires」，把 binding 指出的模块排最前。
;; 不只给 binding 的模块——启发式反查（spec-binding-of）对裸模块路径可能误挂到第一个
;; require；全量候选让 docs-for 逐个试，才不会查错模块而报「无文档」。
(define (doc-mods w vid binding)
  (define ed (ed-of w))
  (define did (and vid (view-did ed vid)))
  (define text (if did (document-string ed did) ""))
  (define path (and did (doc-path (doc-meta w did))))
  (define base-dir (or (and path (let-values ([(d _f _n) (split-path path)]) (and (path? d) d)))
                       (current-directory)))
  (define-values (lang forms) (requires-context text))
  (define parsed (requires-of-forms lang forms #:base-dir base-dir))
  (define mods (if (null? parsed) '(racket/base) parsed))
  (cond
    [(not binding) mods]
    [else (define bm (car binding))
          (cons bm (remove bm mods))]))

;;; ---------- 正文 ----------

(define (origin-text name binding)
  (and binding
       (format "来源: ~a~a"
               (let ([m (car binding)]) (if (symbol? m) m (format "~a" m)))
               (if (equal? (format "~a" (cadr binding)) (format "~a" name))
                   ""
                   (format "  (原 ~a)" (cadr binding))))))

;; 无本地文档时的在线兑底：docs.racket-lang.org 搜索页。
(define (docs-online-search name)
  (format "https://docs.racket-lang.org/search/index.html?q=~a"
          (uri-encode (format "~a" name))))

(define (docs-lines w d)
  (define name (hash-ref d 'name))
  (define binding (hash-ref d 'binding #f))
  (define local (hash-ref d 'local #f))
  (define std (hash-ref d 'std #f))
  (append
   (list (format "~a" name))
   (if (origin-text name binding) (list (origin-text name binding)) '())
   (if local (list "── 本地定义 ──" local) '())
   (cond
     [std (cons (if local "── 文档 ──" "") (string-split (string-trim std) "\n"))]
     [(not local) (list "(无本地文档)"
                        (format "在线: ~a" (docs-online-search name)))]
     [else '()])))

(define (docs-content w _v)
  (define d (sref w 'docs #f))
  (cond
    [(not d) (values "" '())]
    [else
     (define lines (docs-lines w d))
     (values
      (string-join lines "\n")
      (for/list ([i (in-range (length lines))])
        (define l (list-ref lines i))
        (cons i (cond [(zero? i) 'docs]
                      [(or (string-prefix? l "来源:") (string-prefix? l "──")) 'docs-dim]
                      [else 'docs-dim]))))]))

;;; ---------- 开 / 关 / 落位 ----------

(define (docs-close w)
  (define fw (docs-float w))
  (sset (if fw (close-float-by-id w fw) w) 'docs #f))

(define (open-docs w)
  (define d (sref w 'docs #f))
  (cond
    [(not d) w]
    [(docs-float w) w]
    [else
     (define dv (docs-vid w))
     (if dv
         (open-overlay w dv
                       (anchor (or (hash-ref d 'target-w #f) (world-focus w)) 'left 'bottom 0 0)
                       (cons 40 4))
         w)]))

(define (docs-set-std w std)
  (define d (sref w 'docs #f))
  (cond
    [(not d) w]
    [else
     (define w1 (sset w 'docs (hash-set d 'std std)))
     (if (or std (hash-ref d 'local #f)) (open-docs w1) w1)]))

(define (docs-kick w)
  (define d (sref w 'docs #f))
  (cond
    [(not d) w]
    [(hash-ref d 'local-binding? #f) w]
    [(cached? w (hash-ref d 'key)) (docs-set-std w (cached w (hash-ref d 'key)))]
    [(any-pending? w) w]
    [else
     (define key (hash-ref d 'key))
     (mark-pending! w key)
     (define-values (w* _j)
       (job-submit w 'doc (list 'doc (format "~a" (hash-ref d 'orig)) (hash-ref d 'mods)) key))
     w*]))

(define (docs-show w vid name binding)
  (define ed (ed-of w))
  (define did (view-did ed vid))
  (define text (if did (document-string ed did) ""))
  (define orig (if binding (cadr binding) name))
  (define local (and (string? orig) (local-def text (string->symbol orig))))
  (define lb? (local-binding? binding))
  (define mods (if lb? '() (doc-mods w vid binding)))
  (define key (list (format "~a" orig) mods))
  (define tw (wid-of-vid w vid))
  (define d (hash 'name name 'binding binding 'orig orig
                  'local local 'std #f 'key key 'mods mods 'local-binding? lb?
                  'target-w tw 'target-vid vid))
  (define w1 (sset w 'docs d))
  (cond
    [(and (not lb?) (cached? w1 key)) (open-docs (docs-set-std w1 (cached w1 key)))]
    [else (open-docs (docs-kick w1))]))

(define (on-selection w args)
  (match args
    [(list vid name binding)
     (cond
       [(or (not vid) (not name)) (docs-close w)]
       [else (docs-show w vid name binding)])]
    [_ w]))

(define (docs-on-job w args)
  (match args
    [(list _id kind result tag)
     (cond
       [(not (eq? kind 'doc)) w]
       [else
        (clear-pending! w tag)
        (cache-put! w tag (and (string? result) result))
        (docs-kick w)])]
    [_ w]))

;; 每帧：贴在编辑区（所有非面板平铺窗的包围盒）的下/上边。
(define (reposition w size)
  (define d (sref w 'docs #f))
  (define fw (docs-float w))
  (cond
    [(or (not d) (not fw) (not size)) w]
    [else
     (define ed (ed-of w))
     (define c (c-of w))
     (define tv (hash-ref d 'target-vid #f))
     (define pos (and tv (memv tv (view-id-list ed))
                      (point->screen ed tv (view-line ed tv) (view-col ed tv))))
     (define fr (world-frame w size))
     (define tiled (frame-tiled fr))
     (define rects (geometry-rects tiled))
     (define tw (hash-ref d 'target-w #f))
     (define tpl-rect (and tw (hash-ref rects tw #f)))
     (define area
       (cond
         [(and tw (wid-float? w tw) (frame-float-rect fr tw)) (frame-float-rect fr tw)]
         [else
          (define rs (for/list ([(id r) (in-hash rects)]
                                #:when (let ([v (content-vid-of c id)])
                                         (or (not v) (not (panel-name-of-vid c v)))))
                       r))
          (or (rect-bounds rs) tpl-rect)]))
     (cond
       [(not area) w]
       [else
        (define lines (docs-lines w d))
        (define rows (min (length lines) max-rows))
        (define W (car size)) (define H (cdr size))
        (define width (max 3 (min (rect-w area) (- W (rect-x area)))))
        (define height (max 3 (min (+ rows 2) (rect-h area) H)))
        (define target-rect tpl-rect)
        (define crow (+ (rect-y (or target-rect area)) (if pos (car pos) 0)))
        (define area-bottom (+ (rect-y area) (rect-h area)))
        (define place-top? (>= (+ crow height 1) area-bottom))
        (define ay (if place-top? (rect-y area) (- area-bottom height)))
        (define a (anchor 'screen 'left 'top (rect-x area) ay))
        (define f (float fw a (cons width height)))
        (set-float-on-world w f)])]))

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

(define (cmd-show-docs _ctx w _args)
  (define vid (focused-vid w))
  (cond
    [(not vid) (cons w '())]
    [else
     (define ed (ed-of w))
     (define did (view-did ed vid))
     (define m (doc-meta w did))
     (define path (and m (doc-path m)))
     (cond
       [(not (racket-file? path)) (cons w '())]
       [else
        (define text (view-string ed vid))
        (define id (identifier-at text (view-line ed vid) (view-col ed vid)))
        (cond
          [(not id) (cons (docs-close w) '())]
          [else
           (define base-dir (let-values ([(d _f _n) (split-path path)]) (if (path? d) d (current-directory))))
           (define-values (lang forms) (requires-context text))
           (define binding (with-handlers ([exn:fail? (lambda (_) #f)])
                             (spec-binding-of id (require-specs-of-forms lang forms) base-dir)))
           (cons (docs-show w vid id binding) '())])])]))

;;; ---------- 插件 ----------

(define docs-commands
  (make-command-registry (list (cons 'docs-show cmd-show-docs))))

(define docs-plugin
  (make-plugin
   #:name 'docs
   #:commands docs-commands
   #:panels (list (named-panel "*docs*" docs-content))
   #:keymap (list (list '(key d alt) 'editor (cmd 'docs-show)))
   #:services (list (service 'doc docs-service))
   #:boot (lambda (w) (sset w 'docs-cache (hash 'done (make-hash) 'pending (make-hash))))
   #:hooks (list (reaction* 'complete-selection on-selection)
                 (reaction* 'job docs-on-job)
                 (reaction* 'after-nav (lambda (w _a) (if (docs-float w) (docs-close w) w)))
                 (reaction* 'focus-changed (lambda (w _a) (if (docs-float w) (docs-close w) w)))
                 (reaction* 'before-render
                            (lambda (w args)
                              (if (and (pair? args) (car args)) (reposition w (car args)) w))))))
