#lang racket

(require "../atom/point.rkt" "../atom/lines.rkt" "../atom/edit.rkt"
         "../atom/restrict.rkt" rackunit)

;;; unit/restrictions.rkt —— 行内约束区间（唯一槽：restrict）
;;;
;;; 文档里**只存作者态约束**（read-only 等），由 core 解释。
;;; **face 不在这里**：派生 face 走投影时的 face-provider（viewport/render.rkt）。
;;;
;;; 不变量（restrictions-check 强制）：
;;;   P1  每行内 rspan 按 start 升序、互不重叠
;;;   P2  相邻且 restrict 相同的 rspan 已合并
;;;   P3  restrict 为空的 rspan 不保留
;;;
;;; 编辑传播：新文本一律**无约束**（不继承）。

(provide
 (struct-out restrictions)
 make-restrictions
 restrictions-line-count
 restrictions-at
 restrictions-put
 restrictions-remove
 restrictions-runs
 restrictions-apply-edit
 restrictions-check)

;;; ---------- 数据 ----------

;; rspan 是内部结构，不导出。
(struct rspan (start end restrict) #:transparent)
;; start / end : nat       行内列号，半开区间 [start, end)
;; restrict    : restrict

(struct restrictions (rows) #:transparent)
;; rows : (vectorof (listof rspan))   行号由下标表达，不重复存

(define (rspan-empty? sp) (restrict-empty? (rspan-restrict sp)))
(define (rspan=? a b) (equal? (rspan-restrict a) (rspan-restrict b)))

;;; ---------- 构造 / 不变量 ----------

(define (make-restrictions line-count)
  (unless (and (exact-nonnegative-integer? line-count) (>= line-count 1))
    (error 'make-restrictions "line-count must be >= 1, got ~a" line-count))
  (restrictions (make-vector line-count '())))

(define (restrictions-line-count p) (vector-length (restrictions-rows p)))

(define (check-row! row)
  (let loop ([prev-end -1] [rest row])
    (unless (null? rest)
      (define sp (car rest))
      (unless (< (rspan-start sp) (rspan-end sp))
        (error 'restrictions-check "rspan start >= end: ~a" sp))
      (unless (>= (rspan-start sp) prev-end)
        (error 'restrictions-check "overlapping / unordered rspans: ~a" row))
      (unless (not (rspan-empty? sp))
        (error 'restrictions-check "empty rspan present: ~a" sp))
      (loop (rspan-end sp) (cdr rest)))))

(define (restrictions-check p)
  (for ([row (in-vector (restrictions-rows p))]) (check-row! row))
  p)

;;; ---------- 行内工具 ----------

(define (rspan-boundaries row)
  (append-map (lambda (sp) (list (rspan-start sp) (rspan-end sp))) row))

;; 该行 col 处的约束；无覆盖 → 空 restrict。
(define (row-restrict-at row col)
  (define sp (for/first ([sp (in-list row)]
                         #:when (and (<= (rspan-start sp) col) (< col (rspan-end sp))))
              sp))
  (if sp (rspan-restrict sp) (make-restrict)))

;; 合并相邻且 restrict 相同的 rspan（P2）。输入须升序。
(define (merge-adjacent spans)
  (reverse
   (for/fold ([acc '()]) ([sp (in-list spans)])
     (cond
       [(null? acc) (list sp)]
       [else
        (define last (car acc))
        (if (and (= (rspan-end last) (rspan-start sp)) (rspan=? last sp))
            (cons (rspan (rspan-start last) (rspan-end sp) (rspan-restrict last))
                  (cdr acc))
            (cons sp acc))]))))

;; 对 [start, end) 统一设 rs；单遍切段后丢空段、合并相邻同值段。
(define (row-put row start end rs)
  (when (>= start end)
    (error 'restrictions-put "约束区间必须 start < end，得到 [~a,~a)" start end))
  (define bounds (sort (remove-duplicates (append (list start end)
                                                  (rspan-boundaries row)))
                       <))
  (define segments
    (for/list ([a (in-list (drop-right bounds 1))]
               [b (in-list (rest bounds))])
      (define rs* (if (and (<= start a) (<= b end)) rs (row-restrict-at row a)))
      (rspan a b rs*)))
  (merge-adjacent (filter (lambda (sp) (not (rspan-empty? sp))) segments)))

(define (restrictions-put p line start end rs)
  (define rows (restrictions-rows p))
  (define rows* (vector-copy rows))
  (vector-set! rows* line (row-put (vector-ref rows line) start end rs))
  (restrictions rows*))

;; 清约束（= put 传空 restrict）。
(define (restrictions-remove p line start end)
  (restrictions-put p line start end (make-restrict)))

;;; ---------- 读 ----------

(define (restrictions-at p line col)
  (row-restrict-at (vector-ref (restrictions-rows p) line) col))

;; 整行约束段：(listof (list start end restrict))，恰好覆盖 [0, line-length)。
;; 枚举只读区间用（O(段数)，不是 O(列数)）。
(define (restrictions-runs p line line-length)
  (define row (vector-ref (restrictions-rows p) line))
  (define pts (sort (remove-duplicates (append (list 0 line-length)
                                               (rspan-boundaries row)))
                    <))
  (define raw (for/list ([a (in-list (drop-right pts 1))]
                         [b (in-list (rest pts))])
                (list a b (row-restrict-at row a))))
  (reverse
   (for/fold ([acc '()]) ([seg (in-list raw)])
     (cond
       [(null? acc) (list seg)]
       [(equal? (caddr (car acc)) (caddr seg))
        (cons (list (car (car acc)) (cadr seg) (caddr seg)) (cdr acc))]
       [else (cons seg acc)]))))

;;; ---------- 编辑调整（新文本无约束，不继承） ----------

;; 在 col 处把一行切成两半；跨切点的 rspan 被切成两个。
(define (split-row row col)
  (define-values (left right)
    (for/fold ([l '()] [r '()]) ([sp (in-list row)])
      (define s (rspan-start sp)) (define e (rspan-end sp)) (define rs (rspan-restrict sp))
      (cond
        [(<= e col) (values (cons sp l) r)]
        [(>= s col) (values l (cons (rspan (- s col) (- e col) rs) r))]
        [else       (values (cons (rspan s col rs) l)
                            (cons (rspan 0 (- e col) rs) r))])))
  (values (reverse left) (reverse right)))

(define (shift-spans row n)
  (for/list ([sp (in-list row)])
    (rspan (+ n (rspan-start sp)) (+ n (rspan-end sp)) (rspan-restrict sp))))

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

;; 在 start 处插入 k 行文本，返回新 rows（新文本无约束）。
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

;; 施加一条 edit-desc：先删区间，再插新文本。
(define (restrictions-apply-edit p d)
  (define rows (restrictions-rows p))
  (define rows1 (delete-range rows (edit-desc-start d) (edit-desc-end d)))
  (restrictions
   (insert-lines rows1 (edit-desc-start d)
                 (string->lines (edit-desc-new-text d)))))

;;; ---------- 测试 ----------

(module+ test
  (define (fresh) (make-restrictions 3))
  (define ro (restrict #t))
  (define (apply* p d) (restrictions-apply-edit p d))

  ;; 半开区间 + 点查询
  (define p0 (restrictions-put (fresh) 1 0 5 ro))
  (check-true (restrict-read-only? (restrictions-at p0 1 0)))
  (check-true (restrict-read-only? (restrictions-at p0 1 4)))
  (check-false (restrict-read-only? (restrictions-at p0 1 5)))

  ;; 相邻同约束合并（P2）
  (define p1 (restrictions-put (restrictions-put (fresh) 0 1 2 ro) 0 2 4 ro))
  (check-equal? (restrictions-runs p1 0 5)
                (list (list 0 1 (make-restrict)) (list 1 4 ro) (list 4 5 (make-restrict))))

  ;; 清约束
  (define p2 (restrictions-remove p0 1 2 3))
  (check-true (restrict-read-only? (restrictions-at p2 1 1)))
  (check-false (restrict-read-only? (restrictions-at p2 1 2)))
  (check-true (restrict-read-only? (restrictions-at p2 1 3)))

  ;; 编辑：区间内插入 → 右半后移，插入点无约束
  (define e0 (restrictions-put (fresh) 0 0 5 ro))
  (define e1 (apply* e0 (edit-desc (point 0 2) (point 0 2) "x")))
  (check-equal? (restrictions-runs e1 0 6)
                (list (list 0 2 ro) (list 2 3 (make-restrict)) (list 3 6 ro)))
  ;; 删除区间内部 → 收缩
  (define e2 (apply* e0 (edit-desc (point 0 1) (point 0 3) "")))
  (check-equal? (restrictions-runs e2 0 3) (list (list 0 3 ro)))

  ;; 跨行删除 + 多行插入：只读段被正确切/移，新行无约束
  (define p4 (restrictions-put (fresh) 0 0 3 ro))
  (define p5 (apply* p4 (edit-desc (point 0 1) (point 1 1) "PQ\nR")))
  (check-true (restrict-read-only? (restrictions-at p5 0 0)))     ; 删/插后 col0 仍只读
  (check-false (restrict-read-only? (restrictions-at p5 0 1)))    ; 被删区间不再只读
  (check-false (restrict-read-only? (restrictions-at p5 1 0)))    ; 插入的新行无约束
  (check-equal? (restrictions-check p5) p5)

  ;; 空 / 反向区间 → 报错
  (check-exn exn:fail? (lambda () (restrictions-put (fresh) 1 2 2 ro)))
  (check-exn exn:fail? (lambda () (restrictions-put (fresh) 1 3 1 ro)))

  (displayln "restrictions.rkt: all tests passed"))
