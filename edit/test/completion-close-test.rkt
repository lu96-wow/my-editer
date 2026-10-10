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

(define p (make-temporary-file "cc-~a.rkt"))
(display-to-file "alpha alphabet\n" p #:exists 'replace)

(define s (demo-session 80 24))
(define s1 (session-open-file s (normalize p)))
(define vid (session-edit-vid s1))

;; 新行输入 "alph" → 自动弹菜单（无 #lang → 基座导出走 worker，需轮询）
(define s2 (session-ed-set-point! s1 vid 1 0))
(define (pump-until-menu s n)
  (cond
    [(session-layer-active? s 'complete) s]
    [(zero? n) s]
    [else (sleep 0.01) (pump-until-menu (session-prepare-render s) (sub1 n))]))
(define s3 (pump-until-menu (step s2 (cmd-insert "alph")) 500))
(check-true (session-layer-active? s3 'complete))

;; 退格逐个删：还有前缀时菜单在；删空 → 关闭
(define s4 (step s3 (cmd-backspace)))
(check-true (session-layer-active? s4 'complete))   ; "alp"
(define s5 (step s4 (cmd-backspace)))                ; "al"
(define s6 (step s5 (cmd-backspace)))                ; "a"
(define s7 (step s6 (cmd-backspace)))                ; ""
(check-false (session-layer-active? s7 'complete))
(check-equal? (session-overlays s7) '())

(delete-file p)
