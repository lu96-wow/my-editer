#lang racket

;;; edit/test/surface-test.rkt —— 面（surface）与输入上下文（纯）
;;;
;;;   raco test edit/test/surface-test.rkt

(require rackunit
         "../surface/surface.rkt"
         "../surface/context.rkt"
         "../core/keymap.rkt"
         "../command/key.rkt")

;;; ---------- surface 值 ----------

;; 停靠面：panel 是 dock 的一个实例
(define d (dock-surface 'tree 1 #f (kbd) 'side 'height 'flex))
(check-true (surface? d))
(check-true (surface-dock? d))
(check-false (surface-float? d))
(check-equal? (surface-id d) 'tree)
(check-equal? (surface-vid d) 1)
(check-equal? (surface-kind d) 'dock)
(check-true (dock? (surface-placement d)))
(check-equal? (dock-region (surface-placement d)) 'side)
(check-equal? (dock-axis (surface-placement d)) 'height)
(check-equal? (dock-size (surface-placement d)) 'flex)

;; 浮动面：overlay 是 float 的一个实例（pos 每帧算）
(define pos (lambda (_s) (list 5 3 20 6)))
(define f (float-surface 'complete 2 #f (float pos 1000) (kbd) #f #f #f))
(check-true (surface-float? f))
(check-false (surface-dock? f))
(check-true (float? (surface-placement f)))
(check-equal? ((float-pos (surface-placement f)) #f) (list 5 3 20 6))
(check-equal? (surface-id f) 'complete)

;;; ---------- 输入上下文 ----------

(define low  (kbd (key 'a 'ctrl) 'low))
(define high (kbd (key 'a 'ctrl) 'high))

;; 栈顶在前：先命中先赢
(check-equal? (context-lookup (list high low) (key 'a 'ctrl)) 'high)
(check-equal? (context-lookup (list low high) (key 'a 'ctrl)) 'low)
;; 落空 → #f
(check-equal? (context-lookup (list high low) (key 'b 'ctrl)) #f)
(check-equal? (context-lookup (list high low) #f) #f)
