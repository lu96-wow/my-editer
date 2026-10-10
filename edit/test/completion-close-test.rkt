#lang racket

;;; edit/test/completion-close-test.rkt —— 补全菜单的关闭时机（headless）
;;;
;;;   raco test edit/test/completion-close-test.rkt
;;;
;;; 覆盖：打字自动弹；退格逐个删前缀时菜单跟着 refine；前缀被删空 → 关菜单。

(require rackunit
         racket/file
         "../demo.rkt"
         "../session.rkt"
         "../document/document.rkt"
         "../feature/api.rkt"
         "../core/path.rkt")

;; 菜单是否打开：以「complete 面存在」判定（补全菜单现在是一个 float 面）。
(define (menu-open? s) (and (session-surface-ref s 'complete) #t))

(define p (make-temporary-file "cc-~a.rkt"))
(display-to-file "alpha alphabet\n" p #:exists 'replace)

(define s (demo-session 80 24))
(define s1 (session-open-file s (normalize p)))
(define vid (session-edit-vid s1))

;; 新行输入 "alph" → 自动弹菜单（无 #lang → 基座导出走 worker，需轮询）
(define s2 (session-ed-set-point! s1 vid 1 0))
(define (pump-until-menu s n)
  (cond
    [(menu-open? s) s]
    [(zero? n) s]
    [else (sleep 0.01) (pump-until-menu (session-prepare-render s) (sub1 n))]))
(define s3 (pump-until-menu (step s2 (cmd-insert "alph")) 500))
(check-true (menu-open? s3))

;; 退格逐个删：还有前缀时菜单在；删空 → 关闭
(define s4 (step s3 (cmd-backspace)))
(check-true (menu-open? s4))   ; "alp"
(define s5 (step s4 (cmd-backspace)))                ; "al"
(define s6 (step s5 (cmd-backspace)))                ; "a"
(define s7 (step s6 (cmd-backspace)))                ; ""
(check-false (menu-open? s7))
(check-equal? (session-overlays s7) '())

(delete-file p)
