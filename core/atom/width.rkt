#lang racket

(require rackunit)

;;; width.rkt —— 显示宽度（wcwidth 语义，查 Unicode 表，不依赖 locale）
;;;
;;; 终端/GUI 自己会把宽字符显示成 2 列，所以本层只做**几何换算**，不加空格：
;;;   char-display-width / string-display-width   一个字符 / 一串占几列
;;;   index->column / column->index               字符索引 ↔ 显示列
;;;   snap-column-forward                         把显示列规范到「字符起点」
;;;
;;; 宽度规则：2 = East Asian Wide/Fullwidth；0 = 组合字符(Mn/Me)与格式符(Cf)；
;;;           1 = 其余（含 tab —— tab 按 1 计，要展开是使用方的事）。
;;; Ambiguous 按 1。组合字符宽 0，不占列，column->index 会把它附到前一个基字符。

(provide
 char-display-width
 string-display-width
 index->column
 column->index
 snap-column-forward)

;;; ---------- 宽字符区间（East Asian Wide/Fullwidth）----------
;; 已按升序排列，二分查找。
(define wide-ranges
  '((#x1100 . #x115F)   ; Hangul Jamo
    (#x2329 . #x232A)
    (#x2E80 . #x2FFB)   ; CJK 部首 / 康熙部首
    (#x3000 . #x303E)   ; CJK 符号与标点
    (#x3041 . #x33FF)   ; 假名 / 注音 / CJK 兼容
    (#x3400 . #x4DBF)   ; CJK 扩展 A
    (#x4E00 . #x9FFF)   ; CJK 统一表意
    (#xA000 . #xA4CF)   ; 彝文
    (#xA960 . #xA97C)
    (#xAC00 . #xD7A3)   ; 谚文音节
    (#xF900 . #xFAFF)
    (#xFE10 . #xFE19)
    (#xFE30 . #xFE6B)
    (#xFF00 . #xFF60)   ; 全角
    (#xFFE0 . #xFFE6)
    (#x1B000 . #x1B2FF)
    (#x1F300 . #x1F64F) ; 表情
    (#x1F900 . #x1F9FF)
    (#x20000 . #x2FFFD) ; CJK 扩展 B~F
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

;; Mn 非间距标记 / Me 包围标记 / Cf 格式符（ZWJ 等）
(define (zero-width-char? c)
  (memq (char-general-category c) '(mn me cf)))

(define (char-display-width c)
  (cond [(wide-char? c) 2]
        [(zero-width-char? c) 0]
        [else 1]))

(define (string-display-width s)
  (for/sum ([c (in-string s)]) (char-display-width c)))

;; 字符索引 i 处的显示列（i 是字符边界；i = 长度 → 总列数）。
(define (index->column s i)
  (let loop ([j 0] [col 0])
    (cond [(>= j i) col]
          [else (loop (add1 j) (+ col (char-display-width (string-ref s j))))])))

;; 显示列 col 落在哪个字符上 → 字符索引。
;; 约定：宽字符右半格命中同一字符；0 宽字符附在前一基字符上；越界 → 字符串长度。
(define (column->index s col)
  (define n (string-length s))
  (let loop ([j 0] [start 0])
    (cond
      [(>= j n) n]
      [else
       (define w (char-display-width (string-ref s j)))
       (cond [(zero? w) (loop (add1 j) start)]
             [(< col (+ start w)) j]
             [else (loop (add1 j) (+ start w))])])))

;; 把显示列 L 吸附到「字符起点列」：L 恰在起点 / ≥总宽 → 规范化；落在宽字符右半 → 后移到下一字符起点。
;; L < 0 按 0 处理。
(define (snap-column-forward s L)
  (define L* (max 0 L))
  (define n (string-length s))
  (define i (column->index s L*))
  (cond
    [(>= i n) (string-display-width s)]
    [else
     (define c (index->column s i))
     (if (= c L*) L* (+ c (char-display-width (string-ref s i))))]))

;;; ---------- 测试 ----------

(module+ test
  ;; 字符/串显示宽度（宽字符=2，组合字符/ZWJ=0）
  (check-equal? (char-display-width #\a) 1)
  (check-equal? (char-display-width #\中) 2)
  (check-equal? (char-display-width #\あ) 2)
  (check-equal? (char-display-width #\가) 2)
  (check-equal? (char-display-width #\！) 2)
  (check-equal? (char-display-width #\😀) 2)
  (check-equal? (char-display-width (integer->char #x0301)) 0)   ; 组合重音
  (check-equal? (char-display-width (integer->char #x200D)) 0)   ; ZWJ

  (check-equal? (string-display-width "abc") 3)
  (check-equal? (string-display-width "中文") 4)
  (check-equal? (string-display-width "a中b") 4)
  (check-equal? (string-display-width "e\u0301") 1)

  ;; index ↔ column
  (define s "a中b")
  (check-equal? (index->column s 0) 0)
  (check-equal? (index->column s 1) 1)
  (check-equal? (index->column s 2) 3)
  (check-equal? (index->column s 3) 4)
  (check-equal? (column->index s 0) 0)
  (check-equal? (column->index s 1) 1)
  (check-equal? (column->index s 2) 1)    ; 右半格命中同一字符
  (check-equal? (column->index s 3) 2)
  (check-equal? (column->index s 4) 3)

  ;; 0 宽字符附着
  (define t "e\u0301x")
  (check-equal? (string-display-width t) 2)
  (check-equal? (column->index t 0) 0)
  (check-equal? (column->index t 1) 2)    ; 跳过组合字符到 x

  ;; 列吸附："中a中" 的边界 0/2/3/5
  (define sw "中a中")
  (check-equal? (snap-column-forward sw 0) 0)
  (check-equal? (snap-column-forward sw 1) 2)   ; 右半格 → 下一字符起点
  (check-equal? (snap-column-forward sw 2) 2)
  (check-equal? (snap-column-forward sw 3) 3)
  (check-equal? (snap-column-forward sw 4) 5)
  (check-equal? (snap-column-forward sw 5) 5)
  (check-equal? (snap-column-forward sw 99) 5)
  (check-equal? (snap-column-forward sw -1) 0)

  (displayln "width.rkt: all tests passed"))
