#lang racket

(require "point.rkt" "edit.rkt" rackunit)

;;; atom/selection.rkt —— 选区 (anchor, head)
;;;
;;; anchor = 选择时不动的那端；head = 活动端（光标 / 打字点）。
;;; 空选区 anchor = head，就是一个普通光标。
;;; 方向由 anchor/head 的顺序表达（head 在 anchor 左 = 反向选区）。
;;;
;;; 这里只有**值 + 位置代数**：单个端点如何随一条 edit-desc 移动。
;;; 「一组选区怎么批量映射、合并」由 view 层（rebase）用这几个原语组合。

(provide
 (struct-out selection)
 caret
 caret?
 caret-point
 selection-point
 selection-range
 selection-empty?
 selection-map-edit
 selection-with-head
 selection-with-anchor
 selection-map-head
 selection-map-anchor
 selection-map-both
 selection<?
 selections-normalize
 selections-primary-index)

(struct selection (anchor head) #:transparent)

;;; ---------- 光标 = 空选区（构造 API 把「同位置」藏起来）----------
;; 底层仍是 selection；caret 只是「anchor = head」的显式命名。

(define (caret p) (selection p p))
(define (caret? s) (selection-empty? s))
(define (caret-point s) (selection-point s))

;; 光标点 = 活动端
(define (selection-point s) (selection-head s))

;; 半开区间 [start, end)，与 anchor/head 的方向无关
(define (selection-range s)
  (define a (selection-anchor s)) (define h (selection-head s))
  (if (point<=? a h) (values a h) (values h a)))

(define (selection-empty? s) (point=? (selection-anchor s) (selection-head s)))

;; 端点随一次编辑移动；落在被删区间内 → 吸附到删除起点（不消失，只塌缩）。
(define (map-endpoint d p)
  (or (edit-desc-map-position d p) (edit-desc-start d)))

(define (selection-map-edit d s)
  (selection (map-endpoint d (selection-anchor s))
             (map-endpoint d (selection-head s))))

;;; ---------- 空间变换（point → point）----------
;; 与 selection-map-edit（按 edit-desc 映射）职责不同：这里是「把端点搬到另一个点」。

(define (selection-with-head s p) (selection (selection-anchor s) p))
(define (selection-with-anchor s p) (selection p (selection-head s)))
(define (selection-map-head f s) (selection-with-head s (f (selection-head s))))
(define (selection-map-anchor f s) (selection-with-anchor s (f (selection-anchor s))))
(define (selection-map-both f s)
  (selection (f (selection-anchor s)) (f (selection-head s))))

;; 按 (起点, 终点) 字典序
(define (selection<? a b)
  (define-values (as ae) (selection-range a))
  (define-values (bs be) (selection-range b))
  (cond [(point<? as bs) #t]
        [(point<? bs as) #f]
        [else (point<? ae be)]))

;; 一组选区规范化：去重 → 按起点排序 → 重叠（含包含）合并成包络。
;; 注意：只合并**真重叠**；首尾相接（[0,2) 与 [2,4)）保持两个。
(define (selections-normalize sels)
  (define uniq (sort (remove-duplicates sels) selection<?))
  (reverse
   (for/fold ([acc '()]) ([s (in-list uniq)])
     (cond
       [(null? acc) (list s)]
       [else
        (define prev (car acc))
        (define-values (ps pe) (selection-range prev))
        (define-values (ss se) (selection-range s))
        (if (point<? ss pe)
            (cons (selection ps (if (point<? pe se) se pe)) (cdr acc))
            (cons s acc))]))))

;; 规范化后的 sels 里，原 primary（target）落在哪一项：用于 primary 跨规范化（排序/去重/合并）
;; 的**位置追踪**。半开区间在边界上有歧义，故分情况：
;;   · target 是区间：找「完整包含 target 区间」的项（合并后的包络）；
;;   · target 是光标：先精确相等，再退到半开包含 [xa,xb)，最后才用含端点的包含。
;; 这样 [0,2) 与 caret(2) 并存时 caret 归 caret，而不会被前一个区间吃掉。
(define (selections-primary-index sels target)
  (define-values (a b) (selection-range target))
  (define (full-contains? x)
    (let-values ([(xa xb) (selection-range x)]) (and (point<=? xa a) (point<=? b xb))))
  (define (half-open-contains? x p)
    (let-values ([(xa xb) (selection-range x)]) (and (point<=? xa p) (point<? p xb))))
  (define (closed-contains? x p)
    (let-values ([(xa xb) (selection-range x)]) (and (point<=? xa p) (point<=? p xb))))
  (cond
    [(point=? a b)
     (or (for/first ([x (in-list sels)] [i (in-naturals)] #:when (equal? x target)) i)
         (for/first ([x (in-list sels)] [i (in-naturals)] #:when (half-open-contains? x a)) i)
         (for/first ([x (in-list sels)] [i (in-naturals)] #:when (closed-contains? x a)) i)
         0)]
    [else
     (or (for/first ([x (in-list sels)] [i (in-naturals)] #:when (full-contains? x)) i)
         0)]))

;;; ---------- 测试 ----------

(module+ test
  (define p (lambda (l c) (point l c)))
  ;; 基本：空选区 / 光标点 / 区间（反向端点归一）
  (check-true (selection-empty? (selection (p 0 0) (p 0 0))))
  (check-equal? (selection-point (selection (p 0 0) (p 0 3))) (p 0 3))
  (check-equal? (call-with-values (lambda () (selection-range (selection (p 1 2) (p 0 1)))) list)
                (list (p 0 1) (p 1 2)))

  ;; 映射：端点随编辑移动 / 落在删除区内塌缩到删除起点
  (define d-ins (edit-desc (p 0 0) (p 0 0) "XX"))
  (check-equal? (selection-map-edit d-ins (selection (p 0 0) (p 0 1)))
                (selection (p 0 0) (p 0 3)))
  (define d-del (edit-desc (p 0 0) (p 0 3) ""))
  (check-equal? (selection-map-edit d-del (selection (p 0 1) (p 0 2)))
                (selection (p 0 0) (p 0 0)))

  ;; 规范化：去重 / 排序 / 重叠合并 / 相邻不合并
  (check-equal? (selections-normalize (list (selection (p 0 2) (p 0 4)) (selection (p 0 0) (p 0 2))))
                (list (selection (p 0 0) (p 0 2)) (selection (p 0 2) (p 0 4))))
  (check-equal? (selections-normalize (list (selection (p 0 1) (p 0 4)) (selection (p 0 0) (p 0 2))))
                (list (selection (p 0 0) (p 0 4))))
  (check-equal? (selections-normalize (list (selection (p 0 0) (p 0 0)) (selection (p 0 0) (p 0 0))))
                (list (selection (p 0 0) (p 0 0))))

  ;; 定位：primary 跨规范化的追踪（区间完整包含 / 光标边界不被前一区间吃掉）
  (define sels* (list (selection (p 0 0) (p 0 2)) (selection (p 0 5) (p 0 6))))
  (check-equal? (selections-primary-index sels* (selection (p 0 5) (p 0 6))) 1)
  ;; [0,2) 与 caret(2) 并存：primary 是 caret → 不得归给 [0,2)
  (check-equal? (selections-primary-index (list (selection (p 0 0) (p 0 2)) (caret (p 0 2)))
                                          (caret (p 0 2)))
                1)
  ;; 首尾相接的两个区间：主选是后者时不得归给前者
  (check-equal? (selections-primary-index (list (selection (p 0 0) (p 0 2)) (selection (p 0 2) (p 0 4)))
                                          (selection (p 0 2) (p 0 4)))
                1)

  ;; caret 构造器/谓词（底层仍是 selection）
  (check-equal? (caret (p 0 3)) (selection (p 0 3) (p 0 3)))
  (check-true (caret? (caret (p 0 3))))
  (check-false (caret? (selection (p 0 0) (p 0 3))))
  (check-equal? (caret-point (caret (p 1 2))) (p 1 2))

  ;; 空间变换：只动 head / 只动 anchor / 两端同动
  (check-equal? (selection-map-head (lambda (p) (point 0 5)) (selection (p 0 1) (p 0 2)))
                (selection (p 0 1) (p 0 5)))
  (check-equal? (selection-map-anchor (lambda (p) (point 0 0)) (selection (p 0 1) (p 0 2)))
                (selection (p 0 0) (p 0 2)))
  (check-equal? (selection-map-both (lambda (p) (point 0 (+ 10 (point-col p)))) (selection (p 0 1) (p 0 2)))
                (selection (p 0 11) (p 0 12)))

  (displayln "selection.rkt: all tests passed"))
