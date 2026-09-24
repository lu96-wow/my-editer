#lang racket

(require "point.rkt" "lines.rkt" "edit.rkt" rackunit)

;;; atom/content.rkt —— 行向量文本存储
;;;
;;; 职责只有一件：**存文本、施加编辑**。不含光标、不含属性、不含 外观。
;;;
;;; 编辑的唯一单位是 编辑-描述（见 atom/edit.rkt）；原语只有一个 内容-施加。
;;; 插入/删除/换行/合并都只是「造一条 编辑-描述」。退格/删除需要看文本才能定出
;;; 被删区间，故提供两个**纯函数**先算出 描述，再由 内容-施加 施加。

(provide
 (struct-out 内容)
 内容-空
 字符串转内容
 行列表转内容
 内容->字符串
 内容->行列表
 内容-行-数量
 内容-行-引用
 内容-检查
 内容-夹紧-位置
 内容-行-长度
 内容-位置->偏移
 内容-偏移->位置
 内容-夹紧-描述
 内容-施加
 内容-退格-描述
 内容-删除-描述)

;;; ---------- 数据 ----------

(struct 内容 (行列表) #:transparent)
;; 行列表 : (vectorof string)   至少一行，每行是纯文本（不含 \n）

;;; ---------- 构造 / 投影 ----------

(define (内容-空) (内容 (vector "")))

(define (行列表转内容 行列表)
  (unless (and (pair? 行列表) (andmap string? 行列表))
    (error '行列表转内容 "expect non-empty list of strings, got ~a" 行列表))
  (内容 (list->vector 行列表)))

(define (字符串转内容 s)
  (unless (string? s) (error '字符串转内容 "expect string, got ~a" s))
  (内容 (list->vector (字符串->行列表 s))))

(define (内容->行列表 c)     (vector->list (内容-行列表 c)))
(define (内容->字符串 c)    (行列表->字符串 (内容->行列表 c)))
(define (内容-行-数量 c) (vector-length (内容-行列表 c)))
(define (内容-行-引用 c i) (vector-ref (内容-行列表 c) i))

;; 行数 ≥ 1（空文本也是 1 个空行）。给诊断/测试用。
(define (内容-检查 c)
  (define n (内容-行-数量 c))
  (unless (>= n 1) (error '内容-检查 "content must have >= 1 line"))
  (for ([行 (in-vector (内容-行列表 c))])
    (unless (string? 行) (error '内容-检查 "non-string line: ~a" 行)))
  c)

;;; ---------- 位置夹紧 ----------
;; 越界位置有唯一合法解释 → 夹到合法域。行 ∈ [0, 行数)，列 ≤ 该行长。
;; 唯一实现在 位置-夹紧；这里只把「行数 + 行长」两个投影喂给它。
(define (内容-夹紧-位置 c p)
  (位置-夹紧 p (内容-行-数量 c)
               (lambda (l) (string-length (内容-行-引用 c l)))))

(define (内容-行-长度 c 行)
  (define n (内容-行-数量 c))
  (define l (max 0 (min 行 (sub1 n))))
  (string-length (内容-行-引用 c l)))

;;; ---------- 行列 ↔ 绝对偏移 ----------
;; 偏移以 内容->字符串 为坐标系：行内字符各占 1，行间 \n 占 1；末行无尾 \n。
;; 因此第 i 行行首偏移 = Σ_{j<i} (行长_j + 1)，最大偏移 = 字符串长度。
;; 输入先夹紧，故两个方向对任意输入都有定义，且互为逆（在合法域内）。

(define (内容-位置->偏移 c p)
  (define q (内容-夹紧-位置 c p))
  (+ (for/sum ([i (in-range (位置-行 q))])
       (+ (string-length (内容-行-引用 c i)) 1))
     (位置-列 q)))

(define (内容-偏移->位置 c 偏移)
  (define n (内容-行-数量 c))
  (define 最大-偏移
    (sub1 (for/sum ([i (in-range n)]) (+ (string-length (内容-行-引用 c i)) 1))))
  (define o (max 0 (min 偏移 最大-偏移)))
  (let loop ([i 0] [rest o])
    (define 长度 (string-length (内容-行-引用 c i)))
    (cond
      [(and (< i (sub1 n)) (> rest 长度)) (loop (add1 i) (- rest (add1 长度)))]
      [else (位置 i (min rest 长度))])))

;;; ---------- 施加：唯一原语 ----------

;; 把一条 编辑-描述 夹到 内容 的合法域，返回**生效 描述**（不动 内容）。
;; 端点先夹紧；夹紧后仍反向（起点 > 末尾）没有合法解释 → 报错。
(define (内容-夹紧-描述 c d)
  (define s (内容-夹紧-位置 c (编辑-描述-起点 d)))
  (define e (内容-夹紧-位置 c (编辑-描述-末尾 d)))
  (when (位置<? e s)
    (error '内容-夹紧-描述 "编辑区间反向: ~a..~a" s e))
  (编辑-描述 s e (编辑-描述-新-文本 d)))

;; 施加一条 编辑-描述。生效 描述 里的坐标是**夹紧后**的值，
;; 上层（属性/账本/视图）一律用它，不要用传入的原始 描述。
(define (内容-施加 c d)
  (define n (内容-行-数量 c))
  (define 行列表 (内容-行列表 c))
  (define d* (内容-夹紧-描述 c d))
  (define s (编辑-描述-起点 d*))
  (define e (编辑-描述-末尾 d*))
  (define sl (位置-行 s)) (define sc (位置-列 s))
  (define el (位置-行 e)) (define ec (位置-列 e))
  (define 文本 (编辑-描述-新-文本 d*))
  ;; 新文本拆行：k 段（k ≥ 1，字符串->行列表 至少一行）。
  (define 新-行列表 (list->vector (字符串->行列表 文本)))
  (define k (vector-length 新-行列表))
  (define 头部 (substring (vector-ref 行列表 sl) 0 sc))
  (define 尾部 (substring (vector-ref 行列表 el) ec
                          (string-length (vector-ref 行列表 el))))
  (define 已插入 k)
  (define v* (make-vector (- (+ n 已插入) (+ (- el sl) 1)) #f))
  (vector-copy! v* 0 行列表 0 sl)
  (cond
    [(= k 1)   (vector-set! v* sl (string-append 头部 (vector-ref 新-行列表 0) 尾部))]
    [else
     (vector-set! v* sl (string-append 头部 (vector-ref 新-行列表 0)))
     (for ([i (in-range 1 (sub1 k))])
       (vector-set! v* (+ sl i) (vector-ref 新-行列表 i)))
     (vector-set! v* (+ sl (sub1 k))
                  (string-append (vector-ref 新-行列表 (sub1 k)) 尾部))])
  (vector-copy! v* (+ sl 已插入) 行列表 (add1 el) n)
  (values (内容 v*) d*))

;;; ---------- 退格 / 删除：先算 描述（纯），不直接施加 ----------

(define (内容-退格-描述 c p)
  (define q (内容-夹紧-位置 c p))
  (define l (位置-行 q))
  (define o (位置-列 q))
  (cond
    [(> o 0) (编辑-描述 (位置 l (sub1 o)) q "")]                ; 删前一个字符
    [(> l 0) (编辑-描述 (位置 (sub1 l) (string-length (内容-行-引用 c (sub1 l))))
                        (位置 l 0) "")]                          ; 与上一行合并
    [else #f]))

(define (内容-删除-描述 c p)
  (define q (内容-夹紧-位置 c p))
  (define l (位置-行 q))
  (define o (位置-列 q))
  (cond
    [(< o (string-length (内容-行-引用 c l)))                ; 删该处字符
     (编辑-描述 q (位置 l (add1 o)) "")]
    [(< l (sub1 (内容-行-数量 c)))                         ; 与下一行合并
     (编辑-描述 q (位置 (add1 l) 0) "")]
    [else #f]))

;;; ---------- 测试 ----------

(module+ test
  (define (施加* c d) (let-values ([(c* _) (内容-施加 c d)]) c*))

  (check-equal? (内容->字符串 (内容-空)) "")
  (check-equal? (内容->字符串 (字符串转内容 "hello\nworld")) "hello\nworld")
  (check-equal? (内容->行列表 (字符串转内容 "hello\nworld")) '("hello" "world"))
  (check-equal? (内容-行-数量 (字符串转内容 "a\nb\n")) 3)   ; 尾换行保留空行

  (define c0 (字符串转内容 "hello\nworld"))
  (check-equal? (内容-行-长度 c0 0) 5)
  (check-equal? (内容-行-长度 c0 9) 5)
  (check-equal? (内容-位置->偏移 c0 (位置 0 0)) 0)
  (check-equal? (内容-位置->偏移 c0 (位置 1 0)) 6)
  (check-equal? (内容-偏移->位置 c0 6) (位置 1 0))
  (for ([偏移 (in-range 0 12)])
    (check-equal? (内容-位置->偏移 c0 (内容-偏移->位置 c0 偏移)) 偏移))

  (check-equal? (内容->字符串 (施加* c0 (编辑-描述 (位置 0 0) (位置 0 0) "X")))
                "Xhello\nworld")
  (define c1 (字符串转内容 "abcd\nefgh\nijkl"))
  (check-equal? (内容->字符串 (施加* c1 (编辑-描述 (位置 0 1) (位置 2 1) "XY\nZ")))
                "aXY\nZjkl")
  (check-equal? (let-values ([(c* d*) (内容-施加 (字符串转内容 "abc")
                                                     (编辑-描述 (位置 0 1) (位置 0 99) ""))])
                  (list (内容->字符串 c*) d*))
                (list "a" (编辑-描述 (位置 0 1) (位置 0 3) "")))
  (check-exn exn:fail?
             (lambda () (内容-施加 (字符串转内容 "abcdef")
                                       (编辑-描述 (位置 0 3) (位置 0 1) ""))))

  ;; 内容-夹紧-描述：不动 内容，只给出生效 描述
  (check-equal? (内容-夹紧-描述 c0 (编辑-描述 (位置 0 1) (位置 0 99) ""))
                (编辑-描述 (位置 0 1) (位置 0 5) ""))
  (check-equal? (内容-夹紧-描述 c0 (编辑-描述 (位置 9 9) (位置 9 9) "X"))
                (编辑-描述 (位置 1 5) (位置 1 5) "X"))

  (check-equal? (内容-退格-描述 c0 (位置 0 2)) (编辑-描述 (位置 0 1) (位置 0 2) ""))
  (check-false (内容-退格-描述 c0 (位置 0 0)))
  (check-equal? (内容-删除-描述 c0 (位置 0 0)) (编辑-描述 (位置 0 0) (位置 0 1) ""))
  (check-false (内容-删除-描述 c0 (位置 1 5)))

  (displayln "content.rkt: all tests passed"))
