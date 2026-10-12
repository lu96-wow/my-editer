#lang racket

;;; edit4/core/pointer.rkt —— 指针 / 拖拽命令
;;;
;;; 拖拽 = World.drag 里的一个快照 + 三个命令（press/move/release）。
;;; move 只依赖「按下快照 + 总位移」，所以幂等、不漂；不在拖拽时让位（#f），
;;; 于是拖拽天然抢占（base 条目排在前）。
;;;
;;; 命中统一走 layout/frame.rkt 的 hit-frame（浮窗 z 优先，再平铺的缝 / 内容）。

(provide pointer-commands)

(require racket/match
         "event.rkt" "world.rkt" "command.rkt" "drag.rkt"
         "../layout.rkt")

(define (h-pointer-press ctx world args)
  (define fr (ctx-frame ctx))
  (cond
    [(not fr) #f]
    [else
     (define ev (ctx-event ctx))
     (define x (cursor-event-x ev))
     (define y (cursor-event-y ev))
     (define t (hit-frame fr x y))
     (cond
       [(not t) #f]
       [(pane-target? t) (cons (world-set-focus world (pane-target-id t)) '())]
       [(seam-target? t)
        (define cuts (seam-target-cuts t))
        (cons (world-set-drag world
                              (dragging x y (list 'cut (segs-of-axis cuts 'x) (segs-of-axis cuts 'y))))
              '())]
       [(float-target? t)
        (define id (float-target-id t))
        (define act (float-target-action t))
        (define f0 (float-by-id (world-floats world) id))
        (cond
          [(not f0) #f]
          [else
           (define rel0 (frame-rel-rect fr f0))
           (cons (world-set-drag (world-set-focus world id)
                                 (dragging x y (list 'float id act f0 rel0)))
                 '())])]
       [else #f])]))

(define (h-pointer-move ctx world args)
  (define d (world-drag world))
  (cond
    [(not (dragging? d)) #f]                       ; 不在拖拽 → 让位
    [else
     (define ev (ctx-event ctx))
     (define dx (- (cursor-event-x ev) (dragging-start-x d)))
     (define dy (- (cursor-event-y ev) (dragging-start-y d)))
     (match (dragging-target d)
       [(list 'cut xs ys)
        (define moves (append (move-cut xs dx) (move-cut ys dy)))
        (cons (world-set-layout
               world
               (for/fold ([t (world-layout world)]) ([m (in-list moves)])
                 (set-sizes t (car m) (cadr m))))
              '())]
       [(list 'float id act f0 rel0)
        (define w (car (ctx-size ctx)))
        (define h (cdr (ctx-size ctx)))
        (define f* (if (eq? act 'move)
                       (move-float* f0 dx dy)
                       (resize-float* f0 act dx dy rel0 w h)))
        (cons (world-set-floats world (set-float (world-floats world) id f*)) '())]
       [_ #f])]))

(define (h-pointer-release ctx world args)
  (cond
    [(dragging? (world-drag world)) (cons (world-set-drag world (idle)) '())]
    [else #f]))

(define (h-pointer-scroll ctx world args) #f)      ; 先靠边：让位

(define pointer-commands
  (make-command-registry
   (list (cons 'pointer-press h-pointer-press)
         (cons 'pointer-move h-pointer-move)
         (cons 'pointer-release h-pointer-release)
         (cons 'pointer-scroll h-pointer-scroll))))
