#lang racket

(require "../../core/editor.rkt"
         "../platform/state.rkt"
         "../platform/command.rkt"
         "edit.rkt")

;;; lab-rebuild/builtin/indent.rkt —— 换行语法缩进（内置包）
;;;
;;; 覆盖基础编辑包注册的 newline-and-indent：按光标前的括号嵌套深度决定新行缩进。
;;; 规则（Racket 风格、够用）：缩进 = 2 × 光标前未闭合的 ( [ { 数。
;;;
;;;   (define (f x)⏎   → 缩进 2（外层 define）
;;;   (define x 1)⏎    → 缩进 0
;;;   (let ([x 1])⏎    → 缩进 2
;;;
;;; 粗略跳过字符串（含 \\ 转义）与行注释（; 到行尾）。不做 reader 级精确解析。
;;;
;;; 加载即生效（命令注册是覆盖式）。可从 config/packages.rkt 撤掉 → 回落纯换行。

(provide indent-width indent-for cmd-newline-and-indent)

(define indent-width 2)

;; 光标前文本（到 line/col 为止）。
(define (text-before text line col)
  (define lines (string-split text "\n"))
  (define n (length lines))
  (string-append
   (string-join (take lines (min line n)) "\n")
   (if (positive? line) "\n" "")
   (let ([l (if (< line n) (list-ref lines line) "")])
     (substring l 0 (min (max 0 col) (string-length l))))))

;; 光标前的括号嵌套深度。
(define (indent-for text line col)
  (define before (text-before text line col))
  (let loop ([cs (string->list before)] [d 0] [in-str? #f] [in-comment? #f])
    (cond
      [(null? cs) (* indent-width d)]
      [(and in-comment? (not (char=? (car cs) #\newline))) (loop (cdr cs) d in-str? #t)]
      [in-str?
       (cond [(char=? (car cs) #\\) (loop (drop cs (min 2 (length cs))) d #t #f)]
             [(char=? (car cs) #\") (loop (cdr cs) d #f #f)]
             [else (loop (cdr cs) d #t #f)])]
      [(char=? (car cs) #\") (loop (cdr cs) d #t #f)]
      [(char=? (car cs) #\;) (loop (cdr cs) d #f #t)]
      [(memv (car cs) '(#\( #\[ #\{)) (loop (cdr cs) (add1 d) #f #f)]
      [(memv (car cs) '(#\) #\] #\})) (loop (cdr cs) (max 0 (sub1 d)) #f #f)]
      [else (loop (cdr cs) d #f #f)])))

(define (cmd-newline-and-indent e a)
  (define ed (app-ed a))
  (define vid (app-focus a))
  (define text (editor-view-string ed vid))
  (define p (editor-view-point ed vid))
  (define indent (indent-for text (point-line p) (point-column p)))
  (app-insert-typed! a (string-append "\n" (make-string indent #\space))))

;; 覆盖基础编辑包的纯换行实现。
(define-command newline-and-indent cmd-newline-and-indent)
