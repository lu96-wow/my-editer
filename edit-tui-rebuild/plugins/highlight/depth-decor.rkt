#lang racket

;;; layer  : plugins/highlight
;;; effect : 无（纯：text -> state/layer）
;;;
;;; depth-decor.rkt —— 括号深度背景 decor（增量）
;;;
;;; open   : 整篇扫，得到逐行括号栈 + 每格背景 face
;;; change : 从首个脏行带括号栈重扫到状态收敛
;;;
;;; 适用性由 face-decor 的 applies? 判断（Racket 文件）。层名 = depth-bg。

(provide depth-face-decor)

(require "../../model/face-decor.rkt"
         "../../model/face-layer.rkt"
         "kind.rkt"
         "depth.rkt")

(define (wrap-bg x) (and x (face-set-bg face-empty x)))

(define (scan-line stack _ln line)
  (define-values (stack* vec) (depth-line stack line))
  (values stack* (for/vector ([x (in-vector vec)]) (wrap-bg x))))

(define (depth-open _path text)
  (define-values (states layers _st)
    (for/fold ([ss '()] [ls '()] [st '()])
              ([line (in-list (track->list text))] [ln (in-naturals)])
      (define-values (st* vec) (scan-line st ln line))
      (values (cons st* ss) (cons vec ls) st*)))
  (values (track-of-list (reverse states))
          (track-of-list (reverse layers))))

(define (depth-change state layer ctx)
  (define changes (face-ctx-changes ctx))
  (cond
    [(null? changes)
     (values state layer (dirty-lines '()))]
    [else
     (define-values (state* layer* dirty)
       (stateful-advance state layer (face-ctx-new-text ctx) changes
                         scan-line '()))
     (values state* layer* dirty)]))

(define depth-face-decor
  (face-decor 'depth 'depth-bg racket-doc-meta? depth-open depth-change))
