#lang racket

;;; lab-test/command/smoke.rkt —— 命令层冒烟：自插入 / 默认表 / effects

(require rackunit
         "../../lab/command/dispatch.rkt"
         "../../lab/protocol.rkt"
         "../../lab/model/session.rkt"
         "../../lab/model/ops.rkt"
         (prefix-in core: "../../core/editor.rkt"))

(define m0 (modifiers #f #f #f #f))
(define mC (modifiers #t #f #f #f))
(define mA (modifiers #f #t #f #f))

(define s0 (session-open "abc" 40 10 "d0"))

;; 自插入：光标在 0 → 插到最前
(define-values (s1 e1) (dispatch s0 (text "X" m0)))
(check-equal? (document-text s1 0) "Xabc")
(check-equal? e1 '())

;; 右移光标
(define-values (s2 e2) (dispatch s1 (key 'right m0)))
(check-equal? (core:editor-view-point-col (session-editor s2) 0) 2)

;; 退格
(define-values (s3 e3) (dispatch s2 (key 'backspace m0)))
(check-equal? (document-text s3 0) "Xbc")

;; text 输入（粘贴）
(define-values (s4 e4) (dispatch s3 (text "HI" m0)))
(check-equal? (document-text s4 0) "XHIbc")

;; undo（C-z）
(define-values (s5 e5) (dispatch s4 (key #\z mC)))
(check-equal? (document-text s5 0) "Xbc")

;; 新开文档 → 焦点在 vid 1
(define-values (s6 did vid) (session-open-document s5 "xyz" "d1"))
(check-equal? did 1)
(check-equal? (session-active s6) 1)

;; M-left → 焦点切回 vid 0
(define-values (s7 e7) (dispatch s6 (key 'left mA)))
(check-equal? (session-active s7) 0)

;; C-b 切换侧栏
(define-values (s11 e11) (dispatch s7 (key #\b mC)))
(check-true (session-sidebar-hidden? s11))

;; C-q 产生 quit effect
(define-values (s12 e12) (dispatch s11 (key #\q mC)))
(check-equal? (length e12) 1)
(check-true (quit? (car e12)))

;; 分屏：焦点在 vid 0，C-\ → 同文档新视图
(define before (length (core:editor-views (session-editor s12))))
(define-values (s13 e13) (dispatch s12 (key #\\ mC)))
(check-equal? (length (core:editor-views (session-editor s13))) (add1 before))
(check-equal? (view-document-id s13 (session-active s13)) 0)

(printf "ALL COMMAND SMOKE OK\n")
