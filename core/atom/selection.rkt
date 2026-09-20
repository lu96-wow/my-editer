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
 selection-map
 selection<?
 selections-normalize
 selections-index-containing)

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

(define (selection-map d s)
  (selection (map-endpoint d (selection-anchor s))
             (map-endpoint d (selection-head s))))

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

;; 规范化后的列表里，哪个选区含点 p（用于把 primary 追到合并后的那个）。
(define (selections-index-containing sels p)
  (for/first ([s (in-list sels)] [i (in-naturals)]
              #:when (let-values ([(a b) (selection-range s)])
                       (and (point<=? a p) (point<=? p b))))
    i))

;;; ---------- 测试 ----------

(module+ test
  (define p (lambda (l c) (point l c)))
  (check-true (selection-empty? (selection (p 0 0) (p 0 0))))
  (check-equal? (selection-point (selection (p 0 0) (p 0 3))) (p 0 3))
  (check-equal? (call-with-values (lambda () (selection-range (selection (p 1 2) (p 0 1)))) list)
                (list (p 0 1) (p 1 2)))

  ;; 映射：端点随编辑移动 / 落在删除区内塌缩到删除起点
  (define d-ins (edit-desc (p 0 0) (p 0 0) "XX"))
  (check-equal? (selection-map d-ins (selection (p 0 0) (p 0 1)))
                (selection (p 0 0) (p 0 3)))
  (define d-del (edit-desc (p 0 0) (p 0 3) ""))
  (check-equal? (selection-map d-del (selection (p 0 1) (p 0 2)))
                (selection (p 0 0) (p 0 0)))

  ;; 规范化：去重 / 排序 / 重叠合并 / 相邻不合并
  (check-equal? (selections-normalize (list (selection (p 0 2) (p 0 4)) (selection (p 0 0) (p 0 2))))
                (list (selection (p 0 0) (p 0 2)) (selection (p 0 2) (p 0 4))))
  (check-equal? (selections-normalize (list (selection (p 0 1) (p 0 4)) (selection (p 0 0) (p 0 2))))
                (list (selection (p 0 0) (p 0 4))))
  (check-equal? (selections-normalize (list (selection (p 0 0) (p 0 0)) (selection (p 0 0) (p 0 0))))
                (list (selection (p 0 0) (p 0 0))))

  (check-equal? (selections-index-containing (list (selection (p 0 0) (p 0 2)) (selection (p 0 5) (p 0 6))) (p 0 5)) 1)

  ;; caret 构造器/谓词（底层仍是 selection）
  (check-equal? (caret (p 0 3)) (selection (p 0 3) (p 0 3)))
  (check-true (caret? (caret (p 0 3))))
  (check-false (caret? (selection (p 0 0) (p 0 3))))
  (check-equal? (caret-point (caret (p 1 2))) (p 1 2))

  (displayln "selection.rkt: all tests passed"))
