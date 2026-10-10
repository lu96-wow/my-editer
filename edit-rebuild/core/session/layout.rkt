#lang racket

;;; edit-rebuild/core/session/layout.rkt —— 由注册的停靠面构造骨架 bindings（通用组合）
;;;
;;; 局部问题：把「谁在哪个 region」的声明（每个 dock 面的 placement）变成骨架 slot 的
;;; 内容（region → stack(leaf vid)）。布局**形状**在 config/layout.rkt；这里只把面归位。

(require racket/list
         "session.rkt"
         "../surface/surface.rkt"
         "../geometry/layout.rkt"
         "../ids.rkt")

(provide session-region-bindings session-first-panel-vid session-init-region-visibility)

(define (session-dock-list s)
  (for/list ([sf (in-list (session-surfaces s))] #:when (surface-dock? sf)) sf))

;; region → (stack (leaf vid) …)，面注册顺序即列表顺序。
(define (session-region-bindings s)
  (define dock (session-dock-list s))
  (define regions (remove-duplicates (for/list ([sf (in-list dock)])
                                       (dock-region (surface-placement sf)))))
  (for/hash ([r (in-list regions)])
    (values r (stack (for/list ([sf (in-list dock)]
                               #:when (eq? r (dock-region (surface-placement sf))))
                       (leaf (surface-vid sf)))))))

;; 首个停靠面的 vid（优先 slot-side），供装配设初始焦点。
(define (session-first-panel-vid s)
  (define dock (session-dock-list s))
  (define side (for/first ([sf (in-list dock)]
                           #:when (eq? (dock-region (surface-placement sf)) slot-side)) sf))
  (define chosen (or side (and (pair? dock) (first dock)) #f))
  (and chosen (surface-vid chosen)))

;; 每个 region 初始只显示第一个面（其余隐藏）——同区域互斥的初始态。
(define (session-init-region-visibility s)
  (define dock (session-dock-list s))
  (define regions (remove-duplicates (for/list ([sf (in-list dock)])
                                       (dock-region (surface-placement sf)))))
  (for/fold ([s s]) ([r (in-list regions)])
    (define members (for/list ([sf (in-list dock)]
                              #:when (eq? r (dock-region (surface-placement sf)))) sf))
    (for/fold ([s s]) ([sf (in-list members)] [i (in-naturals)])
      (session-set-visible s (surface-vid sf) (zero? i)))))
