#lang racket

;;; width.rkt —— 显示宽度（wcwidth 语义）与「格索引 ↔ 显示列」换算
;;;
;;; 这是**唯一的换算层**：文本和属性共用同一套字符索引，只有渲染时需要把
;;; 「字符索引」变成「屏幕显示列」（宽字符占 2 列、组合字符占 0 列）。
;;; 把它放在一处，就不会出现「文本一套、属性一套」的不一致。
;;;
;;; 约定：本文件的索引是**字符索引**（与 line.rkt / Racket string 一致）；
;;; 显示列是终端/GUI 的列坐标。二者只经这里的函数互转。
;;;
;;; **粒度约定**：本编辑器按**码点**（Racket char）编辑——光标 / 选区 / 插入删除的
;;; 最小单位是一个码点，**不做 grapheme 簇分割**。所以 "e"+U+0301 算 2 格、
;;; ZWJ 序列/旗帜可能被拆开，这是既定行为。组合标记等 0 宽**只用于显示对齐**
;;; （不占列），并不意味着它们是同一个编辑单位。

(provide
 ;; ---------- 显示宽 ----------
 char-display-width
 string-display-width

 ;; ---------- 索引 ↔ 显示列 ----------
 index->display-column
 display-col->index
 snap-display-col-forward)

;;; ---------- 宽字符区间（East Asian Wide/Fullwidth），升序二分 ----------
(define wide-ranges
  '((#x1100 . #x115F)
    (#x2329 . #x232A)
    (#x2E80 . #x2FFB)
    (#x3000 . #x303E)
    (#x3041 . #x33FF)
    (#x3400 . #x4DBF)
    (#x4E00 . #x9FFF)
    (#xA000 . #xA4CF)
    (#xA960 . #xA97C)
    (#xAC00 . #xD7A3)
    (#xF900 . #xFAFF)
    (#xFE10 . #xFE19)
    (#xFE30 . #xFE6B)
    (#xFF00 . #xFF60)
    (#xFFE0 . #xFFE6)
    (#x1B000 . #x1B2FF)
    (#x1F300 . #x1F64F)
    (#x1F900 . #x1F9FF)
    (#x20000 . #x2FFFD)
    (#x30000 . #x3FFFD)))
(define wide-ranges-v (list->vector wide-ranges))

(define (wide-char? c)
  (define cp (char->integer c))
  (let loop ([lo 0] [hi (sub1 (vector-length wide-ranges-v))])
    (cond
      [(> lo hi) #f]
      [else
       (define mid (quotient (+ lo hi) 2))
       (define r (vector-ref wide-ranges-v mid))
       (cond [(< cp (car r)) (loop lo (sub1 mid))]
             [(> cp (cdr r)) (loop (add1 mid) hi)]
             [else #t])])))

;; Mn 非间距标记 / Me 包围标记 / Cf 格式符（ZWJ 等）→ 0 列
(define (zero-width-char? c)
  (memq (char-general-category c) '(mn me cf)))

(define (char-display-width c)
  (cond [(wide-char? c) 2]
        [(zero-width-char? c) 0]
        [else 1]))

(define (string-display-width s)
  (for/sum ([c (in-string s)]) (char-display-width c)))

;; 字符索引 i 处的显示列（i 是字符边界；i = 长度 → 总列数）。
(define (index->display-column s i)
  (let loop ([j 0] [col 0])
    (cond [(>= j i) col]
          [else (loop (add1 j) (+ col (char-display-width (string-ref s j))))])))

;; 显示列 col 落在哪个字符上 → 字符索引。
;; 约定：宽字符右半格命中同一字符；0 宽字符附在前一基字符上；越界 → 字符串长度。
(define (display-col->index s col)
  (define n (string-length s))
  (let loop ([j 0] [start 0])
    (cond
      [(>= j n) n]
      [else
       (define w (char-display-width (string-ref s j)))
       (cond [(zero? w) (loop (add1 j) start)]
             [(< col (+ start w)) j]
             [else (loop (add1 j) (+ start w))])])))

;; 把显示列 L 吸附到「字符起点列」：落在宽字符右半 → 后移到下一字符起点。
(define (snap-display-col-forward s L)
  (define L* (max 0 L))
  (define n (string-length s))
  (define i (display-col->index s L*))
  (cond
    [(>= i n) (string-display-width s)]
    [else
     (define c (index->display-column s i))
     (if (= c L*) L* (+ c (char-display-width (string-ref s i))))]))
