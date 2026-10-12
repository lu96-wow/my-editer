#lang racket

;;; edit4/core/window.rkt —— 窗口 / 焦点 / 前缀 / 退出命令
;;;
;;; 只调布局代数（split-leaf / remove-leaf / neighbor）；不认识事件本身。
;;; 需要几何时从 Ctx.frame 取（neighbor 走 frame 的平铺几何）。

(provide window-commands)

(require racket/match
         "world.rkt" "command.rkt" "effect.rkt"
         "../layout.rkt")

(define (h-split ctx world args)
  (match-define (list axis side) args)
  (define id (world-focus world))
  (cond
    [(not id) #f]
    [else
     (define lay (world-layout world))
     (define nid (fresh-id lay))
     (define nl (split-leaf lay id axis side (leaf nid (cons 2 2))))
     (cons (world-set-focus (world-set-layout world nl) nid) '())]))

(define (h-close ctx world args)
  (define id (world-focus world))
  (cond
    [(not id) #f]
    [else
     (define nl (remove-leaf (world-layout world) id))
     (define ws (ids nl))
     (cons (world-set-focus (world-set-layout world nl)
                            (if (pair? ws) (car ws) #f))
           '())]))

(define (h-focus ctx world args)
  (define target (car args))
  (define lay (world-layout world))
  (define all (ids lay))
  (define cur (world-focus world))
  (cond
    [(memq target '(next prev))
     (cond
       [(null? all) #f]
       [else
        (define n (length all))
        (define i (or (for/first ([x (in-list all)] [k (in-naturals)] #:when (eqv? x cur)) k) 0))
        (define j (if (eq? target 'next) (modulo (add1 i) n) (modulo (sub1 i) n)))
        (cons (world-set-focus world (list-ref all j)) '())])]
    [(memq target '(left right up down))
     (define fr (ctx-frame ctx))
     (cond
       [(not fr) #f]
       [else
        (define nid (neighbor (frame-tiled fr) cur target))
        (if nid (cons (world-set-focus world nid) '()) #f)])]
    [else (cons (world-set-focus world target) '())]))

(define (h-prefix ctx world args) (cons (world-set-prefix world (car args)) '()))
(define (h-cancel ctx world args) (cons (world-set-prefix world #f) '()))
(define (h-quit ctx world args) (cons world (list (quit-effect))))

(define window-commands
  (make-command-registry
   (list (cons 'split h-split)
         (cons 'close h-close)
         (cons 'focus h-focus)
         (cons 'prefix h-prefix)
         (cons 'cancel h-cancel)
         (cons 'quit h-quit))))
