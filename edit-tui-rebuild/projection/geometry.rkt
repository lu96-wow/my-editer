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

(require (prefix-in l: "../layout/model.rkt")
         (prefix-in p: "../panel/model.rkt")
         "../../core/view/base/rect.rkt"
         "../../core/view/panel.rkt")

(define (layout->render-panels layout area
                                #:view-object [view-object (λ (v) v)])
  (define solution (l:layout-solve layout area))
  (for/list ([id (in-list (l:layout-visible-panel-ids layout))])
    (define panel (l:layout-panel layout id))
    (define r (hash-ref (l:layout-solution-panel-rects solution) id))
    (make-panel (view-object (p:panel-view panel))
                r
                (p:panel-borders panel)
                #:face (p:panel-face panel)
                #:weight (p:panel-weight panel))))

(define (layout->hit-panels layout area)
  (define solution (l:layout-solve layout area))
  (for/list ([id (in-list (l:layout-visible-panel-ids layout))])
    (define panel (l:layout-panel layout id))
    (define r (hash-ref (l:layout-solution-panel-rects solution) id))
    (make-panel id
                r
                (p:panel-borders panel)
                #:face (p:panel-face panel)
                #:weight (p:panel-weight panel))))
