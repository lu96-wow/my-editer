#lang racket

;;; layout.rkt —— 布局：纯数据
;;;
;;; 叶是**稳定的 pane-id**（数字），节点是切分。pane 的 vid 会随「打开文件换视图」
;;; 而变，但 pane-id 不变 —— 所以焦点 / 命中 / 循环都记 pane-id，不记 vid。
;;;
;;;   (lpane id)                            叶子
;;;   (hsplit left right [gap])             左右均分
;;;   (hsplit-left w left right [gap])      左固定宽
;;;   (vsplit top bottom [gap])             上下均分
;;;   (vsplit-bottom h top bottom [gap])    下固定高（状态栏）
;;;
;;;   (layout->rects l x y w h) → (listof lrect)   ; lrect = (id x y w h)
;;;   (layout-leaves l)         → (listof pane-id) ; 深度优先 = 焦点循环顺序
;;;   (layout-hit l w h row col)→ pane-id | #f
;;;
;;; 不认识文档、不认识渲染、不认识输入。

(provide (struct-out lpane) hsplit hsplit-left vsplit vsplit-bottom layout?
         (struct-out lrect)
         layout->rects layout-leaves layout-hit)

(struct lpane (id) #:transparent)
(struct hsplit-node (left right gap left-w) #:transparent)
(struct vsplit-node (top bottom gap top-h bottom-h) #:transparent)

(struct lrect (id x y w h) #:transparent)

(define (hsplit left right [gap 0]) (hsplit-node left right gap #f))
(define (hsplit-left w left right [gap 0]) (hsplit-node left right gap w))
(define (vsplit top bottom [gap 0]) (vsplit-node top bottom gap #f #f))
(define (vsplit-bottom h top bottom [gap 0]) (vsplit-node top bottom gap #f h))

(define (layout? l)
  (or (lpane? l) (hsplit-node? l) (vsplit-node? l)))

(define (layout->rects l x y w h)
  (cond
    [(lpane? l) (list (lrect (lpane-id l) x y w h))]
    [(hsplit-node? l)
     (define g (hsplit-node-gap l))
     (define avail (max 0 (- w g)))
     (define lw (if (hsplit-node-left-w l)
                    (min avail (hsplit-node-left-w l))
                    (quotient avail 2)))
     (append (layout->rects (hsplit-node-left l) x y lw h)
             (layout->rects (hsplit-node-right l) (+ x lw g) y (max 0 (- avail lw)) h))]
    [(vsplit-node? l)
     (define g (vsplit-node-gap l))
     (define avail (max 0 (- h g)))
     (define th (cond [(vsplit-node-top-h l)]
                      [(vsplit-node-bottom-h l) (max 0 (- avail (vsplit-node-bottom-h l)))]
                      [else (quotient avail 2)]))
     (append (layout->rects (vsplit-node-top l) x y w th)
             (layout->rects (vsplit-node-bottom l) x (+ y th g) w (max 0 (- avail th))))]
    [else (error 'layout->rects "不是布局值: ~a" l)]))

(define (layout-leaves l)
  (cond
    [(lpane? l) (list (lpane-id l))]
    [(hsplit-node? l) (append (layout-leaves (hsplit-node-left l))
                              (layout-leaves (hsplit-node-right l)))]
    [(vsplit-node? l) (append (layout-leaves (vsplit-node-top l))
                              (layout-leaves (vsplit-node-bottom l)))]
    [else '()]))

(define (layout-hit l w h row col)
  (for/first ([r (in-list (layout->rects l 0 0 w h))]
              #:when (and (>= col (lrect-x r)) (< col (+ (lrect-x r) (lrect-w r)))
                          (>= row (lrect-y r)) (< row (+ (lrect-y r) (lrect-h r)))))
    (lrect-id r)))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit)

  ;; 左 30 | gap 1 | 右 29；上 9 行 | 下 1 行状态栏
  (define L (vsplit-bottom 1 (hsplit-left 30 (lpane 0) (lpane 1) 1) (lpane 2)))
  (check-equal? (layout-leaves L) '(0 1 2))
  (define rs (layout->rects L 0 0 60 10))
  (check-equal? (map (lambda (r) (list (lrect-id r) (lrect-x r) (lrect-y r) (lrect-w r) (lrect-h r))) rs)
                '((0 0 0 30 9) (1 31 0 29 9) (2 0 9 60 1)))

  (check-equal? (layout-hit L 60 10 3 5) 0)
  (check-equal? (layout-hit L 60 10 3 35) 1)
  (check-equal? (layout-hit L 60 10 9 5) 2)
  (check-equal? (layout-hit L 60 10 3 30) #f)     ; gap 列

  ;; 均分也保留
  (check-equal? (map lrect-w (layout->rects (hsplit (lpane 0) (lpane 1) 0) 0 0 10 4)) '(5 5))

  (displayln "lab-rebuild/layout.rkt: all tests passed"))
