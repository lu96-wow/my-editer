#lang racket

;;; edit4/view/buffers.rkt —— 文档管理面板（buffers）：纯投影
;;;
;;; 文档行在左；其视图作为子行缩进两格，靠缩进 + 颜色区分（与文件树一致，不加符号）。
;;; 文档行颜色看状态（dirty / 当前 / 未命名 / 有路径）；视图行看是否已绑到窗口。

(provide buffers-content)

(require racket/list
         "../core/world.rkt"
         "../content/model.rkt"
         "../content/adapter.rkt"
         "../content/buffers.rkt")

(define (bound-vid? c vid)
  (for/or ([v (in-hash-values (content-bindings c))]) (eqv? v vid)))

(define (buffers-content w v)
  (define c (world-content w))
  (define rows (buffer-rows w))
  (define focus-did
    (let ([fv (and (world-focus w) (content-vid-of c (world-focus w)))])
      (and fv (content-did-of c fv))))
  (define lines
    (for/list ([r (in-list rows)])
      (define label (caddr r))
      (define depth (list-ref r 3))
      (string-append (make-string (* 2 depth) #\space) label)))
  (values (string-join lines "\n")
          (for/list ([r (in-list rows)] [i (in-naturals)])
            (define did (car r))
            (define vid (cadr r))
            (define kind (list-ref r 4))
            (define m (content-doc-meta c did))
            (cons i (cond
                      [(eq? kind 'view) (if (bound-vid? c vid) 'buf-view 'buf-view-idle)]
                      [(doc-dirty? c did) 'buf-dirty]
                      [(eqv? did focus-did) 'buf-current]
                      [(not (and m (doc-path m))) 'buf-untitled]
                      [else 'buf-file])))))
