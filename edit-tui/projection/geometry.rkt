#lang racket

;;; edit-tui-rebuild/projection/geometry.rkt —— layout-solve -> core panel（纯）
;;;
;;; 两类投影：
;;;   layout->render-panels  渲染用：view = panel-content.active（+ 焦点框，见 borders.rkt）
;;;   layout->hit-panels     命中 / 方向导航用：view = app panel-id（不含焦点框）
;;;
;;; 另外提供鼠标内容区命中（去掉边框的相对坐标）。
;;; 几何、固定尺寸、隐藏、兄弟吸收在 layout/solve.rkt / layout/ops.rkt。

(require racket/list
         (prefix-in l: "../layout/tree.rkt")
         (prefix-in l: "../layout/solve.rkt")
         (prefix-in p: "../panel/model.rkt")
         "../../core/view/base/rect.rkt"
         "../../core/view/panel.rkt"
         "borders.rkt")

(provide layout->render-panels
         layout->hit-panels
         layout-content-hit)

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
  (define frame (make-focus-frame layout solution borders panels focus-panel focus-face))
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
(define (layout-content-hit layout area row col)
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
