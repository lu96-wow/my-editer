#lang racket

(require "../atom/point.rkt" "../atom/lines.rkt" "../atom/edit.rkt"
         "../atom/attr.rkt" rackunit)

;;; unit/attrs.rkt —— 行内属性区间（通用 key→value，随编辑移动）
;;;
;;; 一个 attrs 就是一块**属性 buffer**：与 content 同坐标、平行，吃**同一条生效
;;; edit-desc**（由 content-apply 产出）。属性是 span 上的 hash：key/值由使用方定义，
;;; core 只保留并解释 'read-only（见 doc/document.rkt）。
;;;
;;; 不变量（attrs-check 强制）：
;;;   P1  每行内 rspan 按 start 升序、互不重叠
;;;   P2  相邻且 hash 相同的 rspan 已合并
;;;   P3  hash 为空的 rspan 不保留
;;;   P4  行数 == content 行数（attrs-check 用 line-count 参数校验）
;;;
;;; 两条写路径：
;;;   attrs-apply-edit        —— 文本变更时跟随（吃生效 edit-desc），新文本不继承属性
;;;   attrs-apply-attr[-batch]—— 显式属性变更（吃 attr-desc），零宽 = no-op
;;;
;;; 撤销材料：attrs-desc-inverse（单条 attr-desc 的逆）。文本编辑抹掉的属性由 doc 层
;;; 用 attrs-range-runs 捕获后补回（见 doc/document.rkt）。

(provide
 attrs?                             ; 构造器/内部字段不外露（避免绕过不变量）
 attrs-empty
 attrs-line-count
 attrs-at
 attrs-runs
 attrs-key-runs
 attrs-range-runs
 attrs-apply-edit
 attrs-apply-attr
 attrs-apply-attr-batch
 attrs-replace-descs
 attrs-desc-inverse
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

;; 交叉校验：行数必须等于 line-count（与 content 同坐标），否则报错。
(define (attrs-check p line-count)
  (unless (and (exact-nonnegative-integer? line-count) (>= line-count 1))
    (error 'attrs-check "line-count must be >= 1, got ~a" line-count))
  (unless (= (attrs-line-count p) line-count)
    (error 'attrs-check "attrs 行数 ~a ≠ content 行数 ~a"
           (attrs-line-count p) line-count))
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
(define (row-update who row start end f)
  (when (>= start end)
    (error who "属性区间必须 start < end，得到 [~a,~a)" start end))
  (define bounds (sort (remove-duplicates (append (list start end)
                                                  (rspan-boundaries row)))
                       <))
  (define segments
    (for/list ([a (in-list (drop-right bounds 1))]
               [b (in-list (rest bounds))])
      (define inside? (and (<= start a) (<= b end)))
      (define v (if inside? (f (row-val-at row a)) (row-val-at row a)))
      (rspan a b v)))
  (merge-adjacent (filter (lambda (sp) (not (rspan-empty? sp))) segments)))

;; 对 [start,end) 统一设置 key→val（保留其它 key）。
(define (row-put-key who row start end key val)
  (row-update who row start end (lambda (h) (hash-set h key val))))

;; 对 [start,end) 移除 key。
(define (row-remove-key who row start end key)
  (row-update who row start end (lambda (h) (hash-remove h key))))

;;; ---------- 读 ----------

(define (attrs-at p q)
  (define l (point-line q)) (define c (point-col q))
  (row-val-at (vector-ref (attrs-rows p) l) c))

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

;; 跨行枚举 [start,end) 内所有属性段（含每个 key 的完整 hash）；含两端行、中间整行。
;; 半开区间，跨行时按行切；返回 (listof (list line start-col end-col hash))。
;; 用于：文本编辑抹掉某区间时，把该区间的属性捕获下来（撤销时补回）。
(define (attrs-range-runs p start end)
  (unless (point<=? start end)
    (error 'attrs-range-runs "区间反向: ~a..~a" start end))
  (define rows (attrs-rows p))
  (define n (vector-length rows))
  (define sl (point-line start)) (define sc (point-col start))
  (define el (point-line end))   (define ec (point-col end))
  (unless (< sl n) (error 'attrs-range-runs "起始行越界: ~a" sl))
  (unless (< el n) (error 'attrs-range-runs "结束行越界: ~a" el))
  (define (clip-line line lo hi)            ; hi = #f → 到行尾
    (for*/list ([sp (in-list (vector-ref rows line))]
                #:when (and (or (not hi) (< (rspan-start sp) hi))
                            (> (rspan-end sp) lo)))
      (list line (max lo (rspan-start sp))
            (if hi (min hi (rspan-end sp)) (rspan-end sp))
            (rspan-val sp))))
  (cond
    [(= sl el) (clip-line sl sc ec)]
    [else
     (append (clip-line sl sc #f)
             (append* (for/list ([l (in-range (add1 sl) el)]) (clip-line l 0 #f)))
             (clip-line el 0 ec))]))

;;; ---------- 文本编辑跟随（新文本无属性，不继承） ----------

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

;;; ---------- 显式属性变更（attr-desc） ----------

;; attr-desc 的静态合法性：同行、行号在域内、方向不反。零宽由调用方按 no-op 处理。
(define (check-attr-line a who d)
  (define s (attr-desc-start d)) (define e (attr-desc-end d))
  (unless (= (point-line s) (point-line e))
    (error who "属性区间必须同一行: ~a..~a" s e))
  (unless (point<=? s e)
    (error who "属性区间反向: ~a..~a" s e))
  (define l (point-line s))
  (unless (< l (attrs-line-count a))
    (error who "属性行号越界: ~a（attrs 行数 ~a）" l (attrs-line-count a))))

(define (op-fn who d row)
  (case (attr-desc-op d)
    [(set)    (lambda () (row-put-key who row
                                       (point-col (attr-desc-start d))
                                       (point-col (attr-desc-end d))
                                       (attr-desc-key d) (attr-desc-val d)))]
    [(remove) (lambda () (row-remove-key who row
                                         (point-col (attr-desc-start d))
                                         (point-col (attr-desc-end d))
                                         (attr-desc-key d)))]
    [else (error who "未知 attr op: ~a" (attr-desc-op d))]))

;; 施加单条 attr-desc。零宽 = no-op（有唯一合法解释 → 归一，不报错）。
(define (attrs-apply-attr a who d)
  (check-attr-line a who d)
  (if (attr-desc-empty? d)
      a
      (let* ([rows (attrs-rows a)]
             [rows* (vector-copy rows)]
             [line (point-line (attr-desc-start d))]
             [row* ((op-fn who d (vector-ref rows line)))])
        (vector-set! rows* line row*)
        (attrs rows*))))

;; 批量施加：按行分组，每行只拷贝一次行、只做一次 row 折叠。
;; 同 (line,key) 区间不得重叠（否则逆不成立）→ 报错。
(define (check-attr-descs who ds)
  (define groups (make-hash))
  (for ([d (in-list ds)])
    (hash-update! groups (cons (point-line (attr-desc-start d)) (attr-desc-key d))
                  (lambda (l) (cons d l)) '()))
  (for ([(k l) (in-hash groups)])
    (define sorted (sort l (lambda (x y)
                             (< (point-col (attr-desc-start x))
                                (point-col (attr-desc-start y))))))
    (for ([x (in-list (drop-right sorted 1))] [y (in-list (rest sorted))])
      (when (point<? (attr-desc-start y) (attr-desc-end x))
        (error who "属性编辑重叠（同一 key）: ~a 与 ~a" x y)))))

(define (attrs-apply-attr-batch a who ds)
  (for-each (lambda (d) (check-attr-line a who d)) ds)
  (check-attr-descs who ds)
  (define live (filter (lambda (d) (not (attr-desc-empty? d))) ds))
  (cond
    [(null? live) a]
    [else
     (define by-line (make-hash))
     (for ([d (in-list live)])
       (hash-update! by-line (point-line (attr-desc-start d))
                     (lambda (l) (append l (list d))) '()))
     (define rows* (vector-copy (attrs-rows a)))
     (for ([(line line-ds) (in-hash by-line)])
       (define row* (for/fold ([row (vector-ref rows* line)]) ([d (in-list line-ds)])
                      ((op-fn who d row))))
       (vector-set! rows* line row*))
     (attrs rows*)]))

;;; ---------- 逆（显式属性的撤销材料） ----------

;; 对单条 attr-desc，给出「恢复其覆盖前 key 状态」的 attr-desc 列表
;; （同坐标系；依次施加可精确回到 d 之前）。零宽 → '()。
(define (attrs-desc-inverse a d)
  (check-attr-line a 'attrs-desc-inverse d)
  (if (attr-desc-empty? d)
      '()
      (let* ([line (point-line (attr-desc-start d))]
             [s (point-col (attr-desc-start d))]
             [e (point-col (attr-desc-end d))]
             [key (attr-desc-key d)]
             [row (vector-ref (attrs-rows a) line)]
             [pts (sort (remove-duplicates
                         (append (list s e)
                                 (append*
                                  (for*/list ([sp (in-list row)]
                                              #:when (and (< (rspan-start sp) e)
                                                          (> (rspan-end sp) s)))
                                    (list (max s (rspan-start sp))
                                          (min e (rspan-end sp)))))))
                        <)])
        (for/list ([x (in-list (drop-right pts 1))] [y (in-list (rest pts))]
                   #:when (< x y))
          (define h (row-val-at row x))
          (if (hash-has-key? h key)
              (attr-set (point line x) (point line y) key (hash-ref h key))
              (attr-remove (point line x) (point line y) key))))))

;;; ---------- 替换式批量（把某 key 在一行上的 runs 整体换成新 runs） ----------

;; 合并相邻、同 op/key/val 的 attr-desc（把被旧 run 边界切开的同一次 set 接回去）。
(define (merge-replace-descs ds)
  (define (same? a b)
    (and (eq? (attr-desc-op a) (attr-desc-op b))
         (eq? (attr-desc-key a) (attr-desc-key b))
         (equal? (attr-desc-val a) (attr-desc-val b))
         (point=? (attr-desc-end a) (attr-desc-start b))))
  (reverse
   (for/fold ([acc '()]) ([d (in-list ds)])
     (cond
       [(null? acc) (list d)]
       [(same? (car acc) d)
        (cons (attr-desc (attr-desc-start (car acc)) (attr-desc-end d)
                         (attr-desc-key d) (attr-desc-op d) (attr-desc-val d))
              (cdr acc))]
       [else (cons d acc)]))))

;; old-runs / new-runs : (listof (list start end val))，行内列号（nat）。
;; 返回同 line/key、**两两不重叠**的 attr-desc：新 runs 覆盖的段 set，其余原先被旧 runs
;; 覆盖的段 remove；两者都未覆盖的段不产出。结果可直接进 attrs-apply-attr-batch。
;; 语义 = 「该 key 在这一行的值变成且仅变成 new-runs」（旧值自动消失）。
(define (attrs-replace-descs who line key old-runs new-runs)
  (define (norm runs)
    (define sorted
      (sort (for/list ([r (in-list runs)])
              (match-define (list a b v) r)
              (unless (and (exact-nonnegative-integer? a) (exact-nonnegative-integer? b))
                (error who "run 列号必须是 nat: ~a" r))
              (when (< b a) (error who "run 列号反向: ~a" r))
              (list a b v))
            < #:key car))
    (when (pair? sorted)
      (for ([x (in-list (drop-right sorted 1))] [y (in-list (rest sorted))])
        (when (< (car y) (cadr x))
          (error who "新增 run 重叠: ~a 与 ~a" x y))))
    sorted)
  (define old-n (norm old-runs))
  (define new-n (norm new-runs))
  (define pts (sort (remove-duplicates
                     (append* (for/list ([r (in-list (append old-n new-n))])
                                (list (car r) (cadr r)))))
                    <))
  (merge-replace-descs
   (if (null? pts)
       '()
       (filter values
           (for/list ([a (in-list (drop-right pts 1))] [b (in-list (rest pts))])
             (cond
               [(>= a b) #f]
               [else
                (define nr (for/first ([r (in-list new-n)] #:when (and (<= (car r) a) (< a (cadr r)))) r))
                (define orr (for/first ([r (in-list old-n)] #:when (and (<= (car r) a) (< a (cadr r)))) r))
                (cond
                  [nr  (attr-set (point line a) (point line b) key (caddr nr))]
                  [orr (attr-remove (point line a) (point line b) key)]
                  [else #f])]))))))

;;; ---------- 测试 ----------

(module+ test
  (define (fresh) (attrs-empty 3))
  (define (P l c) (point l c))
  (define (apply-attr* a d) (attrs-apply-attr a 'test d))

  ;; 点查询（hash 属性）+ 半开区间
  (define p0 (apply-attr* (fresh) (attr-set (P 1 0) (P 1 5) 'ro #t)))
  (check-equal? (attrs-at p0 (P 1 0)) (hash 'ro #t))
  (check-equal? (attrs-at p0 (P 1 4)) (hash 'ro #t))
  (check-equal? (attrs-at p0 (P 1 5)) (hash))

  ;; 多 key 互不干扰；相邻同 hash 合并（P2）
  (define p1 (apply-attr* (apply-attr* (fresh) (attr-set (P 0 1) (P 0 2) 'a 1))
                          (attr-set (P 0 2) (P 0 4) 'a 1)))
  (check-equal? (attrs-runs p1 0 5)
                (list (list 0 1 (hash)) (list 1 4 (hash 'a 1)) (list 4 5 (hash))))
  (define p1b (apply-attr* p1 (attr-set (P 0 2) (P 0 3) 'b 2)))
  (check-equal? (attrs-key-runs p1b 0 5 'a) (list (list 1 4 1)))
  (check-equal? (attrs-key-runs p1b 0 5 'b) (list (list 2 3 2)))

  ;; remove key
  (define p2 (apply-attr* p0 (attr-remove (P 1 2) (P 1 3) 'ro)))
  (check-equal? (attrs-at p2 (P 1 1)) (hash 'ro #t))
  (check-equal? (attrs-at p2 (P 1 2)) (hash))
  (check-equal? (attrs-at p2 (P 1 3)) (hash 'ro #t))

  ;; 零宽 = no-op（不报错、不变）
  (define z0 (fresh))
  (check-eq? (apply-attr* z0 (attr-set (P 0 1) (P 0 1) 'k #t)) z0)
  (check-eq? (apply-attr* p0 (attr-remove (P 1 2) (P 1 2) 'ro)) p0)

  ;; 跨行先报错（不被夹紧掩盖）；行号越界具名报错
  (check-exn exn:fail? (lambda () (apply-attr* (fresh) (attr-set (P 0 0) (P 1 0) 'k #t))))
  (check-exn exn:fail? (lambda () (apply-attr* (fresh) (attr-set (P 9 0) (P 9 1) 'k #t))))

  ;; 批量：一次施加多条（含跨行）
  (define pb (attrs-apply-attr-batch (fresh) 'test
                                     (list (attr-set (P 0 0) (P 0 3) 'ro #t)
                                           (attr-set (P 1 0) (P 1 2) 'ro #t))))
  (check-equal? (attrs-key-runs pb 0 3 'ro) (list (list 0 3 #t)))
  (check-equal? (attrs-key-runs pb 1 3 'ro) (list (list 0 2 #t)))
  ;; 同 key 重叠 → 报错
  (check-exn exn:fail?
             (lambda () (attrs-apply-attr-batch (fresh) 'test
                          (list (attr-set (P 0 1) (P 0 3) 'ro #t)
                                (attr-set (P 0 2) (P 0 4) 'ro #t)))))

  ;; 逆：set 覆盖后恢复原值/恢复「无 key」
  (define inv-base (apply-attr* (fresh) (attr-set (P 0 1) (P 0 2) 'ro #t)))  ; [1,2) ro
  (define invs (attrs-desc-inverse inv-base (attr-set (P 0 0) (P 0 4) 'ro #t)))
  (define restored
    (for/fold ([a (apply-attr* inv-base (attr-set (P 0 0) (P 0 4) 'ro #t))])
              ([d (in-list invs)]) (apply-attr* a d)))
  (check-equal? (attrs-key-runs restored 0 5 'ro) (list (list 1 2 #t)))

  ;; 文本编辑跟随：区间内插入 → 右半后移，插入点无属性
  (define e0 (apply-attr* (fresh) (attr-set (P 0 0) (P 0 5) 'ro #t)))
  (define e1 (attrs-apply-edit e0 (edit-desc (P 0 2) (P 0 2) "x")))
  (check-equal? (attrs-runs e1 0 6)
                (list (list 0 2 (hash 'ro #t)) (list 2 3 (hash)) (list 3 6 (hash 'ro #t))))
  ;; 删除区间内部 → 收缩
  (define e2 (attrs-apply-edit e0 (edit-desc (P 0 1) (P 0 3) "")))
  (check-equal? (attrs-runs e2 0 3) (list (list 0 3 (hash 'ro #t))))

  ;; 跨行删除 + 多行插入：属性被正确切/移，新行无属性
  (define p4 (apply-attr* (fresh) (attr-set (P 0 0) (P 0 3) 'ro #t)))
  (define p5 (attrs-apply-edit p4 (edit-desc (P 0 1) (P 1 1) "PQ\nR")))
  (check-equal? (attrs-at p5 (P 0 0)) (hash 'ro #t))
  (check-equal? (attrs-at p5 (P 0 1)) (hash))
  (check-equal? (attrs-at p5 (P 1 0)) (hash))
  (check-equal? (attrs-check p5 3) p5)

  ;; attrs-range-runs：跨行捕获
  (define rg (apply-attr* (fresh) (attr-set (P 0 1) (P 0 4) 'ro #t)))
  (check-equal? (attrs-range-runs rg (P 0 0) (P 1 0))
                (list (list 0 1 4 (hash 'ro #t))))
  (check-equal? (attrs-range-runs rg (P 0 2) (P 0 3))
                (list (list 0 2 3 (hash 'ro #t))))

  ;; attrs-check：行数必须一致
  (check-exn exn:fail? (lambda () (attrs-check (fresh) 2)))
  (check-exn exn:fail? (lambda () (attrs-check (fresh) 0)))

  ;; attrs-replace-descs：新覆盖 set、原旧区 remove，结果两两不重叠
  (define (replace old new) (attrs-replace-descs 'test 0 'ro old new))
  (check-equal? (replace '() '((0 2 v))) (list (attr-set (P 0 0) (P 0 2) 'ro 'v)))
  (check-equal? (replace '((0 5 v)) '()) (list (attr-remove (P 0 0) (P 0 5) 'ro)))
  (check-equal? (replace '((0 5 v)) '((2 3 w)))
                (list (attr-remove (P 0 0) (P 0 2) 'ro)
                      (attr-set (P 0 2) (P 0 3) 'ro 'w)
                      (attr-remove (P 0 3) (P 0 5) 'ro)))
  (check-equal? (replace '((0 5 v)) '((0 5 w))) (list (attr-set (P 0 0) (P 0 5) 'ro 'w)))
  (check-equal? (replace '((0 2 v) (4 6 v)) '((1 5 w)))
                (list (attr-remove (P 0 0) (P 0 1) 'ro)
                      (attr-set (P 0 1) (P 0 5) 'ro 'w)
                      (attr-remove (P 0 5) (P 0 6) 'ro)))
  ;; 结果确实不重叠（能进 batch）
  (define rds (replace '((0 5 v)) '((2 3 w))))
  (define base (attrs-apply-attr-batch (fresh) 'test (list (attr-set (P 0 0) (P 0 5) 'ro 'v))))
  (define done (attrs-apply-attr-batch base 'test rds))
  (check-equal? (attrs-key-runs done 0 5 'ro) (list (list 2 3 'w)))
  ;; 新 runs 自身重叠 → 报错
  (check-exn exn:fail? (lambda () (replace '() '((0 3 v) (1 4 w)))))
  (check-exn exn:fail? (lambda () (replace '() '((4 2 v)))))

  (displayln "attrs.rkt: all tests passed"))
