#lang racket

;;; edit4-test/content.rkt —— 内容层（文档/视图 + 编辑/导航命令）

(require rackunit
         racket/list
         "../edit4/layout.rkt"
         "../edit4/core.rkt"
         "../edit4/content/adapter.rkt"
         "../edit4/content/model.rkt"
         "../edit4/content/commands.rkt")

(define SZ (cons 80 24))
(define reg (command-registry-merge base-commands content-commands))
(define km (compose-keymaps (list content-keymap base-keymap)))  ; 与 app 一致
(define (mk-ctx w ev) (ctx ev SZ #f))
(define (run w ev)
  (car (call-with-values (lambda () (dispatch reg base-scopes km (mk-ctx w ev) w)) list)))

;;; ---------- 一个窗口 + 一个绑定文档 ----------

(define c0 (content-blank))
(define-values (c1 did vid) (content-add-doc! c0 "" 40 10 "t" #f))
(define w0 (make-world #:layout (leaf 0 (cons 2 2)) #:focus 0 #:content (content-bind c1 0 vid)))

(define (ed-of w) (content-ed (world-content w)))
(check-equal? (view-string (ed-of w0) vid) "")
(check-equal? (content-did-of (world-content w0) vid) did)
(check-equal? (content-vid-of (world-content w0) 0) vid)

;;; ---------- 打字 ----------

(define w1 (run w0 (text-event "hello")))
(check-equal? (view-string (ed-of w1) vid) "hello")
(check-equal? (view-col (ed-of w1) vid) 5)
(check-true (doc-dirty? (world-content w1) did))       ; 编辑 → 脏

;;; ---------- 导航 ----------

(define w2 (run w1 (key-event 'left '())))
(check-equal? (view-col (ed-of w2) vid) 4)
(define w3 (run w2 (key-event 'home '())))
(check-equal? (view-col (ed-of w3) vid) 0)
(define w4 (run w3 (key-event 'right '())))
(check-equal? (view-col (ed-of w4) vid) 1)

;;; ---------- 删除 ----------

(define w5 (run (run w4 (key-event 'end '())) (key-event 'backspace '())))
(check-equal? (view-string (ed-of w5) vid) "hell")
(define w6 (run (run w5 (key-event 'home '())) (key-event 'delete '())))
(check-equal? (view-string (ed-of w6) vid) "ell")

;;; ---------- 保存标记 → 干净 ----------

(define c2 (doc-save-mark! (world-content w6) did))
(check-false (doc-dirty? c2 did))

;;; ---------- 同文档多视图 ----------

(define-values (c3 vid2) (content-add-view! c2 did 30 10))
(check-equal? (content-did-of c3 vid2) did)
;; 两个视图看到同一文本
(check-equal? (view-string (content-ed c3) vid2) (view-string (content-ed c3) vid))

;;; ---------- 焦点无绑定时编辑让位（World 不变） ----------

(define w7 (make-world #:layout (leaf 0 (cons 2 2)) #:focus 0 #:content c0))  ; c0 无绑定
(check-equal? (run w7 (text-event "x")) w7)   ; 让位 → World 不变

(displayln "edit4/content.rkt: all tests passed")
