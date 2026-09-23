#lang racket

;;; default-editor/layout.rkt —— 屏幕分区几何（纯函数，不碰 editor）
;;;
;;; core 只管「一个 document 的一个 viewport」，不管窗口管理。窗口管理的第一层是**几何**：
;;; 把 rows×cols 切成若干矩形（前端 / 左栏文件树 / 底部状态栏），全是纯计算，可单独测试。
;;;
;;; layout 是各组件**唯一**共享的东西之一（另一个是命令）：它只说「哪个 pane 在哪个矩形、
;;; 是否可见」，不认识 pane 的内容。pane 的显隐（window hide）由这里表达，与 document
;;; 的打开/关闭无关 —— 隐藏一个 pane 不会动它的 document。
;;;
;;; 布局规则（本稿固定）：
;;;   status   = 底部整宽，高 status-height（status? 关或高 0 时不可见）
;;;   tree     = 左栏，宽 sidebar-width（sidebar? 关或宽 0 时不可见）
;;;   frontend = 其余全部（保证至少 1×1）
;;;
;;; 一旦某个尺寸不合域（栏比屏还宽、状态栏吃掉全部行），layout-normalize 用「最近合法解释」夹紧。

(require rackunit)

(provide
 ;; rect
 rect rect? rect-x rect-y rect-w rect-h rect-right rect-bottom rect-contains?
 ;; layout
 layout? layout-open layout-normalize
 layout-rows layout-cols
 layout-sidebar? layout-sidebar-width layout-status? layout-status-height
 layout-frontend layout-main layout-tree layout-status
 ;; 通用 pane 视图（几何耦合点）
 pane-ids layout-pane-ids layout-rect layout-pane-visible? layout-region-at
 layout-set-sidebar? layout-set-sidebar-width layout-set-status? layout-set-status-height
 layout-set-visible?)

;;; ---------- rect：屏幕上一块矩形 ----------

(struct rect (x y w h) #:transparent)
;; x/y 可以是负数（贴在合成屏外，超出部分裁掉）；w/h ≥ 0。

(define (rect-right r) (+ (rect-x r) (rect-w r)))
(define (rect-bottom r) (+ (rect-y r) (rect-h r)))
(define (rect-contains? r x y)
  (and (>= x (rect-x r)) (< x (rect-right r))
       (>= y (rect-y r)) (< y (rect-bottom r))))

;;; ---------- layout：分区方案 ----------

(struct layout (rows cols sidebar? sidebar-width status? status-height) #:transparent)
;; rows/cols        : nat   整屏尺寸
;; sidebar?         : bool  左栏是否参与
;; sidebar-width    : nat   左栏宽（已夹到 [0, cols-1]）
;; status?          : bool  状态栏是否参与
;; status-height    : nat   底部高（已夹到 [0, rows-1]）

(define (layout-open rows cols
                     #:sidebar? [sidebar? #t]
                     #:sidebar-width [sidebar-width 30]
                     #:status? [status? #t]
                     #:status-height [status-height 1])
  (layout-normalize (layout (max 1 rows) (max 1 cols)
                            sidebar? sidebar-width status? status-height)))

;; 夹紧：frontend 至少 1×1；status 不超 rows-1；tree 不超 cols-1（宽 0 = 不可见）。
(define (layout-normalize l)
  (define rows (max 1 (layout-rows l)))
  (define cols (max 1 (layout-cols l)))
  (define sh (max 0 (min (layout-status-height l) (sub1 rows))))
  (define sw (max 0 (min (layout-sidebar-width l) (sub1 cols))))
  (layout rows cols (and (layout-sidebar? l) #t) sw (and (layout-status? l) #t) sh))

;; 实际生效的宽度/高度（开关关掉即 0）。
(define (tree-width l) (if (layout-sidebar? l) (layout-sidebar-width l) 0))
(define (status-height* l) (if (layout-status? l) (layout-status-height l) 0))

(define (layout-frontend l)
  (define sw (tree-width l))
  (define sh (status-height* l))
  (rect sw 0 (- (layout-cols l) sw) (- (layout-rows l) sh)))

;; 历史名字：main = frontend。
(define (layout-main l) (layout-frontend l))

(define (layout-tree l)
  (define sh (status-height* l))
  (rect 0 0 (tree-width l) (- (layout-rows l) sh)))

(define (layout-status l)
  (define sh (status-height* l))
  (rect 0 (- (layout-rows l) sh) (layout-cols l) sh))

;;; ---------- 通用 pane 视图：几何耦合点 ----------

;; pane id 固定为三者之一；顺序 = 合成顺序（tree/status 叠在 frontend 之上）。
(define pane-ids '(frontend tree status))

(define (layout-pane-ids l)
  (filter (lambda (id) (layout-pane-visible? l id)) pane-ids))

(define (layout-rect l id)
  (case id
    [(frontend) (layout-frontend l)]
    [(tree) (layout-tree l)]
    [(status) (layout-status l)]
    [else (error 'layout-rect "未知 pane id: ~a" id)]))

(define (layout-pane-visible? l id)
  (case id
    [(frontend) #t]
    [(tree) (> (tree-width l) 0)]
    [(status) (> (status-height* l) 0)]
    [else (error 'layout-pane-visible? "未知 pane id: ~a" id)]))

;; 鼠标命中：status 叠在 tree 之上（同列更靠下），故先判 status。
(define (layout-region-at l x y)
  (cond
    [(and (layout-pane-visible? l 'status) (rect-contains? (layout-status l) x y)) 'status]
    [(and (layout-pane-visible? l 'tree) (rect-contains? (layout-tree l) x y)) 'tree]
    [(rect-contains? (layout-frontend l) x y) 'frontend]
    [else #f]))

(define (layout-set-sidebar? l on?)
  (layout-normalize (struct-copy layout l [sidebar? (and on? #t)])))
(define (layout-set-sidebar-width l w)
  (layout-normalize (struct-copy layout l [sidebar-width (inexact->exact (max 0 (truncate w)))])))
(define (layout-set-status? l on?)
  (layout-normalize (struct-copy layout l [status? (and on? #t)])))
(define (layout-set-status-height l h)
  (layout-normalize (struct-copy layout l [status-height (inexact->exact (max 0 (truncate h)))])))

;; 显隐统一入口（window hide，不碰 document）：只改几何开关。
(define (layout-set-visible? l id on?)
  (case id
    [(frontend) l]                       ; 前端恒可见；要「不看文档」请关闭 buffer
    [(tree) (layout-set-sidebar? l on?)]
    [(status) (layout-set-status? l on?)]
    [else (error 'layout-set-visible? "未知 pane id: ~a" id)]))

;;; ---------- 测试 ----------

(module+ test
  (define l (layout-open 24 80 #:sidebar? #t #:sidebar-width 30 #:status-height 1))
  (check-equal? (layout-rows l) 24)
  (check-equal? (layout-cols l) 80)
  (check-equal? (layout-status l) (rect 0 23 80 1))
  (check-equal? (layout-tree l) (rect 0 0 30 23))
  (check-equal? (layout-frontend l) (rect 30 0 50 23))
  (check-equal? (layout-main l) (layout-frontend l))

  ;; 关栏：前端从 0 开始
  (define l0 (layout-set-sidebar? l #f))
  (check-false (layout-sidebar? l0))
  (check-equal? (layout-frontend l0) (rect 0 0 80 23))
  (check-equal? (layout-tree l0) (rect 0 0 0 23))

  ;; 关状态栏：前端变高（window hide，与 document 无关）
  (define l1 (layout-set-status? l #f))
  (check-false (layout-status? l1))
  (check-false (layout-pane-visible? l1 'status))
  (check-equal? (rect-h (layout-frontend l1)) 24)

  ;; 命中
  (check-equal? (layout-region-at l 5 5) 'tree)
  (check-equal? (layout-region-at l 40 5) 'frontend)
  (check-equal? (layout-region-at l 40 23) 'status)
  (check-equal? (layout-region-at l0 5 5) 'frontend)

  ;; 通用 pane 视图
  (check-equal? (layout-pane-ids l) '(frontend tree status))
  (check-equal? (layout-pane-ids l0) '(frontend status))
  (check-equal? (layout-rect l 'frontend) (rect 30 0 50 23))
  (check-equal? (layout-rect l 'tree) (rect 0 0 30 23))
  (check-equal? (layout-rect l 'status) (rect 0 23 80 1))
  (check-true (layout-pane-visible? l 'tree))
  (check-false (layout-pane-visible? l0 'tree))
  (check-equal? (layout-set-visible? l 'tree #f) l0)
  (check-equal? (layout-set-visible? l 'status #f) l1)

  ;; 夹紧：栏不得吃掉全部列，状态栏不得吃掉全部行
  (define ln (layout-open 5 10 #:sidebar-width 999 #:status-height 999))
  (check-equal? (layout-sidebar-width ln) 9)
  (check-equal? (layout-status-height ln) 4)
  (check-equal? (rect-w (layout-frontend ln)) 1)
  (check-equal? (rect-h (layout-frontend ln)) 1)

  ;; 极小屏：1×1 → 状态栏 0 高、栏 0 宽，前端 1×1
  (define l2 (layout-open 1 1 #:sidebar-width 10 #:status-height 10))
  (check-equal? (layout-status-height l2) 0)
  (check-equal? (layout-sidebar-width l2) 0)
  (check-equal? (layout-frontend l2) (rect 0 0 1 1))
  (check-equal? (layout-status l2) (rect 0 1 1 0))

  (displayln "layout.rkt: all tests passed"))
