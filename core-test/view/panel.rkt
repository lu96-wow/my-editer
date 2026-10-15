#lang racket

;;; 由 core/view/panel.rkt 的测试外移而来（core 只留实现）。
(require rackunit
         "../../core/view/panel.rkt"
         "../../core/view/base/rect.rkt")

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

(displayln "core/view/panel.rkt: ok")
