#lang racket

(require "point.rkt" rackunit)

;;; content.rkt —— 行向量 + gap 游标文本存储
;;;
;;; 核心原语只有一个：splice。
;;;   删除 [s-line,s-col) .. [e-line,e-col)，插入 new-text（可含 \n）。
;;; 其余编辑（插入/删除/换行/合并）都是 splice 的特例。
;;;
;;; 一次编辑返回 (values new-content edit-desc)；
;;; edit-desc 是唯一跨层契约，marker/props/overlay 各自解释。

(provide
 (struct-out content)
 (struct-out edit-desc)
 make-content
 content-of-lines
 content-of-string
 string->lines
 content->lines
 content->string
 content-current-line
 content-line-count
 content-line-ref
 content-check
 content-set-col
 content-gap-up
 content-gap-down
 content-gap-goto
 content-splice
 content-insert-char
 content-insert-string
 content-newline
 content-backspace
 content-delete
 edit-desc-map-position
 edit-desc-after-position)

(struct content (lines gap-line gap-col) #:transparent)
;; lines    : (vectorof string)   至少一行
;; gap-line : 当前行号
;; gap-col  : 当前行内列号

;; 一次编辑 = 删除区间 + 插入文本。全部「操作前坐标」。
;;   [s-line,s-col) .. [e-line,e-col)  被删除的半开区间
;;   new-text                          插入的文本（可含 \n）
;; 语义：文本 = before(start) + new-text + after(end)。
(struct edit-desc (s-line s-col e-line e-col new-text) #:transparent)

;;; ---------- 不变量断言 ----------

(define (content-check c)
  (define n (vector-length (content-lines c)))
  (unless (>= n 1) (error 'content-check "empty lines"))
  (unless (and (exact-nonnegative-integer? (content-gap-line c))
               (< (content-gap-line c) n))
    (error 'content-check "bad gap-line ~a" (content-gap-line c)))
  (unless (and (exact-nonnegative-integer? (content-gap-col c))
               (<= (content-gap-col c)
                   (string-length (content-line-ref c (content-gap-line c)))))
    (error 'content-check "bad gap-col ~a" (content-gap-col c)))
  c)

;;; ---------- 构造 ----------

(define (make-content) (content (vector "") 0 0))

(define (content-of-lines lines)
  (unless (and (pair? lines) (andmap string? lines))
    (error 'content-of-lines "expect non-empty list of strings, got ~a" lines))
  (content-check (content (list->vector lines) 0 0)))

;; 把字符串拆成行（统一行尾）：\n、\r\n、孤立 \r 都视为一个换行。
;; 结果至少一行；"a\n" => '("a" "")（保留尾部空行）。
(define (string->lines s)
  (define ls (string-split (regexp-replace* #rx"\r\n?" s "\n") "\n" #:trim? #f))
  (if (null? ls) (list "") ls))

(define (content-of-string s)
  (unless (string? s) (error 'content-of-string "expect string, got ~a" s))
  (content-check (content (list->vector (string->lines s)) 0 0)))

;;; ---------- 投影 ----------

(define (content->lines c)       (vector->list (content-lines c)))
(define (content->string c)      (string-join (content->lines c) "\n"))
(define (content-current-line c) (vector-ref (content-lines c) (content-gap-line c)))
(define (content-line-count c)   (vector-length (content-lines c)))
(define (content-line-ref c i)   (vector-ref (content-lines c) i))

;;; ---------- gap 定位（全部 O(1)）----------

(define (content-set-col c col)
  (define l (content-gap-line c))
  (struct-copy content c
    [gap-col (max 0 (min col (string-length (content-line-ref c l))))]))

(define (content-gap-up c)
  (define l (content-gap-line c))
  (if (> l 0)
      (struct-copy content c
        [gap-line (sub1 l)]
        [gap-col (min (content-gap-col c)
                      (string-length (content-line-ref c (sub1 l))))])
      c))

(define (content-gap-down c)
  (define l (content-gap-line c))
  (if (< l (sub1 (content-line-count c)))
      (struct-copy content c
        [gap-line (add1 l)]
        [gap-col (min (content-gap-col c)
                      (string-length (content-line-ref c (add1 l))))])
      c))

(define (content-gap-goto c line col)
  (define n (content-line-count c))
  (define l (max 0 (min line (sub1 n))))
  (content (content-lines c) l
           (max 0 (min col (string-length (content-line-ref c l))))))

;;; ---------- 核心：splice ----------

(define (content-splice c s-line s-col e-line e-col new-text)
  (define lines (content-lines c))
  (define n (vector-length lines))
  (define head (substring (vector-ref lines s-line) 0 s-col))
  (define tail (substring (vector-ref lines e-line) e-col
                          (string-length (vector-ref lines e-line))))
  (define new-lines (list->vector (string->lines new-text)))
  (define k (vector-length new-lines))
  (define inserted (max 1 k))                       ; k=0 时是合并出的 1 行
  (define new-n (- (+ n inserted) (+ (- e-line s-line) 1)))
  (define v* (make-vector new-n #f))
  (vector-copy! v* 0 lines 0 s-line)
  (cond
    [(zero? k) (vector-set! v* s-line (string-append head tail))]
    [(= k 1)   (vector-set! v* s-line (string-append head (vector-ref new-lines 0) tail))]
    [else
     (vector-set! v* s-line (string-append head (vector-ref new-lines 0)))
     (for ([i (in-range 1 (sub1 k))])
       (vector-set! v* (+ s-line i) (vector-ref new-lines i)))
     (vector-set! v* (+ s-line (sub1 k))
                  (string-append (vector-ref new-lines (sub1 k)) tail))])
  (vector-copy! v* (+ s-line inserted) lines (add1 e-line) n)
  (define gap-line (if (zero? k) s-line (+ s-line (sub1 k))))
  (define gap-col
    (cond [(zero? k) s-col]
          [(= k 1)   (+ s-col (string-length (vector-ref new-lines 0)))]
          [else      (string-length (vector-ref new-lines (sub1 k)))]))
  (values (content-check (content v* gap-line gap-col))
          (edit-desc s-line s-col e-line e-col new-text)))

;;; ---------- 编辑原语（都是 splice 的特例）----------

(define (content-insert-char c ch)
  (define l (content-gap-line c))
  (define col (content-gap-col c))
  (content-splice c l col l col (string ch)))

(define (content-insert-string c s)
  (define l (content-gap-line c))
  (define col (content-gap-col c))
  (if (zero? (string-length s))
      (values c #f)
      (content-splice c l col l col s)))

(define (content-newline c)
  (define l (content-gap-line c))
  (define col (content-gap-col c))
  (content-splice c l col l col "\n"))

(define (content-backspace c)
  (define l (content-gap-line c))
  (define col (content-gap-col c))
  (define line (content-line-ref c l))
  (cond
    [(> col 0)                                       ; 删 gap 前一个字符
     (content-splice c l (sub1 col) l col "")]
    [(> l 0)                                         ; 与上一行合并
     (define above (content-line-ref c (sub1 l)))
     (content-splice c (sub1 l) (string-length above) l 0 "")]
    [else (values c #f)]))

(define (content-delete c)
  (define l (content-gap-line c))
  (define col (content-gap-col c))
  (define line (content-line-ref c l))
  (cond
    [(< col (string-length line))                    ; 删 gap 处字符
     (content-splice c l col l (add1 col) "")]
    [(< l (sub1 (content-line-count c)))             ; 与下一行合并
     (content-splice c l col (add1 l) 0 "")]
    [else (values c #f)]))

;;; ---------- 位置映射（marker/props 共用的唯一调整机制）----------

;; 编辑前位置 -> 编辑后位置；返回 point 或 #f（#f = 落在被删区间内）
(define (edit-desc-map-position d l c)
  (define s-line (edit-desc-s-line d))
  (define s-col (edit-desc-s-col d))
  (define e-line (edit-desc-e-line d))
  (define e-col (edit-desc-e-col d))
  (define new-lines (string->lines (edit-desc-new-text d)))
  (define k (length new-lines))
  (define delta (- k (- e-line s-line) 1))           ; k - (e-line-s-line+1)
  (define last-len (if (zero? k) 0 (string-length (last new-lines))))
  (cond
    [(pos<? l c s-line s-col)   (point l c)]        ; 在起点之前
    [(pos=? l c s-line s-col)   (point l c)]        ; 插入点（before/after 由调用者处理）
    [(pos<? l c e-line e-col)   #f]                  ; 在 [start,end) 内 → 被删
    [else                                            ; >= end
     (cond
       [(= l e-line)
        (cond
          [(zero? k) (point s-line (+ s-col (- c e-col)))]
          ;; 单行插入：after 接在 before + 插入文本之后，需加 s-col
          [(= k 1)   (point s-line (+ s-col last-len (- c e-col)))]
          ;; 多行插入：after 接到最后一行行首（新行），不加 s-col
          [else      (point (+ s-line (sub1 k)) (+ last-len (- c e-col)))])]
       [else
        (point (+ l delta) c)])]))

;; 插入点处「插入文本之后」的位置（'after' marker 用）
(define (edit-desc-after-position d)
  (define new-lines (string->lines (edit-desc-new-text d)))
  (define k (length new-lines))
  (cond
    [(zero? k)   ; 纯删除：回到删除起点
     (point (edit-desc-s-line d) (edit-desc-s-col d))]
    [(= k 1)     ; 单行插入：起点 + 长度
     (point (edit-desc-s-line d)
             (+ (edit-desc-s-col d) (string-length (last new-lines))))]
    [else        ; 多行插入：末行行尾（末行从列 0 开始）
     (point (+ (edit-desc-s-line d) (sub1 k))
             (string-length (last new-lines)))]))

(define (pos<? l1 c1 l2 c2)
  (or (< l1 l2) (and (= l1 l2) (< c1 c2))))

(define (pos=? l1 c1 l2 c2)
  (and (= l1 l2) (= c1 c2)))

;;; ---------- 测试 ----------

(module+ test
  ;; 构造 & 投影
  (check-equal? (content->string (make-content)) "")
  (check-equal? (content->string (content-of-string "hello\nworld")) "hello\nworld")
  (check-equal? (content->lines  (content-of-string "hello\nworld"))
                (list "hello" "world"))
  (check-equal? (content-line-count (content-of-string "a\nb\nc")) 3)
  (check-equal? (content-current-line (content-of-string "hello\nworld")) "hello")
  ;; 尾部换行保留空行
  (check-equal? (content-line-count (content-of-string "a\nb\n")) 3)
  (check-equal? (content->string (content-of-string "a\nb\n")) "a\nb\n")
  ;; 统一行尾：\r\n / \r 都归一成 \n
  (check-equal? (content->lines (content-of-string "a\r\nb\rc")) '("a" "b" "c"))
  (check-equal? (content->string (content-of-string "a\r\nb")) "a\nb")

  (define c0 (content-of-string "hello\nworld"))
  (check-equal? (content-gap-line c0) 0)
  (check-equal? (content-gap-col  c0) 0)

  ;; gap 定位
  (define c-r3 (content-set-col c0 3))
  (check-equal? (content-gap-col c-r3) 3)
  (define c-dn (content-gap-down c0))
  (check-equal? (content-gap-line c-dn) 1)
  (define c-up (content-gap-up c-dn))
  (check-equal? (content-gap-line c-up) 0)
  (define c-g (content-gap-goto c0 1 3))
  (check-equal? (content-gap-line c-g) 1)
  (check-equal? (content-gap-col  c-g) 3)
  (check-equal? (content-gap-col (content-gap-goto c0 0 100)) 5)
  (check-equal? (content-gap-col (content-gap-goto c0 0 -5)) 0)

  ;; insert
  (define-values (c-i d-i) (content-insert-char c0 #\X))
  (check-equal? (content->string c-i) "Xhello\nworld")
  (check-equal? (content-gap-col c-i) 1)
  (check-equal? d-i (edit-desc 0 0 0 0 "X"))

  ;; insert（在非零列插入，光标也要正确推进）
  (define c-mid (content-set-col c0 2))
  (define-values (c-mid2 d-mid) (content-insert-char c-mid #\X))
  (check-equal? (content->string c-mid2) "heXllo\nworld")
  (check-equal? (content-gap-col c-mid2) 3)
  (check-equal? d-mid (edit-desc 0 2 0 2 "X"))

  ;; insert-text（多字符）
  (define-values (c-it d-it) (content-insert-string c0 "XYZ"))
  (check-equal? (content->string c-it) "XYZhello\nworld")
  (check-equal? (content-gap-col c-it) 3)
  (check-equal? d-it (edit-desc 0 0 0 0 "XYZ"))

  ;; newline
  (define c-n (content-set-col c0 2))
  (define-values (c-n2 d-n) (content-newline c-n))
  (check-equal? (content->string c-n2) "he\nllo\nworld")
  (check-equal? (content-gap-line c-n2) 1)
  (check-equal? (content-gap-col c-n2) 0)
  (check-equal? d-n (edit-desc 0 2 0 2 "\n"))

  ;; backspace 删字符
  (define-values (c-bs d-bs) (content-backspace c-n))
  (check-equal? (content->string c-bs) "hllo\nworld")
  (check-equal? (content-gap-col c-bs) 1)
  (check-equal? d-bs (edit-desc 0 1 0 2 ""))

  ;; backspace 合并
  (define c-bm-0 (content-gap-goto c0 1 0))
  (define-values (c-bm d-bm) (content-backspace c-bm-0))
  (check-equal? (content->string c-bm) "helloworld")
  (check-equal? (content-gap-line c-bm) 0)
  (check-equal? (content-gap-col c-bm) 5)
  (check-equal? d-bm (edit-desc 0 5 1 0 ""))

  ;; delete 删字符
  (define-values (c-dc d-dc) (content-delete c0))
  (check-equal? (content->string c-dc) "ello\nworld")
  (check-equal? d-dc (edit-desc 0 0 0 1 ""))

  ;; delete 合并
  (define c-dm-0 (content-gap-goto c0 0 5))
  (define-values (c-dm d-dm) (content-delete c-dm-0))
  (check-equal? (content->string c-dm) "helloworld")
  (check-equal? d-dm (edit-desc 0 5 1 0 ""))

  ;; 无操作边界
  (define-values (c-bs2 d-bs2) (content-backspace c0))
  (check-false d-bs2)
  (define c-end (content-gap-goto c0 1 5))
  (define-values (c-de d-de) (content-delete c-end))
  (check-false d-de)

  ;; splice：跨行删除 + 多行插入
  (define b3 (content-of-string "abcd\nefgh\nijkl"))
  (define-values (c-sp d-sp) (content-splice b3 0 1 2 1 "XY\nZ"))
  (check-equal? (content->string c-sp) "aXY\nZjkl")
  (check-equal? (content-gap-line c-sp) 1)
  (check-equal? (content-gap-col c-sp) 1)

  ;; 位置映射：对照上面 splice 的各个位置
  (check-equal? (edit-desc-map-position d-sp 0 0) (point 0 0))   ; 起点前不变
  (check-equal? (edit-desc-map-position d-sp 0 1) (point 0 1))   ; 插入点
  (check-false (edit-desc-map-position d-sp 0 2))                 ; 被删
  (check-false (edit-desc-map-position d-sp 1 0))                 ; 被删
  (check-equal? (edit-desc-map-position d-sp 2 1) (point 1 1))   ; == end
  (check-equal? (edit-desc-map-position d-sp 2 3) (point 1 3))   ; > end，同行
  (check-equal? (edit-desc-after-position d-sp) (point 1 1))     ; 多行插入之后
  ;; 单行插入在非零列：起点 + 长度（旧 bug 会丢掉 s-col）
  (check-equal? (edit-desc-after-position (edit-desc 0 3 0 3 "XY")) (point 0 5))
  ;; 宽字符插入：point 按字符数前进（中 = 1 字符，显示宽 2）
  (check-equal? (edit-desc-after-position (edit-desc 2 4 2 4 "中")) (point 2 5))
  ;; 纯删除：回到删除起点
  (check-equal? (edit-desc-after-position (edit-desc 0 1 0 3 "")) (point 0 1))

  (displayln "content.rkt: all tests passed"))
