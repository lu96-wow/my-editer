#lang racket

;;; edit4-test/faces.rkt —— face 投影/写回（括号深度 / 括号配对 / 当前词）

(require rackunit racket/list racket/path
         "../edit4/core/world.rkt"
         "../edit4/content/model.rkt"
         "../edit4/content/adapter.rkt"
         "../edit4/view/decor.rkt"
         "../edit4/view/face.rkt"
         "../edit4/decor/bracket-depth.rkt"
         "../edit4/decor/bracket-match.rkt"
         "../edit4/decor/syntax.rkt"
         "../edit4/decor/words.rkt"
         "../edit4/layout.rkt")

(define (make-doc text path)
  (define c0 (content-blank))
  (define-values (c1 did v) (content-add-doc! c0 text 40 3 "t" path))
  (values (make-world #:layout (leaf 0 (cons 2 2)) #:focus 0 #:content (content-bind c1 0 v)) did v))

;;; ---------- 语法：关键字 / 字符串 / 注释 / 数字 ----------

(define-values (ws dids vs) (make-doc "(define x 1) ; hi\n\"str\"" (string->path "t.rkt")))
(define eds (content-ed (world-content ws)))
(define-values (_fcs projs-s) (ensure-faces (hash) (list syntax-decor) ws))
(commit-faces! eds projs-s)
(check-not-false (document-face-at eds dids 0 1))          ; define 关键字
(check-not-false (document-face-at eds dids 0 13))         ; hi 注释
(check-not-false (document-face-at eds dids 1 0))          ; "str" 字符串

;;; ---------- 括号深度：嵌套底色 ----------

(define-values (w1 did1 v1) (make-doc "(a (b) c)" (string->path "t.rkt")))
(define ed1 (content-ed (world-content w1)))
(define-values (_fc1 projs1) (ensure-faces (hash) (list bracket-depth-decor) w1))
(check-true (pair? projs1))
(commit-faces! ed1 projs1)
(check-not-false (document-face-at ed1 did1 0 0))          ; 外层括号有深度底色
(check-not-false (document-face-at ed1 did1 0 3))          ; 内层括号有深度底色

;;; ---------- 括号配对：光标在括号上时标配对 ----------

(define-values (w2 did2 v2) (make-doc "(a (b) c)" (string->path "t.rkt")))
(define ed2 (content-ed (world-content w2)))
(set-point! ed2 v2 0 0)                                     ; 光标在外层 (
(define-values (_fc2 projs2) (ensure-faces (hash) (list bracket-match-decor) w2))
(commit-faces! ed2 projs2)
(check-not-false (document-face-at ed2 did2 0 0))          ; 光标处括号
(check-not-false (document-face-at ed2 did2 0 8))          ; 配对括号
(check-false (document-face-at ed2 did2 0 1))              ; 非括号

;; 深度 + 配对叠加 → face-stack
(define-values (w3 did3 v3) (make-doc "(a (b) c)" (string->path "t.rkt")))
(define ed3 (content-ed (world-content w3)))
(set-point! ed3 v3 0 0)
(define-values (_fc3 projs3)
  (ensure-faces (hash) (list bracket-depth-decor bracket-match-decor) w3))
(commit-faces! ed3 projs3)
(check-true (face-stack? (document-face-at ed3 did3 0 0)))

;;; ---------- 当前词 ----------

(define-values (w4 did4 v4) (make-doc "hello world" #f))
(define ed4 (content-ed (world-content w4)))
(set-point! ed4 v4 0 2)                                     ; 光标在 hello 内
(define-values (_fc4 projs4) (ensure-faces (hash) (list words-decor) w4))
(commit-faces! ed4 projs4)
(check-not-false (document-face-at ed4 did4 0 1))          ; hello 被 word-mark
(check-false (document-face-at ed4 did4 0 7))              ; world 不涂

;;; ---------- 多层叠加：后层不吞掉前层（回归：≥3 层时嵌套 face-stack → 掉色）----------

(define-values (w7 did7 v7) (make-doc "(define hello 1)" (string->path "t.rkt")))
(define ed7 (content-ed (world-content w7)))
(set-point! ed7 v7 0 2)                                    ; 光标在 define 内
(define-values (_fc7 projs7)
  (ensure-faces (hash) (list syntax-decor bracket-depth-decor words-decor) w7))
(commit-faces! ed7 projs7)
(define f7 (document-face-at ed7 did7 0 2))
(check-true (face-stack? f7))
(check-equal? (map (lambda (l) (and (symbol? l) l)) (face-layers f7))
              '(#f #f word-mark))                          ; 层是平的，没有嵌套 face-stack
(define b7 (bytes->string/latin-1 (face-bytes f7)))
(check-true (regexp-match? #rx"38;2;120;180;240" b7))     ; 关键字前景仍在
(check-true (regexp-match? #rx"48;2;60;70;90" b7))        ; word-mark 背景盖在括号深度色上

;;; ---------- 同词着色（参考 edit1）：同词同色、异词异色、非词不着色 ----------

(require "../edit4/decor/word-color.rkt")

(define wc (word-color-decor #f "alpha beta alpha" #f))
(define (wc-at line col) (vector-ref (list-ref wc line) col))
(check-equal? (wc-at 0 0) (wc-at 0 11))                   ; 两处 alpha 同色
(check-equal? (wc-at 0 0) (word-face "alpha"))
(check-not-equal? (wc-at 0 0) (wc-at 0 6))                ; alpha vs beta 不同色
(check-false (wc-at 0 5))                                 ; 空格不着色
(check-false (vector-ref (list-ref (word-color-decor #f "(alpha)" #f) 0) 0))  ; 括号不着色

;;; ---------- 缓存：handle+cursor 不变 → 跳过 ----------

(define-values (fc5 projs5) (ensure-faces (hash) (list bracket-depth-decor) w1))
(check-true (pair? projs5))
(define-values (fc6 projs6) (ensure-faces fc5 (list bracket-depth-decor) w1))
(check-equal? projs6 '())                               ; 命中缓存，不重算

;;; ---------- theme 编码不炸 ----------

(require "../edit4/view/theme.rkt")
(check-true (bytes? (attr-bytes 'bracket-match)))

(displayln "edit4/faces.rkt: all tests passed")
