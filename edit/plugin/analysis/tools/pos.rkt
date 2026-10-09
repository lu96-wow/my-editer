#lang racket

;;; edit/plugin/analysis/tools/pos.rkt —— 字符偏移 ↔ (line,col)（纯）
;;;
;;; 编辑器把文本归一为只含 \n（track 的 lines->string）。行 / 列 0-based，
;;; 与 core track 的 (line,col) 一致。
;;;
;;; 建一次「行首偏移向量」，之后查行 O(log n)、行列互转 O(log n)。
;;; 本模块不依赖 core / session / tui。

(provide (struct-out line-index) make-line-index
         line-count line-start line-end line-length
         clamp-offset offset->line offset->col offset->line/col line/col->offset)

(struct line-index (starts len) #:prefab)
;; starts : (vectorof exact-nonnegative-integer)  各行首字符偏移；starts[0] = 0
;; len    : 文本字符数

(define (make-line-index text)
  (define n (string-length text))
  (define rev
    (let loop ([i 0] [acc (list 0)])
      (cond
        [(>= i n) acc]
        [(char=? (string-ref text i) #\newline) (loop (add1 i) (cons (add1 i) acc))]
        [else (loop (add1 i) acc)])))
  (line-index (list->vector (reverse rev)) n))

(define (line-count idx) (vector-length (line-index-starts idx)))

(define (clamp-offset idx off)
  (max 0 (min off (line-index-len idx))))

(define (line-start idx l) (vector-ref (line-index-starts idx) l))

;; 行末偏移（不含换行；末行 = 文本末）。
(define (line-end idx l)
  (if (< (add1 l) (line-count idx))
      (sub1 (vector-ref (line-index-starts idx) (add1 l)))
      (line-index-len idx)))

(define (line-length idx l) (max 0 (- (line-end idx l) (line-start idx l))))

;; 最大的 l 使 starts[l] <= off（starts 非空）。
(define (line-of-offset idx off)
  (define starts (line-index-starts idx))
  (let loop ([lo 0] [hi (sub1 (vector-length starts))])
    (if (>= lo hi)
        lo
        (let ([mid (quotient (+ lo hi 1) 2)])
          (if (<= (vector-ref starts mid) off) (loop mid hi) (loop lo (sub1 mid)))))))

(define (offset->line idx off) (line-of-offset idx (clamp-offset idx off)))

(define (offset->col idx off)
  (define o (clamp-offset idx off))
  (- o (line-start idx (line-of-offset idx o))))

(define (offset->line/col idx off)
  (define o (clamp-offset idx off))
  (define l (line-of-offset idx o))
  (values l (- o (line-start idx l))))

(define (line/col->offset idx l c)
  (define l* (max 0 (min l (sub1 (line-count idx)))))
  (define c* (max 0 (min c (line-length idx l*))))
  (+ (line-start idx l*) c*))
