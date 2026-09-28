#lang racket

(require "../core/editor.rkt")

;;; layout.rkt —— 声明式布局：把一块区域切成若干 pane
;;;
;;; 只跟 **pane-id** 和 core 的 **rect** 打交道，不认识 document / 组件 / 渲染。
;;; 它是纯数据 + 纯函数：布局值 → rect 列表（给 core）/ 命中结果（给鼠标）。
;;;
;;;   (pane id)                          ; 叶子
;;;   (hsplit left right [gap])          ; 左右均分，中间留 gap 列
;;;   (hsplit-left left-w left right [gap])   ; 左固定宽
;;;   (vsplit top bottom [gap])          ; 上下均分
;;;   (vsplit-bottom bottom-h top bottom [gap]); 下固定高（状态栏常用）
;;;
;;;   (layout->rects l x y w h) → (listof rect)          ; 给 editor-render-layout
;;;   (layout-gaps   l x y w h) → (listof gap)           ; 给宿主画分隔线（可选）
;;;   (layout-hit    l w h row col) → (list id local-row local-col) | #f

(provide
 ;; ---------- 布局值 ----------
 (struct-out pane)
 hsplit hsplit-left
 vsplit vsplit-bottom
 layout?

 ;; ---------- 解析 ----------
 layout->rects layout-gaps layout-hit
 (struct-out gap))

;;; ---------- 布局值 ----------

(struct pane (id) #:transparent)

(struct hsplit-node (left right gap left-w) #:transparent)
(struct vsplit-node (top bottom gap top-h bottom-h) #:transparent)

;; 左右均分（gap = 中间留白列数）。
(define (hsplit left right [gap 0]) (hsplit-node left right gap #f))
;; 左固定宽 left-w，右吃掉剩余。
(define (hsplit-left left-w left right [gap 0]) (hsplit-node left right gap left-w))
;; 上下均分（gap = 中间留白行数）。
(define (vsplit top bottom [gap 0]) (vsplit-node top bottom gap #f #f))
;; 下固定高 bottom-h，上吃掉剩余（状态栏写在最底）。
(define (vsplit-bottom bottom-h top bottom [gap 0]) (vsplit-node top bottom gap #f bottom-h))

;; 叶子也可以是裸 pane-id（数字），省一层 (pane id)。
(define (leaf? l) (or (pane? l) (exact-nonnegative-integer? l)))
(define (leaf-id l) (if (pane? l) (pane-id l) l))

(define (layout? l) (or (leaf? l) (hsplit-node? l) (vsplit-node? l)))

;;; ---------- 解析：布局值 → rect 列表 ----------

(define (layout->rects l x y w h)
  (cond
    [(leaf? l) (list (rect (leaf-id l) x y w h))]
    [(hsplit-node? l)
     (define g (hsplit-node-gap l))
     (define avail (max 0 (- w g)))
     (define lw (if (hsplit-node-left-w l) (min avail (hsplit-node-left-w l)) (quotient avail 2)))
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

;;; ---------- 分隔带（宿主可用来画竖线 / 横线） ----------

(struct gap (orient x y w h) #:transparent)
;; orient : 'v（竖带，宽 w、高 h）| 'h（横带）

(define (layout-gaps l x y w h)
  (cond
    [(leaf? l) '()]
    [(hsplit-node? l)
     (define g (hsplit-node-gap l))
     (define avail (max 0 (- w g)))
     (define lw (if (hsplit-node-left-w l) (min avail (hsplit-node-left-w l)) (quotient avail 2)))
     (append (layout-gaps (hsplit-node-left l) x y lw h)
             (if (> g 0) (list (gap 'v (+ x lw) y g h)) '())
             (layout-gaps (hsplit-node-right l) (+ x lw g) y (max 0 (- avail lw)) h))]
    [(vsplit-node? l)
     (define g (vsplit-node-gap l))
     (define avail (max 0 (- h g)))
     (define th (cond [(vsplit-node-top-h l)]
                      [(vsplit-node-bottom-h l) (max 0 (- avail (vsplit-node-bottom-h l)))]
                      [else (quotient avail 2)]))
     (append (layout-gaps (vsplit-node-top l) x y w th)
             (if (> g 0) (list (gap 'h x (+ y th) w g)) '())
             (layout-gaps (vsplit-node-bottom l) x (+ y th g) w (max 0 (- avail th))))]
    [else '()]))

;;; ---------- 命中：屏幕 (row,col) → pane ----------

;; → (list pane-id local-row local-col) | #f
(define (layout-hit l w h row col)
  (for/first ([r (in-list (layout->rects l 0 0 w h))]
              #:when (and (>= col (rect-x r)) (< col (+ (rect-x r) (rect-w r)))
                          (>= row (rect-y r)) (< row (+ (rect-y r) (rect-h r)))))
    (list (rect-vid r) (- row (rect-y r)) (- col (rect-x r)))))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit)

  (define (rects l w h)
    (for/list ([r (in-list (layout->rects l 0 0 w h))])
      (list (rect-vid r) (rect-x r) (rect-y r) (rect-w r) (rect-h r))))

  ;; 均分 + gap
  (check-equal? (rects (hsplit 0 1 1) 10 5) '((0 0 0 4 5) (1 5 0 5 5)))
  ;; 左固定宽
  (check-equal? (rects (hsplit-left 3 0 1 1) 10 5) '((0 0 0 3 5) (1 4 0 6 5)))
  ;; 下固定高（状态栏）
  (check-equal? (rects (vsplit-bottom 1 0 2) 10 5) '((0 0 0 10 4) (2 0 4 10 1)))
  ;; 嵌套：内容两格 + 底行状态栏
  (check-equal? (rects (vsplit-bottom 1 (hsplit 0 1 1) 2) 10 5)
                '((0 0 0 4 4) (1 5 0 5 4) (2 0 4 10 1)))
  ;; 裸数字 = (pane id)
  (check-equal? (rects (hsplit (pane 0) 1 0) 10 5) (rects (hsplit 0 1 0) 10 5))

  ;; 命中：内容 / 状态栏 / gap
  (define L (vsplit-bottom 1 (hsplit 0 1 1) 2))
  (check-equal? (layout-hit L 10 5 0 6) (list 1 0 1))
  (check-equal? (layout-hit L 10 5 4 3) (list 2 0 3))
  (check-equal? (layout-hit L 10 5 0 4) #f)                   ; gap 列没有 pane

  ;; 分隔带：只有中间那条竖带
  (define g (layout-gaps L 0 0 10 5))
  (check-equal? (length g) 1)
  (check-equal? (list (gap-orient (car g)) (gap-x (car g)) (gap-y (car g))
                      (gap-w (car g)) (gap-h (car g)))
                '(v 4 0 1 4))

  (displayln "lab/layout.rkt: all tests passed"))
