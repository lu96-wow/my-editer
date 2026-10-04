#lang racket

(require "../../../core/editor.rkt"
         (except-in racket/list range)
         "area.rkt"
         "split.rkt")

;;; lab/base/layout/main.rkt —— 窗口布局（骨架）
;;;
;;; 把窗口切成三块区域 + 主区按分裂树铺窗格：
;;;
;;;   left       左侧面板（文件树 / 文档列表），整高，可隐藏（**预定义**）
;;;   main       主编辑区，按 split 树铺
;;;   statusbar  底部一条（状态 / 将来的输入行），主区下方（**预定义**）
;;;
;;; 左栏与底部条的尺寸 / 位置是预定义的，不进 split 树；split 树只铺主区。
;;;
;;; 全是纯函数：不碰 editor、不持状态、不认识焦点语义（焦点移动只在几何上找邻居）。
;;;
;;; 设计待定：
;;;   - pane-dir 的邻居度量（中心曼哈顿距离）是否是你想要的（尤其非对齐格）。

(provide (all-from-out "area.rkt")
         (all-from-out "split.rkt")
         (struct-out regions)
         (struct-out layout-result)
         compute-regions compute-layout
         default-sidebar-width default-statusbar-height
         pane-at pane-vid-at bar-at region-at
         layout-vid-at layout-bar-at layout-region-at layout-hit-at
         pane-dir pane-left pane-right pane-up pane-down
         layout-dir layout-left layout-right layout-up layout-down)

;;; ================= 区域 =================

(define default-sidebar-width 24)
(define default-statusbar-height 1)

(struct regions (left main statusbar) #:transparent)
;; left / statusbar : area（可挂 vid，也可纯预留）
;; main            : area，主编辑区

(define (compute-regions width height
                         #:sidebar? [sidebar? #t]
                         #:sidebar-width [sidebar-width default-sidebar-width]
                         #:statusbar-height [statusbar-height default-statusbar-height])
  (define sw (if sidebar? sidebar-width 0))
  (define st statusbar-height)
  (define main-w (max 0 (- width sw)))
  (define main-h (max 0 (- height st)))
  (regions (area 0 0 sw height)
           (area sw 0 main-w main-h)
           (area sw main-h main-w st)))

(struct layout-result (regions panes bars warnings) #:transparent)
;; panes    : (listof rectangle)，view-id = 落到的 vid
;; bars     : (listof bar)，分割条（主区）
;; warnings : (listof size-warning)，空间不足提示

(define (compute-layout tree width height
                        #:sidebar? [sidebar? #t]
                        #:sidebar-width [sidebar-width default-sidebar-width]
                        #:statusbar-height [statusbar-height default-statusbar-height]
                        #:left-vid [left-vid #f]
                        #:bottom-vid [bottom-vid #f])
  ;; tree = #f：主区暂时没有窗格（例如还没打开任何文档）。
  (define rs (compute-regions width height
                              #:sidebar? sidebar?
                              #:sidebar-width sidebar-width
                              #:statusbar-height statusbar-height))
  (define-values (mains bars warnings)
    (if tree
        (tree->rectangles tree (regions-main rs))
        (values '() '() '())))
  (define left (regions-left rs))
  (define bottom (regions-statusbar rs))
  (layout-result
   rs
   (append
    (if (and left-vid (positive? (area-width left)) (positive? (area-height left)))
        (list (rectangle left-vid (area-x left) (area-y left)
                         (area-width left) (area-height left) 0))
        '())
    mains
    (if (and bottom-vid (positive? (area-width bottom)) (positive? (area-height bottom)))
        (list (rectangle bottom-vid (area-x bottom) (area-y bottom)
                         (area-width bottom) (area-height bottom) 0))
        '()))
   bars
   warnings))

;;; ================= 坐标 → 部分 =================

;; 点在哪个编辑窗格。x = 屏幕列，y = 屏幕行；矩形右 / 下边界为开区间。
(define (pane-at panes x y)
  (for/first ([r (in-list panes)]
              #:when (and (>= x (rectangle-x r)) (< x (+ (rectangle-x r) (rectangle-width r)))
                          (>= y (rectangle-y r)) (< y (+ (rectangle-y r) (rectangle-height r)))))
    r))

(define (pane-vid-at panes x y)
  (define r (pane-at panes x y))
  (and r (rectangle-view-id r)))

;; 点在哪个分割条（分割条也是矩形）。
(define (bar-at bars x y)
  (for/first ([b (in-list bars)]
              #:when (and (>= x (bar-x b)) (< x (+ (bar-x b) (bar-width b)))
                          (>= y (bar-y b)) (< y (+ (bar-y b) (bar-height b)))))
    b))

;; 点在哪个区域：'left / 'main / 'statusbar / #f。
(define (region-at rs x y)
  (cond [(area-contains? (regions-left rs) y x) 'left]
        [(area-contains? (regions-statusbar rs) y x) 'statusbar]
        [(area-contains? (regions-main rs) y x) 'main]
        [else #f]))

(define (layout-vid-at result x y) (pane-vid-at (layout-result-panes result) x y))
(define (layout-bar-at result x y) (bar-at (layout-result-bars result) x y))
(define (layout-region-at result x y) (region-at (layout-result-regions result) x y))

;; 一步到位：编辑窗格 → vid；分割条 → bar；预留区 → 'left / 'statusbar / 'main；外部 → #f。
(define (layout-hit-at result x y)
  (or (layout-vid-at result x y) (layout-bar-at result x y)
      (layout-region-at result x y)))

;;; ================= 方向移动焦点（纯几何） =================

(define (rect-right r) (+ (rectangle-x r) (rectangle-width r)))
(define (rect-bottom r) (+ (rectangle-y r) (rectangle-height r)))
(define (rect-cx r) (+ (rectangle-x r) (quotient (rectangle-width r) 2)))
(define (rect-cy r) (+ (rectangle-y r) (quotient (rectangle-height r) 2)))

(define (v-overlap? r0 r1) (and (< (rectangle-y r0) (rect-bottom r1))
                                (< (rectangle-y r1) (rect-bottom r0))))
(define (h-overlap? r0 r1) (and (< (rectangle-x r0) (rect-right r1))
                                (< (rectangle-x r1) (rect-right r0))))

;; panes : (listof rectangle)；dir : 'left | 'right | 'up | 'down
(define (pane-dir panes vid dir)
  (define cur (for/first ([r (in-list panes)] #:when (eqv? (rectangle-view-id r) vid)) r))
  (and cur
       (let ([cx (rect-cx cur)] [cy (rect-cy cur)])
         (define cands
           (for/list ([r (in-list panes)]
                      #:unless (eqv? (rectangle-view-id r) vid)
                      #:when (case dir
                               [(left)  (and (< (rect-cx r) cx) (v-overlap? cur r))]
                               [(right) (and (> (rect-cx r) cx) (v-overlap? cur r))]
                               [(up)    (and (< (rect-cy r) cy) (h-overlap? cur r))]
                               [(down)  (and (> (rect-cy r) cy) (h-overlap? cur r))]
                               [else (error 'pane-dir "dir 必须是 left/right/up/down，得到 ~a" dir)]))
             r))
         (and (pair? cands)
              (rectangle-view-id
               (argmin (lambda (r) (+ (abs (- (rect-cx r) cx)) (abs (- (rect-cy r) cy))))
                       cands))))))

(define (pane-left  panes vid) (pane-dir panes vid 'left))
(define (pane-right panes vid) (pane-dir panes vid 'right))
(define (pane-up    panes vid) (pane-dir panes vid 'up))
(define (pane-down  panes vid) (pane-dir panes vid 'down))

(define (layout-dir   result vid dir) (pane-dir (layout-result-panes result) vid dir))
(define (layout-left  result vid) (layout-dir result vid 'left))
(define (layout-right result vid) (layout-dir result vid 'right))
(define (layout-up    result vid) (layout-dir result vid 'up))
(define (layout-down  result vid) (layout-dir result vid 'down))
