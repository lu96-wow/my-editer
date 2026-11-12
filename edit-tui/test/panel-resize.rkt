#lang racket

;;; sidebar fixed 边界可拖；C-b show 恢复旧尺寸并 clamp 到 min size。

(require rackunit
         "../editor/host-api.rkt"
         "../core/layout/api.rkt"
         "../host/layout.rkt")

(define area (rect 0 0 60 15))
(define config rebuild-layout-config)
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
