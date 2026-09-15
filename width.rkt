#lang racket

(require rackunit)

;;; width.rkt —— 显示宽度（wcwidth 语义，但用 Unicode 表，确定性、不依赖 locale）
;;;
;;; 终端会自动把宽字符显示成 2 列，所以本模块的职责不是「加空格」，
;;; 而是提供几何换算：
;;;   - char-display-width   字符占几列（0/1/2）
;;;   - string-display-width 字符串总列数
;;;   - index->column        字符索引 → 显示列（光标定位用）
;;;   - column->index        显示列 → 字符索引（鼠标命中用）
;;;
;;; 宽度判定：
;;;   2 : East Asian Wide/Fullwidth（下表区间）
;;;   0 : 组合字符（Mn/Me）与零宽格式符（Cf）
;;;   1 : 其余（含 tab——tab 展开由 paint 层负责，这里按 1 计）
;;;
;;; 注意：Ambiguous（A）按 1 列处理（与 xterm/qterminal 默认一致）。
;;;       组合字符 width=0，不占列，column->index 会把它附到前一个基字符上。

(provide
 char-display-width
 string-display-width
 index->column
 column->index
 snap-column-forward)

;;; ---------- 宽字符区间表（East Asian Wide/Fullwidth）----------
;; 排序 + 二分。覆盖 CJK 统一表意文字、假名、谚文、全角、表情、CJK 扩展。

(define wide-ranges
  '((#x1100 . #x115F)   ; Hangul Jamo
    (#x2329 . #x232A)   ; 尖括号（W）
    (#x2E80 . #x2FFB)   ; CJK 部首 / 康熙部首 / 表意描述
    (#x3000 . #x303E)   ; CJK 符号与标点
    (#x3041 . #x33FF)   ; 平假名 / 片假名 / 注音 / CJK 兼容
    (#x3400 . #x4DBF)   ; CJK 扩展 A
    (#x4E00 . #x9FFF)   ; CJK 统一表意文字（中文主体）
    (#xA000 . #xA4CF)   ; 彝文
    (#xA960 . #xA97C)   ; Hangul Jamo 扩展 A
    (#xAC00 . #xD7A3)   ; 谚文音节
    (#xF900 . #xFAFF)   ; CJK 兼容表意
    (#xFE10 . #xFE19)   ; 竖排形式
    (#xFE30 . #xFE6B)   ; CJK 兼容形式 / 小型变体
    (#xFF00 . #xFF60)   ; 全角形式
    (#xFFE0 . #xFFE6)   ; 全角符号
    (#x1B000 . #x1B2FF) ; 假名补充 / 假名扩展 A
    (#x1F300 . #x1F64F) ; 表情符号
    (#x1F900 . #x1F9FF) ; 补充表情
    (#x20000 . #x2FFFD) ; CJK 扩展 B~F
    (#x30000 . #x3FFFD) ; CJK 扩展 G
    ))

(define wide-ranges-v (list->vector wide-ranges)) ; 已按升序书写

(define (wide-char? c)
  (define cp (char->integer c))
  (let loop ([lo 0] [hi (sub1 (vector-length wide-ranges-v))])
    (cond
      [(> lo hi) #f]
      [else
       (define mid (quotient (+ lo hi) 2))
       (define r (vector-ref wide-ranges-v mid))
       (cond
         [(< cp (car r))  (loop lo (sub1 mid))]
         [(> cp (cdr r))  (loop (add1 mid) hi)]
         [else #t])])))

(define (zero-width-char? c)
  ;; Mn=非间距标记 Me=包围标记 Cf=格式符（ZWJ/ZWNJ 等）
  (memq (char-general-category c) '(mn me cf)))

(define (char-display-width c)
  (cond
    [(wide-char? c) 2]
    [(zero-width-char? c) 0]
    [else 1]))

(define (string-display-width s)
  (for/sum ([c (in-string s)]) (char-display-width c)))

;; 字符索引 i 处的显示列（i 是字符边界，i = 字符串长度时 = 总列数）。
(define (index->column s i)
  (let loop ([j 0] [col 0])
    (cond
      [(>= j i) col]
      [else (loop (add1 j)
                  (+ col (char-display-width (string-ref s j))))])))

;; 列吸附：把任意显示列 L 规范到「字符起点列」（即该列处的字符可被完整显示）。
;; 规则：
;;   L 恰在字符起点 → 原样返回；
;;   L 落在宽字符右半格 → 前移到下一字符起点（保证左边界不丢字、无空格浮动）；
;;   L 越界（>= 总列数）→ 返回总列数。
(define (snap-column-forward s L)
  (define n (string-length s))
  (define i (column->index s L))
  (cond
    [(>= i n) (string-display-width s)]
    [else
     (define c (index->column s i))
     (if (= c L) L
         (+ c (char-display-width (string-ref s i))))]))

;; 显示列 col 落在哪个字符上，返回该字符的索引。
;; 约定：宽字符的右半格命中同一字符；0 宽字符附着在前一个基字符上；
;;       col 超出末尾时返回字符串长度。
(define (column->index s col)
  (define n (string-length s))
  (let loop ([j 0] [start 0])   ; start = 字符 j 起始列
    (cond
      [(>= j n) n]
      [else
       (define w (char-display-width (string-ref s j)))
       (cond
         [(zero? w) (loop (add1 j) start)]          ; 0 宽：不推进列
         [(< col (+ start w)) j]                    ; 落在 [start, start+w)
         [else (loop (add1 j) (+ start w))])])))

;;; ---------- 测试 ----------

(module+ test
  ;; 基本宽度
  (check-equal? (char-display-width #\a) 1)
  (check-equal? (char-display-width #\A) 1)
  (check-equal? (char-display-width #\1) 1)
  (check-equal? (char-display-width #\space) 1)

  ;; 中文 / 假名 / 谚文 / 全角 / 表情 → 2
  (check-equal? (char-display-width #\中) 2)
  (check-equal? (char-display-width #\你) 2)
  (check-equal? (char-display-width #\あ) 2)          ; 3042 平假名
  (check-equal? (char-display-width #\가) 2)          ; AC00 谚文
  (check-equal? (char-display-width #\！) 2)          ; FF01 全角！
  (check-equal? (char-display-width #\😀) 2)          ; 1F600 表情

  ;; 组合字符 / 零宽 → 0
  (check-equal? (char-display-width (integer->char #x0301)) 0) ; 组合重音
  (check-equal? (char-display-width (integer->char #x200D)) 0) ; ZWJ

  ;; 字符串总宽
  (check-equal? (string-display-width "abc") 3)
  (check-equal? (string-display-width "中文") 4)
  (check-equal? (string-display-width "a中b") 4)
  (check-equal? (string-display-width "e\u0301") 1)   ; e + 组合重音 = 1 列

  ;; index -> column
  (define s "a中b")
  (check-equal? (index->column s 0) 0)
  (check-equal? (index->column s 1) 1)   ; 中 在列 1
  (check-equal? (index->column s 2) 3)   ; b 在列 3（中占 1~3）
  (check-equal? (index->column s 3) 4)   ; 末尾 = 总列数

  ;; column -> index
  (check-equal? (column->index s 0) 0)   ; 列 0 → a
  (check-equal? (column->index s 1) 1)   ; 列 1 → 中（左半）
  (check-equal? (column->index s 2) 1)   ; 列 2 → 中（右半，命中同一字符）
  (check-equal? (column->index s 3) 2)   ; 列 3 → b
  (check-equal? (column->index s 4) 3)   ; 列 4 → 末尾

  ;; 0 宽字符附着：光标不能落在组合字符前
  (define t "e\u0301x")
  (check-equal? (string-display-width t) 2)
  (check-equal? (index->column t 2) 1)   ; 组合字符后仍在第 1 列
  (check-equal? (column->index t 0) 0)
  (check-equal? (column->index t 1) 2)   ; 列 1 → x（跳过 0 宽组合）

  ;; 列吸附：snap-column-forward
  ;; "中a中" 的列：中[0,2) a[2,3) 中[3,5)；边界 0/2/3/5
  (define sw "中a中")
  (check-equal? (snap-column-forward sw 0) 0)    ; 边界，不变
  (check-equal? (snap-column-forward sw 1) 2)    ; 右半格 → 下一字符起点
  (check-equal? (snap-column-forward sw 2) 2)    ; 边界，不变
  (check-equal? (snap-column-forward sw 3) 3)    ; 边界，不变
  (check-equal? (snap-column-forward sw 4) 5)    ; 右半格 → 行尾
  (check-equal? (snap-column-forward sw 5) 5)    ; 行尾
  (check-equal? (snap-column-forward sw 99) 5)   ; 越界 → 总列数

  (displayln "width.rkt: all tests passed"))
