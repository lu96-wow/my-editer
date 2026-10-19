#lang racket

;;; 统一 API 面冒烟测试：只 require edit-tui-rebuild/main.rkt。

(require rackunit
         "../main.rkt")

(define area (rect 0 0 80 24))

(define (attach! l target dir p)
  (define-values (l* ok?) (layout-panel-attach l target dir p))
  (check-true ok?)
  l*)

(define ft (make-panel 'filetree 'sidebar
                       #:views '(filetree resources)
                       #:active 'filetree
                       #:fixed-w 30
                       #:borders '(right)))
(define st (make-panel 'state 'status
                       #:views '(status-view)
                       #:active 'status-view
                       #:fixed-h 1))
(define ed (make-empty-editor-panel 'editor))

(define l0 (make-layout #:root (make-leaf 'editor)
                        #:panels (hash 'editor ed)
                        #:focus 'editor))
(define l1 (attach! l0 'editor 'left ft))
(define l (attach! l1 'editor 'down st))

;; layout 状态
(check-equal? (layout-visible-panel-ids l) '(filetree editor state))
(check-equal? (layout-panel-active-view l 'filetree) 'filetree)
(check-equal? (layout-panel-view-ids l 'filetree) '(filetree resources))

;; view 切换
(define-values (l* ok-switch?) (layout-panel-cycle-active-view l 'filetree))
(check-true ok-switch?)
(check-equal? (layout-panel-active-view l* 'filetree) 'resources)

;; solve / 接缝
(define solution (layout-solve l area))
(check-equal? (hash-ref (layout-solution-panel-rects solution) 'editor)
              (rect 30 0 50 23))
(check-equal? (layout-panel-rects l area)
              (layout-solution-panel-rects solution))
(check-not-false (layout-seam-at l area 0 30))

;; 焦点导航
(check-equal? (layout-focus-neighbor l area default-config 'editor 'left) 'filetree)
(check-equal? (layout-focus-panel-at l area default-config 0 0) 'filetree)

;; 隐藏 / 显示
(define-values (l-hidden ok-hide?) (layout-panel-hide l area 'filetree))
(check-true ok-hide?)
(check-equal? (layout-panel-rects l-hidden area)
              (layout-solution-panel-rects (layout-solve l-hidden area)))

;; 投影
(check-equal? (length (layout->render-panels l area)) 3)
(check-equal? (length (layout->hit-panels l area)) 3)

;; 命令表
(define base (keys ['a 'cmd-a] ['x 's 'cmd-xs]))
(define popup (keys ['a 'popup-a]))
(define stack (command-table-stack-push
               (command-table-stack-from-tables (list base))
               popup))
(let-values ([(st* v) (command-table-stack-lookup stack '(a))])
  (check-equal? st* 'command)
  (check-equal? v 'popup-a))
(let-values ([(st* v) (command-table-stack-lookup stack '(x s))])
  (check-equal? st* 'command)
  (check-equal? v 'cmd-xs))

;; config
(check-true (config-panel-splittable? default-config 'editor))
(check-false (config-panel-splittable? default-config 'sidebar))

(displayln "edit-tui-rebuild/test/api.rkt: ok")
