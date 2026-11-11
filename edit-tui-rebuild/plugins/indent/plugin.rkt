#lang racket

;;; edit-tui-rebuild/plugins/indent/plugin.rkt —— Enter 换行缩进
;;;
;;; before-insert transform：
;;;   Enter（文本正好是 "\n"）时，保留当前行前导空白；
;;;   如果当前行去掉首尾空白后以开括号结尾，再额外加两个空格。
;;;
;;; 这里故意做得很小：先证明扩展点，不把完整的 Racket 缩进算法搬进来。

(require racket/string
         "../../editor/api.rkt")

(provide indent-plugin)

(define (leading-whitespace line)
  (let loop ([i 0])
    (cond
      [(>= i (string-length line)) ""]
      [(char=? (string-ref line i) #\space)
       (loop (add1 i))]
      [(char=? (string-ref line i) #\tab)
       (loop (add1 i))]
      [else (substring line 0 i)])))

(define (line-opens-block? line)
  (define trimmed (string-trim line))
  (and (positive? (string-length trimmed))
       (memv (string-ref trimmed (sub1 (string-length trimmed)))
             '(#\( #\[ #\{))))

(define (line-text-at ctx)
  (define engine (edit-context-engine ctx))
  (define vid (edit-context-view-id ctx))
  (define text (engine-view-text engine vid))
  (and text
       (let ([lines (string-split text "\n" #:trim? #f)])
         (define line (point-line (edit-context-point ctx)))
         (and (< line (length lines)) (list-ref lines line)))))

(define (before-insert ctx ps)
  (define text (edit-context-text ctx))
  (cond
    [(not (equal? text "\n")) (values ctx ps '() #t)]
    [else
     (define line (line-text-at ctx))
     (cond
       [(not line) (values ctx ps '() #t)]
       [else
        (define base (leading-whitespace line))
        (define extra (if (line-opens-block? line) "  " ""))
        (values (struct-copy edit-context ctx
                             [text (string-append "\n" base extra)])
                ps '() #t)])]))

(define indent-plugin
  (make-plugin
   #:id 'indent
   #:state #t
   #:hooks
   (list
    (make-hook #:owner 'indent
               #:id 'newline-indent
               #:operation 'insert
               #:phase 'transform
               #:priority 20
               #:fn before-insert))))
