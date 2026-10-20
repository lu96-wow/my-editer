#lang racket

;;; edit-tui-rebuild/projection/borders.rkt —— 共享边框 + 焦点框（纯）
;;;
;;; 1. 共享边框：相邻 panel 不各画一条边，而是共享一列 / 一行：
;;;    左 / 上边的 panel 保留 right / down，右 / 下边的 panel 去掉 left / up。
;;;    这样不会出现双线，也不改变 rect；内容区按「去掉之后」的边内缩。
;;;
;;; 2. 焦点框：在焦点 panel 的边框格上叠一个空 core panel
;;;    （view = #f，face = focused-border，weight 比所有 panel 大），
;;;    core 对同一格按 weight 取边框 face。
;;;    共享边在 rect 外一格（邻居画的那格），所以框要外扩 1；
;;;    没有任何边框的边（屏幕外沿）不画，避免盖内容。
;;;
;;; 只产出 core panel / border 集合，不碰 State / engine / 渲染。

(require (prefix-in l: "../layout/tree.rkt")
         (prefix-in l: "../layout/solve.rkt")
         (prefix-in p: "../panel/model.rkt")
         "../../core/view/base/rect.rkt"
         "../../core/view/panel.rkt")

(provide effective-borders
         make-focus-frame)

;;; ---------- 共享边框 ----------
;;;
;;; 相邻 panel 不各画一条边，而是共享一列 / 一行：
;;; 左 / 上边的 panel 保留 right / down 边框，右 / 下边的 panel 去掉 left / up。
;;; 这样不会出现双线，也不改变 rect。

(define (panels-on-edge l n side)
  ;; side : 'left | 'right | 'up | 'down
  (cond
    [(not n) '()]
    [(l:leaf? n)
     (if (l:layout-subtree-visible? l n)
         (list (l:leaf-panel-id n))
         '())]
    [else
     (define axis (l:split-axis n))
     (define lc (l:split-left n))
     (define rc (l:split-right n))
     (define lv? (l:layout-subtree-visible? l lc))
     (define rv? (l:layout-subtree-visible? l rc))
     (case side
       [(left)
        (cond [(eq? axis 'lr)
               (if lv? (panels-on-edge l lc 'left) (panels-on-edge l rc 'left))]
              [else
               (append (if lv? (panels-on-edge l lc 'left) '())
                       (if rv? (panels-on-edge l rc 'left) '()))])]
       [(right)
        (cond [(eq? axis 'lr)
               (if rv? (panels-on-edge l rc 'right) (panels-on-edge l lc 'right))]
              [else
               (append (if lv? (panels-on-edge l lc 'right) '())
                       (if rv? (panels-on-edge l rc 'right) '()))])]
       [(up)
        (cond [(eq? axis 'tb)
               (if lv? (panels-on-edge l lc 'up) (panels-on-edge l rc 'up))]
              [else
               (append (if lv? (panels-on-edge l lc 'up) '())
                       (if rv? (panels-on-edge l rc 'up) '()))])]
       [(down)
        (cond [(eq? axis 'tb)
               (if rv? (panels-on-edge l rc 'down) (panels-on-edge l lc 'down))]
              [else
               (append (if lv? (panels-on-edge l lc 'down) '())
                       (if rv? (panels-on-edge l rc 'down) '()))])]
       [else (error 'panels-on-edge "未知 side：~a" side)])]))

(define (effective-borders layout)
  (define h (make-hash))
  (for ([p (in-list (l:layout-panel-resources layout))])
    (hash-set! h (p:panel-id p) (p:panel-borders p)))
  (define (walk n)
    (when (l:split? n)
      (define lc (l:split-left n))
      (define rc (l:split-right n))
      (define lv? (l:layout-subtree-visible? layout lc))
      (define rv? (l:layout-subtree-visible? layout rc))
      (when (and lv? rv?)
        (case (l:split-axis n)
          [(lr)
           (define left-edge (panels-on-edge layout lc 'right))
           (define right-edge (panels-on-edge layout rc 'left))
           (when (for/or ([id (in-list left-edge)])
                   (memq 'right (hash-ref h id '())))
             (for ([id (in-list right-edge)])
               (hash-set! h id (remove 'left (hash-ref h id '())))))]
          [(tb)
           (define top-edge (panels-on-edge layout lc 'down))
           (define bottom-edge (panels-on-edge layout rc 'up))
           (when (for/or ([id (in-list top-edge)])
                   (memq 'down (hash-ref h id '())))
             (for ([id (in-list bottom-edge)])
               (hash-set! h id (remove 'up (hash-ref h id '())))))]))
      (walk lc)
      (walk rc)))
  (walk (l:layout-root layout))
  h)

;;; ---------- 焦点框 ----------
;;;
;;; 高亮走 core 的边框合成：在焦点 panel 的边框格上再叠一个空 panel
;;; （view = #f，face = focused-border，weight 比所有 panel 都大），
;;; core 对同一格按 weight 取边框 face，于是焦点框赢。
;;;
;;; 边框格位置（共享边框：相邻 panel 只留一边，另一边的边由邻居画）：
;;;   自己画的边     -> 就在 rect 边上
;;;   被邻居共享的边 -> 缝在 rect 外一格（框外扩 1）
;;;   谁都没画的边   -> 不画（屏幕外沿 / 没有边框，画了会盖内容）
;;;
;;; 只改边框格 face：内容区、命中、layout 全不变。

(define (edge-overlap? a0 a1 b0 b1)
  (< (max a0 b0) (min a1 b1)))

(define (opposite-side side)
  (case side [(left) 'right] [(right) 'left] [(up) 'down] [else 'up]))

;; side 上的邻居 panel-id | #f
(define (neighbor-on-side rects id side)
  (define r (hash-ref rects id))
  (for/first ([(oid ro) (in-hash rects)]
              #:unless (eq? oid id)
              #:when
              (case side
                [(left) (and (= (rect-right ro) (rect-x r))
                             (edge-overlap? (rect-y r) (rect-bottom r)
                                            (rect-y ro) (rect-bottom ro)))]
                [(right) (and (= (rect-x ro) (rect-right r))
                              (edge-overlap? (rect-y r) (rect-bottom r)
                                             (rect-y ro) (rect-bottom ro)))]
                [(up) (and (= (rect-bottom ro) (rect-y r))
                           (edge-overlap? (rect-x r) (rect-right r)
                                          (rect-x ro) (rect-right ro)))]
                [(down) (and (= (rect-y ro) (rect-bottom r))
                             (edge-overlap? (rect-x r) (rect-right r)
                                            (rect-x ro) (rect-right ro)))]))
    oid))

;; → (values rect sides) | (values #f '())
(define (focus-frame-geometry layout solution borders id)
  (define rects (l:layout-solution-panel-rects solution))
  (define r (hash-ref rects id #f))
  (cond
    [(not r) (values #f '())]
    [else
     (define own (hash-ref borders id '()))
     (define (drawn? side)
       (or (memq side own)
           (let ([n (neighbor-on-side rects id side)])
             (and n (memq (opposite-side side) (hash-ref borders n '())) #t))))
     (define left? (drawn? 'left))
     (define right? (drawn? 'right))
     (define up? (drawn? 'up))
     (define down? (drawn? 'down))
     (define sides
       (filter values (list (and left? 'left) (and right? 'right)
                            (and up? 'up) (and down? 'down))))
     (cond
       [(null? sides) (values #f '())]
       [else
        (define x0 (if (and left? (not (memq 'left own)))
                       (sub1 (rect-x r))
                       (rect-x r)))
        (define y0 (if (and up? (not (memq 'up own)))
                       (sub1 (rect-y r))
                       (rect-y r)))
        (define x1 (if (and right? (not (memq 'right own)))
                       (add1 (rect-right r))
                       (rect-right r)))
        (define y1 (if (and down? (not (memq 'down own)))
                       (add1 (rect-bottom r))
                       (rect-bottom r)))
        (values (rect x0 y0 (- x1 x0) (- y1 y0)) sides)])]))

(define (make-focus-frame layout solution borders panels focus-id face)
  (and focus-id
       (l:layout-panel-visible? layout focus-id)
       (let-values ([(r sides) (focus-frame-geometry layout solution borders focus-id)])
         (and r
              (empty-panel r sides
                           #:face face
                           ;; 比所有 core panel 的边框权重都大 -> 缝上也赢
                           #:weight (add1 (for/fold ([m 0]) ([cp (in-list panels)])
                                            (max m (panel-weight cp)))))))))
