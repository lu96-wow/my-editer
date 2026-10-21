#lang racket

;;; edit-tui-rebuild/render/layout.rkt —— layout -> core panels -> bytes
;;;
;;; 使用 layout 的投影 + core 的增量渲染：
;;;   layout->render-panels
;;;   render-display-patch
;;;   render-pieces

(require racket/bytes
         (only-in "../../core/editor.rkt" view? panels-sync!)
         (prefix-in vp: "../../core/view/panel.rkt")
         "../../core/editor/render.rkt"
         "../core/base/api.rkt"
         "../core/layout/api.rkt"
         "../core/panel/api.rkt"
         "../core/projection/api.rkt"
         "core.rkt")

(provide render-layout
         layout-sync!
         make-overlay-panel)

;; → (values cache' bytes)
;; cache = #f 表示冷启动；非 #f 时做增量。
;; 把 panels 的尺寸落进 core view 的 viewport。
(define (layout-sync! layout area
                      #:view-object [view-object (λ (v) v)]
                      #:focus-panel [focus-panel #f]
                      #:solution [solution #f]
                      #:overlays [overlays '()])
  (define panels (append (layout->render-panels layout area
                                               #:view-object view-object
                                               #:focus-panel focus-panel
                                               #:solution solution)
                         overlays))
  (panels-sync! panels)
  panels)

;; overlay panel 不进入 layout 树：位置由调用方按光标计算，deep 高，压在所有平铺 panel 上。
(define (make-overlay-panel view rect
                            #:borders [borders '()]
                            #:face [face 'float-border]
                            #:weight [weight 100]
                            #:deep [deep 100])
  (vp:make-panel view rect borders #:face face #:weight weight #:deep deep))

(define (render-layout layout area
                       #:focus-panel [focus-panel #f]
                       #:cache [cache #f]
                       #:sync? [sync? #t]
                       #:view-object [view-object (λ (v) v)]
                       #:solution [solution #f]
                       #:panels [panels #f]
                       #:overlays [overlays '()])
  ;; panels 可以由 sync-ui/panels! 直接传入：本帧已经完成尺寸写回。
  (define panels*
    (cond
      [panels
       (unless (null? overlays) (panels-sync! overlays))
       (append panels overlays)]
      [sync?
       (layout-sync! layout area #:view-object view-object
                     #:focus-panel focus-panel #:solution solution
                     #:overlays overlays)]
      [else
       (append (layout->render-panels layout area #:view-object view-object
                                      #:focus-panel focus-panel
                                      #:solution solution)
               overlays)]))
  (define focus-view
    (and focus-panel
         (let ([p (layout-panel layout focus-panel)])
           (and p
                (let ([v (view-object (panel-view p))])
                  (and (view? v) v))))))
  (define-values (cache* rows sels)
    (render-display-patch panels* focus-view
                          (rect-w area) (rect-h area)
                          cache))
  (define out
    (bytes-append (if cache (bytes) (render-clear))
                  (render-pieces (append rows sels))))
  (values cache* out))
