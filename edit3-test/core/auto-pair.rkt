#lang racket

;;; edit3-test/auto-pair.rkt —— 括号自动配对（成对插入 / 跳过右括号 / 选区不配对 / 普通文本）

(require rackunit racket/list
         "../../edit3/core/state.rkt"
         "../../edit3/core/event.rkt"
         "../../edit3/core/step.rkt"
         "../../edit3/core/window.rkt"
         "../../edit3/core/adapter.rkt"
         "../../edit3/core/panels.rkt"
         "../../edit3/plugins/auto-pair.rkt")

(define SZ (cons 80 24))
(define (run1 st ev) (call-with-values (lambda () (step (refresh-panels! st) SZ ev)) (lambda (s e) s)))

;; 给空编辑窗装缓冲区。
(define (with-buffer st text)
  (define-values (ed _did vid) (add-document-view! (state-ed st) text 40 10 "*scratch*"))
  (set-wid-vid (struct-copy state st [ed ed]) 0 vid))

(define (type st s) (run1 st (text-event s)))
(define (buf st) (view-string (state-ed st) (focused-vid st)))
(define (cur st) (cons (view-line (state-ed st) (focused-vid st))
                       (view-col (state-ed st) (focused-vid st))))

(define (fresh [text ""]) (with-buffer (boot 80 24 #:plugins (list auto-pair-spec)) text))

;; 左括号成对 + 光标停在中间
(define s1 (type (fresh) "("))
(check-equal? (buf s1) "()")
(check-equal? (cur s1) '(0 . 1))

;; 在中间打字
(define s2 (type s1 "a"))
(check-equal? (buf s2) "(a)")
(check-equal? (cur s2) '(0 . 2))

;; 右括号且右边已是它 → 跳过（不重复插入）
(define s3 (type s2 ")"))
(check-equal? (buf s3) "(a)")
(check-equal? (cur s3) '(0 . 3))

;; 之后普通字符照常插入
(define s4 (type s3 "b"))
(check-equal? (buf s4) "(a)b")
(check-equal? (cur s4) '(0 . 4))

;; 空缓冲输入右括号：不该跳过（右边没有），正常插入
(define e1 (type (fresh) ")"))
(check-equal? (buf e1) ")")
(check-equal? (cur e1) '(0 . 1))

;; {} 同样
(define b1 (type (fresh) "{"))
(check-equal? (buf b1) "{}")
(check-equal? (cur b1) '(0 . 1))
(define b2 (type b1 "}"))
(check-equal? (buf b2) "{}")
(check-equal? (cur b2) '(0 . 2))

;; 有选区时不配对：保持“替换选区”语义
(define sel0 (fresh "abc"))
(define sel1 (run1 sel0 (key-event 'a '(ctrl))))     ; C-a 全选
(define sel2 (type sel1 "("))
(check-equal? (buf sel2) "(")
(check-equal? (cur sel2) '(0 . 1))

(displayln "edit3/auto-pair.rkt: all tests passed")
