#lang racket

;;; edit4-test/faces.rkt —— face 投影/写回（语法 + 当前词）

(require rackunit racket/list racket/path
         "../edit4/core/world.rkt"
         "../edit4/content/content.rkt"
         "../edit4/content/engine.rkt"
         "../edit4/view/face-plugin.rkt"
         "../edit4/face/syntax.rkt"
         "../edit4/face/words.rkt"
         "../edit4/layout.rkt")

(define (make-doc text path)
  (define c0 (content-blank))
  (define-values (c1 did v) (content-add-doc! c0 text 40 3 "t" path))
  (values (make-world #:layout (leaf 0 (cons 2 2)) #:focus 0 #:content (content-bind c1 0 v)) did v))

;;; ---------- 语法：关键字/字符串/注释/数字 ----------

(define-values (w1 did1 v1)
  (make-doc "(define x 1) ; hi\n\"str\"" (string->path "t.rkt")))
(define ed1 (content-ed (world-content w1)))
(define-values (_fc1 projs1) (ensure-faces (hash) (list syntax-plugin) w1))
(check-true (pair? projs1))
(commit-faces! ed1 projs1)
(check-not-false (document-face-at ed1 did1 0 1))          ; "define" 涂了色
(check-not-false (document-face-at ed1 did1 0 13))          ; "hi" 注释涂了色
(check-not-false (document-face-at ed1 did1 1 0))           ; 字符串涂了色

;;; ---------- 当前词 ----------

(define-values (w2 did2 v2) (make-doc "hello world" #f))
(define ed2 (content-ed (world-content w2)))
(set-point! ed2 v2 0 2)                                 ; 光标在 hello 内
(define-values (_fc2 projs2) (ensure-faces (hash) (list words-plugin) w2))
(commit-faces! ed2 projs2)
(check-not-false (document-face-at ed2 did2 0 1))           ; hello 被 word-mark
(check-false (document-face-at ed2 did2 0 7))          ; world 不涂

;;; ---------- 缓存：handle+cursor 不变 → 跳过 ----------

(define-values (fc3 projs3) (ensure-faces (hash) (list syntax-plugin) w1))
(check-true (pair? projs3))
(define-values (fc4 projs4) (ensure-faces fc3 (list syntax-plugin) w1))
(check-equal? projs4 '())                               ; 命中缓存，不重算

;;; ---------- theme 编码不炸 ----------

(require "../edit4/view/theme.rkt")
(check-true (bytes? (attr-bytes 'syntax-def)))

(displayln "edit4/faces.rkt: all tests passed")
