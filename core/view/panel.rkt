#lang racket

;;; core/view/panel.rkt —— 面板：外框矩形 + 四条边可选边框 + 深度 + 边框 face + 边框权重 + 内容区
;;;
;;; panel 是**值**（每帧的显示项）：view + 外框 rect + 存在的边 + deep + 边框 face + 边框权重。
;;;   view    : 显示槽（可替换，换 view = 造一个新 panel 值）| #f（空面板，无内容）
;;;   rect    : 外框矩形（尺寸真相在这里）
;;;   borders : 存在的边（每边可选）；不存在的那条边，内容顶到外框
;;;   deep    : 越大越在上；浮窗 = deep 高的 panel（决定内容遮挡 / 命中）
;;;   face    : 边框 face（#f | symbol | face），宿主设；core 不解释颜色
;;;   weight  : 边框 face 权重。deep 相同时，大的边框格赢（焦点框抬边框用）；
;;;             不影响 deep 比较，也不影响内容 / 命中。默认 0。
;;;
;;; 内容区 = 外框按存在的边各内缩 1。view 的 viewport 尺寸由 editor/sync.rkt 的
;;; panels-sync! 从 panel-content 落进去 —— 渲染保持纯，绝不 resize。
;;;
;;; 身份不在这里（view 可替换，不能拿 view 当身份）：命中 / 布局树在 core 外，
;;; 宿主自己用 id / owner 记「这是哪块面板」。render-display 只吃值。

(require "base/rect.rkt")

(provide (struct-out panel)
         make-panel empty-panel panel-empty?
         borders-all borders-none
         panel-content
         panel-at
         panel-at-all
         panel-move
         panel-neighbor
         panel-depth-neighbor
         panel-screen->content
         panel-content->screen)

(struct panel (view rect borders deep face weight) #:transparent)

;; 便捷构造（关键字）。face 缺省 'window-border；weight 缺省 0。
(define (make-panel view rect borders
                    #:deep [deep 0] #:face [face 'window-border] #:weight [weight 0])
  (panel view rect borders deep face weight))

;; 空面板：没有 view（view = #f）→ 没有内容，只有几何 + 边框。
;; 命中 / 导航 / 边框照常；内容路径（sync / 渲染）会跳过它（透明）。
(define (empty-panel rect borders
                     #:deep [deep 0] #:face [face 'window-border] #:weight [weight 0])
  (panel #f rect borders deep face weight))

(define (panel-empty? p) (not (panel-view p)))

(define borders-all  '(up down left right))
(define borders-none '())

;; 内容区：外框按存在的边内缩 1。
(define (panel-content p)
  (define b (panel-borders p))
  (rect-inset-sides (panel-rect p)
                    (if (memq 'up b)    1 0)
                    (if (memq 'right b) 1 0)
                    (if (memq 'down b)  1 0)
                    (if (memq 'left b)  1 0)))

;;; ---------- 命中 ----------

;; 覆盖屏幕格 (row, col) 的 panel：deep 最大者胜；同 deep 列表靠后者胜；都无 → #f。
;; 与边框遮挡同一套规则（见 border.rkt）：渲染吃的 panels，就是这里查的 panels。
;; rect 是 (x=列, y=行)；这里按屏幕坐标收参，方便鼠标直接换算（x→col, y→row）。
(define (panel-at panels row col)
  (for/fold ([best #f]) ([p (in-list panels)])
    (if (and (rect-contains? (panel-rect p) col row)
             (or (not best) (>= (panel-deep p) (panel-deep best))))
        p
        best)))

;; 覆盖屏幕格 (row, col) 的**所有** panel，按从上到下排序（deep 降；同 deep 列表靠后在前）。
;; 无 → '()。首个元素 = panel-at 的结果（同一套规则）。
(define (panel-at-all panels row col)
  (define hits
    (for/list ([p (in-list panels)] [i (in-naturals)]
               #:when (rect-contains? (panel-rect p) col row))
      (cons i p)))
  (map cdr
       (sort hits (λ (a b)
                    (define pa (cdr a)) (define pb (cdr b))
                    (cond [(> (panel-deep pa) (panel-deep pb)) #t]
                          [(< (panel-deep pa) (panel-deep pb)) #f]
                          [else (> (car a) (car b))])))))

;;; ---------- 坐标（纯几何）----------
;;
;; 屏幕坐标 ↔ 面板内容内坐标。视图尺寸就是内容区尺寸（panels-sync! 保证），
;; 所以“内容内坐标”就是 view 内屏幕坐标 —— 鼠标 / 光标定位靠这两个纯平移。

;; 屏幕格 (row, col) → 内容内 (row, col)。
(define (panel-screen->content p row col)
  (define c (panel-content p))
  (values (- row (rect-y c)) (- col (rect-x c))))

;; 内容内 (row, col) → 屏幕格 (row, col)（上式的逆）。
(define (panel-content->screen p row col)
  (define c (panel-content p))
  (values (+ row (rect-y c)) (+ col (rect-x c))))

;;; ---------- 方向导航 ----------

;; dir 方向、**与 from 同层（deep 相同）**、且垂直轴有重叠的 panel 里，取最近的；无 → #f。
;; 只在同层平铺里走（deep 不参与排名）；跨层用 panel-depth-neighbor。dir ∈ 'up 'down 'left 'right。
;; 一遍线性扫描：候选逐个与当前 best 比（不建表、不排序），全等保持靠前者（确定性）。
;; 比较键：沿轴间隙 → 重叠更长 → 中心更近。
(define (panel-neighbor panels from dir)
  (define r (panel-rect from))
  (define d (panel-deep from))
  (for/fold ([best #f]) ([p (in-list panels)])
    (cond
      [(or (eq? p from)
           (not (= (panel-deep p) d))
           (not (beyond? dir r (panel-rect p)))
           (not (cross-overlap? dir r (panel-rect p))))
       best]
      [(not best) p]
      [(nearer? dir r (panel-rect p) (panel-rect best)) p]
      [else best])))

;; r2 在 r 的 dir 一侧（允许相接 / 共享 1 格接缝：边框重叠是 1 格）。
(define (beyond? dir r r2)
  (case dir
    [(left)  (<= (rect-right r2) (add1 (rect-x r)))]
    [(right) (>= (rect-x r2) (sub1 (rect-right r)))]
    [(up)    (<= (rect-bottom r2) (add1 (rect-y r)))]
    [(down)  (>= (rect-y r2) (sub1 (rect-bottom r)))]
    [else (error 'panel-neighbor "方向要是 'up/'down/'left/'right：~a" dir)]))

;; 垂直轴上是否重叠（半开区间，正长度）。
(define (cross-overlap? dir r r2)
  (case dir
    [(left right) (< (max (rect-y r) (rect-y r2)) (min (rect-bottom r) (rect-bottom r2)))]
    [(up down)    (< (max (rect-x r) (rect-x r2)) (min (rect-right r) (rect-right r2)))]))

;; 沿轴间隙（beyond? 保证 ≥ 0）。
(define (axis-gap dir r r2)
  (case dir
    [(left)  (- (rect-x r) (rect-right r2))]
    [(right) (- (rect-x r2) (rect-right r))]
    [(up)    (- (rect-y r) (rect-bottom r2))]
    [(down)  (- (rect-y r2) (rect-bottom r))]))

;; 垂直轴上的重叠长度。
(define (axis-overlap dir r r2)
  (case dir
    [(left right) (- (min (rect-bottom r) (rect-bottom r2)) (max (rect-y r) (rect-y r2)))]
    [(up down)    (- (min (rect-right r) (rect-right r2)) (max (rect-x r) (rect-x r2)))]))

;; 垂直轴上中心距离。
(define (axis-center-dist dir r r2)
  (case dir
    [(left right) (abs (- (+ (rect-y r) (quotient (rect-h r) 2))
                          (+ (rect-y r2) (quotient (rect-h r2) 2))))]
    [(up down)    (abs (- (+ (rect-x r) (quotient (rect-w r) 2))
                          (+ (rect-x r2) (quotient (rect-w r2) 2))))]))

;; a 比 b 更该选？全等 → #f（靠 sort 稳定性保持列表序）。
(define (nearer? dir r a b)
  (define ga (axis-gap dir r a)) (define gb (axis-gap dir r b))
  (cond [(< ga gb) #t] [(> ga gb) #f]
        [else
         (define oa (axis-overlap dir r a)) (define ob (axis-overlap dir r b))
         (cond [(> oa ob) #t] [(< oa ob) #f]
               [else
                (define ca (axis-center-dist dir r a)) (define cb (axis-center-dist dir r b))
                (cond [(< ca cb) #t] [else #f])])]))

;;; ---------- 深度前后 ----------

;; 跨层：toward='front（deep 更大）/ 'back（deep 更小）的 panel 里，按距离取最近的；无 → #f。
;; 一遍线性扫描；“距离” = 两矩形间隙（相交 = 0），同距取层差最小（逐层步进），全等保持靠前者。
(define (panel-depth-neighbor panels from toward)
  (define r (panel-rect from))
  (define d (panel-deep from))
  (define (in-depth? p)
    (case toward
      [(front) (> (panel-deep p) d)]
      [(back)  (< (panel-deep p) d)]
      [else (error 'panel-depth-neighbor "toward 要是 'front 或 'back：~a" toward)]))
  (define (nearer? p q)                       ; p 比 q（当前 best）更该选？
    (define gp (rect-gap r (panel-rect p)))
    (define gq (rect-gap r (panel-rect q)))
    (cond [(< gp gq) #t] [(> gp gq) #f]
          [else (< (abs (- (panel-deep p) d))
                   (abs (- (panel-deep q) d)))]))
  (for/fold ([best #f]) ([p (in-list panels)])
    (cond [(or (eq? p from) (not (in-depth? p))) best]
          [(not best) p]
          [(nearer? p best) p]
          [else best])))

;; 两矩形间隙（相交 / 相切 = 0）；Manhattan（x 间隙 + y 间隙）。
(define (rect-gap r r2)
  (define dx (max 0 (max (- (rect-x r) (rect-right r2))
                         (- (rect-x r2) (rect-right r)))))
  (define dy (max 0 (max (- (rect-y r) (rect-bottom r2))
                         (- (rect-y r2) (rect-bottom r)))))
  (+ dx dy))

;;; ---------- 六向入口 ----------

;; 六向移动：left/right/up/down = 同层平铺（panel-neighbor）；
;;            front/back        = 跨层前后（panel-depth-neighbor）。
;; 无目标 → #f。这是给键绑定用的单入口。
(define (panel-move panels from dir)
  (case dir
    [(left right up down) (panel-neighbor panels from dir)]
    [(front back)         (panel-depth-neighbor panels from dir)]
    [else (error 'panel-move
                 "方向要是 'left/'right/'up/'down/'front/'back：~a" dir)]))

(module+ test
  (require rackunit)
  (define (mk owner x y w h #:deep [d 0]) (make-panel owner (rect x y w h) borders-all #:deep d))
  (define lo (mk 'lo 0 0 10 10))
  (define hi (mk 'hi 2 2 4 4 #:deep 5))
  (define ps (list lo hi))

  ;; 命中 / 落空
  (check-eq? (panel-at ps 0 0) lo)
  (check-eq? (panel-at ps 3 3) hi)          ; 高 deep 浮窗盖住
  (check-eq? (panel-at ps 9 9) lo)
  (check-false (panel-at ps 10 0))          ; 右边界开
  (check-false (panel-at ps 0 10))

  ;; weight 是边框 face 权重：同 deep 时大者边框赢，且不影响命中
  (define wa (make-panel 'a (rect 0 0 10 6) borders-all #:face 'a-face #:weight 0))
  (define wb (make-panel 'b (rect 9 0 10 6) borders-all #:face 'b-face #:weight 1))
  (check-equal? (panel-weight wb) 1)
  (check-eq? (panel-at (list wb wa) 1 9) wa)      ; 命中按 deep/列表序，weight 不参与

  ;; 同 deep：列表靠后者胜
  (define a (mk 'a 0 0 5 5))
  (define b (mk 'b 0 0 5 5))
  (check-eq? (panel-at (list a b) 1 1) b)
  (check-eq? (panel-at (list b a) 1 1) a)

  ;; 零尺寸 / 空表
  (check-false (panel-at (list (make-panel 'z (rect 0 0 0 0) borders-none)) 0 0))
  (check-false (panel-at '() 0 0))

  ;; 空面板：view = #f，几何 / 命中 / 内容区照常
  (define pe (empty-panel (rect 2 1 8 4) borders-all))
  (check-true (panel-empty? pe))
  (check-false (panel-view pe))
  (check-eq? (panel-at (list pe) 2 3) pe)
  (check-equal? (let ([c (panel-content pe)]) (list (rect-x c) (rect-y c) (rect-w c) (rect-h c)))
                '(3 2 6 2))                    ; 有边框 → 各内缩 1

  ;; panel-at-all：覆盖点的所有 panel，上→下
  (check-equal? (panel-at-all ps 3 3) (list hi lo))       ; deep 5 在 deep 0 上
  (check-equal? (panel-at-all ps 0 0) (list lo))
  (check-equal? (panel-at-all ps 100 100) '())
  (check-equal? (car (panel-at-all ps 3 3)) (panel-at ps 3 3))   ; 首个 = panel-at
  ;; 同 deep：列表靠后者在前
  (check-equal? (panel-at-all (list a b) 1 1) (list b a))

  ;; 坐标平移：内容原点 = 外框 + 有边框的边各 1
  (define pc (make-panel 'v (rect 5 2 10 4) borders-all))
  (check-equal? (call-with-values (λ () (panel-screen->content pc 3 6)) list) '(0 0))
  (check-equal? (call-with-values (λ () (panel-content->screen pc 0 0)) list) '(3 6))
  ;; 往返
  (check-equal? (call-with-values (λ () (panel-content->screen pc 2 4)) list) '(5 10))
  (check-equal? (call-with-values (λ () (panel-screen->content pc 5 10)) list) '(2 4))
  ;; 无边框：内容原点 = 外框原点
  (define pn (make-panel 'v (rect 5 2 10 4) borders-none))
  (check-equal? (call-with-values (λ () (panel-screen->content pn 2 5)) list) '(0 0))

  ;; 方向导航：2×2 平铺
  (define ga (make-panel 'ga (rect 0 0 10 10) borders-none))   ; 左上
  (define gb (make-panel 'gb (rect 10 0 10 10) borders-none))  ; 右上
  (define gc (make-panel 'gc (rect 0 10 10 10) borders-none))  ; 左下
  (define gd (make-panel 'gd (rect 10 10 10 10) borders-none)) ; 右下
  (define grid (list ga gb gc gd))
  (check-eq? (panel-neighbor grid ga 'right) gb)
  (check-eq? (panel-neighbor grid ga 'down) gc)
  (check-eq? (panel-neighbor grid gb 'left) ga)
  (check-eq? (panel-neighbor grid gb 'down) gd)
  (check-eq? (panel-neighbor grid gc 'right) gd)
  (check-eq? (panel-neighbor grid gd 'up) gb)
  (check-false (panel-neighbor grid ga 'left))
  (check-false (panel-neighbor grid ga 'up))

  ;; 垂直轴无重叠 → 不算候选
  (define far (make-panel 'far (rect 20 20 5 5) borders-none))
  (check-false (panel-neighbor (list ga far) ga 'right))

  ;; 先看间隙：近的胜，哪怕对齐差
  (define near (make-panel 'near (rect 10 5 5 2) borders-none))   ; 间隙 0
  (define far2 (make-panel 'far2 (rect 12 0 5 10) borders-none))  ; 间隙 2，对齐好
  (check-eq? (panel-neighbor (list ga near far2) ga 'right) near)

  ;; 间隙同 → 重叠更长者胜
  (define o4 (make-panel 'o4 (rect 10 0 5 4) borders-none))
  (define o3 (make-panel 'o3 (rect 10 0 5 3) borders-none))
  (check-eq? (panel-neighbor (list ga o3 o4) ga 'right) o4)

  ;; 方向导航只看同层：高 deep 浮窗不参与
  (define float1 (mk 'f1 2 2 6 6 #:deep 5))
  (check-eq? (panel-neighbor (list ga gb float1) ga 'right) gb)
  ;; 浮窗层自己的方向导航
  (define float2 (mk 'f2 12 2 6 6 #:deep 5))
  (check-eq? (panel-neighbor (list float1 float2) float1 'right) float2)
  (check-false (panel-neighbor (list float1) float1 'right))

  ;; 深度前后：先矩形距离，再层差（逐层步进）
  (define f5    (mk 'f5  2 2 6 6 #:deep 5))    ; 与 ga 相交
  (define f9    (mk 'f9  2 2 6 6 #:deep 9))    ; 与 ga 相交
  (define f5far (mk 'f5far 30 30 5 5 #:deep 5)) ; 离得远
  (check-eq? (panel-depth-neighbor (list ga f5 f9 f5far) ga 'front) f5) ; 相交优先于远
  (check-eq? (panel-depth-neighbor (list ga f5 f9) f9 'back) f5)        ; 层差最小
  (check-eq? (panel-depth-neighbor (list ga f5 f9) f5 'back) ga)
  (check-false (panel-depth-neighbor (list ga f5) f5 'front))            ; 无更上层
  (check-false (panel-depth-neighbor (list ga f5) ga 'back))            ; 无更下层

  ;; 六向入口
  (check-eq? (panel-move (list ga gb float1) ga 'right) gb)   ; 同层
  (check-eq? (panel-move (list ga float1) ga 'front) float1)  ; 跨层
  (check-eq? (panel-move (list ga f5 f9) f9 'back) f5)
  (check-false (panel-move (list ga) ga 'up))
  (check-exn exn:fail? (λ () (panel-move (list ga) ga 'sideways)))

  ;; 不能跨层：该方向只剩不同层 → left/right/up/down 返回 #f（不选浮窗）
  (define fRight (mk 'fRight 12 2 6 6 #:deep 5))   ; 在 ga 正右，但不同层
  (check-false (panel-move (list ga fRight) ga 'right))
  (check-eq? (panel-move (list ga fRight) ga 'front) fRight)  ; 同一块，只有 front 能到

  (displayln "panel.rkt: ok"))