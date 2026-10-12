#lang racket

;;; edit4-test/faces.rkt —— 装饰：引擎 document 槽驱动（open/change）+ 逐格 face

(require rackunit racket/path
         "../edit4/core/world.rkt"
         (only-in "../edit4/content/model.rkt"
                  content-blank content-add-doc! content-bind content-ed)
         "../edit4/content/adapter.rkt"
         "../edit4/view/decor.rkt"
         "../edit4/view/face.rkt"
         "../edit4/decor/protocol.rkt"
         "../edit4/decor/dirty.rkt"
         "../edit4/decor/bracket-depth.rkt"
         "../edit4/decor/bracket-match.rkt"
         "../edit4/decor/syntax.rkt"
         "../edit4/decor/words.rkt"
         "../edit4/decor/word-color.rkt"
         "../edit4/layout.rkt"
         "../core/editor.rkt"
         (only-in "../core/text/base/track.rkt" track-of-list track-ref))

(define (make-doc text path)
  (define c0 (content-blank))
  (define-values (c1 did v) (content-add-doc! c0 text 40 3 "t" path))
  (values (make-world #:layout (leaf 0 (cons 2 2)) #:focus 0 #:content (content-bind c1 0 v)) did v))

;; 幕：把一组 decor 应用到该世界（写回引擎 face 端口）。
(define (paint! w decors) (apply-faces! (content-ed (world-content w)) decors w))

;;; ---------- 语法：关键字 / 字符串 / 注释 / 数字 ----------

(define-values (ws dids vs) (make-doc "(define x 1) ; hi\n\"str\"" (string->path "t.rkt")))
(define eds (content-ed (world-content ws)))
(paint! ws (list (pure-decor syntax-decor)))
(check-not-false (document-face-at eds dids 0 1))          ; define 关键字
(check-not-false (document-face-at eds dids 0 13))         ; hi 注释
(check-not-false (document-face-at eds dids 1 0))          ; "str" 字符串

;;; ---------- 括号深度：嵌套底色 ----------

(define-values (w1 did1 v1) (make-doc "(a (b) c)" (string->path "t.rkt")))
(define ed1 (content-ed (world-content w1)))
(paint! w1 (list (pure-decor bracket-depth-decor)))
(check-not-false (document-face-at ed1 did1 0 0))          ; 外层括号有深度底色
(check-not-false (document-face-at ed1 did1 0 3))          ; 内层括号有深度底色

;;; ---------- 括号配对：光标在括号上时标配对 ----------

(define-values (w2 did2 v2) (make-doc "(a (b) c)" (string->path "t.rkt")))
(define ed2 (content-ed (world-content w2)))
(set-point! ed2 v2 0 0)                                     ; 光标在外层 (
(paint! w2 (list (pure-decor bracket-match-decor)))
(check-not-false (document-face-at ed2 did2 0 0))          ; 光标处括号
(check-not-false (document-face-at ed2 did2 0 8))          ; 配对括号
(check-false (document-face-at ed2 did2 0 1))              ; 非括号

;; 深度 + 配对叠加 → face-stack
(define-values (w3 did3 v3) (make-doc "(a (b) c)" (string->path "t.rkt")))
(define ed3 (content-ed (world-content w3)))
(set-point! ed3 v3 0 0)
(paint! w3 (list (pure-decor bracket-depth-decor) (pure-decor bracket-match-decor)))
(check-true (face-stack? (document-face-at ed3 did3 0 0)))

;;; ---------- 当前词 ----------

(define-values (w4 did4 v4) (make-doc "hello world" #f))
(define ed4 (content-ed (world-content w4)))
(set-point! ed4 v4 0 2)                                     ; 光标在 hello 内
(paint! w4 (list (pure-decor words-decor)))
(check-not-false (document-face-at ed4 did4 0 1))          ; hello 被 word-mark
(check-false (document-face-at ed4 did4 0 7))              ; world 不涂

;;; ---------- 多层叠加：后层不吞掉前层（回归：≥3 层时嵌套 face-stack → 掉色）----------

(define-values (w7 did7 v7) (make-doc "(define hello 1)" (string->path "t.rkt")))
(define ed7 (content-ed (world-content w7)))
(set-point! ed7 v7 0 2)                                    ; 光标在 define 内
(paint! w7 (list (pure-decor syntax-decor)
                 (pure-decor bracket-depth-decor)
                 (pure-decor words-decor)))
(define f7 (document-face-at ed7 did7 0 2))
(check-true (face-stack? f7))
(check-equal? (map (lambda (l) (and (symbol? l) l)) (face-layers f7))
              '(#f #f word-mark))                          ; 层是平的，没有嵌套 face-stack
(define b7 (bytes->string/latin-1 (face-bytes f7)))
(check-true (regexp-match? #rx"38;2;120;180;240" b7))     ; 关键字前景仍在
(check-true (regexp-match? #rx"48;2;60;70;90" b7))        ; word-mark 背景盖在括号深度色上

;;; ---------- 同词着色（参考 edit1）：同词同色、异词异色、非词不着色 ----------

(define wc word-color-decor)
(define-values (_wcs wc-layer) ((decor-open wc) #f (track-of-list (list "alpha beta alpha"))))
(define (wc-at col) (vector-ref (track-ref wc-layer 0) col))
(check-equal? (wc-at 0) (wc-at 11))                       ; 两处 alpha 同色
(check-equal? (wc-at 0) (word-face "alpha"))
(check-not-equal? (wc-at 0) (wc-at 6))                    ; alpha vs beta 不同色
(check-false (wc-at 5))                                   ; 空格不着色
(define-values (_s2 l2) ((decor-open wc) #f (track-of-list (list "(alpha)"))))
(check-false (vector-ref (track-ref l2 0) 0))             ; 括号不着色

;;; ---------- 增量：word-color 只把改动行标脏 ----------

(define t3 (track-of-list (list "aaa" "bbb" "ccc")))
(define-values (st3 ly3) ((decor-open wc) #f t3))
;; change：在 0 行插入一个字符（after = (0,0)..(0,1)）
(define ch (change (range (point 0 0) (point 0 0)) (range (point 0 1) (point 0 1))))
(define ctx (face-ctx t3 t3 (list ch)
                      (dirty-lines (changes->dirty-lines (list ch))) #f #f))
(define-values (_st4 ly4 dl4) ((decor-change wc) st3 ly3 ctx))
(check-equal? (dirty-ls dl4) '(0))                        ; 只有第 0 行脏
(check-equal? (track-ref ly3 1) (track-ref ly4 1))        ; 第 1 行结构共享（未动）
;; 纯光标推进：不脏
(define ctx-nav (face-ctx t3 t3 '() (dirty-lines '()) #f (cons 0 0)))
(define-values (_st5 _ly5 dl5) ((decor-change wc) st3 ly3 ctx-nav))
(check-equal? (dirty-ls dl5) '())

;;; ---------- theme 编码不炸 ----------

(require "../edit4/view/theme.rkt")
(check-true (bytes? (attr-bytes 'bracket-match)))

(displayln "edit4/faces.rkt: all tests passed")
