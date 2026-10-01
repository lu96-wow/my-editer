#lang racket

;;; ============================================================================
;;; layout.rkt —— 纯几何：切分 → 矩形
;;; ============================================================================
;;;
;;; 叶是**稳定的 pane-id**（数字）。内容换不换与布局无关，所以焦点/命中/调宽
;;; 都记 pane-id，不记视图。
;;;
;;;   (leaf id)                 叶子
;;;   (split dir a b gap fixed side) 切分：dir='h 左右 / 'v 上下；
;;;                             fixed=#f 均分 | fixed 尺寸，side='a|'b 指定属于哪一侧
;;;
;;; 入口：
;;;   layout-rects   布局 × 区域 → (listof rect)
;;;   layout-leaves  深度优先的 pane-id（焦点循环顺序）
;;;   layout-hit     屏幕坐标 → pane-id | #f
;;;   layout-replace / layout-remove / layout-resize
;;;
;;; 不认识文档、渲染、输入。

(provide (struct-out leaf)
         (struct-out split)
         (struct-out lrect)
         hsplit hsplit-left vsplit vsplit-bottom
         layout? layout-rects layout-leaves layout-hit
         layout-contains?
         layout-replace layout-remove layout-resize)

;;; ---------- 值 ----------

(struct leaf (id) #:transparent)
(struct split (dir a b gap fixed side) #:transparent)
(struct lrect (id x y w h) #:transparent)

(define (hsplit a b [gap 0]) (split 'h a b gap #f 'a))
(define (hsplit-left w a b [gap 0]) (split 'h a b gap w 'a))
(define (vsplit a b [gap 0]) (split 'v a b gap #f 'a))
(define (vsplit-bottom h a b [gap 0]) (split 'v a b gap h 'b))

(define (layout? l) (or (leaf? l) (split? l)))

;;; ---------- 解析 ----------

(define (split-sizes l avail)
  (define f (split-fixed l))
  (cond
    [(not f) (define a (quotient avail 2)) (values a (- avail a))]
    [(eq? (split-side l) 'a) (define a (min avail f)) (values a (max 0 (- avail a)))]
    [else (define b (min avail f)) (values (max 0 (- avail b)) b)]))

(define (layout-rects l x y w h)
  (cond
    [(leaf? l) (list (lrect (leaf-id l) x y w h))]
    [(split? l)
     (define g (split-gap l))
     (define avail (max 0 (- (if (eq? (split-dir l) 'h) w h) g)))
     (define-values (first second) (split-sizes l avail))
     (cond
       [(eq? (split-dir l) 'h)
        (append (layout-rects (split-a l) x y first h)
                (layout-rects (split-b l) (+ x first g) y second h))]
       [else
        (append (layout-rects (split-a l) x y w first)
                (layout-rects (split-b l) x (+ y first g) w second))])]
    [else (error 'layout-rects "不是布局值: ~a" l)]))

(define (layout-leaves l)
  (cond
    [(leaf? l) (list (leaf-id l))]
    [(split? l) (append (layout-leaves (split-a l)) (layout-leaves (split-b l)))]
    [else '()]))

(define (layout-hit l w h row col)
  (for/first ([r (in-list (layout-rects l 0 0 w h))]
              #:when (and (>= col (lrect-x r)) (< col (+ (lrect-x r) (lrect-w r)))
                          (>= row (lrect-y r)) (< row (+ (lrect-y r) (lrect-h r)))))
    (lrect-id r)))

;;; ---------- 改写 ----------

(define (layout-contains? l id)
  (cond
    [(leaf? l) (= (leaf-id l) id)]
    [(split? l) (or (layout-contains? (split-a l) id) (layout-contains? (split-b l) id))]
    [else #f]))

(define (layout-replace l id new)
  (cond
    [(leaf? l) (if (= (leaf-id l) id) new l)]
    [(split? l) (struct-copy split l
                 [a (layout-replace (split-a l) id new)]
                 [b (layout-replace (split-b l) id new)])]
    [else l]))

;; 删叶；父节点只剩一个子就塌缩。#f = 整棵树被删空。
(define (layout-remove l id)
  (cond
    [(leaf? l) (if (= (leaf-id l) id) #f l)]
    [(split? l)
     (define a (layout-remove (split-a l) id))
     (define b (layout-remove (split-b l) id))
     (cond [(not a) b] [(not b) a]
           [else (struct-copy split l [a a] [b b])])]
    [else l]))

;; 调含 id 的**最深**水平切分（只调有明确 fixed 的）：
;;   id 在 fixed 那一侧 → 变大；在另一侧 → 变小。
(define (layout-resize l id delta)
  (cond
    [(leaf? l) (values l #f)]
    [(split? l)
     (define-values (a* da) (layout-resize (split-a l) id delta))
     (cond
       [da (values (struct-copy split l [a a*]) #t)]
       [else
        (define-values (b* db) (layout-resize (split-b l) id delta))
        (cond
          [db (values (struct-copy split l [b b*]) #t)]
          [(and (eq? (split-dir l) 'h) (split-fixed l))
           (define on-fixed? (if (eq? (split-side l) 'a)
                                 (layout-contains? (split-a l) id)
                                 (layout-contains? (split-b l) id)))
           (values (struct-copy split l
                     [fixed (max 1 ((if on-fixed? + -) (split-fixed l) delta))]) #t)]
          [else (values l #f)])])]
    [else (values l #f)]))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit)

  (define L (vsplit-bottom 1 (hsplit-left 15 (leaf 0) (leaf 1) 1) (leaf 2)))
  (check-equal? (layout-leaves L) '(0 1 2))
  (check-equal? (map (lambda (r) (list (lrect-id r) (lrect-x r) (lrect-y r) (lrect-w r) (lrect-h r)))
                     (layout-rects L 0 0 60 10))
                '((0 0 0 15 9) (1 16 0 44 9) (2 0 9 60 1)))
  (check-equal? (layout-hit L 60 10 3 5) 0)
  (check-equal? (layout-hit L 60 10 3 20) 1)
  (check-equal? (layout-hit L 60 10 9 5) 2)
  (check-equal? (layout-hit L 60 10 3 15) #f)          ; gap 列
  (check-equal? (layout-leaves (layout-replace L 1 (vsplit (leaf 1) (leaf 3)))) '(0 1 3 2))
  (check-equal? (layout-leaves (layout-remove L 1)) '(0 2))

  (define-values (L2 done?) (layout-resize L 0 5))
  (check-true done?)
  (check-equal? (lrect-w (car (layout-rects L2 0 0 60 10))) 20)

  (displayln "lab-rebuild/layout.rkt: all tests passed"))
