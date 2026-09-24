#lang racket

(require "point.rkt" "edit.rkt" rackunit)

;;; atom/selection.rkt —— 选区 (锚点, 头部)
;;;
;;; 锚点 = 选择时不动的那端；头部 = 活动端（光标 / 打字点）。
;;; 空选区 锚点 = 头部，就是一个普通光标。
;;; 方向由 锚点/头部 的顺序表达（头部 在 锚点 左 = 反向选区）。
;;;
;;; 这里只有**值 + 位置代数**：单个端点如何随一条 编辑-描述 移动。
;;; 「一组选区怎么批量映射、合并」由 视口 层（重基准）用这几个原语组合。

(provide
 (struct-out 选区)
 插入符
 插入符?
 插入符-位置
 选区-位置
 选区-范围
 选区-空?
 选区-映射-编辑
 选区-附-头部
 选区-附-锚点
 选区-映射-头部
 选区-映射-锚点
 选区-映射-两端
 选区<?
 选区列表-规范化
 选区列表-主选区-索引)

(struct 选区 (锚点 头部) #:transparent)

;;; ---------- 光标 = 空选区（构造 API 把「同位置」藏起来）----------
;; 底层仍是 选区；插入符 只是「锚点 = 头部」的显式命名。

(define (插入符 p) (选区 p p))
(define (插入符? s) (选区-空? s))
(define (插入符-位置 s) (选区-位置 s))

;; 光标点 = 活动端
(define (选区-位置 s) (选区-头部 s))

;; 半开区间 [起点, 末尾)，与 锚点/头部 的方向无关
(define (选区-范围 s)
  (define a (选区-锚点 s)) (define h (选区-头部 s))
  (if (位置<=? a h) (values a h) (values h a)))

(define (选区-空? s) (位置=? (选区-锚点 s) (选区-头部 s)))

;; 端点随一次编辑移动；落在被删区间内 → 吸附到删除起点（不消失，只塌缩）。
(define (映射-端点 d p)
  (or (编辑描述-映射位置 d p) (编辑-描述-起点 d)))

(define (选区-映射-编辑 d s)
  (选区 (映射-端点 d (选区-锚点 s))
             (映射-端点 d (选区-头部 s))))

;;; ---------- 空间变换（位置 → 位置）----------
;; 与 选区-映射-编辑（按 编辑-描述 映射）职责不同：这里是「把端点搬到另一个点」。

(define (选区-附-头部 s p) (选区 (选区-锚点 s) p))
(define (选区-附-锚点 s p) (选区 p (选区-头部 s)))
(define (选区-映射-头部 f s) (选区-附-头部 s (f (选区-头部 s))))
(define (选区-映射-锚点 f s) (选区-附-锚点 s (f (选区-锚点 s))))
(define (选区-映射-两端 f s)
  (选区 (f (选区-锚点 s)) (f (选区-头部 s))))

;; 按 (起点, 终点) 字典序
(define (选区<? a b)
  (define-values (as ae) (选区-范围 a))
  (define-values (bs be) (选区-范围 b))
  (cond [(位置<? as bs) #t]
        [(位置<? bs as) #f]
        [else (位置<? ae be)]))

;; 一组选区规范化：去重 → 按起点排序 → 重叠（含包含）合并成包络。
;; 注意：只合并**真重叠**；首尾相接（[0,2) 与 [2,4)）保持两个。
(define (选区列表-规范化 sels)
  (define 去重 (sort (remove-duplicates sels) 选区<?))
  (reverse
   (for/fold ([acc '()]) ([s (in-list 去重)])
     (cond
       [(null? acc) (list s)]
       [else
        (define 上一个 (car acc))
        (define-values (ps pe) (选区-范围 上一个))
        (define-values (ss se) (选区-范围 s))
        (if (位置<? ss pe)
            (cons (选区 ps (if (位置<? pe se) se pe)) (cdr acc))
            (cons s acc))]))))

;; 规范化后的 sels 里，原 主选区（目标项）落在哪一项：用于 主选区 跨规范化（排序/去重/合并）
;; 的**位置追踪**。半开区间在边界上有歧义，故分情况：
;;   · 目标项 是区间：找「完整包含 目标项 区间」的项（合并后的包络）；
;;   · 目标项 是光标：先精确相等，再退到半开包含 [xa,xb)，最后才用含端点的包含。
;; 这样 [0,2) 与 插入符(2) 并存时 插入符 归 插入符，而不会被前一个区间吃掉。
(define (选区列表-主选区-索引 sels 目标项)
  (define-values (a b) (选区-范围 目标项))
  (define (全-包含? x)
    (let-values ([(xa xb) (选区-范围 x)]) (and (位置<=? xa a) (位置<=? b xb))))
  (define (半开-包含? x p)
    (let-values ([(xa xb) (选区-范围 x)]) (and (位置<=? xa p) (位置<? p xb))))
  (define (闭-包含? x p)
    (let-values ([(xa xb) (选区-范围 x)]) (and (位置<=? xa p) (位置<=? p xb))))
  (cond
    [(位置=? a b)
     (or (for/first ([x (in-list sels)] [i (in-naturals)] #:when (equal? x 目标项)) i)
         (for/first ([x (in-list sels)] [i (in-naturals)] #:when (半开-包含? x a)) i)
         (for/first ([x (in-list sels)] [i (in-naturals)] #:when (闭-包含? x a)) i)
         0)]
    [else
     (or (for/first ([x (in-list sels)] [i (in-naturals)] #:when (全-包含? x)) i)
         0)]))

;;; ---------- 测试 ----------

(module+ test
  (define p (lambda (l c) (位置 l c)))
  ;; 基本：空选区 / 光标点 / 区间（反向端点归一）
  (check-true (选区-空? (选区 (p 0 0) (p 0 0))))
  (check-equal? (选区-位置 (选区 (p 0 0) (p 0 3))) (p 0 3))
  (check-equal? (call-with-values (lambda () (选区-范围 (选区 (p 1 2) (p 0 1)))) list)
                (list (p 0 1) (p 1 2)))

  ;; 映射：端点随编辑移动 / 落在删除区内塌缩到删除起点
  (define d-ins (编辑-描述 (p 0 0) (p 0 0) "XX"))
  (check-equal? (选区-映射-编辑 d-ins (选区 (p 0 0) (p 0 1)))
                (选区 (p 0 0) (p 0 3)))
  (define d-del (编辑-描述 (p 0 0) (p 0 3) ""))
  (check-equal? (选区-映射-编辑 d-del (选区 (p 0 1) (p 0 2)))
                (选区 (p 0 0) (p 0 0)))

  ;; 规范化：去重 / 排序 / 重叠合并 / 相邻不合并
  (check-equal? (选区列表-规范化 (list (选区 (p 0 2) (p 0 4)) (选区 (p 0 0) (p 0 2))))
                (list (选区 (p 0 0) (p 0 2)) (选区 (p 0 2) (p 0 4))))
  (check-equal? (选区列表-规范化 (list (选区 (p 0 1) (p 0 4)) (选区 (p 0 0) (p 0 2))))
                (list (选区 (p 0 0) (p 0 4))))
  (check-equal? (选区列表-规范化 (list (选区 (p 0 0) (p 0 0)) (选区 (p 0 0) (p 0 0))))
                (list (选区 (p 0 0) (p 0 0))))

  ;; 定位：主选区 跨规范化的追踪（区间完整包含 / 光标边界不被前一区间吃掉）
  (define sels* (list (选区 (p 0 0) (p 0 2)) (选区 (p 0 5) (p 0 6))))
  (check-equal? (选区列表-主选区-索引 sels* (选区 (p 0 5) (p 0 6))) 1)
  ;; [0,2) 与 插入符(2) 并存：主选区 是 插入符 → 不得归给 [0,2)
  (check-equal? (选区列表-主选区-索引 (list (选区 (p 0 0) (p 0 2)) (插入符 (p 0 2)))
                                          (插入符 (p 0 2)))
                1)
  ;; 首尾相接的两个区间：主选是后者时不得归给前者
  (check-equal? (选区列表-主选区-索引 (list (选区 (p 0 0) (p 0 2)) (选区 (p 0 2) (p 0 4)))
                                          (选区 (p 0 2) (p 0 4)))
                1)

  ;; 插入符 构造器/谓词（底层仍是 选区）
  (check-equal? (插入符 (p 0 3)) (选区 (p 0 3) (p 0 3)))
  (check-true (插入符? (插入符 (p 0 3))))
  (check-false (插入符? (选区 (p 0 0) (p 0 3))))
  (check-equal? (插入符-位置 (插入符 (p 1 2))) (p 1 2))

  ;; 空间变换：只动 头部 / 只动 锚点 / 两端同动
  (check-equal? (选区-映射-头部 (lambda (p) (位置 0 5)) (选区 (p 0 1) (p 0 2)))
                (选区 (p 0 1) (p 0 5)))
  (check-equal? (选区-映射-锚点 (lambda (p) (位置 0 0)) (选区 (p 0 1) (p 0 2)))
                (选区 (p 0 0) (p 0 2)))
  (check-equal? (选区-映射-两端 (lambda (p) (位置 0 (+ 10 (位置-列 p)))) (选区 (p 0 1) (p 0 2)))
                (选区 (p 0 11) (p 0 12)))

  (displayln "selection.rkt: all tests passed"))
