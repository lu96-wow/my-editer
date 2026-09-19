#lang racket

(require "point.rkt" "content.rkt" rackunit)

;;; properties.rkt —— 行内属性区间（两个槽）
;;;
;;; 每个区间 = 一个 **span**，带两个性质不同的槽：
;;;   presentation : 开放式「键 → 值」袋（'face 等）。core **不解释**，只随文本搬运；
;;;                  投影时逐字进 glyph.face，永不过滤。
;;;   restrict     : typed 约束（core **解释**，如 read-only）。
;;;                  「加约束」= 加字段（编译期可见），不是加魔法键名。
;;;
;;; 传播规则（显式两槽，唯一实现在 inherit-presentation）：
;;;   presentation 继承左邻；restrict 永不继承；
;;;   左邻带 restrict ⇒ presentation 也不继承（约束变化处 = 字段边界）。
;;;
;;; 不变量（由 properties-check 强制）：
;;;   P1  每行内区间按 start 升序、互不重叠
;;;   P2  相邻且 (presentation, restrict) 都相同的区间已合并
;;;   P3  (presentation, restrict) 都为空的区间不保留
;;;
;;; 区间是半开的 [start, end)，坐标为行内列号。
;;; 行号由 rows 向量的下标隐式表达，不重复存储。
;;;
;;; 对外不暴露 span 的内部结构。所有查询走
;;; properties-at / properties-get / properties-restrict-at
;;; ／行内段分解 properties-runs（表现层）/ properties-restrict-runs（约束层）。

(provide
 (struct-out properties)
 (struct-out restrict)
 make-properties
 make-restrict
 properties-check
 properties-debug?
 properties-line-count
 properties-at
 properties-get
 properties-put
 properties-put-many
 properties-remove
 properties-replace-key
 properties-put-restrict
 properties-restrict-at
 properties-apply-edit
 properties-splice
 properties-runs
 properties-restrict-runs)

;;; ---------- 内部结构 ----------

(struct restrict (read-only?) #:transparent)
;; 约束槽：core 解释的语义。加约束 = 加字段（编译期可见），不是加魔法键名。

(define (make-restrict) (restrict #f))          ; 空约束
;; 用 equal? 与空约束比较：以后加字段时，只要 make-restrict 给出默认值，这里自动跟随。
(define (restrict-empty? r) (equal? r (make-restrict)))

(struct span (start end presentation restrict) #:transparent)
;; presentation : immutable hash
;; restrict     : restrict

(struct properties (rows) #:transparent)
;; rows : (vectorof (listof span))

(define empty-plist (hash))

(define (span-empty? sp)
  (and (zero? (hash-count (span-presentation sp)))
       (restrict-empty? (span-restrict sp))))

(define (span-slots=? a b)
  (and (equal? (span-presentation a) (span-presentation b))
       (equal? (span-restrict a) (span-restrict b))))

;;; ---------- 构造 & 不变量 ----------

(define (make-properties line-count)
  (unless (and (exact-nonnegative-integer? line-count) (>= line-count 1))
    (error 'make-properties "line-count must be >= 1, got ~a" line-count))
  (properties (make-vector line-count '())))

(define (properties-line-count p)
  (vector-length (properties-rows p)))

;; 热路径只校验受影响行；全量校验走 properties-check（测试/诊断用）。
(define properties-debug? (make-parameter #f))

(define (properties-check-line row)
  (let loop ([prev-end -1] [rest row])
    (unless (null? rest)
      (define sp (car rest))
      (unless (< (span-start sp) (span-end sp))
        (error 'properties-check-line "span start >= end: ~a" sp))
      (unless (>= (span-start sp) prev-end)
        (error 'properties-check-line "overlapping or unordered spans in row: ~a" row))
      (unless (not (span-empty? sp))
        (error 'properties-check-line "empty span should not exist: ~a" sp))
      (loop (span-end sp) (cdr rest)))))

(define (properties-check p)
  (for ([row (in-vector (properties-rows p))])
    (properties-check-line row))
  p)

;;; ---------- 内部工具 ----------

(define (vec-set v i x)
  (define v* (vector-copy v))
  (vector-set! v* i x)
  v*)

;; 某行内 col 处的两个槽；没被任何区间覆盖 → (空 plist, 空约束)
(define (row-slots row col)
  (define sp (for/first ([sp (in-list row)]
                         #:when (and (<= (span-start sp) col)
                                     (< col (span-end sp))))
              sp))
  (if sp
      (values (span-presentation sp) (span-restrict sp))
      (values empty-plist (make-restrict))))

(define (merge-adjacent spans)
  (if (null? spans)
      '()
      (reverse
       (for/fold ([acc (list (car spans))])
                 ([sp (in-list (cdr spans))])
         (define last (car acc))
         (if (and (= (span-end last) (span-start sp))
                  (span-slots=? last sp))
             (cons (span (span-start last) (span-end sp)
                         (span-presentation last) (span-restrict last))
                   (cdr acc))
             (cons sp acc))))))

;; 对 [start, end) 范围内每一段施加 transform（两个槽一起），重铺区间。
;; transform : plist restrict -> (values plist restrict)
;; 单遍扫描：suffix 指针只向前走，整体 O(k log k)（排序主导）。
(define (row-modify row start end transform)
  ;; 空区间/反向没有合法解释 → 报错。否则静默什么都不写，而调用方以为设上了
  ;; （写只读区时"以为锁住了没锁"）。清除约束请传 (make-restrict)。见 ARCHITECTURE §8.5 A2。
  (when (>= start end)
    (error 'properties "属性/约束区间必须 start < end，得到 [~a,~a)" start end))
  (define points
    (sort (remove-duplicates
           (append (list start end)
                   (append-map (lambda (sp) (list (span-start sp) (span-end sp)))
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
         (define-values (base-pl base-rs suffix*)
           (let skip ([s suffix])
             (cond
               [(null? s) (values empty-plist (make-restrict) s)]
               [(<= (span-end (car s)) a)   (skip (cdr s))]
               [(<= (span-start (car s)) a) (values (span-presentation (car s))
                                                    (span-restrict (car s)) s)]
               [else                        (values empty-plist (make-restrict) s)])))
         (define-values (pl* rs*)
           (if (and (<= start a) (<= b end))
               (transform base-pl base-rs)
               (values base-pl base-rs)))
         (loop (cdr pts) (cdr bnd) suffix* (cons (span a b pl* rs*) acc))])))
  (merge-adjacent
   (filter (lambda (sp) (not (span-empty? sp))) segments)))

(define (properties-modify p line start end transform)
  (define rows (properties-rows p))
  (define merged (row-modify (vector-ref rows line) start end transform))
  (when (properties-debug?) (properties-check-line merged))
  (properties (vec-set rows line merged)))

;;; ---------- 查询 ----------

;; 单点取槽：两个槽各一个入口，别处就不必反复解构 row-slots 的双值
(define (row-presentation row col) (let-values ([(pl _rs) (row-slots row col)]) pl))
(define (row-restrict row col)     (let-values ([(_pl rs) (row-slots row col)]) rs))

(define (properties-at p line col)
  (row-presentation (vector-ref (properties-rows p) line) col))

(define (properties-get p line col prop)
  (hash-ref (properties-at p line col) prop #f))

;; 约束槽：没被覆盖 → 空约束
(define (properties-restrict-at p line col)
  (row-restrict (vector-ref (properties-rows p) line) col))

;; 行内「某个槽」的段分解：切点 = 所有 span 边界 ∪ {0, line-length}，
;; 逐段取该槽的值，再合并相邻**同值**段。
;; 两个槽共用这一份——**只有取值不同**（slot : row col -> 值），切分与合并规则不各写一遍。
;; 注意切点来自 span 边界（两槽共同的边界），所以另一槽只变一处时也会切一刀，
;; 但紧接着会被"合并同值段"合回去——结果只由**被取的槽**决定。
(define (properties-slot-runs p line line-length slot)
  (define row (vector-ref (properties-rows p) line))
  (define pts
    (sort (remove-duplicates
           (append (list 0 line-length)
                   (append-map (lambda (sp) (list (span-start sp) (span-end sp)))
                               row)))
          <))
  (define raw
    (for/fold ([acc '()])
              ([a (in-list (drop-right pts 1))] [b (in-list (rest pts))])
      (cons (list a b (slot row a)) acc)))
  ;; 合并相邻同值的段
  (reverse
   (for/fold ([acc '()]) ([seg (in-list (reverse raw))])
     (cond
       [(null? acc) (list seg)]
       [(equal? (caddr (car acc)) (caddr seg))
        (cons (list (car (car acc)) (cadr seg) (caddr seg)) (cdr acc))]
       [else (cons seg acc)]))))

;; 渲染扫描：一行内所有**表现层**段，恰好覆盖 [0, line-length)。
;; 返回 (listof (list start end plist))，按 start 升序，相邻段的 plist 必不同。
;; 结果只由 presentation 决定——**约束槽不参与**（它不影响画面），
;; 于是一个只读区间不会在画面里多切一段。
(define (properties-runs p line line-length)
  (properties-slot-runs p line line-length row-presentation))

;; 约束扫描：一行内所有**约束槽**段，形状同上： (listof (list start end restrict))，
;; 恰好覆盖 [0, line-length)，相邻段的 restrict 必不同。
;; 用途：**枚举**只读区间（`buffer-read-only-at?` 只能逐点问，这是 O(段数)）。
(define (properties-restrict-runs p line line-length)
  (properties-slot-runs p line line-length row-restrict))

;;; ---------- 写入（表现层）----------

(define (properties-put p line start end prop val)
  (properties-modify p line start end
                     (lambda (pl rs) (values (hash-set pl prop val) rs))))

;; 批量写：segs = (listof (list line start end prop val))。
;; 只拷贝 rows 向量一次（否则 properties-put 每个 seg 都 O(n) 拷贝 → O(m·n)）。
;; 同一行内的多个段按出现顺序依次应用，与逐个 properties-put 完全等价。
(define (properties-put-many p segs)
  (cond
    [(null? segs) p]
    [else
     (define rows (properties-rows p))
     (define groups (make-hash))
     (for ([s (in-list segs)])
       (match-define (list line start end prop val) s)
       (hash-update! groups line
                     (lambda (gs) (cons (list start end prop val) gs))
                     '()))
     (define rows* (vector-copy rows))
     (for ([(line gs) (in-hash groups)])
       (define row* (for/fold ([row (vector-ref rows line)])
                              ([g (in-list (reverse gs))])
                      (match-define (list start end prop val) g)
                      (row-modify row start end
                                  (lambda (pl rs) (values (hash-set pl prop val) rs)))))
       (vector-set! rows* line row*))
     (when (properties-debug?)
       (for ([row (in-vector rows*)]) (properties-check-line row)))
     (properties rows*)]))

(define (properties-remove p line start end prop)
  (properties-modify p line start end
                     (lambda (pl rs) (values (hash-remove pl prop) rs))))

;; 清掉 [first-line,last-line] 各行内 prop 键的全部旧值，再写入 segs（同键）。
;; segs = (listof (list line start end val))；一次拷贝 rows 向量，O(n + m log m)。
(define (properties-replace-key p first-line last-line prop segs)
  (define rows (properties-rows p))
  (define n (vector-length rows))
  (define f (max 0 (min first-line (sub1 n))))
  (define l (max 0 (min last-line (sub1 n))))
  (define rows* (vector-copy rows))
  (for ([line (in-range f (add1 l))])
    (define row (vector-ref rows line))
    (vector-set! rows* line
      (merge-adjacent
       (filter (lambda (sp) (not (span-empty? sp)))
               (for/list ([sp (in-list row)])
                 (span (span-start sp) (span-end sp)
                       (hash-remove (span-presentation sp) prop)
                       (span-restrict sp)))))))
  (properties-put-many (properties rows*)
                  (for/list ([s (in-list segs)])
                    (match-define (list line start end val) s)
                    (list line start end prop val))))

;;; ---------- 写入（约束槽）----------

;; 给 [start, end) 设约束（传 (make-restrict) 即清除）。只动约束槽，不碰表现层。
(define (properties-put-restrict p line start end rs)
  (properties-modify p line start end
                     (lambda (pl _old) (values pl rs))))

;;; ---------- 编辑调整：统一 splice ----------
;;; 编辑 desc 是「操作前坐标」。所有调整由两个行操作组合：
;;;   properties-splice = properties-insert-lines ∘ properties-delete-range

;; 在 col 处拆分一行：两个槽都跟着切（约束区间被切开，两半都保留该约束）。
(define (split-row row col)
  (define-values (left-rev right-rev)
    (for/fold ([l '()] [r '()]) ([sp (in-list row)])
      (define s (span-start sp))
      (define e (span-end sp))
      (define pl (span-presentation sp))
      (define rs (span-restrict sp))
      (cond [(<= e col) (values (cons sp l) r)]
            [(>= s col) (values l (cons (span (- s col) (- e col) pl rs) r))]
            [else       (values (cons (span s col pl rs) l)
                                (cons (span 0 (- e col) pl rs) r))])))
  (values (reverse left-rev) (reverse right-rev)))

(define (shift-spans row n)
  (for/list ([sp (in-list row)])
    (span (+ n (span-start sp)) (+ n (span-end sp))
          (span-presentation sp) (span-restrict sp))))

;; 删除 [s-line,s-col)..[e-line,e-col)，返回新 rows。
(define (properties-delete-range rows s-line s-col e-line e-col)
  (define n (vector-length rows))
  (define-values (s-left s-right) (split-row (vector-ref rows s-line) s-col))
  (define-values (_e-left e-right) (split-row (vector-ref rows e-line) e-col))
  ;; e-right 是相对 e-col 的，平移到合并行的 s-col 处
  (define merged
    (merge-adjacent (append s-left (shift-spans e-right s-col))))
  (define new-n (- (+ n s-line) e-line))   ; n - (e-line-s-line+1) + 1
  (define v* (make-vector new-n '()))
  (vector-copy! v* 0 rows 0 s-line)
  (vector-set! v* s-line merged)
  (vector-copy! v* (add1 s-line) rows (add1 e-line) n)
  v*)

;; 插入时的继承规则（显式两槽，唯一实现）：
;;   presentation 继承左邻；restrict 永不继承（新文本一律空约束）；
;;   左邻带 restrict ⇒ presentation 也不继承（约束变化处 = 字段边界）。
;; 返回「要继承的 presentation」或 #f（#f = 不继承）。
(define (inherit-presentation left col)
  (and (pair? left)
       (= (span-end (last left)) col)
       (restrict-empty? (span-restrict (last left)))
       (span-presentation (last left))))

;; 把 left 里「结束于 col」的区间扩到覆盖插入的首行（继承 presentation；
;; 该区间的 restrict 必为空——非空时 inherit-presentation 返回 #f）。
(define (extend-last left inherit col first-len)
  (if inherit
      (let ([sp (last left)])
        (append (drop-right left 1)
                (list (span (span-start sp) (+ col first-len)
                            (span-presentation sp) (span-restrict sp)))))
      left))

;; 在 (line,col) 插入 k 行 new-lines，返回新 rows。
(define (properties-insert-lines rows line col new-lines)
  (define n (vector-length rows))
  (define k (length new-lines))
  (cond
    [(zero? k) rows]
    [else
     (define-values (left right) (split-row (vector-ref rows line) col))
     (define inherit (inherit-presentation left col))
     (define first-len (string-length (car new-lines)))
     (define last-len (string-length (last new-lines)))
     (define new-n (+ n (sub1 k)))
     (define v* (make-vector new-n '()))
     (vector-copy! v* 0 rows 0 line)
     (cond
       [(= k 1)
        (vector-set! v* line
          (merge-adjacent
           (append (extend-last left inherit col first-len)
                   (shift-spans right (+ col first-len)))))]
       [else
        (vector-set! v* line (merge-adjacent (extend-last left inherit col first-len)))
        (for ([i (in-range 1 (sub1 k))])
          (vector-set! v* (+ line i)
            (if inherit
                (list (span 0 (string-length (list-ref new-lines i))
                            inherit (make-restrict)))
                '())))
        (vector-set! v* (+ line (sub1 k))
          (merge-adjacent
           (append (if inherit
                       (list (span 0 last-len inherit (make-restrict)))
                       '())
                   (shift-spans right last-len))))])
     (vector-copy! v* (+ line k) rows (add1 line) n)
     v*]))

;; 统一 splice：删除 + 插入。
(define (properties-splice p s-line s-col e-line e-col new-text)
  (define rows (properties-rows p))
  (define rows1 (properties-delete-range rows s-line s-col e-line e-col))
  (define new-lines (string->lines new-text))
  (define p* (properties (properties-insert-lines rows1 s-line s-col new-lines)))
  (when (properties-debug?) (properties-check p*))
  p*)

;;; ---------- edit-desc 分派 ----------

(define (properties-apply-edit p desc)
  (properties-splice p
                (edit-desc-s-line desc) (edit-desc-s-col desc)
                (edit-desc-e-line desc) (edit-desc-e-col desc)
                (edit-desc-new-text desc)))

;;; ---------- 测试 ----------

(module+ test
  (define (fresh) (make-properties 3))
  (define ro (restrict #t))

  ;; 点查询 & 半开区间（presentation）
  (define p0 (properties-put (fresh) 1 0 5 'face 'bold))
  (check-equal? (properties-get p0 1 2 'face) 'bold)
  (check-equal? (properties-get p0 1 0 'face) 'bold)
  (check-equal? (properties-get p0 1 5 'face) #f)
  (check-equal? (properties-get p0 0 0 'face) #f)

  ;; 相邻同 plist 合并（P2）
  (define p1 (properties-put p0 1 5 8 'face 'bold))
  (define p2 (properties-put p1 1 0 8 'face 'bold))
  (check-equal? (length (vector-ref (properties-rows p2) 1)) 1)

  ;; 编辑调整：插在区间内 → 扩张
  (parameterize ([properties-debug? #t])
    (define p3 (properties-apply-edit p2 (edit-desc 1 3 1 3 "X")))
    (check-equal? (properties-get p3 1 4 'face) 'bold)
    (properties-check p3)
    (void))   ; 收尾为 void，避免 raco test 打印整个 properties 值

  ;; splice：跨行删除 + 多行插入，继承左邻
  (define p4 (properties-put (fresh) 0 0 3 'face 'bold))
  (define p5 (properties-splice p4 0 1 1 1 "PQ\nR"))
  (check-equal? (properties-get p5 0 2 'face) 'bold)   ; 继承覆盖首行
  (check-equal? (properties-get p5 1 0 'face) 'bold)   ; 继承覆盖末行
  (check-equal? (properties-get p5 1 1 'face) #f)      ; 末行之后无属性

  ;; 批量写：与逐个 properties-put 等价，且保持出现顺序（后写覆盖先写）
  (define p6 (properties-put-many (fresh)
                             (list (list 1 0 5 'a 1)
                                   (list 1 2 3 'b 2)
                                   (list 0 0 2 'a 9))))
  (define p7 (properties-put (properties-put (properties-put (fresh) 1 0 5 'a 1) 1 2 3 'b 2) 0 0 2 'a 9))
  (check-equal? p6 p7)
  (check-equal? (properties-get p6 1 0 'a) 1)
  (check-equal? (properties-get p6 1 2 'b) 2)
  (check-equal? (properties-get p6 0 1 'a) 9)

  ;; properties-replace-key：清旧写新（patch 应用原语），约束槽不受影响
  (define pr0 (properties-put (fresh) 1 0 5 'face 'bold))
  (define pr1 (properties-put pr0 1 7 9 'face 'bold))
  (define pr2 (properties-replace-key pr1 0 2 'face (list (list 1 0 2 'red))))
  (check-equal? (properties-get pr2 1 0 'face) 'red)
  (check-equal? (properties-get pr2 1 3 'face) #f)   ; 旧 [0,5) 被清
  (check-equal? (properties-get pr2 1 7 'face) #f)   ; 旧 [7,9) 被清
  (check-equal? (properties-get pr2 0 0 'face) #f)

  ;; ---- 约束槽（restrict）----

  ;; 两槽独立：写表现不动约束，写约束不动表现
  (define q0 (properties-put (fresh) 1 0 5 'face 'bold))
  (define q1 (properties-put-restrict q0 1 2 4 ro))
  (check-equal? (properties-restrict-at q1 1 3) ro)
  (check-equal? (restrict-read-only? (properties-restrict-at q1 1 3)) #t)
  (check-equal? (properties-get q1 1 3 'face) 'bold)              ; 表现仍在
  (check-equal? (properties-restrict-at q1 1 0) (make-restrict))  ; 区间外 → 空约束
  (check-equal? (properties-restrict-at q1 0 0) (make-restrict))
  ;; 反向：先约束后表现
  (define q2 (properties-put-restrict (fresh) 1 0 5 ro))
  (define q3 (properties-put q2 1 0 5 'face 'bold))
  (check-equal? (properties-get q3 1 3 'face) 'bold)
  (check-equal? (properties-restrict-at q3 1 3) ro)

  ;; 清除约束：传空约束 → 该处约束消失
  (define q4 (properties-put-restrict q3 1 0 5 (make-restrict)))
  (check-equal? (properties-restrict-at q4 1 3) (make-restrict))
  (check-equal? (properties-get q4 1 3 'face) 'bold)   ; 表现不受影响
  ;; 只剩空约束的区间被丢弃（P3）→ 行内应只剩表现区间 1 个
  (check-equal? (length (vector-ref (properties-rows q4) 1)) 1)

  ;; 相邻同 (presentation, restrict) 合并；仅约束不同则不合并（P2）
  (define q5 (properties-put-restrict (properties-put (fresh) 1 0 6 'face 'bold) 1 0 3 ro))
  (check-equal? (length (vector-ref (properties-rows q5) 1)) 2)

  ;; 编辑调整：约束位置随文本走；「硬边界」在插入处不继承
  (parameterize ([properties-debug? #t])
    (define q6 (properties-put-restrict (fresh) 0 0 5 ro))
    ;; 区间**内部**插入（程序编辑，绕过守卫）：硬边界生效 → 新字符不受约束，区间被切开
    (define q7 (properties-apply-edit q6 (edit-desc 0 2 0 2 "x")))
    (check-equal? (restrict-read-only? (properties-restrict-at q7 0 1)) #t)  ; 左半仍只读
    (check-equal? (restrict-read-only? (properties-restrict-at q7 0 2)) #f)  ; 新字符不受约束
    (check-equal? (restrict-read-only? (properties-restrict-at q7 0 3)) #t)  ; 右半仍只读
    (check-equal? (restrict-read-only? (properties-restrict-at q7 0 5)) #t)
    ;; 区间**末尾**插入 → 同样不继承（硬边界）
    (define q8 (properties-apply-edit q6 (edit-desc 0 5 0 5 "y")))
    (check-equal? (restrict-read-only? (properties-restrict-at q8 0 4)) #t)
    (check-equal? (restrict-read-only? (properties-restrict-at q8 0 5)) #f)
    ;; 区间**之前**的删除 → 约束位置随文本左移
    (define q9 (properties-apply-edit q6 (edit-desc 0 0 0 1 "")))
    (check-equal? (restrict-read-only? (properties-restrict-at q9 0 3)) #t)
    (check-equal? (restrict-read-only? (properties-restrict-at q9 0 4)) #f)
    (properties-check q7)
    (properties-check q8)
    (properties-check q9)
    (void))

  ;; 硬边界：约束区间的右边界，presentation 不继承、restrict 不继承
  (define m0 (properties-put-restrict (fresh) 0 0 5 ro))
  (define m1 (properties-put m0 0 0 5 'face 'prompt))
  (define m2 (properties-apply-edit m1 (edit-desc 0 5 0 5 "x")))
  (check-equal? (properties-get m2 0 5 'face) #f)                   ; 表现不继承
  (check-equal? (restrict-read-only? (properties-restrict-at m2 0 5)) #f)  ; 约束不继承
  (check-equal? (properties-get m2 0 3 'face) 'prompt)              ; 原区间不受影响
  (check-equal? (restrict-read-only? (properties-restrict-at m2 0 3)) #t)

  ;; 无约束处：presentation 照常继承（不受约束机制影响）
  (define m3 (properties-put (fresh) 0 0 5 'face 'bold))
  (define m4 (properties-apply-edit m3 (edit-desc 0 5 0 5 "x")))
  (check-equal? (properties-get m4 0 5 'face) 'bold)

  ;; properties-runs 只报表现层
  (define r0 (properties-put-restrict (properties-put (fresh) 1 0 2 'face 'bold) 1 3 6 ro))
  (check-equal? (properties-runs r0 1 8)
                (list (list 0 2 (hash 'face 'bold)) (list 2 8 empty-plist)))

  ;; properties-restrict-runs 只报约束层：同一个 r0，切分独立
  ;; （[3,6) 是约束边界，对 presentation 被合并、对 restrict 就是一段）
  (check-equal? (properties-restrict-runs r0 1 8)
                (list (list 0 3 (make-restrict)) (list 3 6 ro) (list 6 8 (make-restrict))))
  ;; 相邻同约束合并（两段都只读 → 一段）
  (define r1 (properties-put-restrict (properties-put-restrict (fresh) 0 1 2 ro) 0 2 4 ro))
  (check-equal? (properties-restrict-runs r1 0 5)
                (list (list 0 1 (make-restrict)) (list 1 4 ro) (list 4 5 (make-restrict))))
  ;; 一行里两段只读（中间可写）→ 三段
  (define r2 (properties-put-restrict (properties-put-restrict (fresh) 0 0 1 ro) 0 3 4 ro))
  (check-equal? (properties-restrict-runs r2 0 5)
                (list (list 0 1 ro) (list 1 3 (make-restrict)) (list 3 4 ro) (list 4 5 (make-restrict))))
  ;; 空行 → 没有段
  (check-equal? (properties-restrict-runs (fresh) 0 0) '())

  ;; A2 回归：空区间/反向区间 → 报错（原来静默什么都不写）
  (check-exn exn:fail? (lambda () (properties-put (fresh) 1 2 2 'face 'bold)))
  (check-exn exn:fail? (lambda () (properties-put-restrict (fresh) 1 3 1 (restrict #t))))

  (displayln "properties.rkt: all tests passed"))