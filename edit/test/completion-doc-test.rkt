#lang racket

;;; edit/test/completion-doc-test.rkt —— 补全的异步文档浮窗（headless）
;;;
;;;   raco test edit/test/completion-doc-test.rkt
;;;
;;; 覆盖：模块导出补全选中候选后，异步取回该候选的文档（bluebox/HTML），
;;; 在**独立的文档浮窗**里显示（与补全菜单是两个叠加视图）。

(require rackunit
         racket/file
         "../demo.rkt"
         "../session.rkt"
         "../document/document.rkt"
         "../feature/api.rkt"
         "../core/path.rkt")

(define p (make-temporary-file "cd-~a.rkt"))
(display-to-file "#lang racket/base\n(require racket/list)\n(fir" p #:exists 'replace)

(define s (demo-session 100 30))
(define s1 (session-open-file s (normalize p)))
(define vid (session-edit-vid s1))
(define s2 (session-ed-set-point! s1 vid 2 4))

(define (pump-until s pred n)
  (cond
    [(pred s) s]
    [(zero? n) s]
    [else (sleep 0.1) (pump-until (session-prepare-render s) pred (sub1 n))]))

;; 等菜单打开（池由 place worker 算）
(define s3 (pump-until (step s2 (cmd-complete))
                       (lambda (s) (session-layer-active? s 'complete)) 600))
(check-true (session-layer-active? s3 'complete))
;; 此时只有补全菜单一个浮窗
(check-equal? (length (session-overlays s3)) 1)

;; idx 0 是正在输入的 "fir"（edit 保留与前缀相同的候选）→ 下移到 "first"（模块导出）
(define s3b (step s3 (cmd-complete-move 1)))

;; 等文档到齐：某个浮窗里出现签名（"(first"）
(define (overlay-strs s) (for/list ([v (in-list (session-overlays s))]) (session-view-string s v)))
(define (doc-ready? s)
  (for/or ([str (in-list (overlay-strs s))]) (and (regexp-match? #rx"\\(first" str) #t)))
(define s4 (pump-until s3b doc-ready? 1200))
(check-true (doc-ready? s4))

;; 两个**独立**浮窗：补全菜单 + 文档窗
(check-equal? (length (session-overlays s4)) 2)
(check-true (for/or ([str (in-list (overlay-strs s4))]) (regexp-match? #rx"first" str)))

;; 文档窗有固定高度（半屏上界），内容超出可滚动；Tab 切换接键窗口。
;; 叠加是 prepend：文档窗后加，故在最前。
(define docs-vid (car (session-overlays s4)))
(define (ds s) (session-view-string s docs-vid))
(define doc-before (ds s4))

;; Tab → 文档接键；上/下滚一行
(define s4a (step s4 (cmd-complete-switch)))
(define s4b (step s4a (cmd-complete-move 1)))          ; active=docs → 向下滚 1 行
(define doc-b (ds s4b))
(check-not-equal? doc-b doc-before)

;; 左/右滚一大步
(define s4c (step s4b (cmd-complete-scroll 5)))
(check-not-equal? (ds s4c) doc-b)

;; Tab 回补全：接键窗口回到补全（再按上/下就变成移候选）
(define s4d (step s4c (cmd-complete-switch)))
(check-true (session-layer-active? s4d 'complete))

;; 接受候选 → 两个浮窗都关掉
(define s5 (step s4d (cmd-complete-accept)))
(check-false (session-layer-active? s5 'complete))
(check-equal? (session-overlays s5) '())

(delete-file p)
