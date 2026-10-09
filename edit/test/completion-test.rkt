#lang racket

;;; edit/test/completion-test.rkt —— 词补全链路验证（headless）
;;;
;;;   raco test edit/test/completion-test.rkt
;;;
;;; 覆盖：打开菜单（输入层 + 浮层）/ 打字 fallthrough 后刷新候选 / 接受替换前缀。

(require rackunit
         racket/file
         "../demo.rkt"
         "../session.rkt"
         "../document/document.rkt"
         "../feature/api.rkt"
         "../core/path.rkt"
         "../core/focus.rkt")

(define p (make-temporary-file "cp-~a.rkt"))
(display-to-file "alpha alphabet\n" p #:exists 'replace)

(define s (demo-session 80 24))
(define s1 (session-open-file s (normalize p)))
(define vid (session-edit-vid s1))

;; 在空行输入 "alph"，光标停在前缀后
(define s2 (session-ed-set-point! s1 vid 1 0))
(define s3 (step s2 (cmd-insert "alph")))
(check-equal? (session-view-string s3 vid) "alpha alphabet\nalph")

;; 打开补全菜单
(define s4 (step s3 (cmd-complete)))
(check-true (session-layer-active? s4 'complete))
(check-true (pair? (session-floats s4)))

;; 输入层键表接管上下 / Enter / Esc（普通字符不在此，fallthrough 到文档键表）
(define lk (for/first ([l (in-list (session-layers s4))]) (layer-keys l)))
(check-pred cmd-complete-move? (keymap-lookup lk (key 'down)))
(check-pred cmd-complete-accept? (keymap-lookup lk (key 'enter)))
(check-pred cmd-complete-cancel? (keymap-lookup lk (key 'escape)))

;; 打字 fallthrough：插入 + 刷新（"alpha" == 前缀被排除，只剩 "alphabet"）
(define s5 (step s4 (cmd-insert "a")))
(check-equal? (session-view-string s5 vid) "alpha alphabet\nalpha")

;; 接受：把前缀换成候选
(define s6 (step s5 (cmd-complete-accept)))
(check-equal? (session-view-string s6 vid) "alpha alphabet\nalphabet")
(check-false (session-layer-active? s6 'complete))
(check-equal? (session-floats s6) '())

;; 焦点移开 → focus-changed hook 取消菜单
(define t1 (step (session-ed-set-point! s6 vid 1 0) (cmd-insert "al")))
(define t2 (step t1 (cmd-complete)))
(check-true (session-layer-active? t2 'complete))
(define t3 (session-set-focus t2 (focus-set (session-focus t2) (session-panel-vid t2 panel-tree))))
(check-false (session-layer-active? t3 'complete))
(check-equal? (session-floats t3) '())

(delete-file p)
