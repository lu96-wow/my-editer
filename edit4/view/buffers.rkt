#lang racket

;;; edit4/view/buffers.rkt —— 文档管理面板（buffers）：纯投影
;;;
;;; 文档行：▾ 展开 / ▸ 折叠 / 空（无视图）；视图行：● 已显示 / · 未显示。

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
  (define ed (content-ed c))
  (define rows (buffer-rows w))
  (define folded (content-fold c))
  (define focus-did
    (let ([fv (and (world-focus w) (content-vid-of c (world-focus w)))])
      (and fv (content-did-of c fv))))
  (define lines
    (for/list ([r (in-list rows)])
      (define did (car r))
      (define vid (cadr r))
      (define label (caddr r))
      (define depth (list-ref r 3))
      (define kind (list-ref r 4))
      (define marker
        (cond
          [(eq? kind 'view) (if (bound-vid? c vid) "● " "· ")]
          [(null? (document-view-list ed did)) "  "]
          [(hash-has-key? folded did) "▸ "]
          [else "▾ "]))
      (string-append (make-string (* 2 depth) #\space) marker label)))
  (values (string-join lines "\n")
          (for/list ([r (in-list rows)] [i (in-naturals)])
            (define did (car r))
            (define kind (list-ref r 4))
            (define m (content-doc-meta c did))
            (cons i (cond
                      [(doc-dirty? c did) 'buf-dirty]
                      [(eqv? did focus-did) 'buf-current]
                      [(not (and m (doc-path m))) 'buf-untitled]
                      [(eq? kind 'doc) 'buf-file]
                      [else 'buf-view])))))
