#lang racket

;;; sidebar fixed 边界可拖；C-b show 恢复旧尺寸并 clamp 到 min size。

(require rackunit
         "../editor/host-api.rkt"
         "../core/layout/api.rkt"
         "../app/layout.rkt")

(define area (rect 0 0 60 15))
(define config default-layout-config)
(define layout (make-editor-layout #:editor-view 1
                                   #:status-view 2
                                   #:sidebar-view 3))

(define rects (layout-panel-rects layout area))
(check-equal? (rect-w (hash-ref rects 'filetree)) 24)

;; 拖 sidebar/editor 接缝：fixed 侧改 fixed-w，不改 ratio。
(define seam (layout-seam-at layout area 5 24))
(check-not-false seam)
(define d (layout-seam-drag-start layout area 5 24
                                  #:config config
                                  #:seam seam))
(check-not-false d)
(check-eq? (drag-fixed-side d) 'left)

(define-values (l1 ok1)
  (layout-seam-drag-move layout area d 5 30 #:config config))
(check-true ok1)
(check-equal? (layout-panel-fixed-size l1 'filetree 'lr) 30)
(check-equal? (rect-w (hash-ref (layout-panel-rects l1 area) 'filetree)) 30)

;; 往左拖过头：clamp 到 sidebar min-w = 8，不会把 panel 拖没。
(define d2 (layout-seam-drag-start l1 area 5 30 #:config config))
(check-not-false d2)
(define-values (l2 ok2)
  (layout-seam-drag-move l1 area d2 5 0 #:config config))
(check-true ok2)
(check-equal? (layout-panel-fixed-size l2 'filetree 'lr) 8)
(check-equal? (rect-w (hash-ref (layout-panel-rects l2 area) 'filetree)) 8)

;; hide / show：同一尺寸下恢复 30。
(define-values (hidden hidden-ok?)
  (layout-panel-hide l1 area 'filetree #:config config))
(check-true hidden-ok?)
(check-false (layout-panel-visible? hidden 'filetree))
(define-values (shown shown-ok?)
  (layout-panel-show hidden area 'filetree #:config config))
(check-true shown-ok?)
(check-equal? (rect-w (hash-ref (layout-panel-rects shown area) 'filetree)) 30)

;; 焦点 panel 自己的尺寸：left 变窄，right 变宽。
(define editor-w0 (rect-w (hash-ref (layout-panel-rects layout area) 'editor)))
(define-values (narrow narrow?)
  (layout-panel-resize layout area 'editor 'left #:config config))
(check-true narrow?)
(check-equal? (rect-w (hash-ref (layout-panel-rects narrow area) 'editor))
              (sub1 editor-w0))
(define-values (wide wide?)
  (layout-panel-resize layout area 'editor 'right #:config config))
(check-true wide?)
(check-equal? (rect-w (hash-ref (layout-panel-rects wide area) 'editor))
              (add1 editor-w0))

;; 缩到 min-w 时被 clamp。
(define-values (min-sidebar min-ok?)
  (layout-panel-resize layout area 'filetree 'left #:config config #:step 100))
(check-true min-ok?)
(check-equal? (rect-w (hash-ref (layout-panel-rects min-sidebar area) 'filetree)) 8)

;; 纵向：up 变高，down 变矮；docs 提供可见的 flex 兄弟。
(define tall-area (rect 0 0 60 30))
(define tall-layout
  (make-editor-layout #:editor-view 1
                      #:status-view 2
                      #:sidebar-view 3
                      #:docs-view 4))
(define editor-h0 (rect-h (hash-ref (layout-panel-rects tall-layout tall-area) 'editor)))
(define-values (taller taller?)
  (layout-panel-resize tall-layout tall-area 'editor 'up #:config config))
(check-true taller?)
(check-equal? (rect-h (hash-ref (layout-panel-rects taller tall-area) 'editor))
              (add1 editor-h0))
(define-values (shorter shorter?)
  (layout-panel-resize taller tall-area 'editor 'down #:config config))
(check-true shorter?)
(check-equal? (rect-h (hash-ref (layout-panel-rects shorter tall-area) 'editor))
              editor-h0)

;; 窗口缩小后 show：恢复尺寸被 clamp 到 min，不能消失。
(define small-area (rect 0 0 9 10))
(define-values (shown-small show-small-ok?)
  (layout-panel-show hidden small-area 'filetree #:config config))
(check-true show-small-ok?)
(check-equal? (rect-w (hash-ref (layout-panel-rects shown-small small-area)
                                'filetree))
              8)
(check-true (layout-valid? shown-small small-area config))

(displayln "edit-tui/test/panel-resize.rkt: ok")
