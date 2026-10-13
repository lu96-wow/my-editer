#lang racket

;;; edit3-test/layout.rkt —— 求解器 / 几何 / 命中 / 手术（纯函数）
;;; 约定：叶子最小 2 格；相邻子项之间预留 1 格分隔线（不占内容）。

(require rackunit
         racket/list
         "../../edit3/core/state.rkt"
         "../../edit3/core/event.rkt"
         "../../edit3/core/layout.rkt"
         "../../edit3/core/resize.rkt"
         "../../edit3/core/interaction.rkt")

(define (mk axis basis grow shrink child)
  (item basis grow shrink (axis-min child axis) child))
(define (tile* wid) (tile wid 'v (cons 2 2) 'window-border))
(define (g* tl [fs '()] [size (cons 80 10)]) (layout tl fs size))
(define (rect-of g wid)
  (placement-rect (findf (lambda (p) (eqv? wid (placement-wid p))) (geometry-placements g))))

;; ---- 最小尺寸：叶子 2；split 沿轴相加 + 每条缝 1 ----
(check-equal? (call-with-values (lambda () (min-size (tile* 'a))) list) '(2 2))
(check-equal? (call-with-values
               (lambda () (min-size (split 'h (list (mk 'h 1 1 1 (tile* 'a))
                                                    (mk 'h 1 1 1 (tile* 'b))))))
               list) '(5 2))                                     ; 2+2+1
(check-equal? (call-with-values
               (lambda () (min-size (split 'v (list (mk 'v 1 1 1 (tile* 'a))
                                                    (mk 'v 1 1 1 (tile* 'b))))))
               list) '(2 5))
;; 嵌套 h[(v[a b]) c] → 宽 (2)+(2)+1=5，高 max(5,2)=5
(check-equal? (call-with-values
               (lambda () (min-size
                           (split 'h (list (mk 'h 1 1 1 (split 'v (list (mk 'v 1 1 1 (tile* 'a))
                                                                        (mk 'v 1 1 1 (tile* 'b)))))
                                           (mk 'h 1 1 1 (tile* 'c))))))
               list) '(5 5))

;; ---- 叶子最小尺寸是**每叶**属性：编辑窗 2×2、面板 1×1 ----
(check-equal? (call-with-values (lambda () (min-size (editor-tile 'e 'ev 'window-border))) list) '(2 2))
(check-equal? (call-with-values (lambda () (min-size (panel-tile 'p 'pv 'window-border))) list) '(1 1))
;; 竖直 [编辑(min2) | 面板(min1)]：面板可只占 1 行且贴底（最后一个 item 终点 = extent）
(define tp (tiling (split 'v (list (mk 'v 1 1 2 (editor-tile 'a 'av 'window-border))
                                   (mk 'v 1 0 1 (panel-tile 's 'sv 'window-border))))))
(define gp (g* tp '() (cons 10 8)))
(check-equal? (rect-of gp 'a) (rect 0 0 10 6))     ; content 7 = 6 + 缝 1 + 面板 1
(check-equal? (rect-of gp 's) (rect 0 7 10 1))     ; 贴底：y+h = 8 = extent

;; ---- 分配：basis + 剩余按 grow；grow=0 的固定；缝占 1 ----
(define t1 (tiling (split 'h (list (mk 'h 30 1 1 (tile* 'a))
                                   (mk 'h 30 1 1 (tile* 'b))
                                   (mk 'h 28 0 0 (tile* 'c))))))
(define g1 (g* t1 '() (cons 90 10)))                       ; content = 90-2 = 88 = Σbasis
(check-equal? (rect-of g1 'a) (rect 0 0 30 10))
(check-equal? (rect-of g1 'b) (rect 31 0 30 10))           ; 跳过第 30 列的缝
(check-equal? (rect-of g1 'c) (rect 62 0 28 10))
(define g1b (g* t1 '() (cons 110 10)))                     ; content 108，编辑窗 +10
(check-equal? (rect-of g1b 'a) (rect 0 0 40 10))
(check-equal? (rect-of g1b 'b) (rect 41 0 40 10))
(check-equal? (rect-of g1b 'c) (rect 82 0 28 10))

;; ---- 运行时改尺寸：只改相邻 basis，其余精确不动 ----
(define t2 (tiling (split 'h (list (mk 'h 30 1 1 (tile* 'a))
                                   (mk 'h 30 1 1 (tile* 'b))))))
(check-equal? (map (lambda (w) (rect-of (g* t2 '() (cons 81 10)) w)) '(a b))
              (list (rect 0 0 40 10) (rect 41 0 40 10)))   ; content 80 → 40/40
(define t2b (layout-resize-boundary t2 '() 0 6))           ; basis 36/24
(check-equal? (map (lambda (w) (rect-of (g* t2b '() (cons 81 10)) w)) '(a b))
              (list (rect 0 0 46 10) (rect 47 0 34 10)))   ; 精确 +6/-6
(check-equal? (map (lambda (w) (rect-of (g* t2b '() (cons 101 10)) w)) '(a b))
              (list (rect 0 0 56 10) (rect 57 0 44 10)))   ; 容器 resize

;; ---- min 硬约束：basis 离谱也不会 < 2 ----
(define t3 (tiling (split 'h (list (mk 'h -100 1 1 (tile* 'a))
                                   (mk 'h 100 1 1 (tile* 'b))))))
(check-equal? (map (lambda (w) (rect-of (g* t3 '() (cons 81 10)) w)) '(a b))
              (list (rect 0 0 2 10) (rect 3 0 78 10)))
;; extent 连 min+缝 都放不下 → 全取 min（不塌成 0）
(define t4 (tiling (split 'h (list (mk 'h 1 1 1 (tile* 'a))
                                   (mk 'h 1 1 1 (tile* 'b))
                                   (mk 'h 1 1 1 (tile* 'c))))))
(check-equal? (map (lambda (w) (rect-w (rect-of (g* t4 '() (cons 2 10)) w))) '(a b c))
              '(2 2 2))

;; ---- 树手术：split / remove ----
(define ts (layout-split-tile (tiling (tile* 'a)) 'a 'h (tile* 'b) #f))
(check-equal? (node-wids (tiling-root ts)) '(a b))
(define gs (g* ts '() (cons 81 10)))
(check-equal? (rect-of gs 'a) (rect 0 0 40 10))
(check-equal? (rect-of gs 'b) (rect 41 0 40 10))
(check-equal? (node-wids (tiling-root (layout-remove-wid ts 'b))) '(a))
(check-equal? (tiling-root (layout-remove-wid (tiling (tile* 'a)) 'a)) #f)

;; ---- 命中：缝（1 格）命中 handle，窗内容命中 placement ----
(define hb (hit gs 40 5))
(check-true (handle? hb))
(check-equal? (handle-kind hb) 'boundary)
(check-equal? (handle-rect hb) (rect 40 0 1 10))
(check-equal? (handle-data hb) (list 'h '() 0 '(40 40) '(2 2) '(1 1)))
(check-equal? (placement-wid (hit gs 10 5)) 'a)
(check-false (hit gs 200 5))

;; ---- 浮窗：anchor 定位 + z（表头最上）+ move 手柄 ----
(define tf (tiling (tile* 'a)))
(define fs (list (float 'f1 'fv (anchor 'screen 'right 'bottom 2 2) (cons 20 6) 'window-border)
                 (float 'f2 'fv2 (anchor 'screen 'left 'top 0 0) (cons 10 4) 'window-border)))
(define gf (g* tf fs (cons 60 16)))
(check-equal? (rect-of gf 'f1) (rect 40 10 20 6))
(check-equal? (rect-of gf 'f2) (rect 0 0 10 4))
(check-equal? (placement-z (findf (lambda (p) (eqv? 'f1 (placement-wid p))) (geometry-placements gf))) 2)
(check-equal? (placement-z (findf (lambda (p) (eqv? 'f2 (placement-wid p))) (geometry-placements gf))) 1)
(check-true (let ([h (hit gf 40 10)]) (and (handle? h) (eqv? 'f1 (car (handle-data h))))))

;; ---- 浮窗手术：移动 / 缩放（对边不动、最小尺寸） ----
(define scr (rect 0 0 100 20))
(define ff0 (float 'f 'v (anchor 'screen 'left 'top 0 0) (cons 10 4) 'window-border))
(check-equal? (float-anchor (move-float* ff0 3 2)) (anchor 'screen 'left 'top 3 2))
(define ff1 (resize-float* ff0 'se 2 1 scr 100 20))
(check-equal? (float-size ff1) (cons 12 5))
(check-equal? (float-rect scr ff1 100 20) (rect 0 0 12 5))
(define ff2 (resize-float* ff0 'nw 1 1 scr 100 20))
(check-equal? (float-rect scr ff2 100 20) (rect 1 1 9 3))
(define ff3 (float 'f 'v (anchor 'screen 'right 'bottom 0 0) (cons 20 6) 'window-border))
(check-equal? (float-rect scr ff3 100 20) (rect 80 14 20 6))
(define ff4 (resize-float* ff3 'nw 5 2 scr 100 20))
(check-equal? (float-rect scr ff4 100 20) (rect 85 16 15 4))
(define ff5 (resize-float* ff0 'se -100 -100 scr 100 20))
(check-true (and (>= (car (float-size ff5)) 3) (>= (cdr (float-size ff5)) 2)))

;; ---- 交互状态机：拖平铺缝（总位移，不漂） ----
(define ti (tiling (split 'h (list (mk 'h 1 1 1 (tile* 'a)) (mk 'h 1 1 1 (tile* 'b))))))
(define si (make-state #:tiling ti))
(define gi (layout ti '() (cons 81 10)))
(define si1 (pointer-press gi si (cursor-event 'press 'left 40 5)))
(check-true (dragging? (state-drag si1)))
(define si2 (pointer-move gi si1 (cursor-event 'move 'left 46 5)))
(check-equal? (map (lambda (w) (rect-of (layout (state-tiling si2) '() (cons 81 10)) w)) '(a b))
              (list (rect 0 0 46 10) (rect 47 0 34 10)))
(define si2b (pointer-move gi si2 (cursor-event 'move 'left 51 5)))
(check-equal? (map (lambda (w) (rect-of (layout (state-tiling si2b) '() (cons 81 10)) w)) '(a b))
              (list (rect 0 0 51 10) (rect 52 0 29 10)))
(check-true (idle? (state-drag (pointer-release si2 (cursor-event 'release 'left 46 5)))))

;; ---- 交互状态机：浮窗移动 / 角缩放 / 点窗聚焦 ----
(define tfl (tiling (tile* 'a)))
(define ffl (list (float 'f 'fv (anchor 'screen 'left 'top 0 0) (cons 10 4) 'window-border)))
(define sfl (make-state #:tiling tfl #:floats ffl))
(define gfl (layout tfl ffl (cons 80 10)))
(define sm1 (pointer-press gfl sfl (cursor-event 'press 'left 5 2)))
(check-true (dragging? (state-drag sm1)))
(define sm2 (pointer-move gfl sm1 (cursor-event 'move 'left 8 4)))
(check-equal? (float-anchor (car (state-floats sm2))) (anchor 'screen 'left 'top 3 2))
(define sm3 (pointer-press gfl sfl (cursor-event 'press 'left 9 3)))
(check-true (dragging? (state-drag sm3)))
(define sm4 (pointer-move gfl sm3 (cursor-event 'move 'left 11 5)))
(check-equal? (float-size (car (state-floats sm4))) (cons 12 6))
(check-equal? (state-focus (pointer-press gfl sfl (cursor-event 'press 'left 60 5))) 'a)

;; ---- 十字路口 junction：一次拖拽同时改横、竖两条缝 ----
;; 2×2：root h-split，两列为 v-split；交点格 (row 5, col 10)
(define (grid-h)
  (tiling (split 'h (list (mk 'h 8 1 1 (split 'v (list (mk 'v 5 1 1 (tile* 'tl))
                                                        (mk 'v 5 1 1 (tile* 'bl)))))
                       (mk 'h 8 1 1 (split 'v (list (mk 'v 5 1 1 (tile* 'tr))
                                                        (mk 'v 5 1 1 (tile* 'br)))))))))
(define g2x2 (g* (grid-h) '() (cons 21 11)))
(define hj (hit g2x2 10 5))
(check-true (handle? hj))
(check-equal? (handle-kind hj) 'junction)

(define sj0 (make-state #:tiling (grid-h)))
(define sj1 (pointer-move g2x2 (pointer-press g2x2 sj0 (cursor-event 'press 'left 10 5))
                          (cursor-event 'move 'left 12 6)))
(define gj1 (layout (state-tiling sj1) '() (cons 21 11)))
(check-equal? (rect-of gj1 'tl) (rect 0 0 12 6))     ; 竖缝 +2、横缝 +1 同步
(check-equal? (rect-of gj1 'tr) (rect 13 0 8 6))
(check-equal? (rect-of gj1 'bl) (rect 0 7 12 4))
(check-equal? (rect-of gj1 'br) (rect 13 7 8 4))
;; 拖过头：两方向各自被 min 夹住（不会有一段越过 min）
(define sj2 (pointer-move g2x2 (pointer-press g2x2 sj0 (cursor-event 'press 'left 10 5))
                          (cursor-event 'move 'left -100 -100)))
(check-equal? (rect-of (layout (state-tiling sj2) '() (cons 21 11)) 'tl) (rect 0 0 2 2))

;; 反向嵌套（root v-split，两条竖缝各自成段）也能生成 junction 并一起移动
(define (grid-v)
  (tiling (split 'v (list (mk 'v 5 1 1 (split 'h (list (mk 'h 8 1 1 (tile* 'tl))
                                                        (mk 'h 8 1 1 (tile* 'tr)))))
                       (mk 'v 5 1 1 (split 'h (list (mk 'h 8 1 1 (tile* 'bl))
                                                        (mk 'h 8 1 1 (tile* 'br)))))))))
(define g2v (g* (grid-v) '() (cons 21 11)))
(check-equal? (handle-kind (hit g2v 10 5)) 'junction)
(define sv (pointer-move g2v (pointer-press g2v (make-state #:tiling (grid-v))
                                            (cursor-event 'press 'left 10 5))
                         (cursor-event 'move 'left 8 5)))
(check-equal? (rect-of (layout (state-tiling sv) '() (cons 21 11)) 'tl) (rect 0 0 8 5))
(check-equal? (rect-of (layout (state-tiling sv) '() (cons 21 11)) 'tr) (rect 9 0 12 5))

;; 多列：拖交点的纵向位移让**整条**横线一起动（不留台阶）
(define (grid3)
  (tiling (split 'h (list (mk 'h 6 1 1 (split 'v (list (mk 'v 5 1 1 (tile* 'a0)) (mk 'v 5 1 1 (tile* 'b0)))))
                       (mk 'h 6 1 1 (split 'v (list (mk 'v 5 1 1 (tile* 'a1)) (mk 'v 5 1 1 (tile* 'b1)))))
                       (mk 'h 6 1 1 (split 'v (list (mk 'v 5 1 1 (tile* 'a2)) (mk 'v 5 1 1 (tile* 'b2)))))))))
(define g3 (g* (grid3) '() (cons 23 11)))
(check-equal? (handle-kind (hit g3 7 5)) 'junction)
(define s3 (pointer-move g3 (pointer-press g3 (make-state #:tiling (grid3))
                                            (cursor-event 'press 'left 7 5))
                         (cursor-event 'move 'left 7 6)))
(define g3b (layout (state-tiling s3) '() (cons 23 11)))
(check-equal? (map (lambda (w) (rect-of g3b w)) '(a0 a1 a2))
              (list (rect 0 0 7 6) (rect 8 0 7 6) (rect 16 0 7 6)))
(check-equal? (map (lambda (w) (rect-of g3b w)) '(b0 b1 b2))
              (list (rect 0 7 7 4) (rect 8 7 7 4) (rect 16 7 7 4)))

;; T 字路口（三窗）：有竖臂 + 横臂 → 也生成 junction，可同时拖横、竖线
(define tT (tiling (split 'v (list (mk 'v 5 1 1 (split 'h (list (mk 'h 5 1 1 (tile* 'a))
                                                               (mk 'h 5 1 1 (tile* 'b)))))
                                (mk 'v 5 1 1 (tile* 'c))))))
(check-equal? (handle-kind (hit (layout tT '() (cons 21 11)) 10 5)) 'junction)
(define sT (pointer-move (layout tT '() (cons 21 11))
                         (pointer-press (layout tT '() (cons 21 11)) (make-state #:tiling tT)
                                        (cursor-event 'press 'left 10 5))
                         (cursor-event 'move 'left 12 6)))
(define gT (layout (state-tiling sT) '() (cons 21 11)))
(check-equal? (rect-of gT 'a) (rect 0 0 12 6))    ; 竖线 +2、横线 +1 同拖
(check-equal? (rect-of gT 'b) (rect 13 0 8 6))
(check-equal? (rect-of gT 'c) (rect 0 7 21 4))

;; 纯缝（非路口）仍是 boundary：两列之间的竖缝，无横臂
(define tPlain (tiling (split 'h (list (mk 'h 10 1 1 (tile* 'a))
                                      (mk 'h 10 1 1 (tile* 'b))))))
(check-equal? (handle-kind (hit (layout tPlain '() (cons 21 11)) 10 5)) 'boundary)

(displayln "edit3/layout.rkt: all tests passed")
