#lang racket

;;; edit-tui-rebuild/projection/geometry.rkt —— layout-solve → core panel 列表（纯）
;;;
;;; 两类投影：
;;;   layout->render-panels      渲染用：view = panel-content.active
;;;   layout->hit-panels  命中 / 方向导航用：view = app panel-id
;;;
;;; 几何、固定尺寸、隐藏、兄弟吸收都在 layout/model.rkt 的 layout-solve 里。
;;; 本模块只把 rect + panel 资源拼成 core panel。

(provide layout->render-panels
         layout->hit-panels)

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

(define (layout->render-panels layout area
                                #:view-object [view-object (λ (v) v)])
  (define solution (l:layout-solve layout area))
  (define borders (effective-borders layout))
  (for/list ([id (in-list (l:layout-visible-panel-ids layout))])
    (define panel (l:layout-panel layout id))
    (define r (hash-ref (l:layout-solution-panel-rects solution) id))
    (make-panel (view-object (p:panel-view panel))
                r
                (hash-ref borders id '())
                #:face (p:panel-face panel)
                #:weight (p:panel-weight panel))))

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
