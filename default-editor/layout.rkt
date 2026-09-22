#lang racket

;;; default-editor/layout.rkt —— 屏幕分区几何（纯函数，不碰 editor）
;;;
;;; core 只管「一个 document 的一个 viewport」，不管窗口管理。窗口管理的第一层是**几何**：
;;; 把 rows×cols 切成若干矩形（左栏 / 主区 / 底部状态栏），全是纯计算，可单独测试。
;;;
;;; 布局规则（本稿固定）：
;;;   status = 底部整宽，高 status-height
;;;   tree   = 左栏，宽 sidebar-width（sidebar? 为 #f 或宽 0 时不可见）
;;;   main   = 其余全部（保证至少 1×1）
;;;
;;; 一旦某个尺寸不合域（栏比屏还宽、状态栏吃掉全部行），layout-normalize 用「最近合法解释」夹紧。

(require rackunit)

(provide
 ;; rect
 rect? rect-x rect-y rect-w rect-h rect-right rect-bottom rect-contains?
 ;; layout
 layout? layout-open layout-normalize
 layout-rows layout-cols layout-sidebar? layout-sidebar-width layout-status-height
 layout-main layout-tree layout-status layout-region-at
 layout-set-sidebar? layout-set-sidebar-width layout-set-status-height)

;;; ---------- rect：屏幕上一块矩形 ----------

(struct rect (x y w h) #:transparent)
;; x/y 可以是负数（贴在合成屏外，超出部分裁掉）；w/h ≥ 0。

(define (rect-right r) (+ (rect-x r) (rect-w r)))
(define (rect-bottom r) (+ (rect-y r) (rect-h r)))
(define (rect-contains? r x y)
  (and (>= x (rect-x r)) (< x (rect-right r))
       (>= y (rect-y r)) (< y (rect-bottom r))))

;;; ---------- layout：分区方案 ----------

(struct layout (rows cols sidebar? sidebar-width status-height) #:transparent)
;; rows/cols        : nat   整屏尺寸
;; sidebar?         : bool  左栏是否参与
;; sidebar-width    : nat   左栏宽（已夹到 [0, cols-1]）
;; status-height    : nat   底部高（已夹到 [0, rows-1]）

(define (layout-open rows cols
                     #:sidebar? [sidebar? #t]
                     #:sidebar-width [sidebar-width 30]
                     #:status-height [status-height 1])
  (layout-normalize (layout (max 1 rows) (max 1 cols) sidebar? sidebar-width status-height)))

;; 夹紧：main 至少 1×1；status 不超 rows-1；tree 不超 cols-1（宽 0 = 不可见）。
(define (layout-normalize l)
  (define rows (max 1 (layout-rows l)))
  (define cols (max 1 (layout-cols l)))
  (define sh (max 0 (min (layout-status-height l) (sub1 rows))))
  (define sw (max 0 (min (layout-sidebar-width l) (sub1 cols))))
  (layout rows cols (and (layout-sidebar? l) #t) sw sh))

;; 实际生效的左栏宽（sidebar? 关掉即 0）。
(define (tree-width l) (if (layout-sidebar? l) (layout-sidebar-width l) 0))

(define (layout-main l)
  (define sw (tree-width l))
  (define sh (layout-status-height l))
  (rect sw 0 (- (layout-cols l) sw) (- (layout-rows l) sh)))

(define (layout-tree l)
  (define sh (layout-status-height l))
  (rect 0 0 (tree-width l) (- (layout-rows l) sh)))

(define (layout-status l)
  (define sh (layout-status-height l))
  (rect 0 (- (layout-rows l) sh) (layout-cols l) sh))

;; 鼠标命中：status 叠在 tree 之上（同列更靠下），故先判 status。
(define (layout-region-at l x y)
  (cond
    [(rect-contains? (layout-status l) x y) 'status]
    [(and (> (tree-width l) 0) (rect-contains? (layout-tree l) x y)) 'tree]
    [(rect-contains? (layout-main l) x y) 'main]
    [else #f]))

(define (layout-set-sidebar? l on?)
  (layout-normalize (struct-copy layout l [sidebar? (and on? #t)])))
(define (layout-set-sidebar-width l w)
  (layout-normalize (struct-copy layout l [sidebar-width (inexact->exact (max 0 (truncate w)))])))
(define (layout-set-status-height l h)
  (layout-normalize (struct-copy layout l [status-height (inexact->exact (max 0 (truncate h)))])))

;;; ---------- 测试 ----------

(module+ test
  (define l (layout-open 24 80 #:sidebar? #t #:sidebar-width 30 #:status-height 1))
  (check-equal? (layout-rows l) 24)
  (check-equal? (layout-cols l) 80)
  (check-equal? (layout-status l) (rect 0 23 80 1))
  (check-equal? (layout-tree l) (rect 0 0 30 23))
  (check-equal? (layout-main l) (rect 30 0 50 23))

  ;; 关栏：主区从 0 开始
  (define l0 (layout-set-sidebar? l #f))
  (check-false (layout-sidebar? l0))
  (check-equal? (layout-main l0) (rect 0 0 80 23))
  (check-equal? (layout-tree l0) (rect 0 0 0 23))

  ;; 命中
  (check-equal? (layout-region-at l 5 5) 'tree)
  (check-equal? (layout-region-at l 40 5) 'main)
  (check-equal? (layout-region-at l 40 23) 'status)
  (check-equal? (layout-region-at l0 5 5) 'main)

  ;; 夹紧：栏不得吃掉全部列，状态栏不得吃掉全部行
  (define ln (layout-open 5 10 #:sidebar-width 999 #:status-height 999))
  (check-equal? (layout-sidebar-width ln) 9)
  (check-equal? (layout-status-height ln) 4)
  (check-equal? (rect-w (layout-main ln)) 1)
  (check-equal? (rect-h (layout-main ln)) 1)

  ;; 极小屏：1×1 → 状态栏 0 高、栏 0 宽，主区 1×1
  (define l1 (layout-open 1 1 #:sidebar-width 10 #:status-height 10))
  (check-equal? (layout-status-height l1) 0)
  (check-equal? (layout-sidebar-width l1) 0)
  (check-equal? (layout-main l1) (rect 0 0 1 1))
  (check-equal? (layout-status l1) (rect 0 1 1 0))

  (displayln "layout.rkt: all tests passed"))
