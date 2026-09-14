#lang racket

(require "cursor.rkt" "content.rkt" rackunit)

;;; properties.rkt —— 区间文本属性
;;;
;;; 不变量（由 props-check 强制）：
;;;   P1  每行内区间按 start 升序、互不重叠
;;;   P2  相邻且 plist 相同的区间已合并
;;;   P3  空 plist 的区间不保留
;;;
;;; 区间是半开的 [start, end)，坐标为行内列号。
;;; 行号由 rows 向量的下标隐式表达，不重复存储。
;;;
;;; 对外不暴露 interval 的内部结构。所有查询走
;;; props-at / props-get / props-runs。

(provide
 (struct-out text-properties)
 props-empty
 props-check
 props-debug?
 props-line-count
 props-at
 props-get
 props-put
 props-remove
 props-apply-edit
 props-runs)

;;; ---------- 内部结构 ----------

(struct interval (start end plist) #:transparent)
;; plist : immutable hash

(struct text-properties (rows) #:transparent)
;; rows : (vectorof (listof interval))

(define empty-plist (hash))

;;; ---------- 构造 & 不变量 ----------

(define (props-empty line-count)
  (unless (and (exact-nonnegative-integer? line-count) (>= line-count 1))
    (error 'props-empty "line-count must be >= 1, got ~a" line-count))
  (text-properties (make-vector line-count '())))

(define (props-line-count p)
  (vector-length (text-properties-rows p)))

;; 热路径只校验受影响行；全量校验走 props-check（测试/诊断用）。
;; props-debug? 默认 #f，测试里可 parameterize 打开。
(define props-debug? (make-parameter #f))

(define (props-check-line row)
  (let loop ([prev-end -1] [rest row])
    (unless (null? rest)
      (define iv (car rest))
      (unless (< (interval-start iv) (interval-end iv))
        (error 'props-check-line "interval start >= end: ~a" iv))
      (unless (>= (interval-start iv) prev-end)
        (error 'props-check-line "overlapping or unordered intervals in row: ~a" row))
      (unless (positive? (hash-count (interval-plist iv)))
        (error 'props-check-line "empty-plist interval should not exist: ~a" iv))
      (loop (interval-end iv) (cdr rest)))))

(define (props-check p)
  (for ([row (in-vector (text-properties-rows p))])
    (props-check-line row))
  p)

;;; ---------- 内部工具 ----------

(define (vec-set v i x)
  (define v* (vector-copy v))
  (vector-set! v* i x)
  v*)

(define (plist-at row col)
  (or (for/first ([iv (in-list row)]
                  #:when (and (<= (interval-start iv) col)
                              (< col (interval-end iv))))
        (interval-plist iv))
      empty-plist))

(define (merge-adjacent intervals)
  (if (null? intervals)
      '()
      (reverse
       (for/fold ([acc (list (car intervals))])
                 ([iv (in-list (cdr intervals))])
         (define last (car acc))
         (if (and (= (interval-end last) (interval-start iv))
                  (equal? (interval-plist last) (interval-plist iv)))
             (cons (interval (interval-start last) (interval-end iv)
                             (interval-plist last))
                   (cdr acc))
             (cons iv acc))))))

;; 对 [start, end) 范围内每一段调用 transform，重铺区间。
;; 单遍扫描：suffix 指针只向前走，整体 O(k log k)（排序主导）。
(define (props-modify p line start end transform)
  (define rows (text-properties-rows p))
  (define row  (vector-ref rows line))
  (define points
    (sort (remove-duplicates
           (append (list start end)
                   (append-map (lambda (iv)
                                 (list (interval-start iv) (interval-end iv)))
                               row)))
          <))
  (define segments
    (let loop ([pts (drop-right points 1)]
               [bnd (rest points)]
               [suffix row]
               [acc '()])
      (cond
        [(null? pts) (reverse acc)]
        [else
         (define a (car pts))
         (define b (car bnd))
         (define-values (base suffix*)
           (let skip ([s suffix])
             (cond
               [(null? s) (values empty-plist s)]
               [(<= (interval-end (car s)) a)   (skip (cdr s))]
               [(<= (interval-start (car s)) a) (values (interval-plist (car s)) s)]
               [else                            (values empty-plist s)])))
         (define p* (if (and (<= start a) (<= b end)) (transform base) base))
         (loop (cdr pts) (cdr bnd) suffix* (cons (interval a b p*) acc))])))
  (define merged
    (merge-adjacent
     (filter (lambda (iv) (positive? (hash-count (interval-plist iv))))
             segments)))
  (when (props-debug?) (props-check-line merged))
  (text-properties (vec-set rows line merged)))

;;; ---------- 查询 ----------

(define (props-at p line col)
  (plist-at (vector-ref (text-properties-rows p) line) col))

(define (props-get p line col prop)
  (hash-ref (props-at p line col) prop #f))

;;; 渲染扫描：一行内所有属性段，覆盖 [0, line-length)。
;;; 返回 (listof (list start end plist))，按 start 升序；
;;; 相邻段的 plist 必不同（P2）；无属性位置用 empty-plist 段填补。
(define (props-runs p line line-length)
  (define row (vector-ref (text-properties-rows p) line))
  (define out '())
  (define pos 0)
  (for ([iv (in-list row)])
    (define s (interval-start iv))
    (define e (interval-end iv))
    (when (< pos s)
      (set! out (cons (list pos s empty-plist) out)))
    (set! out (cons (list s e (interval-plist iv)) out))
    (set! pos e))
  (when (< pos line-length)
    (set! out (cons (list pos line-length empty-plist) out)))
  (reverse out))

;;; ---------- 行内写入（put / remove 共享 props-modify）----------

(define (props-put p line start end prop val)
  (props-modify p line start end (lambda (h) (hash-set h prop val))))

(define (props-remove p line start end prop)
  (props-modify p line start end (lambda (h) (hash-remove h prop))))

;;; ---------- 编辑调整：三条端点规则 ----------
;;; 编辑 desc 是「操作前坐标」。继承左邻由端点移动规则直接实现。

;; 在 col 处插入 1 个字符：
;;   col <= s      → [s+1, e+1)   区间右移（不继承）
;;   s <  col <= e → [s,   e+1)   区间扩张（继承左邻）
;;   col >  e      → [s,   e)     不动
(define (insert-adjust row col)
  (for/list ([iv (in-list row)])
    (define s (interval-start iv))
    (define e (interval-end iv))
    (cond [(<= col s)                (interval (add1 s) (add1 e) (interval-plist iv))]
          [(and (< s col) (<= col e)) (interval s (add1 e) (interval-plist iv))]
          [else iv])))

;; 删除 col 处字符：
;;   col >= e      → [s, e)     不动
;;   col <  s      → [s-1, e-1) 左移
;;   s <= col < e  → [s, e-1)   收缩（若变空则删）
(define (delete-adjust row col)
  (filter-map
   (lambda (iv)
     (define s (interval-start iv))
     (define e (interval-end iv))
     (cond [(>= col e) iv]
           [(< col s) (interval (sub1 s) (sub1 e) (interval-plist iv))]
           [else
            (define e* (sub1 e))
            (if (= s e*)
                #f
                (interval s e* (interval-plist iv)))]))
   row))

;; 在 col 处拆分一行：区间按切点分成左右两半，右半 -col 平移。
(define (split-row row col)
  (define left '())
  (define right '())
  (for ([iv (in-list row)])
    (define s (interval-start iv))
    (define e (interval-end iv))
    (define pl (interval-plist iv))
    (cond [(<= e col) (set! left (cons iv left))]
          [(>= s col) (set! right (cons (interval (- s col) (- e col) pl) right))]
          [else
           (set! left  (cons (interval s col pl) left))
           (set! right (cons (interval 0 (- e col) pl) right))]))
  (values (reverse left) (reverse right)))

(define (shift-intervals row n)
  (for/list ([iv (in-list row)])
    (interval (+ n (interval-start iv)) (+ n (interval-end iv))
              (interval-plist iv))))

;;; ---------- edit-desc 分派 ----------

(define (props-apply-edit p desc)
  (match-define (edit-desc kind line col) desc)
  (define rows (text-properties-rows p))
  (define n (vector-length rows))
  (define new-rows
    (match kind
      ['insert-char
       (vec-set rows line (insert-adjust (vector-ref rows line) col))]

      ['backspace-char
       (vec-set rows line (delete-adjust (vector-ref rows line) col))]

      ['delete-char
       (vec-set rows line (delete-adjust (vector-ref rows line) col))]

      ['newline
       (define-values (l r) (split-row (vector-ref rows line) col))
       (define v* (make-vector (add1 n) '()))
       (vector-copy! v* 0 rows 0 line)
       (vector-set! v* line l)
       (vector-set! v* (add1 line) r)
       (vector-copy! v* (+ line 2) rows (add1 line) n)
       v*]

      ;; 两种 merge 字面同构：desc.line = 被合并行 L，拼接点在 (L-1, col)。
      ['backspace-merge
       (define L line)
       (define merged
         (merge-adjacent (append (vector-ref rows (sub1 L))
                                 (shift-intervals (vector-ref rows L) col))))
       (define v* (make-vector (sub1 n) '()))
       (vector-copy! v* 0 rows 0 (sub1 L))
       (vector-set! v* (sub1 L) merged)
       (vector-copy! v* L rows (add1 L) n)
       v*]

      ['delete-merge
       (define L line)
       (define merged
         (merge-adjacent (append (vector-ref rows (sub1 L))
                                 (shift-intervals (vector-ref rows L) col))))
       (define v* (make-vector (sub1 n) '()))
       (vector-copy! v* 0 rows 0 (sub1 L))
       (vector-set! v* (sub1 L) merged)
       (vector-copy! v* L rows (add1 L) n)
       v*]))
  (define p* (text-properties new-rows))
  (when (props-debug?) (props-check p*))
  p*)

;;; ---------- 测试 ----------

(module+ test
  (define (fresh) (props-empty 3))

  ;; 点查询 & 半开区间
  (define p0 (props-put (fresh) 1 0 5 'face 'bold))
  (check-equal? (props-get p0 1 2 'face) 'bold)
  (check-equal? (props-get p0 1 0 'face) 'bold)
  (check-equal? (props-get p0 1 5 'face) #f)
  (check-equal? (props-get p0 0 0 'face) #f)

  ;; 相邻同 plist 合并（P2）
  (define p1 (props-put p0 1 5 8 'face 'bold))
  (define p2 (props-put p1 1 0 8 'face 'bold))
  (check-equal? (length (vector-ref (text-properties-rows p2) 1)) 1)

  ;; 编辑调整：插在区间内 → 扩张；debug 打开时全量校验不变量
  (parameterize ([props-debug? #t])
    (define p3 (props-apply-edit p2 (edit-desc 'insert-char 1 3)))
    (check-equal? (props-get p3 1 4 'face) 'bold)
    (props-check p3))

  (displayln "properties.rkt: all tests passed"))
