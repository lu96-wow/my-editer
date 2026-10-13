#lang racket

;;; edit4-test/layout.rkt —— 布局层（求解 / 树 / 几何 / 命中 / 拖拽 / 浮窗）

(require rackunit
         racket/list
         "../edit4/layout.rkt")

;;; ---------- 求解器 ----------

;; 精确快路径：content == Σbasis → 原样返回
(check-equal? (solve-axis 21 1 (list (size 10 #t) (size 10 #t)) (list 2 2)) '(10 10))
;; 增长按当前尺寸等比
(check-equal? (solve-axis 23 1 (list (size 10 #t) (size 10 #t)) (list 2 2)) '(11 11))
;; 固定项不参与（flex=0）
(check-equal? (solve-axis 21 0 (list (size 3 #f) (size 3 #t)) (list 1 1)) '(3 18))
;; **比例不漂**：20:10，容器变大 → 仍 2:1
(check-equal? (solve-axis 61 1 (list (size 20 #t) (size 10 #t)) (list 2 2)) '(40 20))
;; **比例不漂**：20:10，容器变小 → 仍 2:1
(check-equal? (solve-axis 16 1 (list (size 20 #t) (size 10 #t)) (list 2 2)) '(10 5))
;; 最大余数：5 分 3 份 → 2/2/1
(check-equal? (solve-axis 5 0 (list (size 1 #t) (size 1 #t) (size 1 #t)) (list 1 1 1)) '(2 2 1))
;; 收缩按比例
(check-equal? (solve-axis 15 1 (list (size 10 #t) (size 10 #t)) (list 2 2)) '(7 7))
;; 硬下限：content <= Σmin → 全取 min（可能溢出）
(check-equal? (solve-axis 3 1 (list (size 10 #t) (size 10 #t)) (list 2 2)) '(2 2))

;;; ---------- 树 ----------

(define (lf id) (leaf id (cons 2 2)))
(define left (split 'v 1 (list (child (size 2 #t) (lf 'a)) (child (size 2 #t) (lf 'b)))))
(define right (split 'v 1 (list (child (size 2 #t) (lf 'c)) (child (size 2 #t) (lf 'd)))))
(define root (split 'h 1 (list (child (size 2 #t) left) (child (size 2 #t) right))))

(check-equal? (node-min left) (cons 2 5))         ; 2 宽；2 + 缝 1 + 2 高
(check-equal? (node-min root) (cons 5 5))
(check-equal? (path-of root 'd) '(1 1))
(check-equal? (node-at root '(0 1)) (lf 'b))
(check-equal? (ids root) '(a b c d))
;; split-leaf：把 b 换成 (b | e)
(define root* (split-leaf root 'b 'v 'after (lf 'e)))
(check-equal? (ids root*) '(a b e c d))
;; remove-leaf：收拢
(check-equal? (ids (remove-leaf root 'd)) '(a b c))
(check-false (remove-leaf (remove-leaf (remove-leaf (remove-leaf root 'a) 'b) 'c) 'd))

;;; ---------- 几何 / 命中 / 拖拽 ----------

(define g (layout root (rect 0 0 21 11)))
(define (r id) (hash-ref (geometry-rects g) id))
(check-equal? (r 'a) (rect 0 0 10 5))
(check-equal? (r 'b) (rect 0 6 10 5))
(check-equal? (r 'c) (rect 11 0 10 5))
(check-equal? (r 'd) (rect 11 6 10 5))

;; cuts：一条竖线 x=10（1 段）、一条横线 y=5（2 段）
(check-equal? (length (geometry-cuts g)) 2)
(check-equal? (map (lambda (c) (cons (cut-axis c) (cut-offset c))) (geometry-cuts g))
              '((x . 10) (y . 5)))
(check-equal? (length (cut-segs (list-ref (geometry-cuts g) 1))) 2)

;; 命中：内容 / 缝 / 交点
(check-equal? (hit g 1 1) 'a)
(check-equal? (hit g 10 1) (list (list-ref (geometry-cuts g) 0)))
(let ([h (hit g 10 5)])                       ; 十字：两条 cut
  (check-equal? (length h) 2)
  (check-equal? (sort (map cut-axis h) symbol<?) '(x y)))

;; 拖拽：交点 +2,+1 → 竖线 +2、横线 +1，四窗同步；其它项不动
(define hits (hit g 10 5))
(define moves (append (move-cut (segs-of-axis hits 'x) 2)
                      (move-cut (segs-of-axis hits 'y) 1)))
(define g2 (layout (for/fold ([t root]) ([m (in-list moves)]) (set-sizes t (car m) (cadr m)))
                     (rect 0 0 21 11)))
(define (r2 id) (hash-ref (geometry-rects g2) id))
(check-equal? (r2 'a) (rect 0 0 12 6))
(check-equal? (r2 'b) (rect 0 7 12 4))
(check-equal? (r2 'c) (rect 13 0 8 6))
(check-equal? (r2 'd) (rect 13 7 8 4))

;; 拖过头 → min 夹住（竖线最多左移到左列 min=2）
(define hits2 (hit g 10 5))
(define moves2 (move-cut (segs-of-axis hits2 'x) -100))
(define g3 (layout (for/fold ([t root]) ([m (in-list moves2)]) (set-sizes t (car m) (cadr m)))
                     (rect 0 0 21 11)))
(check-equal? (hash-ref (geometry-rects g3) 'a) (rect 0 0 2 5))
(check-equal? (hash-ref (geometry-rects g3) 'c) (rect 3 0 18 5))

;;; ---------- 浮窗 ----------

(define f (float 'f (anchor 'screen 'right 'bottom 2 2) (cons 10 4)))
(check-equal? (float-rect (rect 0 0 80 24) f 80 24) (rect 70 20 10 4))
(define f2 (float 'f2 (anchor 'screen 'center 'center 0 0) (cons 10 4)))
(check-equal? (float-rect (rect 0 0 80 24) f2 80 24) (rect 35 10 10 4))

;;; ---------- T 字路口（三窗）：竖臂只在一侧 ----------

(define ttop (split 'h 1 (list (child (size 2 #t) (lf 'a)) (child (size 2 #t) (lf 'b)))))
(define troot (split 'v 1 (list (child (size 5 #t) ttop) (child (size 5 #t) (lf 'c)))))
(define tg (layout troot (rect 0 0 21 11)))
(check-equal? (hash-ref (geometry-rects tg) 'c) (rect 0 6 21 5))
(let ([h (hit tg 10 5)])
  (check-equal? (length h) 2)                 ; 同时命中竖线（上）与横线（通）
  (check-equal? (sort (map cut-axis h) symbol<?) '(x y)))
(define tmoves (append (move-cut (segs-of-axis (hit tg 10 5) 'x) 2)
                       (move-cut (segs-of-axis (hit tg 10 5) 'y) 1)))
(check-equal? (length tmoves) 2)
(define tg2 (layout (for/fold ([t troot]) ([m (in-list tmoves)]) (set-sizes t (car m) (cadr m)))
                    (rect 0 0 21 11)))
(check-equal? (hash-ref (geometry-rects tg2) 'a) (rect 0 0 12 6))
(check-equal? (hash-ref (geometry-rects tg2) 'b) (rect 13 0 8 6))
(check-equal? (hash-ref (geometry-rects tg2) 'c) (rect 0 7 21 4))

;;; ---------- 整条线：三列，横线一段不断 ----------

(define (col p q) (split 'v 1 (list (child (size 2 #t) (lf p)) (child (size 2 #t) (lf q)))))
(define g3root (split 'h 1 (list (child (size 2 #t) (col 'a0 'b0))
                                 (child (size 2 #t) (col 'a1 'b1))
                                 (child (size 2 #t) (col 'a2 'b2)))))
(define g3col (layout g3root (rect 0 0 23 11)))
(check-equal? (hash-ref (geometry-rects g3col) 'a0) (rect 0 0 7 5))
(check-equal? (hash-ref (geometry-rects g3col) 'a2) (rect 16 0 7 5))
(let ([h (hit g3col 7 5)])                        ; 第一列上的 T，横线共 3 段
  (check-equal? (length (cut-segs (for/first ([c (in-list h)] #:when (eq? 'y (cut-axis c))) c))) 3))
(define g3colmoves (move-cut (segs-of-axis (hit g3col 7 5) 'y) 1))
(check-equal? (length g3colmoves) 3)             ; 三段一起动
(define g3colb (layout (for/fold ([t g3root]) ([m (in-list g3colmoves)]) (set-sizes t (car m) (cadr m)))
                    (rect 0 0 23 11)))
(for ([id (in-list '(a0 a1 a2))]) (check-equal? (rect-h (hash-ref (geometry-rects g3colb) id)) 6))
(for ([id (in-list '(b0 b1 b2))]) (check-equal? (rect-h (hash-ref (geometry-rects g3colb) id)) 4))

;;; ---------- 缓存：输入没变就不重算 ----------

(define-values (c1 fr1) (ensure-layout empty-layout-cache root '() (cons 21 11)))
(check-true (frame? fr1))
;; 相同输入 → 同一个对象（命中缓存）
(define-values (c2 fr2) (ensure-layout c1 root '() (cons 21 11)))
(check-true (eq? fr1 fr2))
;; 只换浮窗 → 平铺级不动，只重算浮窗矩形
(define wl (list (float 'w (anchor 'screen 'right 'bottom 2 2) (cons 6 3))))
(define-values (c3 fr3) (ensure-layout c2 root wl (cons 21 11)))
(check-equal? (frame-float-rect fr3 'w) (rect 15 8 6 3))
;; 只换浮窗 → 平铺几何对象不变
(check-eq? (layout-cache-f-tiled c2) (layout-cache-f-tiled c3))
;; 尺寸变 → 平铺重算
(define-values (c4 fr4) (ensure-layout c3 root wl (cons 22 11)))
(check-false (eq? (layout-cache-f-tiled c3) (layout-cache-f-tiled c4)))
;; 锚到某个 pane（rel = wid）→ 相对该 pane 定位
(define fa (float 'a (anchor 'a 'left 'top 0 0) (cons 3 2)))
(define-values (c5 fr5) (ensure-layout c4 root (list fa) (cons 22 11)))
(check-equal? (frame-float-rect fr5 'a) (rect 0 0 3 2))

;;; ---------- settle：解算结果写回树，之后走快路径 ----------

;; 2×2：未归一化（basis = min）→ settle 后 basis = 解出长度
(define root-s (settle root (rect 0 0 21 11)))
(check-equal? (map (lambda (c) (size-basis (child-size c))) (split-kids root-s)) '(10 10))
(check-equal? (map (lambda (c) (size-basis (child-size c))) (split-kids (child-node (car (split-kids root-s))))) '(5 5))
;; 幂等
(check-equal? (settle root-s (rect 0 0 21 11)) root-s)
;; 几何不变
(check-equal? (geometry-rects (layout root (rect 0 0 21 11)))
              (geometry-rects (layout root-s (rect 0 0 21 11))))
;; 简单两列：basis 2,2 → 10,10
(define pair (split 'h 1 (list (child (size 2 #t) (lf 'x)) (child (size 2 #t) (lf 'y)))))
(define pair-s (settle pair (rect 0 0 21 5)))
(check-equal? (map (lambda (c) (size-basis (child-size c))) (split-kids pair-s)) '(10 10))

;;; ---------- 方向导航 ----------

(check-equal? (neighbor g 'a 'right) 'c)
(check-equal? (neighbor g 'a 'down) 'b)
(check-equal? (neighbor g 'b 'right) 'd)
(check-equal? (neighbor g 'd 'left) 'b)
(check-equal? (neighbor g 'a 'left) #f)
(check-equal? (neighbor g 'a 'up) #f)

;;; ---------- 不变量自检 ----------

(check-equal? (validate root (rect 0 0 21 11)) '())
(check-equal? (validate root-s (rect 0 0 21 11)) '())
;; 坏结构：只有一个孩子
(check-true (pair? (validate (split 'h 1 (list (child (size 2 #t) (lf 'z)))) (rect 0 0 21 11))))
;; 坏 min：叶子 min < (1 . 1)
(check-true (pair? (validate (leaf 'z (cons 0 2)) (rect 0 0 21 11))))

(displayln "edit4/layout.rkt: all tests passed")
