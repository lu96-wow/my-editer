#lang racket

;;; edit4/plugins/completion.rkt —— 补全（不抢焦点的浮窗菜单）
;;;
;;; 关键点（同 edit3）：
;;;   · 菜单是不抢焦点的浮窗：编辑器保持焦点与光标，能边打边筛；
;;;   · 菜单随光标落位（below/above），由 before-render 钩子每帧重算；
;;;   · Up/Down/Tab/Enter/Esc 用「有菜单就操作菜单、否则回落原行为」的命令接住；
;;;     打字走基础 insert，after-insert/after-edit 钩子重筛；
;;;   · require 的模块导出（module->exports）是慢部分，丢给 core/job 的 worker：
;;;     M-/ 时若没缓存就登记 'completion-exports job；结果由 'job 钩子写回缓存再开菜单。
;;;
;;; 广播 complete-selection（docs 插件订阅它）。

(provide completion-plugin)

(require racket/string racket/list racket/path racket/match
         "../plugin.rkt"
         "../core/world.rkt" "../core/store.rkt" "../core/command.rkt" "../core/hook.rkt"
         "../core/job.rkt" "../core/keymap.rkt"
         "../content/model.rkt" "../content/adapter.rkt" "../content/float.rkt"
         "../view/panel.rkt"
         "../decor/kind.rkt" "../decor/lex.rkt" "../config/syntax.rkt"
         "../layout.rkt"
         "lang/source.rkt" "lang/pool.rkt" "lang/module-index.rkt")

;;; ---------- 访问器 ----------

(define (c-of w) (world-content w))
(define (ed-of w) (content-ed (c-of w)))
(define (focused-vid w) (define c (c-of w)) (and c (content-vid-of c (world-focus w))))
(define (sref w k [d #f]) (store-ref (world-store w) k d))
(define (sset w k v) (world-set-store w (store-set (world-store w) k v)))
(define (panel-vid w name) (define c (c-of w)) (and c (content-panel-vid c name)))
(define (doc-meta w did) (content-doc-meta (c-of w) did))

;;; ---------- popup 内容窗口（纯几何） ----------

;; n 项里以 idx 为中心、最多 cap 行的窗口。→ (values start rows)
(define (popup-window n idx cap)
  (define rows (max 1 (min n (max 1 cap))))
  (values (max 0 (min (- idx (quotient rows 2)) (- n rows))) rows))

;;; ---------- 候选 ----------

(define (line-at ed did line)
  (define lines (string-split (document-string ed did) "\n"))
  (if (< line (length lines)) (list-ref lines line) ""))

(define (prefix-at ed vid)
  (define did (view-did ed vid))
  (define s (line-at ed did (view-line ed vid)))
  (define c (min (view-col ed vid) (string-length s)))
  (define start (let loop ([i c])
                  (if (and (> i 0) (symbol-char? (string-ref s (sub1 i)))) (loop (sub1 i)) i)))
  (substring s start c))

;; 本地（快）：所有打开的文档里出现过的词 + Racket 关键字。
(define (local-pool w)
  (define ed (ed-of w))
  (define c (c-of w))
  (define from-docs
    (for*/list ([did (in-list (document-id-list ed))]
                #:unless (panel-doc-name? c (document-name ed did))
                [line (in-list (string-split (document-string ed did) "\n"))]
                [m (in-list (line-tokens line))])
      (substring line (car m) (cdr m))))
  (sort (remove-duplicates (append from-docs (hash-keys keyword-categories))) string<?))

;; 打开的文档：绝对路径字符串 -> 当前缓冲区文本。
(define (open-local-texts w)
  (define ed (ed-of w))
  (for/hash ([did (in-list (document-id-list ed))]
             #:when (let ([m (doc-meta w did)]) (and m (doc-path m))))
    (values (path->string (path->complete-path (doc-path (doc-meta w did))))
            (document-string ed did))))

;; 焦点 Racket 文档的 require 上下文：(list specs base-dir open-map locals) | #f
(define (imports-context w)
  (define ed (ed-of w))
  (define vid (focused-vid w))
  (define did (and vid (view-did ed vid)))
  (define m (and did (doc-meta w did)))
  (define path (and m (doc-path m)))
  (cond
    [(not (racket-file? path)) #f]
    [else
     (define text (view-string ed vid))
     (define-values (lang forms) (requires-context text))
     (define specs (require-specs-of-forms lang forms))
     (define specs* (if (pair? specs) specs (list 'racket/base)))
     (define base-dir (let-values ([(d _f _n) (split-path path)])
                        (if (path? d) d (current-directory))))
     (define open (open-local-texts w))
     (define locals (map symbol->string (definitions-of-forms forms)))
     (list specs* base-dir open locals)]))

;;; ---------- 模块导出缓存 + 异步 job ----------

(define (completion-cache w)
  (sref w 'completion-cache (hash 'exports (make-hash) 'pending (make-hash))))
(define (cache-get w key) (hash-ref (hash-ref (completion-cache w) 'exports) key #f))
(define (cache-put! w key names) (hash-set! (hash-ref (completion-cache w) 'exports) key names))
(define (pending? w key) (hash-ref (hash-ref (completion-cache w) 'pending) key #f))
(define (pending-put! w key) (hash-set! (hash-ref (completion-cache w) 'pending) key #t))
(define (pending-del! w key) (hash-remove! (hash-ref (completion-cache w) 'pending) key))

(define (digest str)
  (for/fold ([h 5381]) ([c (in-string str)])
    (bitwise-and (+ (* h 33) (char->integer c)) #xFFFFFFFF)))

(define (import-key specs base-dir open)
  (list specs (path->string base-dir)
        (sort (for/list ([(p t) (in-hash open)]) (cons p (digest t))) string<? #:key car)))

;; worker：慢部分。
(define (exports-service payload)
  (match payload
    ['(module-paths) (force module-paths)]
    [(list 'exports base-dir specs open)
     (append* (for/list ([s (in-list specs)]) (spec-names s base-dir open)))]
    [_ '()]))

(define (module-path-context w)
  (define ed (ed-of w))
  (define vid (focused-vid w))
  (define did (and vid (view-did ed vid)))
  (define m (and did (doc-meta w did)))
  (define path (and m (doc-path m)))
  (cond
    [(not (racket-file? path)) #f]
    [else
     (define text (view-string ed vid))
     (and (or (require-context? text (view-line ed vid) (view-col ed vid))
              (lang-context? text (view-line ed vid) (view-col ed vid)))
          #t)]))

(define (filter-pool pool prefix)
  (define plen (string-length prefix))
  (for/list ([x (in-list pool)]
             #:when (and (>= (string-length x) plen)
                         (string=? prefix (substring x 0 plen))))
    x))

;; 候选排序：短的在前（同长按字典序）——让短/常用名先出现。
(define (rank-candidates cands)
  (sort cands
        (lambda (a b)
          (cond [(< (string-length a) (string-length b)) #t]
                [(> (string-length a) (string-length b)) #f]
                [else (string<? a b)]))))

;;; ---------- 菜单浮窗 ----------

(define (completion-vid w) (panel-vid w "*completion*"))
(define (completion-float w)
  (define cv (completion-vid w))
  (and cv (for/first ([f (in-list (world-floats w))]
                      #:when (eqv? cv (content-vid-of (c-of w) (float-id f))))
           (float-id f))))
(define (menu-open? w) (and (sref w 'completion #f) (completion-float w) #t))

(define (completion-close w)
  (define fw (completion-float w))
  (define w1 (sset (if fw (close-float-by-id w fw) w) 'completion #f))
  (emit! w1 'complete-selection (list (focused-vid w1) #f #f)))

;; 广播当前选中候选（菜单关时 name=#f）。
(define (publish-selection w)
  (define c (sref w 'completion #f))
  (cond
    [(not c) (emit! w 'complete-selection (list (focused-vid w) #f #f))]
    [else
     (define docs? (hash-ref c 'docs? #f))
     (define name (and docs? (list-ref (hash-ref c 'candidates) (hash-ref c 'index))))
     (define specs (hash-ref c 'specs #f))
     (define base-dir (hash-ref c 'base-dir #f))
     (define binding (and docs? specs base-dir
                          (with-handlers ([exn:fail? (lambda (_) #f)])
                            (spec-binding-of name specs base-dir (hash-ref c 'open #f)))))
     (emit! w 'complete-selection (list (hash-ref c 'target-vid) name binding))]))

;; 菜单每帧落位 + 尺寸。
(define (reposition w size)
  (define c (sref w 'completion #f))
  (define fw (completion-float w))
  (cond
    [(or (not c) (not fw) (not size)) w]
    [else
     (define cands (hash-ref c 'candidates))
     (define idx (hash-ref c 'index))
     (define maxlen (for/fold ([m 0]) ([x (in-list cands)]) (max m (string-length x))))
     (define cap (min 8 (length cands)))
     (define-values (_start rows) (popup-window (length cands) idx cap))
     (define W (car size)) (define H (cdr size))
     (define tw (hash-ref c 'target-w))
     (define fr (world-frame w size))
     (define tiled (frame-tiled fr))
     (define r (hash-ref (geometry-rects tiled) tw #f))
     (define rw (if r (rect-w r) W))
     (define rh (if r (rect-h r) H))
     (define width (max 3 (min (max 12 (+ maxlen 3)) (max 3 (- rw 2)))))
     (define height (min (+ rows 2) rh))
     (define tv (hash-ref c 'target-vid))
     (define ed (ed-of w))
     (define pos (and (memv tv (view-id-list ed))
                      (point->screen ed tv (view-line ed tv) (view-col ed tv))))
     (define vcol (if pos (cdr pos) 0))
     (define vrow (if pos (car pos) 0))
     (define dx (max 0 (min vcol (max 0 (- rw width)))))
     (define below? (<= (+ vrow 1 height) rh))
     (define dy (if below? (add1 vrow) (max 0 (- vrow height))))
     (define a (anchor tw 'left 'top dx dy))
     (define f (float fw a (cons width height)))
     ;; 记住外框宽度：菜单面板按「内容宽 = width-2」补齐，选中行底色才能盖满浮窗。
     (set-float-on-world (sset w 'completion (hash-set c 'width width)) f)]))

;;; ---------- 菜单面板 ----------

(define (completion-content w v)
  (define c (sref w 'completion #f))
  (cond
    [(not c) (values "" '())]
    [else
     (define cands (hash-ref c 'candidates))
     (define idx (hash-ref c 'index))
     (define cap (min 8 (length cands)))
     (define-values (start rows) (popup-window (length cands) idx cap))
     (define shown (take (drop cands start) rows))
     ;; 行宽 = 浮窗内容宽（外框内缩 1）：选中行 face 是整行底色，必须铺满浮窗。
     (define inner-w
       (or (and (hash-ref c 'width #f) (max 1 (- (hash-ref c 'width) 2)))
           (for/fold ([m 1]) ([x (in-list cands)]) (max m (+ 1 (string-length x))))))
     (values
      (string-join (for/list ([x (in-list shown)])
                     (define base (string-append " " x))
                     (string-append base (make-string (max 0 (- inner-w (string-length base))) #\space)))
                   "\n")
      (for/list ([i (in-range rows)])
        (cons i (if (= (+ start i) idx) 'complete-selected 'complete))))]))

;;; ---------- 行为 ----------

(define (complete-move w d)
  (define c (sref w 'completion #f))
  (cond
    [(not c) w]
    [else
     (define n (length (hash-ref c 'candidates)))
     (publish-selection
      (sset w 'completion (hash-set c 'index (modulo (+ (hash-ref c 'index) d) n))))]))

;; 打字 / 删除后按新前缀重筛；前缀空或无候选则关。
(define (refine w)
  (define c (sref w 'completion #f))
  (cond
    [(not c) w]
    [else
     (define v (hash-ref c 'target-vid))
     (define ed (ed-of w))
     (cond
       [(not (memv v (view-id-list ed))) (completion-close w)]
       [else
        (define prefix (prefix-at ed v))
        (cond
          [(zero? (string-length prefix)) (completion-close w)]
          [else
           (define cands (rank-candidates (filter-pool (hash-ref c 'pool) prefix)))
           (cond
             [(null? cands) (completion-close w)]
             [else
              (define idx (min (hash-ref c 'index) (sub1 (length cands))))
              (publish-selection
               (sset w 'completion
                     (hash-set (hash-set (hash-set c 'candidates cands) 'index idx) 'prefix prefix)))])])])]))

;;; ---------- 命令 ----------

(define (open-menu w vid prefix pool [specs #f] [base-dir #f] [docs? #f] [open #f])
  (define cands (rank-candidates (filter-pool (distinct-strings pool) prefix)))
  (cond
    [(null? cands) w]
    [else
     (define c0 (hash 'candidates cands 'index 0 'prefix prefix 'pool pool
                      'specs specs 'base-dir base-dir 'docs? docs? 'open open
                      'target-vid vid 'target-w (world-focus w)))
     (define w1 (sset w 'completion c0))
     (define w2 (open-overlay w1 (completion-vid w1)
                              (anchor (world-focus w1) 'left 'top 0 1) (cons 12 3)))
     (publish-selection w2)]))

(define (completion-start _ctx w _args)
  (define vid (focused-vid w))
  (cond
    [(or (not vid) (panel-name-of-vid (c-of w) vid) (menu-open? w)) (cons w '())]
    [else
     (define ed (ed-of w))
     (define prefix (prefix-at ed vid))
     (cond
       [(zero? (string-length prefix)) (cons w '())]
       [(module-path-context w)
        (define exp (cache-get w 'module-paths))
        (cond
          [(list? exp) (cons (open-menu w vid prefix exp) '())]
          [(pending? w 'module-paths) (cons w '())]
          [else
           (pending-put! w 'module-paths)
           (define-values (w* _j) (job-submit w 'completion-exports '(module-paths) 'module-paths))
           (cons w* '())])]
       [else
        (define ctx* (imports-context w))
        (cond
          [(not ctx*) (cons (open-menu w vid prefix (local-pool w)) '())]
          [else
           (define specs (car ctx*)) (define base-dir (cadr ctx*))
           (define open (caddr ctx*)) (define locals (cadddr ctx*))
           (define key (import-key specs base-dir open))
           (define exp (cache-get w key))
           (cond
             [(list? exp) (cons (open-menu w vid prefix (append exp locals (local-pool w)) specs base-dir #t open) '())]
             [(pending? w key) (cons w '())]
             [else
              (pending-put! w key)
              (define-values (w* _j) (job-submit w 'completion-exports
                                                 (list 'exports base-dir specs open) key))
              (cons w* '())])])])]))

;; 'job 钩子：worker 结果回来 → 写缓存 → 若上下文仍合适就开菜单。
(define (completion-on-job w args)
  (match args
    [(list _id kind result tag)
     (cond
       [(not (eq? kind 'completion-exports)) w]
       [else
        (pending-del! w tag)
        (when (and (list? result) (andmap string? result)) (cache-put! w tag result))
        (maybe-open-cached w)])]
    [_ w]))

(define (maybe-open-cached w)
  (define vid (focused-vid w))
  (cond
    [(or (not vid) (panel-name-of-vid (c-of w) vid) (menu-open? w)) w]
    [else
     (define ed (ed-of w))
     (define prefix (prefix-at ed vid))
     (cond
       [(zero? (string-length prefix)) w]
       [(module-path-context w)
        (define exp (cache-get w 'module-paths))
        (if (list? exp) (open-menu w vid prefix exp) w)]
       [else
        (define ctx* (imports-context w))
        (cond
          [(not ctx*) w]
          [else
           (define specs (car ctx*)) (define base-dir (cadr ctx*))
           (define open (caddr ctx*)) (define locals (cadddr ctx*))
           (define exp (cache-get w (import-key specs base-dir open)))
           (cond
             [(list? exp) (open-menu w vid prefix (append exp locals (local-pool w)) specs base-dir #t open)]
             [else w])])])]))

(define (complete-next _ctx w _args) (cons (if (menu-open? w) (complete-move w 1) w) '()))
(define (complete-prev _ctx w _args) (cons (if (menu-open? w) (complete-move w -1) w) '()))

(define (complete-accept _ctx w _args)
  (define c (sref w 'completion #f))
  (cond
    [(not c) (cons w '())]
    [else
     (define cand (list-ref (hash-ref c 'candidates) (hash-ref c 'index)))
     (define prefix (hash-ref c 'prefix))
     (define tvid (hash-ref c 'target-vid))
     (define ins (substring cand (min (string-length prefix) (string-length cand))))
     (insert! (ed-of w) tvid ins)
     (cons (completion-close w) '())]))

;; Up/Down：有菜单移候选，否则回落普通导航（并补发 after-nav）。
(define (complete-or-move _ctx w args)
  (define dir (car args))
  (cond
    [(menu-open? w) (cons (complete-move w (if (eq? dir 'up) -1 1)) '())]
    [else
     (define v (focused-vid w))
     (cond
       [(not v) (cons w '())]
       [else (nav! (ed-of w) v dir #f)
             (cons (emit! w 'after-nav (list v)) '())])]))

(define (complete-or-enter ctx w args)
  (cond
    [(menu-open? w) (complete-accept ctx w args)]
    [else
     (define v (focused-vid w))
     (cond
       [(not v) (cons w '())]
       [else (insert! (ed-of w) v "\n")
             (cons (emit! w 'after-insert (list v "\n")) '())])]))

(define (complete-or-cancel _ctx w _args)
  (cons (if (menu-open? w) (completion-close w) w) '()))

;;; ---------- 插件 ----------

(define completion-commands
  (make-command-registry
   (list (cons 'complete-start completion-start)
         (cons 'complete-next complete-next)
         (cons 'complete-prev complete-prev)
         (cons 'complete-accept complete-accept)
         (cons 'complete-or-move complete-or-move)
         (cons 'complete-or-enter complete-or-enter)
         (cons 'complete-or-cancel complete-or-cancel))))

(define completion-plugin
  (make-plugin
   #:name 'completion
   #:commands completion-commands
   #:panels (list (named-panel "*completion*" completion-content))
   #:services (list (service 'completion-exports exports-service))
   #:boot (lambda (w) (sset w 'completion-cache (hash 'exports (make-hash) 'pending (make-hash))))
   #:keymap (list (list '(key / alt) 'editor (cmd 'complete-start))
                  (list '(key down) 'editor (cmd 'complete-or-move 'down))
                  (list '(key up) 'editor (cmd 'complete-or-move 'up))
                  (list '(key tab) 'editor (cmd 'complete-next))
                  (list '(key enter) 'editor (cmd 'complete-or-enter))
                  (list '(key escape) 'editor (cmd 'complete-or-cancel)))
   #:hooks (list (reaction* 'after-insert (lambda (w _args) (refine w)))
                 (reaction* 'after-edit (lambda (w _args) (refine w)))
                 (reaction* 'job completion-on-job)
                 (reaction* 'focus-changed
                            (lambda (w _args)
                              (define c (sref w 'completion #f))
                              (if (and c (not (eqv? (focused-vid w) (hash-ref c 'target-vid))))
                                  (completion-close w)
                                  w)))
                 (reaction* 'before-render
                            (lambda (w args)
                              (if (and (pair? args) (car args)) (reposition w (car args)) w))))))
