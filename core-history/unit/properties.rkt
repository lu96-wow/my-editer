#lang racket

(require "../atom/point.rkt" "../atom/lines.rkt" "../atom/edit.rkt"
         "../atom/restrict.rkt" rackunit)

;;; unit/properties.rkt —— 行内属性区间（两个槽）
;;;
;;; 每个区间是一个 span，携带两个**性质不同**的槽：
;;;   presentation : 开放的「键 → 值」袋（'face 等）。core 不解释，只随文本搬运。
;;;   restrict     : typed 约束（如 read-only）。core 解释。
;;;
;;; 不变量（properties-check 强制）：
;;;   P1  每行内 span 按 start 升序、互不重叠
;;;   P2  相邻且 (presentation, restrict) 都相同的 span 已合并
;;;   P3  (presentation, restrict) 都为空的 span 不保留
;;;
;;; 编辑传播（唯一实现 inherit-presentation）：
;;;   · presentation 继承左邻
;;;   · restrict 永不继承（新文本一律无约束）
;;;   · 左邻带 restrict ⇒ presentation 也不继承（约束变化处 = 字段边界）
;;;
;;; 对外不暴露 span：读走 properties-at/get/restrict-at，段分解走
;;; properties-runs（表现层）/ properties-restrict-runs（约束层）。

(provide
 (struct-out properties)
 make-properties
 properties-line-count
 properties-at
 properties-get
 properties-restrict-at
 properties-put
 properties-put-many
 properties-remove
 properties-replace-key
 properties-put-restrict
 properties-runs
 properties-key-runs
 properties-restrict-runs
 properties-apply-edit
 properties-check)

;;; ---------- 数据 ----------

;; span 是内部结构，不导出。
(struct span (start end presentation restrict) #:transparent)
;; start / end  : nat          行内列号，半开区间 [start, end)
;; presentation : hash         表现层（可为空 hash）
;; restrict     : restrict

(struct properties (rows) #:transparent)
;; rows : (vectorof (listof span))   行号由下标表达，不重复存

(define empty-plist (hash))

(define (span-empty? sp)
  (and (zero? (hash-count (span-presentation sp)))
       (restrict-empty? (span-restrict sp))))

(define (span-slots=? a b)
  (and (equal? (span-presentation a) (span-presentation b))
       (equal? (span-restrict a) (span-restrict b))))

;;; ---------- 构造 / 不变量 ----------

(define (make-properties line-count)
  (unless (and (exact-nonnegative-integer? line-count) (>= line-count 1))
    (error 'make-properties "line-count must be >= 1, got ~a" line-count))
  (properties (make-vector line-count '())))

(define (properties-line-count p) (vector-length (properties-rows p)))

(define (check-row! row)
  (let loop ([prev-end -1] [rest row])
    (unless (null? rest)
      (define sp (car rest))
      (unless (< (span-start sp) (span-end sp))
        (error 'properties-check "span start >= end: ~a" sp))
      (unless (>= (span-start sp) prev-end)
        (error 'properties-check "overlapping / unordered spans: ~a" row))
      (unless (not (span-empty? sp))
        (error 'properties-check "empty span present: ~a" sp))
      (loop (span-end sp) (cdr rest)))))

(define (properties-check p)
  (for ([row (in-vector (properties-rows p))]) (check-row! row))
  p)

;;; ---------- 行内工具 ----------

(define (span-boundaries row)
  (append-map (lambda (sp) (list (span-start sp) (span-end sp))) row))

;; 该行的 (presentation, restrict) 在 col 处的值；无覆盖 → 空。
(define (row-slots row col)
  (define sp (for/first ([sp (in-list row)]
                         #:when (and (<= (span-start sp) col) (< col (span-end sp))))
              sp))
  (if sp
      (values (span-presentation sp) (span-restrict sp))
      (values empty-plist (make-restrict))))

;; 合并相邻且两槽都相同的 span（P2）。输入须升序。
(define (merge-adjacent spans)
  (reverse
   (for/fold ([acc '()]) ([sp (in-list spans)])
     (cond
       [(null? acc) (list sp)]
       [else
        (define last (car acc))
        (if (and (= (span-end last) (span-start sp)) (span-slots=? last sp))
            (cons (span (span-start last) (span-end sp)
                        (span-presentation last) (span-restrict last))
                  (cdr acc))
            (cons sp acc))]))))

;; 对 [start, end) 上每一段施加 transform（两个槽一起），重铺整行。
;; transform : presentation restrict -> (values presentation restrict)
;; 单遍扫描：按所有边界切段，每段取「该段起点的槽」，在范围内才 transform，
;; 最后丢空段、合并相邻同值段。
(define (row-modify row start end transform)
  (when (>= start end)
    (error 'properties-put "属性/约束区间必须 start < end，得到 [~a,~a)" start end))
  (define bounds (sort (remove-duplicates (append (list start end)
                                                  (span-boundaries row)))
                       <))
  (define segments
    (for/list ([a (in-list (drop-right bounds 1))]
               [b (in-list (rest bounds))])
      (define-values (pl rs) (row-slots row a))
      (define-values (pl* rs*)
        (if (and (<= start a) (<= b end))
            (transform pl rs)
            (values pl rs)))
      (span a b pl* rs*)))
  (merge-adjacent (filter (lambda (sp) (not (span-empty? sp))) segments)))

(define (properties-modify p line start end transform)
  (define rows (properties-rows p))
  (define row* (row-modify (vector-ref rows line) start end transform))
  (define rows* (vector-copy rows))
  (vector-set! rows* line row*)
  (properties rows*))

;;; ---------- 读 ----------

(define (properties-at p line col)
  (let-values ([(pl _) (row-slots (vector-ref (properties-rows p) line) col)]) pl))

(define (properties-get p line col key)
  (hash-ref (properties-at p line col) key #f))

(define (properties-restrict-at p line col)
  (let-values ([(_ rs) (row-slots (vector-ref (properties-rows p) line) col)]) rs))

;; 一个槽在整行的段分解：切点 = {0, line-length} ∪ 全部 span 边界，
;; 逐段取值后合并相邻同值段。两个槽共用这一份，只是取值函数不同。
(define (slot-runs p line line-length get-slot)
  (define row (vector-ref (properties-rows p) line))
  (define pts (sort (remove-duplicates (append (list 0 line-length)
                                               (span-boundaries row)))
                    <))
  (define raw (for/list ([a (in-list (drop-right pts 1))]
                         [b (in-list (rest pts))])
                (list a b (get-slot row a))))
  (reverse
   (for/fold ([acc '()]) ([seg (in-list raw)])
     (cond
       [(null? acc) (list seg)]
       [(equal? (caddr (car acc)) (caddr seg))
        (cons (list (car (car acc)) (cadr seg) (caddr seg)) (cdr acc))]
       [else (cons seg acc)]))))

;; 渲染扫描：表现层段，恰好覆盖 [0, line-length)，相邻段 plist 必不同。
(define (properties-runs p line line-length)
  (slot-runs p line line-length
             (lambda (row col)
               (let-values ([(pl _) (row-slots row col)]) pl))))

;; 约束扫描：约束槽段，形状同上。枚举只读区间用（O(段数)，不是 O(列数)）。
(define (properties-restrict-runs p line line-length)
  (slot-runs p line line-length
             (lambda (row col)
               (let-values ([(_ rs) (row-slots row col)]) rs))))

;; 表现层单键扫描：只按该 key 的值切段合并，返回覆盖整行的段（无该 key 处为 #f）。
;; 区间查询（诊断/高亮）必须用它：不能先取 properties-runs 再 filter —— 其它 key
;; 会把边界切断/并错，读出来的区间就不是该 key 原来的区间。
(define (properties-key-runs p line line-length key)
  (slot-runs p line line-length
             (lambda (row col)
               (let-values ([(pl _) (row-slots row col)]) (hash-ref pl key #f)))))

;;; ---------- 写（表现层）----------

(define (properties-put p line start end key val)
  (properties-modify p line start end
                     (lambda (pl rs) (values (hash-set pl key val) rs))))

(define (properties-remove p line start end key)
  (properties-modify p line start end
                     (lambda (pl rs) (values (hash-remove pl key) rs))))

;; segs = (listof (list line start end key val))；同一行按出现顺序依次施加。
;; 只拷贝 rows 向量一次（否则每个 seg 都 O(行数) 拷贝）。
(define (properties-put-many p segs)
  (cond
    [(null? segs) p]
    [else
     (define rows (properties-rows p))
     (define by-line (make-hash))
     (for ([s (in-list segs)])
       (match-define (list line start end key val) s)
       (hash-update! by-line line (lambda (l) (cons (list start end key val) l)) '()))
     (define rows* (vector-copy rows))
     (for ([(line items) (in-hash by-line)])
       (define row* (for/fold ([row (vector-ref rows line)])
                              ([it (in-list (reverse items))])
                      (match-define (list start end key val) it)
                      (row-modify row start end
                                  (lambda (pl rs) (values (hash-set pl key val) rs)))))
       (vector-set! rows* line row*))
     (properties rows*)])) 

;; 清掉 [first-line, last-line] 内 key 的全部旧值，再写入 segs（同 key）。
;; segs = (listof (list line start end val))。插件 delta 的实现。
(define (properties-replace-key p first-line last-line key segs)
  (define rows (properties-rows p))
  (define n (vector-length rows))
  (define f (max 0 (min first-line (sub1 n))))
  (define l (max 0 (min last-line (sub1 n))))
  (define rows* (vector-copy rows))
  (for ([line (in-range f (add1 l))])
    (vector-set! rows* line
      (merge-adjacent
       (filter (lambda (sp) (not (span-empty? sp)))
               (for/list ([sp (in-list (vector-ref rows line))])
                 (span (span-start sp) (span-end sp)
                       (hash-remove (span-presentation sp) key)
                       (span-restrict sp)))))))
  (properties-put-many
   (properties rows*)
   (for/list ([s (in-list segs)])
     (match-define (list line start end val) s)
     (list line start end key val))))

;;; ---------- 写（约束层）----------

;; 设 [start, end) 的约束（传 (make-restrict) 清除）。只动约束槽。
(define (properties-put-restrict p line start end rs)
  (properties-modify p line start end
                     (lambda (pl _) (values pl rs))))

;;; ---------- 编辑调整 ----------

;; 在 col 处把一行切成两半；跨切点的 span 被切成两个（两半都保留两个槽）。
(define (split-row row col)
  (define-values (left right)
    (for/fold ([l '()] [r '()]) ([sp (in-list row)])
      (define s (span-start sp)) (define e (span-end sp))
      (define pl (span-presentation sp)) (define rs (span-restrict sp))
      (cond
        [(<= e col) (values (cons sp l) r)]
        [(>= s col) (values l (cons (span (- s col) (- e col) pl rs) r))]
        [else       (values (cons (span s col pl rs) l)
                            (cons (span 0 (- e col) pl rs) r))])))
  (values (reverse left) (reverse right)))

(define (shift-spans row n)
  (for/list ([sp (in-list row)])
    (span (+ n (span-start sp)) (+ n (span-end sp))
          (span-presentation sp) (span-restrict sp))))

;; 插入继承：返回左邻的 presentation（可继承时）或 #f。
(define (inherit-presentation left col)
  (and (pair? left)
       (= (span-end (last left)) col)
       (restrict-empty? (span-restrict (last left)))
       (span-presentation (last left))))

(define (extend-last left inherit col first-len)
  (if inherit
      (let ([sp (last left)])
        (append (drop-right left 1)
                (list (span (span-start sp) (+ col first-len)
                            (span-presentation sp) (span-restrict sp)))))
      left))

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

;; 在 start 处插入 k 行文本，返回新 rows。
(define (insert-lines rows start new-lines)
  (define k (length new-lines))
  (cond
    [(zero? k) rows]
    [else
     (define sl (point-line start)) (define sc (point-col start))
     (define-values (left right) (split-row (vector-ref rows sl) sc))
     (define inherit (inherit-presentation left sc))
     (define first-len (string-length (car new-lines)))
     (define last-len (string-length (last new-lines)))
     (define n (vector-length rows))
     (define v* (make-vector (+ n (sub1 k)) '()))
     (vector-copy! v* 0 rows 0 sl)
     (cond
       [(= k 1)
        (vector-set! v* sl
          (merge-adjacent (append (extend-last left inherit sc first-len)
                                  (shift-spans right (+ sc first-len)))))]
       [else
        (vector-set! v* sl (merge-adjacent (extend-last left inherit sc first-len)))
        (for ([i (in-range 1 (sub1 k))])
          (vector-set! v* (+ sl i)
            (if inherit
                (list (span 0 (string-length (list-ref new-lines i)) inherit (make-restrict)))
                '())))
        (vector-set! v* (+ sl (sub1 k))
          (merge-adjacent
           (append (if inherit
                       (list (span 0 last-len inherit (make-restrict)))
                       '())
                   (shift-spans right last-len))))])
     (vector-copy! v* (+ sl k) rows (add1 sl) n)
     v*]))

;; 施加一条 edit-desc：先删区间，再插新文本（含继承）。
(define (properties-apply-edit p d)
  (define rows (properties-rows p))
  (define rows1 (delete-range rows (edit-desc-start d) (edit-desc-end d)))
  (properties
   (insert-lines rows1 (edit-desc-start d)
                 (string->lines (edit-desc-new-text d)))))

;;; ---------- 测试 ----------

(module+ test
  (define (fresh) (make-properties 3))
  (define ro (restrict #t))
  (define (apply* p d) (properties-apply-edit p d))

  ;; 点查询 + 半开区间
  (define p0 (properties-put (fresh) 1 0 5 'face 'bold))
  (check-equal? (properties-get p0 1 2 'face) 'bold)
  (check-equal? (properties-get p0 1 4 'face) 'bold)
  (check-equal? (properties-get p0 1 5 'face) #f)

  ;; 相邻同槽合并（P2）；两槽不同不合并
  (define p1 (properties-put (properties-put p0 1 5 8 'face 'bold) 1 0 8 'face 'bold))
  (check-equal? (length (vector-ref (properties-rows p1) 1)) 1)
  (define q5 (properties-put-restrict (properties-put (fresh) 1 0 6 'face 'bold) 1 0 3 ro))
  (check-equal? (length (vector-ref (properties-rows q5) 1)) 2)

  ;; 批量写与逐个写等价，且保持出现顺序
  (define p6 (properties-put-many (fresh)
                                  (list (list 1 0 5 'a 1)
                                        (list 1 2 3 'b 2)
                                        (list 0 0 2 'a 9))))
  (define p7 (properties-put (properties-put (properties-put (fresh) 1 0 5 'a 1) 1 2 3 'b 2) 0 0 2 'a 9))
  (check-equal? p6 p7)

  ;; 清旧写新：只动同 key
  (define pr (properties-put (properties-put (fresh) 1 0 5 'face 'bold) 1 7 9 'face 'bold))
  (define pr2 (properties-replace-key pr 0 2 'face (list (list 1 0 2 'red))))
  (check-equal? (properties-get pr2 1 0 'face) 'red)
  (check-equal? (properties-get pr2 1 3 'face) #f)
  (check-equal? (properties-get pr2 1 7 'face) #f)

  ;; 约束槽独立：写约束不动表现、写表现不动约束
  (define q1 (properties-put-restrict (properties-put (fresh) 1 0 5 'face 'bold) 1 2 4 ro))
  (check-true (restrict-read-only? (properties-restrict-at q1 1 3)))
  (check-equal? (properties-get q1 1 3 'face) 'bold)
  (check-equal? (properties-restrict-at q1 1 0) (make-restrict))
  (check-equal? (properties-restrict-at (properties-put-restrict q1 1 2 4 (make-restrict)) 1 3)
                (make-restrict))

  ;; 段分解：表现层与约束层各切各的
  (define r0 (properties-put-restrict (properties-put (fresh) 1 0 2 'face 'bold) 1 3 6 ro))
  (check-equal? (properties-runs r0 1 8)
                (list (list 0 2 (hash 'face 'bold)) (list 2 8 empty-plist)))
  (check-equal? (properties-restrict-runs r0 1 8)
                (list (list 0 3 (make-restrict)) (list 3 6 ro) (list 6 8 (make-restrict))))
  ;; 单键扫描：被其它 key 切断/包裹也还原该键区间
  (define kr (properties-put (properties-put (fresh) 1 0 4 'diag 'D) 1 2 6 'face 'bold))
  (check-equal? (properties-key-runs kr 1 10 'diag)
                (list (list 0 4 'D) (list 4 10 #f)))
  (check-equal? (properties-key-runs kr 1 10 'face)
                (list (list 0 2 #f) (list 2 6 'bold) (list 6 10 #f)))
  ;; 相邻同约束合并
  (define r1 (properties-put-restrict (properties-put-restrict (fresh) 0 1 2 ro) 0 2 4 ro))
  (check-equal? (properties-restrict-runs r1 0 5)
                (list (list 0 1 (make-restrict)) (list 1 4 ro) (list 4 5 (make-restrict))))

  ;; 编辑传播：区间内插入 → 区间扩张，新字符继承 presentation
  (define e0 (properties-put (fresh) 0 0 3 'face 'bold))
  (define e1 (apply* e0 (edit-desc (point 0 1) (point 0 1) "x")))
  (check-equal? (properties-get e1 0 1 'face) 'bold)
  (check-equal? (properties-get e1 0 3 'face) 'bold)
  (check-equal? (properties-get e1 0 4 'face) #f)

  ;; 硬边界：约束区间末尾插入 → 两槽都不继承
  (define m0 (properties-put (properties-put-restrict (fresh) 0 0 5 ro) 0 0 5 'face 'prompt))
  (define m1 (apply* m0 (edit-desc (point 0 5) (point 0 5) "x")))
  (check-equal? (properties-get m1 0 5 'face) #f)
  (check-false (restrict-read-only? (properties-restrict-at m1 0 5)))
  (check-equal? (properties-get m1 0 3 'face) 'prompt)
  (check-true (restrict-read-only? (properties-restrict-at m1 0 3)))

  ;; 约束区间内部插入 → 右半仍只读、新字符不受约束
  (define q6 (properties-put-restrict (fresh) 0 0 5 ro))
  (define q7 (apply* q6 (edit-desc (point 0 2) (point 0 2) "x")))
  (check-true (restrict-read-only? (properties-restrict-at q7 0 1)))
  (check-false (restrict-read-only? (properties-restrict-at q7 0 2)))
  (check-true (restrict-read-only? (properties-restrict-at q7 0 3)))

  ;; 跨行删除 + 多行插入
  (define p4 (properties-put (fresh) 0 0 3 'face 'bold))
  (define p5 (apply* p4 (edit-desc (point 0 1) (point 1 1) "PQ\nR")))
  (check-equal? (properties-get p5 0 2 'face) 'bold)
  (check-equal? (properties-get p5 1 0 'face) 'bold)
  (check-equal? (properties-get p5 1 1 'face) #f)

  ;; 空/反向区间 → 报错
  (check-exn exn:fail? (lambda () (properties-put (fresh) 1 2 2 'face 'bold)))
  (check-exn exn:fail? (lambda () (properties-put-restrict (fresh) 1 3 1 ro)))

  ;; 不变量：编辑后仍合法
  (check-equal? (properties-check p5) p5)

  (displayln "properties.rkt: all tests passed"))
