#lang racket

;;; edit-rebuild/core/test/session-test.rkt —— 会话骨架（headless）
;;;
;;;   raco test edit-rebuild/core/test/session-test.rkt
;;;
;;; 覆盖：根值 = 子值的组合；子值独立变换；adapter 的文档/视图读；几何（布局 + 浮面）。

(require rackunit
         "../session/adapter.rkt"
         "../session/session.rkt"
         "../surface/surface.rkt"
         "../geometry/layout.rkt")

(define s (session-blank 80 24))

;; 空会话
(check-equal? (session-width s) 80)
(check-equal? (session-height s) 24)
(check-false (session-quit? s))
(check-equal? (session-document-ids s) '())
(check-false (session-focus-vid s))

;; 加文档 + 视图（走 adapter 的 core 边界）
(define-values (s1 did vid)
  (session-add-document s (panel-doc (list (list "hello" #f) (list "world" 'x)))
                        40 10 #:name "*t*"))
(check-not-false (memv did (session-document-ids s1)))
(check-equal? (session-view-string s1 vid) "hello\nworld")
(check-equal? (session-document-name s1 did) "*t*")
(check-equal? (session-view-did s1 vid) did)

;; 焦点落到视图后，focused-did 可读（这里用 input 子值直接设）
(check-equal? (session-focused-did s1) #f)   ; 还没设焦点

;; 子值独立：resize 只动 ui，不动其它
(check-equal? (session-width (session-resize s1 100 40)) 100)
(check-equal? (session-width s1) 80)
(check-equal? (session-doc-keymaps (session-resize s1 100 40)) (session-doc-keymaps s1))

;; 显隐是 ui 子值
(check-true (session-visible? s1 vid))
(check-false (session-visible? (session-set-visible s1 vid #f) vid))

;; 面登记 + 浮面几何：session-panes 直接按面的 pos 产 placed
(define sf (float-surface 'pop 777 #f
                          (float (lambda (_s) (area 5 3 10 4)) 1000)
                          #f #f #f #f))
(define s2 (session-add-surface s1 sf))
(check-eq? (session-surface-ref s2 'pop) sf)
(define (has-vid? panes v) (for/or ([p (in-list panes)]) (eqv? v (placed-vid p))))
(check-true (has-vid? (session-panes s2) 777))

;; 注销面 → 几何消失
(check-false (session-surface-ref (session-remove-surface s2 'pop) 'pop))

;; runtime 是可变出口：服务表可存可取
(check-eq? (session-service-ref (session-service-put s1 'demo 'v) 'demo) 'v)

;; 触发器：quit
(check-true (session-quit? (session-quit s1))) 
