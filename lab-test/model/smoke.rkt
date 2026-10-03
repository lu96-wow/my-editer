#lang racket

;;; lab-test/model/smoke.rkt —— P1 模型层冒烟测试

(require rackunit
         "../../lab/model/layout.rkt"
         "../../lab/model/session.rkt"
         "../../lab/model/ops.rkt"
         "../../lab/model/render.rkt"
         "../../core/editor.rkt"
         "../../core/view/base/screen.rkt")

(define s0 (session-open "abc\ndef" 80 24 "d0"))
(check-equal? (editor-document-count (session-editor s0)) 1)
(check-equal? (editor-view-count (session-editor s0)) 1)
(check-equal? (session-active s0) 0)
(check-equal? (editor-view-document-id (session-editor s0) 0) 0)

;; 布局：无侧栏时 main 占满，底部固定 1 行状态栏
(define rects (session-rects s0))
(define v0 (for/first ([r (in-list rects)] #:when (equal? (pane-rect-id r) 0)) r))
(define st (for/first ([r (in-list rects)] #:when (eq? (pane-rect-id r) 'status)) r))
(check-equal? (list (pane-rect-x v0) (pane-rect-w v0) (pane-rect-h v0)) (list 0 80 22))
(check-equal? (list (pane-rect-y st) (pane-rect-h st)) (list 23 1))

;; 渲染
(define scr (session-render s0))
(check-equal? (screen-width scr) 80)
(check-equal? (screen-height scr) 24)

;; 关 view：document 必须还在（生命周期独立）
(define s1 (session-close-view s0 0))
(check-equal? (editor-view-count (session-editor s1)) 0)
(check-equal? (editor-document-count (session-editor s1)) 1)
(check-equal? (session-main s1) '())
(check-false (session-active s1))

;; 再开一个文档
(define-values (s2 did vid) (session-open-document s0 "hello\nworld" "d1"))
(check-equal? did 1)
(check-equal? vid 1)
(check-equal? (editor-document-count (session-editor s2)) 2)
(check-equal? (session-active s2) 1)

;; 关 doc：级联关它的 view
(define s3 (session-close-document s2 0))
(check-equal? (editor-document-count (session-editor s3)) 1)
(check-equal? (editor-view-count (session-editor s3)) 1)
(check-equal? (session-active s3) 1)

;; 插入有变更
(define-values (chs ok?) (editor-view-insert! (session-editor s2) 1 "XY"))
(check-true ok?)
(check-equal? (length chs) 1)

(printf "ALL SMOKE OK\n")
