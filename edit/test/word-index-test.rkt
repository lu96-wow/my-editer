#lang racket

;;; edit/test/word-index-test.rkt —— 增量词表正确性（纯）
;;;
;;;   raco test edit/test/word-index-test.rkt
;;;
;;; 对每次编辑：增量更新后的词表 == 整篇重建的词表。

(require rackunit
         "../lang/word-index.rkt"
         (only-in "../../core/text/base/track.rkt" track-of-list)
         (only-in "../../core/text/base/point.rkt" point)
         (only-in "../../core/text/base/range.rkt" range-of)
         (only-in "../../core/text/base/change.rkt" change)
         (only-in "../../core/text/base/line.rkt" string->lines))

(define (words-of text) (sort (word-index-words (word-index-open text)) string<?))
(define (check-equal-words label w text)
  (check-equal? (sort (word-index-words w) string<?) (words-of text) label))

;; 初始
(define t0 "alpha beta\ngamma alpha\n")
(define w (word-index-open t0))
(check-equal-words "initial" w t0)

;; 1) 行首插入 "delta "（单行，就地改）
(define t1 "delta alpha beta\ngamma alpha\n")
(define c1 (change (range-of (point 0 0) (point 0 0)) (range-of (point 0 0) (point 0 6))))
(void (word-index-update w (list c1) (track-of-list (string->lines t1))))
(check-equal-words "insert line0" w t1)

;; 2) 删除 "alpha"（单行）
(define t2 "delta  beta\ngamma alpha\n")
(define c2 (change (range-of (point 0 6) (point 0 11)) (range-of (point 0 6) (point 0 6))))
(void (word-index-update w (list c2) (track-of-list (string->lines t2))))
(check-equal-words "delete alpha" w t2)

;; 3) 跨行插入 "\nzzz "（重建行 vector）
(define t3 "delta  beta\ngamma\nzzz alpha\n")
(define c3 (change (range-of (point 1 5) (point 1 5)) (range-of (point 1 5) (point 2 4))))
(void (word-index-update w (list c3) (track-of-list (string->lines t3))))
(check-equal-words "multiline insert" w t3)

;; 4) 跨行删除（gamma\nzzz → 空，行合并）
(define t4 "delta  beta\n alpha\n")
(define c4 (change (range-of (point 1 0) (point 2 4)) (range-of (point 1 0) (point 1 0))))
(void (word-index-update w (list c4) (track-of-list (string->lines t4))))
(check-equal-words "multiline delete" w t4)
