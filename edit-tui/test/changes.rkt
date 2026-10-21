#lang racket

;;; change 通道：engine 返回精确 change；run-actions 把它记到 app-state。

(require rackunit
         "../main.rkt")

(define area (rect 0 0 20 5))

(define table
  (keys
   [(key 'x) (insert-command "X")]))

(define engine (make-engine))
(define-values (store actions)
  (resource-open resource-store-empty
                 #:name "main"
                 #:text "hello"
                 #:key-table table))
(define rid 1)
(define vid 1)

(define editor-panel
  (make-panel 'editor 'editor #:views (list vid) #:active vid))
(define layout
  (make-layout #:root (make-leaf 'editor)
               #:panels (hash 'editor editor-panel)
               #:focus 'editor))
(define state0
  (run-actions (make-app-state #:layout layout
                               #:resources store
                               #:area area)
               engine actions))

;;; ════════════════ engine 直接返回 change ════════════════

(define chs (engine-apply-view-action! engine
                                        (view-action 'insert vid #"A")))
(check-true (pair? chs))
(define ch (car chs))
(check-equal? (change-kind ch) 'insert)
(check-equal? (range-start (change-before ch)) (point 0 0))
(check-equal? (range-start (change-after ch)) (point 0 0))
(check-equal? (range-end (change-after ch)) (point 0 1))
(check-equal? (engine-view-text engine vid) "Ahello")

;; 导航 / 光标 / 滚动不产生 change
(check-equal? (engine-apply-view-action! engine (view-action 'nav vid (list 'right #f)))
              '())
(check-equal? (engine-apply-view-action! engine (view-action 'point vid (list 0 0)))
              '())

;; 删除也返回 change
(define del-chs (engine-apply-view-action! engine
                                            (view-action 'delete vid #f)))
(check-true (pair? del-chs))
(check-equal? (change-kind (car del-chs)) 'delete)

;; undo/redo 恢复旧 document，不产生文本 change，也不触发解析。
(define before-undo-text (engine-view-text engine vid))
(check-equal? (engine-apply-view-action! engine (view-action 'undo vid #f)) '())
(check-equal? (engine-view-text engine vid) "Ahello")
(check-equal? (engine-apply-view-action! engine (view-action 'redo vid #f)) '())
(check-equal? (engine-view-text engine vid) before-undo-text)

;;; ════════════════ step / run-actions 记录 doc-change ════════════════

(define-values (s1 acts1) (step state0 (key-event (key 'x))))
(check-true (pair? acts1))
(define s2 (run-actions s1 engine acts1))

(define pending (app-state-pending-doc-changes s2))
(check-equal? (length pending) 1)
(define dc (car pending))
(check-true (doc-change? dc))
(check-equal? (doc-change-doc-id dc) 1)
(check-true (eq? (doc-change-version dc) (engine-doc-version engine 1)))
(check-true (pair? (doc-change-changes dc)))
(check-equal? (change-kind (car (doc-change-changes dc))) 'insert)

;; take 后清空
(define-values (taken s3) (app-state-take-doc-changes s2))
(check-equal? taken pending)
(check-equal? (app-state-pending-doc-changes s3) '())

;; 第二次编辑继续追加
(define-values (s4 acts4) (step s3 (key-event (key 'x))))
(define s5 (run-actions s4 engine acts4))
(check-equal? (length (app-state-pending-doc-changes s5)) 1)

(displayln "edit-tui-rebuild/test/changes.rkt: ok")
