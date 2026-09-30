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
         layout->rects layout-leaves layout-hit
         layout-replace layout-remove
         layout-contains? layout-resize)

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

;;; ---------- 改写布局（分格 / 关格用） ----------

;; 把叶 pid 替换成子树 new。
(define (layout-replace l pid new)
  (cond
    [(lpane? l) (if (= (lpane-id l) pid) new l)]
    [(hsplit-node? l) (hsplit-node (layout-replace (hsplit-node-left l) pid new)
                                   (layout-replace (hsplit-node-right l) pid new)
                                   (hsplit-node-gap l) (hsplit-node-left-w l))]
    [(vsplit-node? l) (vsplit-node (layout-replace (vsplit-node-top l) pid new)
                                   (layout-replace (vsplit-node-bottom l) pid new)
                                   (vsplit-node-gap l) (vsplit-node-top-h l) (vsplit-node-bottom-h l))]
    [else l]))

;; 删掉叶 pid；父节点只剩一个子就塌缩。#f = 整棵树被删空。
(define (layout-remove l pid)
  (cond
    [(lpane? l) (if (= (lpane-id l) pid) #f l)]
    [(hsplit-node? l)
     (define a (layout-remove (hsplit-node-left l) pid))
     (define b (layout-remove (hsplit-node-right l) pid))
     (cond [(not a) b] [(not b) a]
           [else (hsplit-node a b (hsplit-node-gap l) (hsplit-node-left-w l))])]
    [(vsplit-node? l)
     (define a (layout-remove (vsplit-node-top l) pid))
     (define b (layout-remove (vsplit-node-bottom l) pid))
     (cond [(not a) b] [(not b) a]
           [else (vsplit-node a b (vsplit-node-gap l) (vsplit-node-top-h l) (vsplit-node-bottom-h l))])]
    [else l]))

;;; ---------- 查 / 调宽 ----------

(define (layout-contains? l pid)
  (cond
    [(lpane? l) (= (lpane-id l) pid)]
    [(hsplit-node? l) (or (layout-contains? (hsplit-node-left l) pid)
                          (layout-contains? (hsplit-node-right l) pid))]
    [(vsplit-node? l) (or (layout-contains? (vsplit-node-top l) pid)
                          (layout-contains? (vsplit-node-bottom l) pid))]
    [else #f]))

;; 找包含 pid 的**最深**水平切分，按其左右调宽：
;;   pid 在左 → 左宽 + delta；pid 在右 → 左宽 - delta（即右变宽）。
;; 只调有明确左宽的切分（hsplit-left）；均分切分不调，交给外层。
;; → (values layout 是否调过)
(define (layout-resize l pid delta)
  (cond
    [(lpane? l) (values l #f)]
    [(hsplit-node? l)
     (define lw (hsplit-node-left-w l))
     (cond
       [(layout-contains? (hsplit-node-left l) pid)
        (define-values (l* done?) (layout-resize (hsplit-node-left l) pid delta))
        (cond [done? (values (struct-copy hsplit-node l [left l*]) #t)]
              [lw (values (struct-copy hsplit-node l [left-w (max 1 (+ lw delta))]) #t)]
              [else (values l #f)])]
       [(layout-contains? (hsplit-node-right l) pid)
        (define-values (r* done?) (layout-resize (hsplit-node-right l) pid delta))
        (cond [done? (values (struct-copy hsplit-node l [right r*]) #t)]
              [lw (values (struct-copy hsplit-node l [left-w (max 1 (- lw delta))]) #t)]
              [else (values l #f)])]
       [else (values l #f)])]
    [(vsplit-node? l)
     (define-values (t* done?) (layout-resize (vsplit-node-top l) pid delta))
     (cond
       [done? (values (struct-copy vsplit-node l [top t*]) #t)]
       [else
        (define-values (b* done2?) (layout-resize (vsplit-node-bottom l) pid delta))
        (values (if done2? (struct-copy vsplit-node l [bottom b*]) l) done2?)])]
    [else (values l #f)]))

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

  ;; 改写：替换叶 / 删除叶
  (define L2 (layout-replace L 1 (vsplit (lpane 1) (lpane 3))))
  (check-equal? (layout-leaves L2) '(0 1 3 2))
  (check-equal? (layout-leaves (layout-remove L 1)) '(0 2))

  ;; 调宽：左固定 30；焦点在左（0）→ 左变宽；焦点在右（1）→ 左变窄（右变宽）
  (define-values (L3 d3) (layout-resize L 0 5))
  (check-true d3)
  (check-equal? (lrect-w (car (layout->rects L3 0 0 60 10))) 35)
  (define-values (L4 d4) (layout-resize L 1 5))
  (check-equal? (lrect-w (car (layout->rects L4 0 0 60 10))) 25)

  (displayln "lab-rebuild/layout.rkt: all tests passed"))
