#lang racket

;;; edit3/plugins/words.rkt —— 当前词高亮（光标驱动）
;;;
;;; face 插件：光标所在标识符的所有出现处加 'word-mark 背景。
;;; 光标移动 / 编辑时由核心重扫（after-nav / after-edit / after-insert）。

(require racket/string
         "../core/extension.rkt")

(provide words-spec)

;; 一行里包含 col（或恰在 col 结束）的标识符。
(define (word-at line col)
  (for/first ([m (in-list (line-tokens line))]
              #:when (and (<= (car m) col) (<= col (cdr m))))
    (substring line (car m) (cdr m))))

(define (words-scan _path text cursor)
  (define lines (string-split text "\n"))
  (define w (and cursor
                 (let ([l (car cursor)] [c (cdr cursor)])
                   (and (< l (length lines)) (word-at (list-ref lines l) c)))))
  (for/list ([line (in-list lines)])
    (define vec (make-vector (string-length line) #f))
    (when w
      (for ([m (in-list (line-tokens line))])
        (when (string=? w (substring line (car m) (cdr m)))
          (for ([i (in-range (car m) (cdr m))]) (vector-set! vec i 'word-mark)))))
    vec))

(define words-spec
  (make-plugin #:name 'words
               #:faces (list (face-plugin 'words racket-applies? words-scan))))
