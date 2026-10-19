#lang racket

;;; 同一 panel 区域里多个 view 的顺序切换。
;;; 文件树和资源管理面板共用一个 sidebar panel：views = (filetree resources)。

(require rackunit
         "../model/config.rkt"
         "../model/layout.rkt"
         "../model/panel.rkt"
         "../projection/geometry.rkt"
         "../../core/view/base/rect.rkt"
         (prefix-in c: "../../core/view/panel.rkt"))

(define area (rect 0 0 80 24))

(define (attach! l target dir p)
  (define-values (l* ok?) (layout-panel-attach l target dir p))
  (check-true ok?)
  l*)

(define (switch! l id view)
  (define-values (l* ok?) (layout-panel-set-active-view l id view))
  (check-true ok?)
  l*)

(define (cycle! l id [step 1])
  (define-values (l* ok?) (layout-panel-cycle-active-view l id step))
  (check-true ok?)
  l*)

;; sidebar：两个 view 共用一个 panel 区域
(define sidebar
  (make-panel 'sidebar 'sidebar
              #:views '(filetree resources)
              #:active 'filetree
              #:fixed-w 30
              #:borders '(right)))

(define editor (make-empty-editor-panel 'editor))
(define state (make-panel 'state 'status
                          #:views '(status-view)
                          #:active 'status-view
                          #:fixed-h 1))

(define l0 (make-layout #:root (leaf 'editor)
                        #:panels (hash 'editor editor)
                        #:focus 'editor))
(define l (attach! (attach! l0 'editor 'left sidebar) 'editor 'down state))

(define (view-of id)
  (for/first ([p (in-list (layout->render-panels l area))]
              #:when (equal? (c:panel-view p)
                             (c:panel-view p)))
    #f))

;; 初始 active
(check-equal? (layout-panel-view-ids l 'sidebar) '(filetree resources))
(check-equal? (layout-panel-active-view l 'sidebar) 'filetree)
(check-equal? (map c:panel-view (layout->render-panels l area))
              '(filetree #f status-view))

;; 顺序切换：filetree → resources → filetree
(define l1 (cycle! l 'sidebar))
(check-equal? (layout-panel-active-view l1 'sidebar) 'resources)
(check-equal? (map c:panel-view (layout->render-panels l1 area))
              '(resources #f status-view))
;; rect 不变
(check-equal? (hash-ref (layout-panel-rects l1 area) 'sidebar) (rect 0 0 30 24))

(define l2 (cycle! l1 'sidebar))
(check-equal? (layout-panel-active-view l2 'sidebar) 'filetree)

;; 反向 / 多步
(define l3 (cycle! l 'sidebar -1))
(check-equal? (layout-panel-active-view l3 'sidebar) 'resources)

;; 直接指定 active
(define l4 (switch! l 'sidebar 'resources))
(check-equal? (layout-panel-active-view l4 'sidebar) 'resources)

;; 不在 views 里的 view → 拒绝
(define-values (_l-no ok-no?) (layout-panel-set-active-view l 'sidebar 'nope))
(check-false ok-no?)

;; 空 panel 不能切换
(define l-empty (attach! l 'editor 'right
                         (make-empty-editor-panel 'empty)))
(define-values (_l-empty-cycle ok-empty?) (layout-panel-cycle-active-view l-empty 'empty))
(check-false ok-empty?)

(displayln "edit-tui-rebuild/test/switch.rkt: ok")
