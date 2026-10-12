#lang racket

;;; edit4/view/face-plugin.rkt —— face 插件协议 + 投影/写回 + 缓存
;;;
;;;   face-plugin : name + applies? + scan
;;;     applies? : path text -> boolean
;;;     scan     : path text cursor -> (listof (vectorof face))   每行一个向量
;;;
;;; 一个文档可挂多个插件：每行按插件顺序 face-compose 成最终 face。
;;; ensure-faces 是**纯**投影（读 World，不写引擎），按 (handle, cursor) 缓存跳过；
;;; commit-faces! 才写引擎。

(provide (struct-out face-plugin)
         ensure-faces commit-faces!)

(require racket/list
         "../core/world.rkt"
         "../content/engine.rkt"
         "../content/content.rkt"
         "face.rkt")

(struct face-plugin (name applies? scan) #:transparent)

;; 可见的非面板文档视图（did 去重，取第一个）：(listof (list did vid))
(define (visible-doc-views w)
  (define c (world-content w))
  (cond
    [(not c) '()]
    [else
     (define ed (content-ed c))
     (define seen (make-hash))
     (for/fold ([acc '()]) ([(id vid) (in-hash (content-bindings c))])
       (define did (and vid (view-did ed vid)))
       (cond
         [(or (not did) (content-panel? c vid) (hash-has-key? seen did)) acc]
         [else (hash-set! seen did #t) (cons (list did vid) acc)]))]))

;; 一个文档的 face 填充：(listof (list line start line end face))
(define (doc-fills plugins w did vid)
  (define c (world-content w))
  (define ed (content-ed c))
  (define text (document-string ed did))
  (define path (doc-path (content-doc-meta c did)))
  (define cursor (cons (view-line ed vid) (view-col ed vid)))
  (define active (for/list ([p (in-list plugins)] #:when ((face-plugin-applies? p) path text)) p))
  (define layers (for/list ([p (in-list active)]) ((face-plugin-scan p) path text cursor)))
  (define lines (string-split text "\n"))
  (append*
   (for/list ([ln (in-range (length lines))])
     (define len (string-length (list-ref lines ln)))
     (define vec (make-vector len #f))
     (for ([layer (in-list layers)])
       (when (< ln (length layer))
         (define lv (list-ref layer ln))
         (define mlen (min len (vector-length lv)))
         (for ([i (in-range mlen)])
           (define f (vector-ref lv i))
           (when f (vector-set! vec i (face-compose (vector-ref vec i) f))))))
     (for/list ([r (in-list (face-runs vec))]) (list ln (car r) ln (cadr r) (caddr r))))))

;; ensure-faces : cache plugins world -> (values cache (listof (list did fills)))
(define (ensure-faces cache plugins w)
  (define c (world-content w))
  (define ed (and c (content-ed c)))
  (cond
    [(not c) (values cache '())]
    [else
     (for/fold ([cache cache] [projs '()]) ([dv (in-list (visible-doc-views w))])
       (define did (car dv)) (define vid (cadr dv))
       (define cursor (cons (view-line ed vid) (view-col ed vid)))
       (define k (list (document-handle ed did) (car cursor) (cdr cursor)))
       (cond
         [(equal? (hash-ref cache did #f) k) (values cache projs)]
         [else (values (hash-set cache did k) (cons (list did (doc-fills plugins w did vid)) projs))]))]))

;; commit-faces! : ed (listof (list did fills)) -> void
(define (commit-faces! ed projections)
  (for ([pr (in-list projections)])
    (define did (car pr))
    (define fills (cadr pr))
    (define text (document-string ed did))
    (define lines (string-split text "\n"))
    (face-batch! ed did
                 (for/list ([ln (in-range (length lines))])
                   (list ln 0 ln (string-length (list-ref lines ln)) #f)))
    (when (pair? fills) (face-batch! ed did fills))))
