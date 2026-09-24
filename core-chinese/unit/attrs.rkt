#lang racket

(require "../atom/point.rkt" "../atom/lines.rkt" "../atom/edit.rkt"
         "../atom/attr.rkt" rackunit)

;;; unit/attrs.rkt —— 行内属性区间（通用 键→值，随编辑移动）
;;;
;;; 一个 属性集 就是一块**属性 缓冲**：与 内容 同坐标、平行，吃**同一条生效
;;; 编辑-描述**（由 内容-施加 产出）。属性是 跨度 上的 hash：键/值由使用方定义，
;;; core 只保留并解释 '只读（见 doc/document.rkt）。
;;;
;;; 不变量（属性集-检查 强制）：
;;;   P1  每行内 行内跨度 按 起点 升序、互不重叠
;;;   P2  相邻且 hash 相同的 行内跨度 已合并
;;;   P3  hash 为空的 行内跨度 不保留
;;;   P4  行数 == 内容 行数（属性集-检查 用 行-数量 参数校验）
;;;
;;; 两条写路径：
;;;   属性集-施加-编辑        —— 文本变更时跟随（吃生效 编辑-描述），新文本不继承属性
;;;   属性集-施加-属性[-批]—— 显式属性变更（吃 属性-描述），零宽 = no-操作
;;;
;;; 撤销材料：属性集-描述-逆（单条 属性-描述 的逆）。文本编辑抹掉的属性由 doc 层
;;; 用 属性集-范围-片段集 捕获后补回（见 doc/document.rkt）。

(provide
 属性集?                             ; 构造器/内部字段不外露（避免绕过不变量）
 属性集-空
 属性集-行-数量
 属性集-在
 属性集-片段集
 属性集-键-片段集
 属性集-范围-片段集
 属性集-施加-编辑
 属性集-施加-属性
 属性集-施加-属性-批
 属性集-替换-描述集
 属性集-描述-逆
 属性集-检查)

;;; ---------- 数据 ----------

;; 行内跨度 是内部结构，不导出。
(struct 行内跨度 (起点 末尾 值) #:transparent)
;; 起点 / 末尾 : nat       行内列号，半开区间 [起点, 末尾)
;; 值         : hash      键 → 值（键/值由使用方定义）

(struct 属性集 (屏行列表) #:transparent)
;; 屏行列表 : (vectorof (listof 行内跨度))   行号由下标表达，不重复存

(define (行内跨度-空? sp) (hash-empty? (行内跨度-值 sp)))
(define (行内跨度=? a b) (equal? (行内跨度-值 a) (行内跨度-值 b)))

;;; ---------- 构造 / 不变量 ----------

(define (属性集-空 行-数量)
  (unless (and (exact-nonnegative-integer? 行-数量) (>= 行-数量 1))
    (error '属性集-空 "line-count must be >= 1, got ~a" 行-数量))
  (属性集 (make-vector 行-数量 '())))

(define (属性集-行-数量 p) (vector-length (属性集-屏行列表 p)))

(define (检查-屏行! 屏行)
  (let loop ([上一个-末尾 -1] [rest 屏行])
    (unless (null? rest)
      (define sp (car rest))
      (unless (< (行内跨度-起点 sp) (行内跨度-末尾 sp))
        (error '属性集-检查 "rspan start >= end: ~a" sp))
      (unless (>= (行内跨度-起点 sp) 上一个-末尾)
        (error '属性集-检查 "overlapping / unordered rspans: ~a" 屏行))
      (unless (not (行内跨度-空? sp))
        (error '属性集-检查 "empty rspan present: ~a" sp))
      (loop (行内跨度-末尾 sp) (cdr rest)))))

;; 交叉校验：行数必须等于 行-数量（与 内容 同坐标），否则报错。
(define (属性集-检查 p 行-数量)
  (unless (and (exact-nonnegative-integer? 行-数量) (>= 行-数量 1))
    (error '属性集-检查 "line-count must be >= 1, got ~a" 行-数量))
  (unless (= (属性集-行-数量 p) 行-数量)
    (error '属性集-检查 "attrs 行数 ~a ≠ content 行数 ~a"
           (属性集-行-数量 p) 行-数量))
  (for ([屏行 (in-vector (属性集-屏行列表 p))]) (检查-屏行! 屏行))
  p)

;;; ---------- 行内工具 ----------

(define (行内跨度-边界集 屏行)
  (append-map (lambda (sp) (list (行内跨度-起点 sp) (行内跨度-末尾 sp))) 屏行))

;; 该行 列 处的属性 hash；无覆盖 → 空 hash。
(define (屏行-值-在 屏行 列)
  (define sp (for/first ([sp (in-list 屏行)]
                         #:when (and (<= (行内跨度-起点 sp) 列) (< 列 (行内跨度-末尾 sp))))
              sp))
  (if sp (行内跨度-值 sp) (hash)))

;; 合并相邻且内容相同的 行内跨度（P2）。输入须升序。
(define (合并-相邻 跨度集)
  (reverse
   (for/fold ([acc '()]) ([sp (in-list 跨度集)])
     (cond
       [(null? acc) (list sp)]
       [else
        (define last (car acc))
        (if (and (= (行内跨度-末尾 last) (行内跨度-起点 sp)) (行内跨度=? last sp))
            (cons (行内跨度 (行内跨度-起点 last) (行内跨度-末尾 sp) (行内跨度-值 last))
                  (cdr acc))
            (cons sp acc))]))))

;; 对 [起点, 末尾) 的每个子段做 (f 当前 hash)；空段丢弃、相邻相同合并。
(define (屏行-更新 报错者 屏行 起点 末尾 f)
  (when (>= 起点 末尾)
    (error 报错者 "属性区间必须 start < end，得到 [~a,~a)" 起点 末尾))
  (define 边界 (sort (remove-duplicates (append (list 起点 末尾)
                                                  (行内跨度-边界集 屏行)))
                       <))
  (define 段列表
    (for/list ([a (in-list (drop-right 边界 1))]
               [b (in-list (rest 边界))])
      (define 内部? (and (<= 起点 a) (<= b 末尾)))
      (define v (if 内部? (f (屏行-值-在 屏行 a)) (屏行-值-在 屏行 a)))
      (行内跨度 a b v)))
  (合并-相邻 (filter (lambda (sp) (not (行内跨度-空? sp))) 段列表)))

;; 对 [起点,末尾) 统一设置 键→值（保留其它 键）。
(define (屏行-安装-键 报错者 屏行 起点 末尾 键 值)
  (屏行-更新 报错者 屏行 起点 末尾 (lambda (h) (hash-set h 键 值))))

;; 对 [起点,末尾) 移除 键。
(define (屏行-移除-键 报错者 屏行 起点 末尾 键)
  (屏行-更新 报错者 屏行 起点 末尾 (lambda (h) (hash-remove h 键))))

;;; ---------- 读 ----------

(define (属性集-在 p q)
  (define l (位置-行 q)) (define c (位置-列 q))
  (屏行-值-在 (vector-ref (属性集-屏行列表 p) l) c))

;; 整行属性段：(listof (list 起点 末尾 hash))，恰好覆盖 [0, 行-长度)。
(define (属性集-片段集 p 行 行-长度)
  (define 屏行 (vector-ref (属性集-屏行列表 p) 行))
  (define pts (sort (remove-duplicates (append (list 0 行-长度)
                                               (行内跨度-边界集 屏行)))
                    <))
  (define 原始 (for/list ([a (in-list (drop-right pts 1))]
                         [b (in-list (rest pts))])
                (list a b (屏行-值-在 屏行 a))))
  (reverse
   (for/fold ([acc '()]) ([段 (in-list 原始)])
     (cond
       [(null? acc) (list 段)]
       [(equal? (caddr (car acc)) (caddr 段))
        (cons (list (car (car acc)) (cadr 段) (caddr 段)) (cdr acc))]
       [else (cons 段 acc)]))))

;; 只取某个 键 的段：(listof (list 起点 末尾 值))；投影/渲染用。
;; 相邻且 值 相等的段合并（其它 键 的边界不该把一个 键 的段切断）。
(define (属性集-键-片段集 p 行 行-长度 键)
  (define 原始 (for/list ([段 (in-list (属性集-片段集 p 行 行-长度))]
                         #:when (hash-has-key? (caddr 段) 键))
                (list (car 段) (cadr 段) (hash-ref (caddr 段) 键))))
  (reverse
   (for/fold ([acc '()]) ([段 (in-list 原始)])
     (cond
       [(null? acc) (list 段)]
       [(and (= (cadr (car acc)) (car 段)) (equal? (caddr (car acc)) (caddr 段)))
        (cons (list (car (car acc)) (cadr 段) (caddr 段)) (cdr acc))]
       [else (cons 段 acc)]))))

;; 跨行枚举 [起点,末尾) 内所有属性段（含每个 键 的完整 hash）；含两端行、中间整行。
;; 半开区间，跨行时按行切；返回 (listof (list 行 起点-列 末尾-列 hash))。
;; 用于：文本编辑抹掉某区间时，把该区间的属性捕获下来（撤销时补回）。
(define (属性集-范围-片段集 p 起点 末尾)
  (unless (位置<=? 起点 末尾)
    (error '属性集-范围-片段集 "区间反向: ~a..~a" 起点 末尾))
  (define 屏行列表 (属性集-屏行列表 p))
  (define n (vector-length 屏行列表))
  (define sl (位置-行 起点)) (define sc (位置-列 起点))
  (define el (位置-行 末尾))   (define ec (位置-列 末尾))
  (unless (< sl n) (error '属性集-范围-片段集 "起始行越界: ~a" sl))
  (unless (< el n) (error '属性集-范围-片段集 "结束行越界: ~a" el))
  (define (裁剪-行 行 lo hi)            ; hi = #f → 到行尾
    (for*/list ([sp (in-list (vector-ref 屏行列表 行))]
                #:when (and (or (not hi) (< (行内跨度-起点 sp) hi))
                            (> (行内跨度-末尾 sp) lo)))
      (list 行 (max lo (行内跨度-起点 sp))
            (if hi (min hi (行内跨度-末尾 sp)) (行内跨度-末尾 sp))
            (行内跨度-值 sp))))
  (cond
    [(= sl el) (裁剪-行 sl sc ec)]
    [else
     (append (裁剪-行 sl sc #f)
             (append* (for/list ([l (in-range (add1 sl) el)]) (裁剪-行 l 0 #f)))
             (裁剪-行 el 0 ec))]))

;;; ---------- 文本编辑跟随（新文本无属性，不继承） ----------

;; 在 列 处把一行切成两半；跨切点的 行内跨度 被切成两个。
(define (分割-屏行 屏行 列)
  (define-values (左 右)
    (for/fold ([l '()] [r '()]) ([sp (in-list 屏行)])
      (define s (行内跨度-起点 sp)) (define e (行内跨度-末尾 sp)) (define v (行内跨度-值 sp))
      (cond
        [(<= e 列) (values (cons sp l) r)]
        [(>= s 列) (values l (cons (行内跨度 (- s 列) (- e 列) v) r))]
        [else       (values (cons (行内跨度 s 列 v) l)
                            (cons (行内跨度 0 (- e 列) v) r))])))
  (values (reverse 左) (reverse 右)))

(define (平移-跨度集 屏行 n)
  (for/list ([sp (in-list 屏行)])
    (行内跨度 (+ n (行内跨度-起点 sp)) (+ n (行内跨度-末尾 sp)) (行内跨度-值 sp))))

;; 删除 [起点, 末尾) 覆盖的行区间，返回新 屏行列表。
(define (删除-范围 屏行列表 s e)
  (define sl (位置-行 s)) (define sc (位置-列 s))
  (define el (位置-行 e)) (define ec (位置-列 e))
  (define-values (s-左 s-右) (分割-屏行 (vector-ref 屏行列表 sl) sc))
  (define-values (_e-左 e-右) (分割-屏行 (vector-ref 屏行列表 el) ec))
  (define 已合并 (合并-相邻 (append s-左 (平移-跨度集 e-右 sc))))
  (define n (vector-length 屏行列表))
  (define v* (make-vector (- (+ n sl) el) '()))
  (vector-copy! v* 0 屏行列表 0 sl)
  (vector-set! v* sl 已合并)
  (vector-copy! v* (add1 sl) 屏行列表 (add1 el) n)
  v*)

;; 在 起点 处插入 k 行文本，返回新 屏行列表（新文本无属性）。
(define (插入-行列表 屏行列表 起点 新-行列表)
  (define k (length 新-行列表))
  (cond
    [(zero? k) 屏行列表]
    [else
     (define sl (位置-行 起点)) (define sc (位置-列 起点))
     (define-values (左 右) (分割-屏行 (vector-ref 屏行列表 sl) sc))
     (define 首-长度 (string-length (car 新-行列表)))
     (define 末-长度 (string-length (last 新-行列表)))
     (define n (vector-length 屏行列表))
     (define v* (make-vector (+ n (sub1 k)) '()))
     (vector-copy! v* 0 屏行列表 0 sl)
     (cond
       [(= k 1)
        (vector-set! v* sl
          (合并-相邻 (append 左 (平移-跨度集 右 (+ sc 首-长度)))))]
       [else
        (vector-set! v* sl (合并-相邻 左))
        (for ([i (in-range 1 (sub1 k))]) (vector-set! v* (+ sl i) '()))
        (vector-set! v* (+ sl (sub1 k))
          (合并-相邻 (平移-跨度集 右 末-长度)))])
     (vector-copy! v* (+ sl k) 屏行列表 (add1 sl) n)
     v*]))

;; 施加一条 编辑-描述：先删区间，再插新文本。输入须是 内容 产出的生效 描述。
(define (属性集-施加-编辑 p d)
  (define 屏行列表 (属性集-屏行列表 p))
  (define rows1 (删除-范围 屏行列表 (编辑-描述-起点 d) (编辑-描述-末尾 d)))
  (属性集
   (插入-行列表 rows1 (编辑-描述-起点 d)
                 (字符串->行列表 (编辑-描述-新-文本 d)))))

;;; ---------- 显式属性变更（属性-描述） ----------

;; 属性-描述 的静态合法性：同行、行号在域内、方向不反。零宽由调用方按 no-操作 处理。
(define (检查-属性-行 a 报错者 d)
  (define s (属性-描述-起点 d)) (define e (属性-描述-末尾 d))
  (unless (= (位置-行 s) (位置-行 e))
    (error 报错者 "属性区间必须同一行: ~a..~a" s e))
  (unless (位置<=? s e)
    (error 报错者 "属性区间反向: ~a..~a" s e))
  (define l (位置-行 s))
  (unless (< l (属性集-行-数量 a))
    (error 报错者 "属性行号越界: ~a（attrs 行数 ~a）" l (属性集-行-数量 a))))

(define (操作-函数 报错者 d 屏行)
  (case (属性-描述-操作 d)
    [(set)    (lambda () (屏行-安装-键 报错者 屏行
                                       (位置-列 (属性-描述-起点 d))
                                       (位置-列 (属性-描述-末尾 d))
                                       (属性-描述-键 d) (属性-描述-值 d)))]
    [(remove) (lambda () (屏行-移除-键 报错者 屏行
                                         (位置-列 (属性-描述-起点 d))
                                         (位置-列 (属性-描述-末尾 d))
                                         (属性-描述-键 d)))]
    [else (error 报错者 "未知 attr op: ~a" (属性-描述-操作 d))]))

;; 施加单条 属性-描述。零宽 = no-操作（有唯一合法解释 → 归一，不报错）。
(define (属性集-施加-属性 a 报错者 d)
  (检查-属性-行 a 报错者 d)
  (if (属性-描述-空? d)
      a
      (let* ([屏行列表 (属性集-屏行列表 a)]
             [屏行列表* (vector-copy 屏行列表)]
             [行 (位置-行 (属性-描述-起点 d))]
             [屏行* ((操作-函数 报错者 d (vector-ref 屏行列表 行)))])
        (vector-set! 屏行列表* 行 屏行*)
        (属性集 屏行列表*))))

;; 批量施加：按行分组，每行只拷贝一次行、只做一次 屏行 折叠。
;; 同 (行,键) 区间不得重叠（否则逆不成立）→ 报错。
(define (检查-属性-描述集 报错者 ds)
  (define 组集 (make-hash))
  (for ([d (in-list ds)])
    (hash-update! 组集 (cons (位置-行 (属性-描述-起点 d)) (属性-描述-键 d))
                  (lambda (l) (cons d l)) '()))
  (for ([(k l) (in-hash 组集)])
    (define 已排序 (sort l (lambda (x y)
                             (< (位置-列 (属性-描述-起点 x))
                                (位置-列 (属性-描述-起点 y))))))
    (for ([x (in-list (drop-right 已排序 1))] [y (in-list (rest 已排序))])
      (when (位置<? (属性-描述-起点 y) (属性-描述-末尾 x))
        (error 报错者 "属性编辑重叠（同一 key）: ~a 与 ~a" x y)))))

(define (属性集-施加-属性-批 a 报错者 ds)
  (for-each (lambda (d) (检查-属性-行 a 报错者 d)) ds)
  (检查-属性-描述集 报错者 ds)
  (define 实时 (filter (lambda (d) (not (属性-描述-空? d))) ds))
  (cond
    [(null? 实时) a]
    [else
     (define 按-行 (make-hash))
     (for ([d (in-list 实时)])
       (hash-update! 按-行 (位置-行 (属性-描述-起点 d))
                     (lambda (l) (cons d l)) '()))
     (define 屏行列表* (vector-copy (属性集-屏行列表 a)))
     (for ([(行 行-ds) (in-hash 按-行)])
       ;; 行-ds 为逆序（cons 累积）；反向回到原输入顺序。
       (define 屏行* (for/fold ([屏行 (vector-ref 屏行列表* 行)]) ([d (in-list (reverse 行-ds))])
                      ((操作-函数 报错者 d 屏行))))
       (vector-set! 屏行列表* 行 屏行*))
     (属性集 屏行列表*)]))

;;; ---------- 逆（显式属性的撤销材料） ----------

;; 对单条 属性-描述，给出「恢复其覆盖前 键 状态」的 属性-描述 列表
;; （同坐标系；依次施加可精确回到 d 之前）。零宽 → '()。
(define (属性集-描述-逆 a d)
  (检查-属性-行 a '属性集-描述-逆 d)
  (if (属性-描述-空? d)
      '()
      (let* ([行 (位置-行 (属性-描述-起点 d))]
             [s (位置-列 (属性-描述-起点 d))]
             [e (位置-列 (属性-描述-末尾 d))]
             [键 (属性-描述-键 d)]
             [屏行 (vector-ref (属性集-屏行列表 a) 行)]
             [pts (sort (remove-duplicates
                         (append (list s e)
                                 (append*
                                  (for*/list ([sp (in-list 屏行)]
                                              #:when (and (< (行内跨度-起点 sp) e)
                                                          (> (行内跨度-末尾 sp) s)))
                                    (list (max s (行内跨度-起点 sp))
                                          (min e (行内跨度-末尾 sp)))))))
                        <)])
        (for/list ([x (in-list (drop-right pts 1))] [y (in-list (rest pts))]
                   #:when (< x y))
          (define h (屏行-值-在 屏行 x))
          (if (hash-has-key? h 键)
              (属性-设置 (位置 行 x) (位置 行 y) 键 (hash-ref h 键))
              (属性-移除 (位置 行 x) (位置 行 y) 键))))))

;;; ---------- 替换式批量（把某 键 在一行上的 片段集 整体换成新 片段集） ----------

;; 合并相邻、同 操作/键/值 的 属性-描述（把被旧 片段 边界切开的同一次 set 接回去）。
(define (合并-替换-描述集 ds)
  (define (相同? a b)
    (and (eq? (属性-描述-操作 a) (属性-描述-操作 b))
         (eq? (属性-描述-键 a) (属性-描述-键 b))
         (equal? (属性-描述-值 a) (属性-描述-值 b))
         (位置=? (属性-描述-末尾 a) (属性-描述-起点 b))))
  (reverse
   (for/fold ([acc '()]) ([d (in-list ds)])
     (cond
       [(null? acc) (list d)]
       [(相同? (car acc) d)
        (cons (属性-描述 (属性-描述-起点 (car acc)) (属性-描述-末尾 d)
                         (属性-描述-键 d) (属性-描述-操作 d) (属性-描述-值 d))
              (cdr acc))]
       [else (cons d acc)]))))

;; 旧-片段集 / 新-片段集 : (listof (list 起点 末尾 值))，行内列号（nat）。
;; 返回同 行/键、**两两不重叠**的 属性-描述：新 片段集 覆盖的段 set，其余原先被旧 片段集
;; 覆盖的段 remove；两者都未覆盖的段不产出。结果可直接进 属性集-施加-属性-批。
;; 语义 = 「该 键 在这一行的值变成且仅变成 新-片段集」（旧值自动消失）。
(define (属性集-替换-描述集 报错者 行 键 旧-片段集 新-片段集)
  (define (规范 片段集)
    (define 已排序
      (sort (for/list ([r (in-list 片段集)])
              (match-define (list a b v) r)
              (unless (and (exact-nonnegative-integer? a) (exact-nonnegative-integer? b))
                (error 报错者 "run 列号必须是 nat: ~a" r))
              (when (< b a) (error 报错者 "run 列号反向: ~a" r))
              (list a b v))
            < #:key car))
    (when (pair? 已排序)
      (for ([x (in-list (drop-right 已排序 1))] [y (in-list (rest 已排序))])
        (when (< (car y) (cadr x))
          (error 报错者 "新增 run 重叠: ~a 与 ~a" x y))))
    已排序)
  (define 旧-n (规范 旧-片段集))
  (define 新-n (规范 新-片段集))
  (define pts (sort (remove-duplicates
                     (append* (for/list ([r (in-list (append 旧-n 新-n))])
                                (list (car r) (cadr r)))))
                    <))
  ;; 两个 片段 表都已按起点升序，段起点 a 也递增：只需向前推进指针，不再对每个段重扫。
  (define (跳过-之前 片段集 a)
    (cond [(null? 片段集) 片段集]
          [(<= (cadr (car 片段集)) a) (跳过-之前 (cdr 片段集) a)]
          [else 片段集]))
  (define (覆盖 片段集 a)
    (and (pair? 片段集) (<= (car (car 片段集)) a) (car 片段集)))
  (合并-替换-描述集
   (if (null? pts)
       '()
       (let loop ([as (drop-right pts 1)] [bs (rest pts)]
                  [旧-rs 旧-n] [新-rs 新-n] [acc '()])
         (cond
           [(null? as) (reverse acc)]
           [else
            (define a (car as)) (define b (car bs))
            (define 旧-rs* (跳过-之前 旧-rs a))
            (define 新-rs* (跳过-之前 新-rs a))
            (define nr (覆盖 新-rs* a))
            (define orr (覆盖 旧-rs* a))
            (define d (cond
                        [nr  (属性-设置 (位置 行 a) (位置 行 b) 键 (caddr nr))]
                        [orr (属性-移除 (位置 行 a) (位置 行 b) 键)]
                        [else #f]))
            (loop (cdr as) (cdr bs) 旧-rs* 新-rs* (if d (cons d acc) acc))])))))

;;; ---------- 测试 ----------

(module+ test
  (define (新) (属性集-空 3))
  (define (P l c) (位置 l c))
  (define (施加-属性* a d) (属性集-施加-属性 a 'test d))

  ;; 点查询（hash 属性）+ 半开区间
  (define p0 (施加-属性* (新) (属性-设置 (P 1 0) (P 1 5) 'ro #t)))
  (check-equal? (属性集-在 p0 (P 1 0)) (hash 'ro #t))
  (check-equal? (属性集-在 p0 (P 1 4)) (hash 'ro #t))
  (check-equal? (属性集-在 p0 (P 1 5)) (hash))

  ;; 多 键 互不干扰；相邻同 hash 合并（P2）
  (define p1 (施加-属性* (施加-属性* (新) (属性-设置 (P 0 1) (P 0 2) 'a 1))
                          (属性-设置 (P 0 2) (P 0 4) 'a 1)))
  (check-equal? (属性集-片段集 p1 0 5)
                (list (list 0 1 (hash)) (list 1 4 (hash 'a 1)) (list 4 5 (hash))))
  (define p1b (施加-属性* p1 (属性-设置 (P 0 2) (P 0 3) 'b 2)))
  (check-equal? (属性集-键-片段集 p1b 0 5 'a) (list (list 1 4 1)))
  (check-equal? (属性集-键-片段集 p1b 0 5 'b) (list (list 2 3 2)))

  ;; remove 键
  (define p2 (施加-属性* p0 (属性-移除 (P 1 2) (P 1 3) 'ro)))
  (check-equal? (属性集-在 p2 (P 1 1)) (hash 'ro #t))
  (check-equal? (属性集-在 p2 (P 1 2)) (hash))
  (check-equal? (属性集-在 p2 (P 1 3)) (hash 'ro #t))

  ;; 零宽 = no-操作（不报错、不变）
  (define z0 (新))
  (check-eq? (施加-属性* z0 (属性-设置 (P 0 1) (P 0 1) 'k #t)) z0)
  (check-eq? (施加-属性* p0 (属性-移除 (P 1 2) (P 1 2) 'ro)) p0)

  ;; 跨行先报错（不被夹紧掩盖）；行号越界具名报错
  (check-exn exn:fail? (lambda () (施加-属性* (新) (属性-设置 (P 0 0) (P 1 0) 'k #t))))
  (check-exn exn:fail? (lambda () (施加-属性* (新) (属性-设置 (P 9 0) (P 9 1) 'k #t))))

  ;; 批量：一次施加多条（含跨行）
  (define pb (属性集-施加-属性-批 (新) 'test
                                     (list (属性-设置 (P 0 0) (P 0 3) 'ro #t)
                                           (属性-设置 (P 1 0) (P 1 2) 'ro #t))))
  (check-equal? (属性集-键-片段集 pb 0 3 'ro) (list (list 0 3 #t)))
  (check-equal? (属性集-键-片段集 pb 1 3 'ro) (list (list 0 2 #t)))
  ;; 同 键 重叠 → 报错
  (check-exn exn:fail?
             (lambda () (属性集-施加-属性-批 (新) 'test
                          (list (属性-设置 (P 0 1) (P 0 3) 'ro #t)
                                (属性-设置 (P 0 2) (P 0 4) 'ro #t)))))

  ;; 逆：set 覆盖后恢复原值/恢复「无 键」
  (define 逆-基础 (施加-属性* (新) (属性-设置 (P 0 1) (P 0 2) 'ro #t)))  ; [1,2) ro
  (define 逆列表 (属性集-描述-逆 逆-基础 (属性-设置 (P 0 0) (P 0 4) 'ro #t)))
  (define 已恢复
    (for/fold ([a (施加-属性* 逆-基础 (属性-设置 (P 0 0) (P 0 4) 'ro #t))])
              ([d (in-list 逆列表)]) (施加-属性* a d)))
  (check-equal? (属性集-键-片段集 已恢复 0 5 'ro) (list (list 1 2 #t)))

  ;; 文本编辑跟随：区间内插入 → 右半后移，插入点无属性
  (define e0 (施加-属性* (新) (属性-设置 (P 0 0) (P 0 5) 'ro #t)))
  (define e1 (属性集-施加-编辑 e0 (编辑-描述 (P 0 2) (P 0 2) "x")))
  (check-equal? (属性集-片段集 e1 0 6)
                (list (list 0 2 (hash 'ro #t)) (list 2 3 (hash)) (list 3 6 (hash 'ro #t))))
  ;; 删除区间内部 → 收缩
  (define e2 (属性集-施加-编辑 e0 (编辑-描述 (P 0 1) (P 0 3) "")))
  (check-equal? (属性集-片段集 e2 0 3) (list (list 0 3 (hash 'ro #t))))

  ;; 跨行删除 + 多行插入：属性被正确切/移，新行无属性
  (define p4 (施加-属性* (新) (属性-设置 (P 0 0) (P 0 3) 'ro #t)))
  (define p5 (属性集-施加-编辑 p4 (编辑-描述 (P 0 1) (P 1 1) "PQ\nR")))
  (check-equal? (属性集-在 p5 (P 0 0)) (hash 'ro #t))
  (check-equal? (属性集-在 p5 (P 0 1)) (hash))
  (check-equal? (属性集-在 p5 (P 1 0)) (hash))
  (check-equal? (属性集-检查 p5 3) p5)

  ;; 属性集-范围-片段集：跨行捕获
  (define rg (施加-属性* (新) (属性-设置 (P 0 1) (P 0 4) 'ro #t)))
  (check-equal? (属性集-范围-片段集 rg (P 0 0) (P 1 0))
                (list (list 0 1 4 (hash 'ro #t))))
  (check-equal? (属性集-范围-片段集 rg (P 0 2) (P 0 3))
                (list (list 0 2 3 (hash 'ro #t))))

  ;; 属性集-检查：行数必须一致
  (check-exn exn:fail? (lambda () (属性集-检查 (新) 2)))
  (check-exn exn:fail? (lambda () (属性集-检查 (新) 0)))

  ;; 属性集-替换-描述集：新覆盖 set、原旧区 remove，结果两两不重叠
  (define (替换 旧 new) (属性集-替换-描述集 'test 0 'ro 旧 new))
  (check-equal? (替换 '() '((0 2 v))) (list (属性-设置 (P 0 0) (P 0 2) 'ro 'v)))
  (check-equal? (替换 '((0 5 v)) '()) (list (属性-移除 (P 0 0) (P 0 5) 'ro)))
  (check-equal? (替换 '((0 5 v)) '((2 3 w)))
                (list (属性-移除 (P 0 0) (P 0 2) 'ro)
                      (属性-设置 (P 0 2) (P 0 3) 'ro 'w)
                      (属性-移除 (P 0 3) (P 0 5) 'ro)))
  (check-equal? (替换 '((0 5 v)) '((0 5 w))) (list (属性-设置 (P 0 0) (P 0 5) 'ro 'w)))
  (check-equal? (替换 '((0 2 v) (4 6 v)) '((1 5 w)))
                (list (属性-移除 (P 0 0) (P 0 1) 'ro)
                      (属性-设置 (P 0 1) (P 0 5) 'ro 'w)
                      (属性-移除 (P 0 5) (P 0 6) 'ro)))
  ;; 结果确实不重叠（能进 批）
  (define rds (替换 '((0 5 v)) '((2 3 w))))
  (define 基础 (属性集-施加-属性-批 (新) 'test (list (属性-设置 (P 0 0) (P 0 5) 'ro 'v))))
  (define 完成 (属性集-施加-属性-批 基础 'test rds))
  (check-equal? (属性集-键-片段集 完成 0 5 'ro) (list (list 2 3 'w)))
  ;; 新 片段集 自身重叠 → 报错
  (check-exn exn:fail? (lambda () (替换 '() '((0 3 v) (1 4 w)))))
  (check-exn exn:fail? (lambda () (替换 '() '((4 2 v)))))

  (displayln "attrs.rkt: all tests passed"))
