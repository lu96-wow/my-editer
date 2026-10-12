#lang racket

;;; edit4/view/decor.rkt —— 装饰：纯函数流水线（lambda + map/fold）
;;;
;;; 一个装饰就是一个**函数**：
;;;     decor : path text cursor -> (listof (vectorof face))   ; 每行一个向量
;;; 能否应用由函数自己决定（不适用 → 返回 '()）；没有 name / applies? 标签。
;;;
;;; 组合 = 对一组装饰 map 求值，再逐格 fold face-compose：
;;;     (map (lambda (d) (d path text cursor)) decors)
;;; 于是「加一种高亮」= 往列表里加一个 lambda，而不是注册一条带标签的记录。
;;;
;;; ensure-faces 是纯投影（按 handle+cursor 缓存）；commit-faces! 才写引擎。
;;; 具体装饰（syntax/words/…）在 decor/ 下，本模块只管组合与写回。

(provide ensure-faces commit-faces!)

(require racket/list
         "face.rkt"
         "../core/world.rkt"
         "../content/adapter.rkt"
         "../content/model.rkt")

;;; ---------- 组合子（纯） ----------

;; 一个格子的最终 face：把各层在同一位置的 face 逐个 compose。
;; foldl 的回调是 (proc elem acc)；face-compose 的形参是 (old new)（new 叠在 old 上），
;; 所以必须写 (face-compose acc elem)：累加值当底、当前层当顶。
;; 否则累加出的 face-stack 会被当成一层嵌套进去，face->style 不认嵌套 → 整段高亮掉色。
(define (cell-face layers ln i)
  (foldl (lambda (elem acc) (face-compose acc elem)) #f
         (for/list ([layer (in-list layers)] #:when (< ln (length layer)))
           (define lv (list-ref layer ln))
           (and (< i (vector-length lv)) (vector-ref lv i)))))

;; 一行向量 → 填充段
(define (vec->fills ln vec)
  (for/list ([r (in-list (face-runs vec))]) (list ln (car r) ln (cadr r) (caddr r))))

;;; ---------- 投影 ----------

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
(define (doc-fills decors w did vid)
  (define c (world-content w))
  (define ed (content-ed c))
  (define text (document-string ed did))
  (define path (doc-path (content-doc-meta c did)))
  (define cursor (cons (view-line ed vid) (view-col ed vid)))
  (define lines (string-split text "\n"))
  (define layers (map (lambda (d) (d path text cursor)) decors))
  (append*
   (for/list ([ln (in-range (length lines))])
     (define len (string-length (list-ref lines ln)))
     (vec->fills ln (for/vector ([i (in-range len)]) (cell-face layers ln i))))))

;; ensure-faces : cache decors world -> (values cache (listof (list did fills)))
(define (ensure-faces cache decors w)
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
         [else (values (hash-set cache did k) (cons (list did (doc-fills decors w did vid)) projs))]))]))

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
