#lang racket

;;; edit-tui-rebuild/render/layout.rkt —— layout -> core panels -> bytes
;;;
;;; 使用 layout 的投影 + core 的增量渲染：
;;;   layout->render-panels
;;;   render-display-patch
;;;   render-pieces

(require racket/bytes
         (only-in "../../core/editor.rkt" view? panels-sync!)
         "../../core/editor/render.rkt"
         "../base/api.rkt"
         "../layout/api.rkt"
         "../panel/api.rkt"
         "../projection/api.rkt"
         "core.rkt")

(provide render-layout
         layout-sync!)

;; → (values cache' bytes)
;; cache = #f 表示冷启动；非 #f 时做增量。
;; 把 panels 的尺寸落进 core view 的 viewport。
(define (layout-sync! layout area
                      #:view-object [view-object (λ (v) v)]
                      #:focus-panel [focus-panel #f])
  (define panels (layout->render-panels layout area
                                        #:view-object view-object
                                        #:focus-panel focus-panel))
  (panels-sync! panels)
  panels)

(define (render-layout layout area
                       #:focus-panel [focus-panel #f]
                       #:cache [cache #f]
                       #:sync? [sync? #t]
                       #:view-object [view-object (λ (v) v)])
  (define panels
    (if sync?
        (layout-sync! layout area #:view-object view-object #:focus-panel focus-panel)
        (layout->render-panels layout area #:view-object view-object
                               #:focus-panel focus-panel)))
  (define focus-view
    (and focus-panel
         (let ([p (layout-panel layout focus-panel)])
           (and p
                (let ([v (view-object (panel-view p))])
                  (and (view? v) v))))))
  (define-values (cache* rows sels)
    (render-display-patch panels focus-view
                          (rect-w area) (rect-h area)
                          cache))
  (define out
    (bytes-append (if cache (bytes) (render-clear))
                  (render-pieces (append rows sels))))
  (values cache* out))
