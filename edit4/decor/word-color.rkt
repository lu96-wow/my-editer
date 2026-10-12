#lang racket

;;; edit4/decor/word-color.rkt —— 同词着色（参考 edit1 的 plugins/highlight/words.rkt）
;;;
;;; 每个标识符的色 = djb2(词名) % word-color-count → palette-color 'word。
;;; 同词同色、跨行跨文件、跨会话稳定；纯按行着色，无跨行状态
;;; → 第一个迁移到增量的装饰：编辑时只重扫改动行。
;;;
;;; decor 协议见 decor/protocol.rkt：open 整篇扫；change 只按 changes 重扫脏行。

(provide word-color-decor word-face word-color-line)

(require racket/string
         "lex.rkt"
         "protocol.rkt"
         "dirty.rkt"
         "../view/face.rkt"
         "../config/words.rkt")

;; djb2：稳定散列（不依赖 equal-hash-code 的随机性，跨会话一致）。
(define (word-hash w)
  (for/fold ([h 5381]) ([c (in-string w)])
    (bitwise-and (+ (* h 33) (char->integer c)) #xFFFFFFFF)))

(define (word-face w)
  (palette-color 'word (modulo (word-hash w) (max 1 word-color-count))))

;; 一行 → face 向量（标识符整段涂同词色）。
(define (word-color-line _ln line)
  (define vec (make-vector (string-length line) #f))
  (for ([m (in-list (line-tokens line))])
    (define f (word-face (substring line (car m) (cdr m))))
    (for ([i (in-range (car m) (cdr m))]) (vector-set! vec i f)))
  vec)

(define word-color-decor
  (decor
   (lambda (_path text)
     (values #f (scan-track text word-color-line)))
   (lambda (state layer ctx)
     (define changes (face-ctx-changes ctx))
     (cond
       ;; 纯光标推进：按行着色与光标无关 → 不动
       [(null? changes) (values state layer (dirty-lines '()))]
       [else
        (values state
                (refresh-layer layer (face-ctx-new-text ctx) changes '() word-color-line)
                (face-ctx-dirty ctx))]))))
