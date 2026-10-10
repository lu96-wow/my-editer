#lang racket

;;; edit/test/docs-test.rkt —— 文档浮窗插件**独立**工作（headless）
;;;
;;;   raco test edit/test/docs-test.rkt
;;;
;;; 覆盖：不打开补全菜单，用 M-d（cmd-docs-show）对光标处标识符查文档；
;;; 文档窗是独立浮窗（只有 'docs 一个叠加视图），异步到齐后显示。

(require rackunit
         racket/file
         "../demo.rkt"
         "../session.rkt"
         "../document/document.rkt"
         "../feature/api.rkt"
         "../core/path.rkt")

;; 菜单是否打开：以「complete 面存在」判定（补全菜单现在是一个 float 面）。
(define (menu-open? s) (and (session-surface-ref s 'complete) #t))

(define p (make-temporary-file "dt-~a.rkt"))
(display-to-file "#lang racket/base\n(require racket/list)\n(first" p #:exists 'replace)

(define s (demo-session 100 30))
(define s1 (session-open-file s (normalize p)))
(define vid (session-edit-vid s1))
(define s2 (session-ed-set-point! s1 vid 2 3))     ; 光标在 "first" 内

(define (pump-until s pred n)
  (cond
    [(pred s) s]
    [(zero? n) s]
    [else (sleep 0.1) (pump-until (session-prepare-render s) pred (sub1 n))]))

;; 独立触发（无补全菜单）
(define s3 (step s2 (cmd-docs-show)))
(check-false (menu-open? s3))       ; 补全菜单没开

(define (overlay-strs s) (for/list ([v (in-list (session-overlays s))]) (session-view-string s v)))
(define (doc-ready? s)
  (for/or ([str (in-list (overlay-strs s))]) (and (regexp-match? #rx"\\(first" str) #t)))
(define s4 (pump-until s3 doc-ready? 1200))
(check-true (doc-ready? s4))

;; 只有文档一个浮窗（补全没参与）
(check-equal? (length (session-overlays s4)) 1)

;; 光标导航 → 文档窗关闭
(define s5 (step s4 (cmd-nav 'left #f)))
(check-equal? (session-overlays s5) '())

;; 短文档（折行后不足 doc-max-rows 行）不能因 take 崩
(define p2 (make-temporary-file "dt2-~a.rkt"))
(display-to-file "#lang racket/base\n(car" p2 #:exists 'replace)
(define t1 (session-open-file s5 (normalize p2)))
(define tvid (session-edit-vid t1))
(define t2 (session-ed-set-point! t1 tvid 1 2))          ; 光标在 "car"
(define t3 (step t2 (cmd-docs-show)))
(define (has-car? s)
  (for/or ([str (in-list (overlay-strs s))]) (and (regexp-match? #rx"car" str) #t)))
(define t4 (pump-until t3 has-car? 1200))
(check-true (has-car? t4))
(delete-file p2)

(delete-file p)
