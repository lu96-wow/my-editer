#lang racket

;;; layer  : plugins/highlight
;;; effect : 无（纯：text -> state/layer）
;;;
;;; word-color-decor.rkt —— 同词同色（前景层，增量）
;;;
;;; 色 = djb2(词名) % 12；与 history/edit4/decor/word-color.rkt 一致。
;;; 纯按行着色，无跨行状态：编辑时只重扫 changes 波及的行。

(provide word-color-face-decor)

(require "../../model/face-decor.rkt"
         "../../model/face-layer.rkt"
         "kind.rkt"
         "lex.rkt")

(define word-color-count 12)

;; djb2：稳定散列（不依赖 equal-hash-code 的随机性）。
(define (word-hash w)
  (for/fold ([h 5381]) ([c (in-string w)])
    (bitwise-and (+ (* h 33) (char->integer c)) #xFFFFFFFF)))

(define (word-color-line _ln line)
  (define vec (make-vector (string-length line) #f))
  (define n (string-length line))
  (let loop ([i 0])
    (cond
      [(>= i n) vec]
      [(symbol-char? (string-ref line i))
       (define end (let next ([j (add1 i)])
                     (if (and (< j n) (symbol-char? (string-ref line j))) (next (add1 j)) j)))
       (define w (substring line i end))
       (define face (string->symbol
                     (format "fg-word-~a" (modulo (word-hash w) word-color-count))))
       (for ([k (in-range i end)])
         (vector-set! vec k (face-set-fg face-empty face)))
       (loop end)]
      [else (loop (add1 i))])))

(define (word-color-open _path text)
  (values #f (scan-track text word-color-line)))

(define (word-color-change state layer ctx)
  (define changes (face-ctx-changes ctx))
  (cond
    [(null? changes) (values state layer (dirty-lines '()))]
    [else
     (values state
             (refresh-layer layer (face-ctx-new-text ctx) changes '() word-color-line)
             (face-ctx-dirty ctx))]))

(define word-color-face-decor
  (face-decor 'word-color 'word-color racket-doc-meta? word-color-open word-color-change))
