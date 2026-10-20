#lang racket

;;; edit-tui-rebuild/projection/geometry.rkt —— layout-solve → core panel 列表（纯）
;;;
;;; 两类投影：
;;;   layout->render-panels      渲染用：view = panel-content.active
;;;                              + 焦点框（见下）
;;;   layout->hit-panels  命中 / 方向导航用：view = app panel-id
;;;                              （不含焦点框：焦点框不可点）
;;;
;;; 几何、固定尺寸、隐藏、兄弟吸收都在 layout/model.rkt 的 layout-solve 里。
;;; 本模块只把 rect + panel 资源拼成 core panel。

(provide layout->render-panels
         layout->hit-panels
         layout-content-hit-at)

(require racket/list
         (prefix-in l: "../layout/model.rkt")
         (prefix-in p: "../panel/model.rkt")
         "../../core/view/base/rect.rkt"
         "../../core/view/panel.rkt")

;;; ---------- 共享边框 ----------
;;;
;;; 相邻 panel 不各画一条边，而是共享一列 / 一行：
;;; 左 / 上边的 panel 保留 right / down 边框，右 / 下边的 panel 去掉 left / up。
;;; 这样不会出现双线，也不改变 rect。

(define (edge-panels l n side)
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
               (if lv? (edge-panels l lc 'left) (edge-panels l rc 'left))]
              [else
               (append (if lv? (edge-panels l lc 'left) '())
                       (if rv? (edge-panels l rc 'left) '()))])]
       [(right)
        (cond [(eq? axis 'lr)
               (if rv? (edge-panels l rc 'right) (edge-panels l lc 'right))]
              [else
               (append (if lv? (edge-panels l lc 'right) '())
                       (if rv? (edge-panels l rc 'right) '()))])]
       [(up)
        (cond [(eq? axis 'tb)
               (if lv? (edge-panels l lc 'up) (edge-panels l rc 'up))]
              [else
               (append (if lv? (edge-panels l lc 'up) '())
                       (if rv? (edge-panels l rc 'up) '()))])]
       [(down)
        (cond [(eq? axis 'tb)
               (if rv? (edge-panels l rc 'down) (edge-panels l lc 'down))]
              [else
               (append (if lv? (edge-panels l lc 'down) '())
                       (if rv? (edge-panels l rc 'down) '()))])]
       [else (error 'edge-panels "未知 side：~a" side)])]))

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
           (define left-edge (edge-panels layout lc 'right))
           (define right-edge (edge-panels layout rc 'left))
           (when (for/or ([id (in-list left-edge)])
                   (memq 'right (hash-ref h id '())))
             (for ([id (in-list right-edge)])
               (hash-set! h id (remove 'left (hash-ref h id '())))))]
          [(tb)
           (define top-edge (edge-panels layout lc 'down))
           (define bottom-edge (edge-panels layout rc 'up))
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

(define (focus-frame layout solution borders panels focus-id face)
  (and focus-id
       (l:layout-panel-visible? layout focus-id)
       (let-values ([(r sides) (focus-frame-geometry layout solution borders focus-id)])
         (and r
              (empty-panel r sides
                           #:face face
                           ;; 比所有 core panel 的边框权重都大 -> 缝上也赢
                           #:weight (add1 (for/fold ([m 0]) ([cp (in-list panels)])
                                            (max m (panel-weight cp)))))))))

(define (layout->render-panels layout area
                                #:view-object [view-object (λ (v) v)]
                                #:focus-panel [focus-panel #f]
                                #:focus-face [focus-face 'focused-border])
  (define solution (l:layout-solve layout area))
  (define borders (effective-borders layout))
  (define panels
    (for/list ([id (in-list (l:layout-visible-panel-ids layout))])
      (define panel (l:layout-panel layout id))
      (define r (hash-ref (l:layout-solution-panel-rects solution) id))
      (make-panel (view-object (p:panel-view panel))
                  r
                  (hash-ref borders id '())
                  #:face (p:panel-face panel)
                  #:weight (p:panel-weight panel))))
  ;; 焦点框放最后：同 weight 时列表靠后也赢（这里 weight 已经更大）
  (define frame (focus-frame layout solution borders panels focus-panel focus-face))
  (if frame (append panels (list frame)) panels))

(define (layout->hit-panels layout area)
  (define solution (l:layout-solve layout area))
  (define borders (effective-borders layout))
  (for/list ([id (in-list (l:layout-visible-panel-ids layout))])
    (define panel (l:layout-panel layout id))
    (define r (hash-ref (l:layout-solution-panel-rects solution) id))
    (make-panel id
                r
                (hash-ref borders id '())
                #:face (p:panel-face panel)
                #:weight (p:panel-weight panel))))

;;; ---------- 内容区命中（鼠标点 buffer） ----------
;;;
;;; → (values panel-id row col) | (values #f #f #f)
;;; row / col 是相对内容区的 0 基坐标（已去掉边框），可直接喂给
;;; core 的 view-screen-position->point。点在边框 / 接缝上返回 #f。
(define (layout-content-hit-at layout area row col)
  (define solution (l:layout-solve layout area))
  (define borders (effective-borders layout))
  (let loop ([ids (l:layout-visible-panel-ids layout)])
    (cond
      [(null? ids) (values #f #f #f)]
      [else
       (define id (car ids))
       (define r (hash-ref (l:layout-solution-panel-rects solution) id #f))
       (define bs (hash-ref borders id '()))
       (define content
         (and r
              (rect-inset-sides r
                                (if (memq 'up bs) 1 0)
                                (if (memq 'right bs) 1 0)
                                (if (memq 'down bs) 1 0)
                                (if (memq 'left bs) 1 0))))
       (cond
         [(and content (rect-contains? content col row))
          (values id (- row (rect-y content)) (- col (rect-x content)))]
         [else (loop (cdr ids))])])))
