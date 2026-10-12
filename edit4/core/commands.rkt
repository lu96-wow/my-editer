#lang racket

;;; edit4/core/commands.rkt —— 基础命令 + 基础键表/作用域
;;;
;;; 命令只调布局代数（split-leaf / remove-leaf / neighbor / move-cut / set-sizes）
;;; 与浮窗手术（move-float* / resize-float*），不认识事件；数据从 Ctx 取。

(provide base-commands base-keymap base-scopes)

(require racket/match
         "event.rkt" "world.rkt" "command.rkt" "keymap.rkt" "dispatch.rkt" "drag.rkt" "effect.rkt"
         "../layout.rkt")

;;; ---------- 窗口 / 焦点 ----------

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

(define (h-prefix ctx world args)
  (cons (world-set-prefix world (car args)) '()))

(define (h-cancel ctx world args)
  (cons (world-set-prefix world #f) '()))

;;; ---------- 指针（拖拽状态机） ----------

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

(define (h-quit ctx world args) (cons world (list (quit-effect))))

;;; ---------- 注册表 ----------

(define base-commands
  (make-command-registry
   (list (cons 'split h-split)
         (cons 'close h-close)
         (cons 'focus h-focus)
         (cons 'prefix h-prefix)
         (cons 'cancel h-cancel)
         (cons 'pointer-press h-pointer-press)
         (cons 'pointer-move h-pointer-move)
         (cons 'pointer-release h-pointer-release)
         (cons 'pointer-scroll h-pointer-scroll)
         (cons 'quit h-quit))))

;;; ---------- 基础键表 ----------

(define base-keymap
  (list (list '(key s ctrl) 'always (cmd 'prefix 'split))
        (list '(key escape) '(prefix split) (cmd 'cancel))
        (list '(key right) '(prefix split) (cmd 'split 'h 'after))
        (list '(key left)  '(prefix split) (cmd 'split 'h 'before))
        (list '(key down)  '(prefix split) (cmd 'split 'v 'after))
        (list '(key up)    '(prefix split) (cmd 'split 'v 'before))
        (list '(key d ctrl) 'always (cmd 'close))
        (list '(key n alt)  'always (cmd 'focus 'next))
        (list '(key p alt)  'always (cmd 'focus 'prev))
        (list '(key left alt)  'always (cmd 'focus 'left))
        (list '(key right alt) 'always (cmd 'focus 'right))
        (list '(key up alt)    'always (cmd 'focus 'up))
        (list '(key down alt)  'always (cmd 'focus 'down))
        (list '(key q ctrl) 'always (cmd 'quit))
        (list '(cursor press)   'always (cmd 'pointer-press))
        (list '(cursor move)    'always (cmd 'pointer-move))
        (list '(cursor release) 'always (cmd 'pointer-release))
        (list '(cursor scroll)  'always (cmd 'pointer-scroll))))

;;; ---------- 基础作用域（always / (prefix …) 是内置的） ----------

(define base-scopes (make-scope-registry '()))
