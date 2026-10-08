#lang racket

;;; lab-rebuild/builtin/indent.rkt —— 换行语法缩进（覆盖 newline 命令）。
;;;
;;; 同名命令 upsert：后注册的覆盖先注册的。按光标前的括号嵌套深度决定缩进。
;;; 从 config/packages 撤掉 → 回落纯换行。是否适用由 doc-scope 的 'indent 声明决定。

(require racket/string
         "../kernel/api.rkt"
         "lang/file-kind.rkt"
         "doc-scope.rkt")

(provide register-indent! indent-for)

(define indent-width 2)

(define (text-before text line col)
  (define lines (string-split text "\n" #:trim? #f))
  (define n (length lines))
  (string-append
   (string-join (take lines (min line n)) "\n")
   (if (positive? line) "\n" "")
   (let ([l (if (< line n) (list-ref lines line) "")])
     (substring l 0 (min (max 0 col) (string-length l))))))

;; 从光标前的文本算缩进列数（忽略字符串 / 行注释里的括号）。
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

(define (cmd-newline ctx ev)
  (define s (ctx-session ctx))
  (define vid (session-focus-vid s))
  (cond
    [(not vid) '()]
    [else
     (define ins
       (cond
         [(not (doc-applies? ctx 'indent)) "\n"]        ; 不适用 → 纯换行
         [else
          (define ed (session-editor s))
          (define text (editor-view-string ed vid))
          (define p (editor-view-point ed vid))
          (string-append "\n"
                         (make-string (indent-for text (point-line p) (point-column p)) #\space))]))
     (list (e-type vid ins #f))]))

(define (register-indent! r)
  (for/fold ([r r])
            ([c (in-list (list (contrib 'doc-scope 'indent (doc-scope racket-buffer?))
                               (contrib 'command 'newline cmd-newline)))])
    (reg-add r c)))
