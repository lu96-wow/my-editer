#lang racket

;;; edit3-test/docs.rkt —— 补全详情弹窗
;;;   · 来源（binding，rename-in 反查）+ 标准库文档（worker：xref/bluebox/HTML）
;;;   · 本地定义（当前缓冲区的顶层定义，纯）

(require rackunit racket/list racket/file racket/string
         "../../edit3/core/extension.rkt"
         "../../edit3/core/step.rkt"
         "../../edit3/core/panels.rkt"
         "../../edit3/core/session.rkt"
         "../../edit3/core/border.rkt"
         "../../edit3/plugins/completion.rkt"
         "../../edit3/plugins/docs.rkt")

(define SZ (cons 80 24))
(define (run1 st ev) (call-with-values (lambda () (step (refresh-panels! st) SZ ev)) (lambda (s e) s)))
(define (docs-float-wid st)
  (for/first ([f (in-list (state-floats st))]
              #:when (eqv? (panel-vid st "*docs*") (float-vid f)))
    (float-wid f)))
(define (svc st) (feature-ref st 'services (make-service-registry)))
(define (doc-job st) (for/first ([j (in-list (jobs st))] #:when (eq? (job-kind j) 'doc)) j))
(define (deliver st j)
  (define r (run-service (svc st) j))
  (car (call-with-values (lambda () (step (refresh-panels! st) SZ
                                          (job-event (job-id j) (job-kind j) r (job-tag j))))
                         list)))

(define tmp (make-temporary-file "ed3docs~a" 'directory))
(define f (build-path tmp "a.rkt"))
(display-to-file "(require (rename-in racket/list [first zfirst]))\n(define (zlocal x) x)\nz\n"
                 f #:exists 'truncate)

(define st0 (boot 80 24 #:plugins (list completion-spec docs-spec)))
(define-values (st1 ign) (open-file* st0 f))
(set-point! (state-ed st1) (focused-vid st1) 2 1)     ; 光标在第 2 行 "z" 后

;; M-/ → 补全 exports job → 菜单开 → complete-selection → docs
(define st2 (run1 st1 (key-event '/ '(alt))))
(define st3 (deliver st2 (car (jobs st2))))
(check-true (and (feature-ref st3 'completion #f) #t))
(define cands (hash-ref (feature-ref st3 'completion #f) 'candidates))
(check-equal? (take cands 2) '("zfirst" "zlocal"))    ; 去重 + 顺序

;; 选中 zfirst（rename-in 来的）：来源 = racket/list 的 first；已发标准库 doc job
(define d3 (feature-ref st3 'docs #f))
(check-true (and d3 #t))
(check-equal? (hash-ref d3 'name) "zfirst")
(check-equal? (hash-ref d3 'binding) (list 'racket/list "first"))
(check-false (hash-ref d3 'local #f))                 ; 缓冲区里没有 first 的定义
(define dj (doc-job st3))
(check-true (and dj #t))
(check-equal? (job-payload dj) (list 'doc "first" '(racket/list)))

;; 快速上下切换：在途 doc 不堆积（同时最多 1 个，防卡死）
(define ssw (run1 (run1 (run1 st3 (key-event 'down '())) (key-event 'up '())) (key-event 'down '())))
(check-equal? (length (filter (lambda (j) (eq? (job-kind j) 'doc)) (jobs ssw))) 1)

;; 模拟 doc worker：真实查标准库（xref → bluebox/HTML）并回注
(define st3b (deliver st3 dj))
(check-true (and (string? (hash-ref (feature-ref st3b 'docs #f) 'std #f)) #t))
(check-true (and (regexp-match? #rx"first" (hash-ref (feature-ref st3b 'docs #f) 'std "")) #t))
(check-true (and (docs-float-wid st3b) #t))           ; 有内容后才弹

;; 下移到 zlocal（本地定义）：本地片段在
(define st4 (run1 st3b (key-event 'down '())))
(check-equal? (hash-ref (feature-ref st4 'completion #f) 'index) 1)
(define d4 (feature-ref st4 'docs #f))
(check-equal? (hash-ref d4 'name) "zlocal")
(check-true (and (regexp-match? #rx"zlocal" (hash-ref d4 'local "")) #t))

;; Esc 关菜单 → docs 一并关
(define st5 (run1 st4 (key-event 'escape '())))
(check-false (feature-ref st5 'completion #f))
(check-false (feature-ref st5 'docs #f))
(check-false (docs-float-wid st5))

;; M-d：光标处标识符直接查文档（不依赖补全）；光标放到 require 里的 zfirst 上
(define src (view-string (state-ed st5) (focused-vid st5)))
(define l0 (car (string-split src "\n")))
(define zc (car (car (regexp-match-positions #rx"zfirst" l0))))
(set-point! (state-ed st5) (focused-vid st5) 0 zc)
(define md0 (run1 st5 (key-event 'd '(alt))))
(check-true (and (feature-ref md0 'docs #f) #t))
(check-equal? (hash-ref (feature-ref md0 'docs #f) 'binding) (list 'racket/list "first"))
;; zfirst 的文档已缓存（前面查过）→ 命中缓存，直接显示，不再发 job
(check-true (and (string? (hash-ref (feature-ref md0 'docs #f) 'std #f)) #t))
(check-false (for/or ([j (in-list (jobs md0))]
                      #:when (equal? (cadr (job-payload j)) "first")) #t))
(check-true (and (docs-float-wid md0) #t))

;; 位置：不盖住正在输入的行（光标在下半 → 贴顶；否则贴底），且不超出源窗格
(define mdf (emit (refresh-panels! md0) 'before-render (list SZ)))
(define dw (docs-float-wid mdf))
(define geo (layout (state-tiling mdf) (state-floats mdf) SZ))
(define drect (for/first ([p (in-list (geometry-placements geo))] #:when (eqv? dw (placement-wid p)))
                (placement-rect p)))
(define tw (hash-ref (feature-ref mdf 'docs #f) 'target-w))
(define trect (for/first ([p (in-list (geometry-placements geo))] #:when (eqv? tw (placement-wid p)))
                (placement-rect p)))
(define tv (hash-ref (feature-ref mdf 'docs #f) 'target-vid))
(define pos (point->screen (state-ed mdf) tv (view-line (state-ed mdf) tv) (view-col (state-ed mdf) tv)))
(define crows (+ (rect-y trect) (car pos)))
(check-true (and drect #t))
(check-true (<= (rect-x drect) (rect-x trect)))                       ; 在源窗格内
(check-true (<= (+ (rect-x drect) (rect-w drect)) 80))
;; 尺寸必须是精确整数（曾因 rect-bounds 的 ±inf.0 种子变 flonum 而崩在 make-string）
(check-true (exact? (rect-w drect)))
(check-true (exact? (rect-h drect)))
(check-true (list? (border-runs mdf geo)))            ; 不抛 make-string 错
(check-true (or (> (rect-y drect) crows)                              ; 贴在光标下方
                (<= (+ (rect-y drect) (rect-h drect)) crows)))        ; 或上方（不盖住）

;; 无 binding / 无本地定义的候选（如关键词）也要弹文档窗（显示 名字 + (无文档)）
(define f3 (build-path tmp "c.rkt"))
(display-to-file "(require (only-in racket/string string-split))\nan\n" f3 #:exists 'truncate)
(define e0 (boot 80 24 #:plugins (list completion-spec docs-spec)))
(define-values (e1 ign-e1) (open-file* e0 f3))
(set-point! (state-ed e1) (focused-vid e1) 1 2)         ; 前缀 "an"
(define e2 (run1 e1 (key-event '/ '(alt))))
(define e3 (deliver e2 (car (jobs e2))))
(check-true (and (docs-float-wid e3) #t))               ; 弹窗在
(check-equal? (hash-ref (feature-ref e3 'docs #f) 'name) "and")
(check-false (hash-ref (feature-ref e3 'docs #f) 'binding #f))

;; 分屏：文档弹窗贴**整个编辑区**（两编辑器窗的包围盒），而不是单个窗格
(define f2 (build-path tmp "b.rkt"))
(display-to-file "#lang racket\n(define (bfn x) x)\nb\n" f2 #:exists 'truncate)
(define g0 (boot 80 24 #:plugins (list completion-spec docs-spec)))
(define-values (g1 ign-g1) (open-file* g0 f))
(define g2 (run1 (run1 g1 (key-event 's '(ctrl))) (key-event 'right '())))
(define-values (g3 ign-g3) (open-file* g2 f2))
(set-point! (state-ed g3) (focused-vid g3) 1 12)        ; bfn
(define g4 (run1 g3 (key-event 'd '(alt))))
(define g5 (emit (refresh-panels! g4) 'before-render (list SZ)))
(define gg (layout (state-tiling g5) (state-floats g5) SZ))
(define editor-rs
  (for/list ([p (in-list (geometry-placements gg))]
             #:when (and (zero? (placement-z p))
                         (let ([v (placement-vid p)]) (or (not v) (not (panel-name-of-vid g5 v))))))
    (placement-rect p)))
(define area (rect-bounds editor-rs))
(define dgw (docs-float-wid g5))
(define dgr (for/first ([p (in-list (geometry-placements gg))] #:when (eqv? dgw (placement-wid p)))
               (placement-rect p)))
(check-true (and dgr #t))
(check-equal? (rect-x dgr) (rect-x area))               ; 贴整个编辑区左边
(check-equal? (rect-w dgr) (rect-w area))               ; 宽度 = 整个编辑区
(check-true (or (= (rect-y dgr) (rect-y area))          ; 顶边
                (= (+ (rect-y dgr) (rect-h dgr)) (+ (rect-y area) (rect-h area)))))  ; 或底边

(delete-directory/files tmp)
(displayln "edit3/docs.rkt: all tests passed")
