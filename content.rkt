#lang racket

(require "cursor.rkt" rackunit)

;;; content.rkt —— 行向量 + gap 游标文本存储
;;;
;;; 设计：lines 是非空 string 向量，gap 是逻辑游标 (gap-line, gap-col)。
;;;   随机访问 O(1)；编辑在受影响行做字符串拼接 + vector-copy（O(n) memcpy）。
;;;   相比旧的「双 list gap buffer」，牺牲了 O(1) 拆行，换来 O(1) 行访问，
;;;   消除渲染 / 导航里的 O(n²)。
;;;
;;; 不变量
;;;   I1  lines 非空（至少一行）
;;;   I2  0 <= gap-line < (vector-length lines)
;;;   I3  0 <= gap-col <= 行长(gap-line)
;;;
;;; 每次编辑返回 (values new-content edit-desc)。
;;; edit-desc 是唯一跨层信息，描述「发生了什么」，由 marker / props / overlay 各自解释。

(provide
 (struct-out content)
 (struct-out edit-desc)
 content-empty
 content-of-lines
 content-of-string
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
 content-insert
 content-newline
 content-backspace
 content-delete)

;; content-gap-line / content-gap-col 由 (struct-out content) 的字段 accessor 提供。

;; edit-desc 的 kind 语义 —— 全部用「操作前坐标系」描述。
;; 消费者不需要做「操作前 / 操作后」的坐标系转换。
;;
;;   'insert-char     在 (line, col) 前插入 1 个字符；新字符占 (line, col)
;;   'newline         在 (line, col) 处拆分；(line, col) 及之后移到新行 line+1
;;   'backspace-char  删除 (line, col) 处的字符
;;   'delete-char     删除 (line, col) 处的字符
;;   'backspace-merge line 行（被合并行）整体拼到 (line-1, col) 处
;;   'delete-merge    line 行（被合并行）整体拼到 (line-1, col) 处
;;
;; 前置条件（供上层加断言用）：
;;   insert-char      : 0 <= col <= 行长(line)
;;   newline          : 0 <= col <= 行长(line)
;;   backspace-char   : 0 <= col <  行长(line)
;;   delete-char      : 0 <= col <  行长(line)
;;   backspace-merge  : line >= 1, col = 行长(line-1)
;;   delete-merge     : line >= 1, col = 行长(line-1)
;;
;; 注意：两种 merge 的 desc 结构完全一致（被合并行 + 保留行上的拼接点），
;; 差别只在 content 侧计算 line 的公式不同；消费者用同一套规则处理。
(struct edit-desc (kind line col) #:transparent)

(struct content (lines gap-line gap-col) #:transparent)
;; lines    : (vectorof string)   至少一行
;; gap-line : 当前行号
;; gap-col  : 当前行内列号

;;; ---------- 内部：不变量断言 ----------

(define (content-check c)
  (define n (vector-length (content-lines c)))
  (unless (>= n 1)
    (error 'content-check "invariant I1 broken: empty lines"))
  (unless (and (exact-nonnegative-integer? (content-gap-line c))
               (< (content-gap-line c) n))
    (error 'content-check "invariant I2 broken: gap-line ~a out of range ~a"
           (content-gap-line c) n))
  (unless (and (exact-nonnegative-integer? (content-gap-col c))
               (<= (content-gap-col c)
                   (string-length (content-line-ref c (content-gap-line c)))))
    (error 'content-check "invariant I3 broken: gap-col ~a" (content-gap-col c)))
  c)

;;; ---------- 构造 ----------

(define (content-empty) (content (vector "") 0 0))

(define (content-of-lines lines)
  (unless (and (pair? lines) (andmap string? lines))
    (error 'content-of-lines "expect non-empty list of strings, got ~a" lines))
  (content-check (content (list->vector lines) 0 0)))

(define (content-of-string s)
  (unless (string? s) (error 'content-of-string "expect string, got ~a" s))
  (content-check (content (list->vector (string-split s "\n")) 0 0)))

;;; ---------- 投影 ----------

(define (content->lines c)       (vector->list (content-lines c)))
(define (content->string c)      (string-join (content->lines c) "\n"))
(define (content-current-line c) (vector-ref (content-lines c) (content-gap-line c)))
(define (content-line-count c)   (vector-length (content-lines c)))
(define (content-line-ref c i)   (vector-ref (content-lines c) i))

;;; ---------- L1: gap 定位（全部 O(1)）----------
;;; 全部「只动位置、不动字符」。

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

;;; ---------- 内部：vector 定点更新 ----------

(define (vec-set v i x)
  (define v* (vector-copy v))
  (vector-set! v* i x)
  v*)

;;; ---------- L2: 编辑 ----------
;;; 每条返回 (values new-content edit-desc)。
;;; 无操作（如首行行首 backspace）返回 (values c #f)。

(define (content-insert c ch)
  (define l (content-gap-line c))
  (define col (content-gap-col c))
  (define line (content-line-ref c l))
  (values
   (content-check
    (content (vec-set (content-lines c) l
                      (string-append (substring line 0 col)
                                     (string ch)
                                     (substring line col)))
             l (add1 col)))
   (edit-desc 'insert-char l col)))

(define (content-newline c)
  (define l (content-gap-line c))
  (define col (content-gap-col c))
  (define line (content-line-ref c l))
  (define head (substring line 0 col))
  (define tail (substring line col))
  (define lines (content-lines c))
  (define n (vector-length lines))
  (define v* (make-vector (add1 n) #f))
  (vector-copy! v* 0 lines 0 l)
  (vector-set! v* l head)
  (vector-set! v* (add1 l) tail)
  (vector-copy! v* (+ l 2) lines (add1 l) n)
  (values (content v* (add1 l) 0)
          (edit-desc 'newline l col)))

(define (content-backspace c)
  (define l (content-gap-line c))
  (define col (content-gap-col c))
  (define line (content-line-ref c l))
  (cond
    ;; 情形 1：删 gap 前一个字符
    [(> col 0)
     (values
      (content-check
       (content (vec-set (content-lines c) l
                         (string-append (substring line 0 (sub1 col))
                                        (substring line col)))
                l (sub1 col)))
      (edit-desc 'backspace-char l (sub1 col)))]
    ;; 情形 2：与上一行合并。line = 被合并行 L，拼接点 = 上一行行尾。
    [(> l 0)
     (define above (content-line-ref c (sub1 l)))
     (define above-len (string-length above))
     (define merged (string-append above line))
     (define lines (content-lines c))
     (define n (vector-length lines))
     (define v* (make-vector (sub1 n) #f))
     (vector-copy! v* 0 lines 0 (sub1 l))
     (vector-set! v* (sub1 l) merged)
     (vector-copy! v* l lines (add1 l) n)
     (values (content v* (sub1 l) above-len)
             (edit-desc 'backspace-merge l above-len))]
    [else (values c #f)]))

(define (content-delete c)
  (define l (content-gap-line c))
  (define col (content-gap-col c))
  (define line (content-line-ref c l))
  (cond
    ;; 情形 1：删 gap 处字符
    [(< col (string-length line))
     (values
      (content-check
       (content (vec-set (content-lines c) l
                         (string-append (substring line 0 col)
                                        (substring line (add1 col))))
                l col))
      (edit-desc 'delete-char l col))]
    ;; 情形 2：与下一行合并。被合并行 L' = l + 1；拼接点 = 当前行行尾 = col。
    [(< l (sub1 (content-line-count c)))
     (define below (content-line-ref c (add1 l)))
     (define merged (string-append line below))
     (define lines (content-lines c))
     (define n (vector-length lines))
     (define v* (make-vector (sub1 n) #f))
     (vector-copy! v* 0 lines 0 l)
     (vector-set! v* l merged)
     (vector-copy! v* (add1 l) lines (+ l 2) n)
     (values (content v* l col)
             (edit-desc 'delete-merge (add1 l) col))]
    [else (values c #f)]))

;;; ---------- 测试 ----------

(module+ test
  ;; 构造 & 投影
  (check-equal? (content->string (content-empty)) "")
  (check-equal? (content->string (content-of-string "hello\nworld")) "hello\nworld")
  (check-equal? (content->lines  (content-of-string "hello\nworld"))
                (list "hello" "world"))
  (check-equal? (content-line-count (content-of-string "a\nb\nc")) 3)
  (check-equal? (content-current-line (content-of-string "hello\nworld")) "hello")

  ;; 初始 gap 在 (0,0)
  (define c0 (content-of-string "hello\nworld"))
  (check-equal? (content-gap-line c0) 0)
  (check-equal? (content-gap-col  c0) 0)

  ;; gap 定位：行内
  (define c-r3 (content-set-col c0 3))
  (check-equal? (content-gap-line c-r3) 0)
  (check-equal? (content-gap-col  c-r3) 3)
  (check-equal? (content->string  c-r3) "hello\nworld")

  ;; gap 定位：跨行
  (define c-dn (content-gap-down c0))
  (check-equal? (content-gap-line c-dn) 1)
  (check-equal? (content-gap-col  c-dn) 0)
  (check-equal? (content->string  c-dn) "hello\nworld")
  (define c-up (content-gap-up c-dn))
  (check-equal? (content-gap-line c-up) 0)
  (check-equal? (content->string  c-up) "hello\nworld")

  ;; goto：行列都命中
  (define c-g (content-gap-goto c0 1 3))
  (check-equal? (content-gap-line c-g) 1)
  (check-equal? (content-gap-col  c-g) 3)
  (check-equal? (content->string  c-g) "hello\nworld")

  ;; 列越界夹紧
  (check-equal? (content-gap-col (content-gap-goto c0 0 100)) 5)
  (check-equal? (content-gap-col (content-gap-goto c0 0 -5)) 0)

  ;; insert：gap 右移 1，desc 描述原位置
  (define-values (c-i d-i) (content-insert c0 #\X))
  (check-equal? (content->string  c-i) "Xhello\nworld")
  (check-equal? (content-gap-col  c-i) 1)
  (check-equal? d-i (edit-desc 'insert-char 0 0))

  ;; newline：gap 落到新行行首，行数 +1
  (define c-n (content-set-col c0 2))
  (define-values (c-n2 d-n) (content-newline c-n))
  (check-equal? (content->string  c-n2) "he\nllo\nworld")
  (check-equal? (content-gap-line c-n2) 1)
  (check-equal? (content-gap-col  c-n2) 0)
  (check-equal? (content-line-count c-n2) 3)
  (check-equal? d-n (edit-desc 'newline 0 2))

  ;; backspace 情形 1：删字符
  (define-values (c-bs d-bs) (content-backspace c-n))
  (check-equal? (content->string c-bs) "hllo\nworld")
  (check-equal? (content-gap-col  c-bs) 1)
  (check-equal? d-bs (edit-desc 'backspace-char 0 1))

  ;; backspace 情形 2：与上一行合并。
  ;; 操作前 gap 在 (1, 0)，被合并行 L = 1，拼接点 = 上一行行尾 = 5。
  (define c-bm-0 (content-gap-goto c0 1 0))
  (define-values (c-bm d-bm) (content-backspace c-bm-0))
  (check-equal? (content->string  c-bm) "helloworld")
  (check-equal? (content-gap-line c-bm) 0)
  (check-equal? (content-gap-col  c-bm) 5)
  (check-equal? d-bm (edit-desc 'backspace-merge 1 5))

  ;; delete 情形 1：删字符（gap 不动）
  (define-values (c-dc d-dc) (content-delete c0))
  (check-equal? (content->string c-dc) "ello\nworld")
  (check-equal? (content-gap-col  c-dc) 0)
  (check-equal? d-dc (edit-desc 'delete-char 0 0))

  ;; delete 情形 2：与下一行合并。
  ;; 操作前 gap 在 (0, 5)，被合并行 L' = 1，拼接点 = 当前行行尾 = 5。
  (define c-dm-0 (content-gap-goto c0 0 5))
  (define-values (c-dm d-dm) (content-delete c-dm-0))
  (check-equal? (content->string  c-dm) "helloworld")
  (check-equal? (content-gap-line c-dm) 0)
  (check-equal? (content-gap-col  c-dm) 5)
  (check-equal? d-dm (edit-desc 'delete-merge 1 5))

  ;; 无操作边界：首行行首 backspace、末行行尾 delete
  (define-values (c-bs2 d-bs2) (content-backspace c0))
  (check-equal? (content->string c-bs2) "hello\nworld")
  (check-false d-bs2)
  (define c-end (content-gap-goto c0 1 5))
  (define-values (c-de d-de) (content-delete c-end))
  (check-equal? (content->string c-de) "hello\nworld")
  (check-false d-de)

  ;; 三行 full 流程：newline 后再 backspace 应回到原状
  (define c-flow (content-set-col c0 2))
  (define-values (c-f1 _) (content-newline c-flow))
  (define-values (c-f2 __) (content-backspace c-f1))
  (check-equal? (content->string c-f2) "hello\nworld")

  (displayln "content.rkt: all tests passed"))
