#lang racket

(require "../atom/point.rkt" "../atom/lines.rkt" "../atom/edit.rkt" rackunit)

;;; unit/attrs.rkt —— 行内属性区间（通用 key→value，随编辑移动）
;;;
;;; 一个 attrs 就是一块**属性 buffer**：与 content 同坐标、平行，吃**同一条生效
;;; edit-desc**（由 content-apply 产出）。属性是 span 上的 hash：key/值由使用方定义，
;;; core 只保留并解释 'read-only（见 doc/buffer.rkt）。
;;;
;;; 不变量（attrs-check 强制）：
;;;   P1  每行内 rspan 按 start 升序、互不重叠
;;;   P2  相邻且 hash 相同的 rspan 已合并
;;;   P3  hash 为空的 rspan 不保留
;;;
;;; 编辑传播：新文本一律**不继承**任何属性。

(provide
 attrs?                             ; 构造器/内部字段不外露（避免绕过不变量）
 attrs-empty
 attrs-line-count
 attrs-at
 attrs-put
 attrs-remove
 attrs-runs
 attrs-key-runs
 attrs-apply-edit
 attrs-check)

;;; ---------- 数据 ----------

;; rspan 是内部结构，不导出。
(struct rspan (start end val) #:transparent)
;; start / end : nat       行内列号，半开区间 [start, end)
;; val         : hash      key → value（key/值由使用方定义）

(struct attrs (rows) #:transparent)
;; rows : (vectorof (listof rspan))   行号由下标表达，不重复存

(define (rspan-empty? sp) (hash-empty? (rspan-val sp)))
(define (rspan=? a b) (equal? (rspan-val a) (rspan-val b)))

;;; ---------- 构造 / 不变量 ----------

(define (attrs-empty line-count)
  (unless (and (exact-nonnegative-integer? line-count) (>= line-count 1))
    (error 'attrs-empty "line-count must be >= 1, got ~a" line-count))
  (attrs (make-vector line-count '())))

(define (attrs-line-count p) (vector-length (attrs-rows p)))

(define (check-row! row)
  (let loop ([prev-end -1] [rest row])
    (unless (null? rest)
      (define sp (car rest))
      (unless (< (rspan-start sp) (rspan-end sp))
        (error 'attrs-check "rspan start >= end: ~a" sp))
      (unless (>= (rspan-start sp) prev-end)
        (error 'attrs-check "overlapping / unordered rspans: ~a" row))
      (unless (not (rspan-empty? sp))
        (error 'attrs-check "empty rspan present: ~a" sp))
      (loop (rspan-end sp) (cdr rest)))))

(define (attrs-check p)
  (for ([row (in-vector (attrs-rows p))]) (check-row! row))
  p)

;;; ---------- 行内工具 ----------

(define (rspan-boundaries row)
  (append-map (lambda (sp) (list (rspan-start sp) (rspan-end sp))) row))

;; 该行 col 处的属性 hash；无覆盖 → 空 hash。
(define (row-val-at row col)
  (define sp (for/first ([sp (in-list row)]
                         #:when (and (<= (rspan-start sp) col) (< col (rspan-end sp))))
              sp))
  (if sp (rspan-val sp) (hash)))

;; 合并相邻且内容相同的 rspan（P2）。输入须升序。
(define (merge-adjacent spans)
  (reverse
   (for/fold ([acc '()]) ([sp (in-list spans)])
     (cond
       [(null? acc) (list sp)]
       [else
        (define last (car acc))
        (if (and (= (rspan-end last) (rspan-start sp)) (rspan=? last sp))
            (cons (rspan (rspan-start last) (rspan-end sp) (rspan-val last))
                  (cdr acc))
            (cons sp acc))]))))

;; 对 [start, end) 的每个子段做 (f 当前 hash)；空段丢弃、相邻相同合并。
(define (row-update row start end f)
  (when (>= start end)
    (error 'attrs-put "属性区间必须 start < end，得到 [~a,~a)" start end))
  (define bounds (sort (remove-duplicates (append (list start end)
                                                  (rspan-boundaries row)))
                       <))
  (define segments
    (for/list ([a (in-list (drop-right bounds 1))]
               [b (in-list (rest bounds))])
      (define v (if (and (<= start a) (<= b end)) (f (row-val-at row a)) (row-val-at row a)))
      (rspan a b v)))
  (merge-adjacent (filter (lambda (sp) (not (rspan-empty? sp))) segments)))

;; 对 [start,end) 统一设置 key→val（保留其它 key）。
(define (row-put-key row start end key val)
  (row-update row start end (lambda (h) (hash-set h key val))))

;; 对 [start,end) 移除 key。
(define (row-remove-key row start end key)
  (row-update row start end (lambda (h) (hash-remove h key))))

(define (attrs-put p line start end key val)
  (define rows (attrs-rows p))
  (define rows* (vector-copy rows))
  (vector-set! rows* line (row-put-key (vector-ref rows line) start end key val))
  (attrs rows*))

(define (attrs-remove p line start end key)
  (define rows (attrs-rows p))
  (define rows* (vector-copy rows))
  (vector-set! rows* line (row-remove-key (vector-ref rows line) start end key))
  (attrs rows*))

;;; ---------- 读 ----------

(define (attrs-at p line col)
  (row-val-at (vector-ref (attrs-rows p) line) col))

;; 整行属性段：(listof (list start end hash))，恰好覆盖 [0, line-length)。
(define (attrs-runs p line line-length)
  (define row (vector-ref (attrs-rows p) line))
  (define pts (sort (remove-duplicates (append (list 0 line-length)
                                               (rspan-boundaries row)))
                    <))
  (define raw (for/list ([a (in-list (drop-right pts 1))]
                         [b (in-list (rest pts))])
                (list a b (row-val-at row a))))
  (reverse
   (for/fold ([acc '()]) ([seg (in-list raw)])
     (cond
       [(null? acc) (list seg)]
       [(equal? (caddr (car acc)) (caddr seg))
        (cons (list (car (car acc)) (cadr seg) (caddr seg)) (cdr acc))]
       [else (cons seg acc)]))))

;; 只取某个 key 的段：(listof (list start end val))；投影/渲染用。
;; 相邻且 val 相等的段合并（其它 key 的边界不该把一个 key 的段切断）。
(define (attrs-key-runs p line line-length key)
  (define raw (for/list ([seg (in-list (attrs-runs p line line-length))]
                         #:when (hash-has-key? (caddr seg) key))
                (list (car seg) (cadr seg) (hash-ref (caddr seg) key))))
  (reverse
   (for/fold ([acc '()]) ([seg (in-list raw)])
     (cond
       [(null? acc) (list seg)]
       [(and (= (cadr (car acc)) (car seg)) (equal? (caddr (car acc)) (caddr seg)))
        (cons (list (car (car acc)) (cadr seg) (caddr seg)) (cdr acc))]
       [else (cons seg acc)]))))

;;; ---------- 编辑调整（新文本无属性，不继承） ----------

;; 在 col 处把一行切成两半；跨切点的 rspan 被切成两个。
(define (split-row row col)
  (define-values (left right)
    (for/fold ([l '()] [r '()]) ([sp (in-list row)])
      (define s (rspan-start sp)) (define e (rspan-end sp)) (define v (rspan-val sp))
      (cond
        [(<= e col) (values (cons sp l) r)]
        [(>= s col) (values l (cons (rspan (- s col) (- e col) v) r))]
        [else       (values (cons (rspan s col v) l)
                            (cons (rspan 0 (- e col) v) r))])))
  (values (reverse left) (reverse right)))

(define (shift-spans row n)
  (for/list ([sp (in-list row)])
    (rspan (+ n (rspan-start sp)) (+ n (rspan-end sp)) (rspan-val sp))))

;; 删除 [start, end) 覆盖的行区间，返回新 rows。
(define (delete-range rows s e)
  (define sl (point-line s)) (define sc (point-col s))
  (define el (point-line e)) (define ec (point-col e))
  (define-values (s-left s-right) (split-row (vector-ref rows sl) sc))
  (define-values (_e-left e-right) (split-row (vector-ref rows el) ec))
  (define merged (merge-adjacent (append s-left (shift-spans e-right sc))))
  (define n (vector-length rows))
  (define v* (make-vector (- (+ n sl) el) '()))
  (vector-copy! v* 0 rows 0 sl)
  (vector-set! v* sl merged)
  (vector-copy! v* (add1 sl) rows (add1 el) n)
  v*)

;; 在 start 处插入 k 行文本，返回新 rows（新文本无属性）。
(define (insert-lines rows start new-lines)
  (define k (length new-lines))
  (cond
    [(zero? k) rows]
    [else
     (define sl (point-line start)) (define sc (point-col start))
     (define-values (left right) (split-row (vector-ref rows sl) sc))
     (define first-len (string-length (car new-lines)))
     (define last-len (string-length (last new-lines)))
     (define n (vector-length rows))
     (define v* (make-vector (+ n (sub1 k)) '()))
     (vector-copy! v* 0 rows 0 sl)
     (cond
       [(= k 1)
        (vector-set! v* sl
          (merge-adjacent (append left (shift-spans right (+ sc first-len)))))]
       [else
        (vector-set! v* sl (merge-adjacent left))
        (for ([i (in-range 1 (sub1 k))]) (vector-set! v* (+ sl i) '()))
        (vector-set! v* (+ sl (sub1 k))
          (merge-adjacent (shift-spans right last-len)))])
     (vector-copy! v* (+ sl k) rows (add1 sl) n)
     v*]))

;; 施加一条 edit-desc：先删区间，再插新文本。输入须是 content 产出的生效 desc。
(define (attrs-apply-edit p d)
  (define rows (attrs-rows p))
  (define rows1 (delete-range rows (edit-desc-start d) (edit-desc-end d)))
  (attrs
   (insert-lines rows1 (edit-desc-start d)
                 (string->lines (edit-desc-new-text d)))))

;;; ---------- 测试 ----------

(module+ test
  (define (fresh) (attrs-empty 3))
  (define (apply* p d) (attrs-apply-edit p d))

  ;; 半开区间 + 点查询（hash 属性）
  (define p0 (attrs-put (fresh) 1 0 5 'ro #t))
  (check-equal? (attrs-at p0 1 0) (hash 'ro #t))
  (check-equal? (attrs-at p0 1 4) (hash 'ro #t))
  (check-equal? (attrs-at p0 1 5) (hash))

  ;; 多 key 互不干扰；相邻同 hash 合并（P2）
  (define p1 (attrs-put (attrs-put (fresh) 0 1 2 'a 1) 0 2 4 'a 1))
  (check-equal? (attrs-runs p1 0 5)
                (list (list 0 1 (hash)) (list 1 4 (hash 'a 1)) (list 4 5 (hash))))
  (define p1b (attrs-put p1 0 2 3 'b 2))
  (check-equal? (attrs-key-runs p1b 0 5 'a) (list (list 1 4 1)))
  (check-equal? (attrs-key-runs p1b 0 5 'b) (list (list 2 3 2)))

  ;; 移除 key
  (define p2 (attrs-remove p0 1 2 3 'ro))
  (check-equal? (attrs-at p2 1 1) (hash 'ro #t))
  (check-equal? (attrs-at p2 1 2) (hash))
  (check-equal? (attrs-at p2 1 3) (hash 'ro #t))

  ;; 编辑：区间内插入 → 右半后移，插入点无属性
  (define e0 (attrs-put (fresh) 0 0 5 'ro #t))
  (define e1 (apply* e0 (edit-desc (point 0 2) (point 0 2) "x")))
  (check-equal? (attrs-runs e1 0 6)
                (list (list 0 2 (hash 'ro #t)) (list 2 3 (hash)) (list 3 6 (hash 'ro #t))))
  ;; 删除区间内部 → 收缩
  (define e2 (apply* e0 (edit-desc (point 0 1) (point 0 3) "")))
  (check-equal? (attrs-runs e2 0 3) (list (list 0 3 (hash 'ro #t))))

  ;; 跨行删除 + 多行插入：属性被正确切/移，新行无属性
  (define p4 (attrs-put (fresh) 0 0 3 'ro #t))
  (define p5 (apply* p4 (edit-desc (point 0 1) (point 1 1) "PQ\nR")))
  (check-equal? (attrs-at p5 0 0) (hash 'ro #t))
  (check-equal? (attrs-at p5 0 1) (hash))
  (check-equal? (attrs-at p5 1 0) (hash))
  (check-equal? (attrs-check p5) p5)

  ;; 空 / 反向区间 → 报错
  (check-exn exn:fail? (lambda () (attrs-put (fresh) 1 2 2 'ro #t)))
  (check-exn exn:fail? (lambda () (attrs-put (fresh) 1 3 1 'ro #t)))

  (displayln "attrs.rkt: all tests passed"))
