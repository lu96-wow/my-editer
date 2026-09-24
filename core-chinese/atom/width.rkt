#lang racket

(require rackunit)

;;; width.rkt —— 显示宽度（wcwidth 语义，查 Unicode 表，不依赖 locale）
;;;
;;; 终端/GUI 自己会把宽字符显示成 2 列，所以本层只做**几何换算**，不加空格：
;;;   字符-显示-宽度 / 字符串-显示-宽度   一个字符 / 一串占几列
;;;   索引->显示列 / 显示列->索引               字符索引 ↔ 显示列
;;;   吸附-显示列-前向                         把显示列规范到「字符起点」
;;;
;;; 宽度规则：2 = East Asian Wide/Fullwidth；0 = 组合字符(Mn/Me)与格式符(Cf)；
;;;           1 = 其余（含 tab —— tab 按 1 计，要展开是使用方的事）。
;;; Ambiguous 按 1。组合字符宽 0，不占列，显示列->索引 会把它附到前一个基字符。

(provide
 字符-显示-宽度
 字符串-显示-宽度
 索引->显示列
 显示列->索引
 吸附-显示列-前向)

;;; ---------- 宽字符区间（East Asian Wide/Fullwidth）----------
;; 已按升序排列，二分查找。
(define 宽字符范围
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
(define 宽字符范围-v (list->vector 宽字符范围))

(define (宽-字符? c)
  (define cp (char->integer c))
  (let loop ([lo 0] [hi (sub1 (vector-length 宽字符范围-v))])
    (cond
      [(> lo hi) #f]
      [else
       (define 中点 (quotient (+ lo hi) 2))
       (define r (vector-ref 宽字符范围-v 中点))
       (cond [(< cp (car r)) (loop lo (sub1 中点))]
             [(> cp (cdr r)) (loop (add1 中点) hi)]
             [else #t])])))

;; Mn 非间距标记 / Me 包围标记 / Cf 格式符（ZWJ 等）
(define (零-宽度-字符? c)
  (memq (char-general-category c) '(mn me cf)))

(define (字符-显示-宽度 c)
  (cond [(宽-字符? c) 2]
        [(零-宽度-字符? c) 0]
        [else 1]))

(define (字符串-显示-宽度 s)
  (for/sum ([c (in-string s)]) (字符-显示-宽度 c)))

;; 字符索引 i 处的显示列（i 是字符边界；i = 长度 → 总列数）。
(define (索引->显示列 s i)
  (let loop ([j 0] [列 0])
    (cond [(>= j i) 列]
          [else (loop (add1 j) (+ 列 (字符-显示-宽度 (string-ref s j))))])))

;; 显示列 列 落在哪个字符上 → 字符索引。
;; 约定：宽字符右半格命中同一字符；0 宽字符附在前一基字符上；越界 → 字符串长度。
(define (显示列->索引 s 列)
  (define n (string-length s))
  (let loop ([j 0] [起点 0])
    (cond
      [(>= j n) n]
      [else
       (define w (字符-显示-宽度 (string-ref s j)))
       (cond [(zero? w) (loop (add1 j) 起点)]
             [(< 列 (+ 起点 w)) j]
             [else (loop (add1 j) (+ 起点 w))])])))

;; 把显示列 L 吸附到「字符起点列」：L 恰在起点 / ≥总宽 → 规范化；落在宽字符右半 → 后移到下一字符起点。
;; L < 0 按 0 处理。
(define (吸附-显示列-前向 s L)
  (define L* (max 0 L))
  (define n (string-length s))
  (define i (显示列->索引 s L*))
  (cond
    [(>= i n) (字符串-显示-宽度 s)]
    [else
     (define c (索引->显示列 s i))
     (if (= c L*) L* (+ c (字符-显示-宽度 (string-ref s i))))]))

;;; ---------- 测试 ----------

(module+ test
  ;; 字符/串显示宽度（宽字符=2，组合字符/ZWJ=0）
  (check-equal? (字符-显示-宽度 #\a) 1)
  (check-equal? (字符-显示-宽度 #\中) 2)
  (check-equal? (字符-显示-宽度 #\あ) 2)
  (check-equal? (字符-显示-宽度 #\가) 2)
  (check-equal? (字符-显示-宽度 #\！) 2)
  (check-equal? (字符-显示-宽度 #\😀) 2)
  (check-equal? (字符-显示-宽度 (integer->char #x0301)) 0)   ; 组合重音
  (check-equal? (字符-显示-宽度 (integer->char #x200D)) 0)   ; ZWJ

  (check-equal? (字符串-显示-宽度 "abc") 3)
  (check-equal? (字符串-显示-宽度 "中文") 4)
  (check-equal? (字符串-显示-宽度 "a中b") 4)
  (check-equal? (字符串-显示-宽度 "e\u0301") 1)

  ;; 索引 ↔ 显示列
  (define s "a中b")
  (check-equal? (索引->显示列 s 0) 0)
  (check-equal? (索引->显示列 s 1) 1)
  (check-equal? (索引->显示列 s 2) 3)
  (check-equal? (索引->显示列 s 3) 4)
  (check-equal? (显示列->索引 s 0) 0)
  (check-equal? (显示列->索引 s 1) 1)
  (check-equal? (显示列->索引 s 2) 1)    ; 右半格命中同一字符
  (check-equal? (显示列->索引 s 3) 2)
  (check-equal? (显示列->索引 s 4) 3)

  ;; 0 宽字符附着
  (define t "e\u0301x")
  (check-equal? (字符串-显示-宽度 t) 2)
  (check-equal? (显示列->索引 t 0) 0)
  (check-equal? (显示列->索引 t 1) 2)    ; 跳过组合字符到 x

  ;; 列吸附："中a中" 的边界 0/2/3/5
  (define sw "中a中")
  (check-equal? (吸附-显示列-前向 sw 0) 0)
  (check-equal? (吸附-显示列-前向 sw 1) 2)   ; 右半格 → 下一字符起点
  (check-equal? (吸附-显示列-前向 sw 2) 2)
  (check-equal? (吸附-显示列-前向 sw 3) 3)
  (check-equal? (吸附-显示列-前向 sw 4) 5)
  (check-equal? (吸附-显示列-前向 sw 5) 5)
  (check-equal? (吸附-显示列-前向 sw 99) 5)
  (check-equal? (吸附-显示列-前向 sw -1) 0)

  (displayln "width.rkt: all tests passed"))
