#lang racket

(require "point.rkt")

;;; base/selection.rkt —— 选区 (anchor, head)
;;;
;;; anchor = 选择时不动的那端；head = 活动端（光标 / 打字点）。
;;; 空选区 anchor = head，就是一个普通**光标**（caret）。
;;; 方向由 anchor/head 的先后表达（head 在 anchor 左 = 反向选区），selection-range 归一。
;;;
;;; 这里只有值 + 空间变换；「按方向键怎么动」由调用方给出 point -> point 的函数（见 point.rkt）。

(provide
 ;; ---------- 单选区：类型 / 构造 ----------
 (struct-out selection)
 caret caret? selection-point

 ;; ---------- 单选区：读 ----------
 selection-range selection-empty? selection<?

 ;; ---------- 单选区：空间变换（point -> point） ----------
 selection-with-head selection-with-anchor
 selection-map-head selection-map-anchor selection-map-both
 selection-go selection-extend selection-normalize

 ;; ---------- 选区集（多光标）：类型 / 构造 ----------
 (struct-out selections)
 selections-one selections-of

 ;; ---------- 选区集：读 ----------
 selections-count selections-primary selections-items

 ;; ---------- 选区集：变换 ----------
 selections-add selections-remove
 selections-set-primary selections-set-primary-value
 selections-map selections-map-primary
 selections-go selections-extend selections-go-primary selections-extend-primary

 ;; ---------- 选区集：归一 ----------
 selections-dedupe selections-normalize selections-clamp)

(struct selection (anchor head) #:transparent)
;; anchor / head : point

;;; ---------- 光标 = 空选区（构造 API 把「同位置」藏起来） ----------

(define (caret p) (selection p p))
(define (caret? s) (selection-empty? s))

;; 光标点 = 活动端。
(define (selection-point s) (selection-head s))

(define (selection-empty? s) (point=? (selection-anchor s) (selection-head s)))

;; 半开区间 [start, end)，与 anchor/head 的方向无关。
(define (selection-range s)
  (define a (selection-anchor s)) (define h (selection-head s))
  (if (point<=? a h) (values a h) (values h a)))

;;; ---------- 空间变换（point -> point） ----------

(define (selection-with-head s p) (selection (selection-anchor s) p))
(define (selection-with-anchor s p) (selection p (selection-head s)))
(define (selection-map-head f s) (selection-with-head s (f (selection-head s))))
(define (selection-map-anchor f s) (selection-with-anchor s (f (selection-anchor s))))
(define (selection-map-both f s)
  (selection (f (selection-anchor s)) (f (selection-head s))))

;; 按 (起, 止) 字典序；用于排序 / 合并。
(define (selection<? a b)
  (define-values (as ae) (selection-range a))
  (define-values (bs be) (selection-range b))
  (cond [(point<? as bs) #t]
        [(point<? bs as) #f]
        [else (point<? ae be)]))

;; 普通方向键：坍缩到 head 再移动（选择消失）。
(define (selection-go s f) (caret (f (selection-head s))))
;; Shift+方向键：只动 head（扩选 / 缩选）。
(define (selection-extend s f) (selection-map-head f s))

;; 规范成正向（anchor ≤ head）。
(define (selection-normalize s)
  (define-values (a h) (selection-range s))
  (selection a h))

;;; ---------- 选区集（多光标） ----------
;;; 若干选区 + 一个 primary（主选区）。保持顺序与 primary-index；需要非重叠时调
;;; selections-normalize。

(struct selections (items primary-index) #:transparent)
;; items         : (nonempty-listof selection)
;; primary-index : nat

(define (selections-of items [primary-index 0])
  (unless (pair? items) (error 'selections-of "至少一个选区，得到 ~a" items))
  (selections items (max 0 (min primary-index (sub1 (length items))))))
(define (selections-one s) (selections (list s) 0))
(define (selections-count ss) (length (selections-items ss)))
(define (selections-primary ss) (list-ref (selections-items ss) (selections-primary-index ss)))

;; primary 在 items 中的下标；找不到 → 0。
(define (index-of-primary items primary)
  (or (for/first ([x (in-list items)] [i (in-naturals)] #:when (equal? x primary)) i)
      0))

;; 追加（primary 不变）。
(define (selections-add ss new-items)
  (struct-copy selections ss [items (append (selections-items ss) new-items)]))

;; 删除与 drops 相等的项；primary 尽量保持，删空则原样。
(define (selections-remove ss drops)
  (define old (selections-items ss))
  (define primary (selections-primary ss))
  (define kept (remove* drops old))
  (if (null? kept) ss (selections kept (index-of-primary kept primary))))

(define (selections-set-primary ss i)
  (selections (selections-items ss)
              (max 0 (min i (sub1 (length (selections-items ss)))))))
(define (selections-set-primary-value ss s)
  (define idx (for/first ([x (in-list (selections-items ss))] [i (in-naturals)]
                          #:when (equal? x s)) i))
  (if idx (selections (selections-items ss) idx) ss))

;; 对每个 / 仅 primary 施 f（selection -> selection）。
(define (selections-map ss f)
  (struct-copy selections ss [items (map f (selections-items ss))]))
(define (selections-map-primary ss f)
  (define i (selections-primary-index ss))
  (define items (selections-items ss))
  (struct-copy selections ss [items (list-set items i (f (list-ref items i)))]))

;; 普通方向键：每个选区坍缩到 head 再走；去重。
(define (selections-go ss f)
  (selections-dedupe (selections-map ss (lambda (s) (selection-go s f)))))
;; Shift+方向键：只动各选区 head。
(define (selections-extend ss f)
  (selections-map ss (lambda (s) (selection-extend s f))))
(define (selections-go-primary ss f)
  (selections-map-primary ss (lambda (s) (selection-go s f))))
(define (selections-extend-primary ss f)
  (selections-map-primary ss (lambda (s) (selection-extend s f))))

;; 把每个选区的两端夹进合法域（line-count / line-length 函数，见 point-clamp）。
(define (selections-clamp ss line-count line-length)
  (selections-map ss
    (lambda (s)
      (selection (point-clamp (selection-anchor s) line-count line-length)
                 (point-clamp (selection-head s) line-count line-length)))))

;; 去重（保持顺序与 primary）。
(define (selections-dedupe ss)
  (define old (selections-items ss))
  (define primary (selections-primary ss))
  (define kept (remove-duplicates old))
  (selections kept (index-of-primary kept primary)))

;; 排序 + 合并重叠（首尾相接不合并），primary 追到包含它的那一项。
(define (selections-normalize ss)
  (define target (selections-primary ss))
  (define items
    (for/fold ([acc '()] #:result (reverse acc))
              ([s (in-list (sort (remove-duplicates (selections-items ss)) selection<?))])
      (cond
        [(null? acc) (list s)]
        [else
         (define prev (car acc))
         (define-values (ps pe) (selection-range prev))
         (define-values (ss_ se) (selection-range s))
         (if (point<? ss_ pe)
             (cons (selection ps (if (point<? pe se) se pe)) (cdr acc))
             (cons s acc))])))
  (selections items (primary-index-of items target)))

;; target 落到归一后的哪一项：
;;   区间 → 完整包含它的项；光标 → 先精确相等，再半开包含，最后含端点包含。
(define (primary-index-of items target)
  (define-values (a b) (selection-range target))
  (define (full-contains? x)
    (let-values ([(xa xb) (selection-range x)]) (and (point<=? xa a) (point<=? b xb))))
  (define (half-open-contains? x p)
    (let-values ([(xa xb) (selection-range x)]) (and (point<=? xa p) (point<? p xb))))
  (define (closed-contains? x p)
    (let-values ([(xa xb) (selection-range x)]) (and (point<=? xa p) (point<=? p xb))))
  (cond
    [(point=? a b)
     (or (for/first ([x (in-list items)] [i (in-naturals)] #:when (equal? x target)) i)
         (for/first ([x (in-list items)] [i (in-naturals)] #:when (half-open-contains? x a)) i)
         (for/first ([x (in-list items)] [i (in-naturals)] #:when (closed-contains? x a)) i)
         0)]
    [else (or (for/first ([x (in-list items)] [i (in-naturals)] #:when (full-contains? x)) i) 0)]))
