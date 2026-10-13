#lang racket

;;; edit3/face-plugin.rkt —— face 插件协议 + 每文档刷新（简化：整篇重扫）
;;;
;;;   face-plugin : name + applies? + scan
;;;     applies? : path text -> boolean          该文档是否适用
;;;     scan     : path text cursor -> (listof (vectorof face))   每行一个 face 向量
;;;
;;; 一个文档可以挂多个 face 插件：每行按插件顺序 `face-compose` 叠成最终 face，再写成
;;; 引擎的 face 区间。整篇重扫（edit/ 的按行增量缓存见其 face/line-scan.rkt，将来可换）。
;;;
;;; 刷新时机由核心驱动：打开文档 / 编辑后 / 移动光标后。

(provide (struct-out face-plugin) refresh-doc-faces! refresh-faces-vid!)

(require racket/string
         "state.rkt" "adapter.rkt" "face.rkt")

;; scan : path text cursor -> (listof (vectorof face))
(struct face-plugin (name applies? scan) #:transparent)

(define (refresh-doc-faces! st did v)
  (define m (hash-ref (state-docs st) did #f))
  (define path (and m (doc-meta-path m)))
  (define ed (state-ed st))
  (define text (document-string ed did))
  (define lines (string-split text "\n"))
  (define n (length lines))
  (define cursor (and v (cons (view-line ed v) (view-col ed v))))
  (define plugins (for/list ([p (in-list (feature-ref st 'faces '()))]
                             #:when ((face-plugin-applies? p) path text))
                    p))
  (define layers (for/list ([p (in-list plugins)]) ((face-plugin-scan p) path text cursor)))
  (define fills
    (append*
     (for/list ([ln (in-range n)])
       (define len (string-length (list-ref lines ln)))
       (define vec (make-vector len #f))
       (for ([layer (in-list layers)])
         (when (< ln (length layer))
           (define lv (list-ref layer ln))
           (define mlen (min len (vector-length lv)))
           (for ([i (in-range mlen)])
             (define f (vector-ref lv i))
             (when f (vector-set! vec i (face-compose (vector-ref vec i) f))))))
       (for/list ([r (in-list (face-runs vec))])
         (list ln (car r) ln (cadr r) (caddr r))))))
  ;; 先清整篇旧 face（一行一个 fill），再写新 face。
  (face-batch! ed did (for/list ([ln (in-range n)])
                        (list ln 0 ln (string-length (list-ref lines ln)) #f)))
  (when (pair? fills) (face-batch! ed did fills))
  st)

;; 焦点视频所在的文档刷新；只对「有路径 + 有 face 插件」的文档动（不碰面板）。
(define (refresh-faces-vid! st v)
  (define did (and v (view-did (state-ed st) v)))
  (define m (and did (hash-ref (state-docs st) did #f)))
  (when (and did (and m (doc-meta-path m)) (pair? (feature-ref st 'faces '())))
    (refresh-doc-faces! st did v))
  st)
