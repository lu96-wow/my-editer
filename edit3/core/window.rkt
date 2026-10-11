#lang racket

;;; edit3/window.rkt —— 窗口查询与手术：wid（平铺或浮窗）↔ vid
;;;
;;; 平铺窗与浮窗同构（都是 wid + vid），所以焦点、命中、编辑、改 vid 共用一套入口。
;;; 本模块只看 State 的 tiling/floats，不知道「面板」是什么（那在 panels.rkt）。

(provide wid-vid focused-vid
         wid-float? float-wid-of-vid
         all-wids wid-of-vid has-vid? has-wid?
         set-wid-vid remove-wid*
         wid-border set-wid-border)

(require "state.rkt" "layout.rkt" "resize.rkt" racket/list)

(define (wid-vid st w)
  (cond
    [(not w) #f]
    [(layout-tile-vid (state-tiling st) w)]
    [else (define f (float-by-id (state-floats st) w)) (and f (float-vid f))]))

(define (focused-vid st) (wid-vid st (state-focus st)))

;; 某 wid 是否是浮窗。
(define (wid-float? st w)
  (and w (float-by-id (state-floats st) w) #t))

;; 显示某 vid 的第一个浮窗 wid（没有 → #f）。
(define (float-wid-of-vid st v)
  (for/first ([f (in-list (state-floats st))] #:when (eqv? v (float-vid f)))
    (float-wid f)))

;; 平铺树 + 浮窗里的所有 wid（平铺在前，浮窗按 z 从底到顶）。
(define (all-wids st)
  (append (node-wids (tiling-root (state-tiling st)))
          (reverse (map float-wid (state-floats st)))))

;; 显示某 vid 的第一个窗口 wid（平铺优先，再浮窗；没有 → #f）。
(define (wid-of-vid st vid)
  (or (layout-wid-of-vid (state-tiling st) vid)
      (float-wid-of-vid st vid)))

(define (has-vid? st vid)
  (and (wid-of-vid st vid) #t))

;; 某 wid 是否还在窗口集合里（平铺或浮窗）。
(define (has-wid? st w)
  (and (memv w (all-wids st)) #t))

;; 某 wid 的边框 face（平铺 tile 或浮窗；无 → #f）。
(define (wid-border st w)
  (cond
    [(not w) #f]
    [(float-by-id (state-floats st) w) => float-border]
    [else (layout-tile-border (state-tiling st) w)]))

;; 设某 wid 的边框（#f = 关；命名 face = 开）。
(define (set-wid-border st w border)
  (cond
    [(float-by-id (state-floats st) w)
     (struct-copy state st
                  [floats (set-float (state-floats st) w
                                     (struct-copy float (float-by-id (state-floats st) w)
                                                  [border border]))])]
    [else
     (define (go node)
       (cond
         [(not node) node]
         [(tile? node) (if (eqv? w (tile-wid node)) (struct-copy tile node [border border]) node)]
         [(split? node) (split (split-axis node)
                               (for/list ([it (in-list (split-items node))])
                                 (struct-copy item it [child (go (item-child it))])))]
         [else node]))
     (struct-copy state st [tiling (tiling (go (tiling-root (state-tiling st))))])]))

;; 改某 wid 显示的 vid（平铺窗或浮窗，不动位置/尺寸）。
(define (set-wid-vid st w vid)
  (cond
    [(float-by-id (state-floats st) w)
     (struct-copy state st
                  [floats (set-float (state-floats st) w
                                     (struct-copy float (float-by-id (state-floats st) w)
                                                  [vid vid]))])]
    [else (struct-copy state st
                       [tiling (layout-set-tile-vid (state-tiling st) w vid)])]))

;; 摘掉一个窗口（平铺 tile 或浮窗）；焦点交给调用方。
(define (remove-wid* st w)
  (cond
    [(float-by-id (state-floats st) w)
     (struct-copy state st
                  [floats (filter (lambda (f) (not (eqv? w (float-wid f)))) (state-floats st))])]
    [else (struct-copy state st [tiling (layout-remove-wid (state-tiling st) w)])]))
