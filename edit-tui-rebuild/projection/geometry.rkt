#lang racket

;;; edit-tui-rebuild/projection/geometry.rkt —— layout pass → core panel 列表（纯）
;;;
;;; 两类投影：
;;;   layout->panels      渲染用：view = panel-content.active
;;;   layout->hit-panels  命中 / 方向导航用：view = app panel-id
;;;
;;; 几何、固定尺寸、隐藏、兄弟吸收都在 model/layout.rkt 的 layout-pass 里。
;;; 本模块只把 rect + panel 资源拼成 core panel。

(provide layout->panels
         layout->hit-panels
         layout->rects)

(require (prefix-in l: "../model/layout.rkt")
         (prefix-in p: "../model/panel.rkt")
         "../../core/view/base/rect.rkt"
         "../../core/view/panel.rkt")

(define (layout->panels layout area)
  (define pass (l:layout-pass layout area))
  (for/list ([id (in-list (l:layout-visible-panel-ids layout))])
    (define panel (l:layout-panel layout id))
    (define r (hash-ref (l:pass-rects pass) id))
    (make-panel (p:panel-view panel)
                r
                (p:panel-borders panel)
                #:face (p:panel-face panel)
                #:weight (p:panel-weight panel))))

(define (layout->hit-panels layout area)
  (define pass (l:layout-pass layout area))
  (for/list ([id (in-list (l:layout-visible-panel-ids layout))])
    (define panel (l:layout-panel layout id))
    (define r (hash-ref (l:pass-rects pass) id))
    (make-panel id
                r
                (p:panel-borders panel)
                #:face (p:panel-face panel)
                #:weight (p:panel-weight panel))))

(define (layout->rects layout area)
  (l:layout-rects layout area))
