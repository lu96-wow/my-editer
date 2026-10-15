#lang racket

;;; core/edit-tui/layout/float.rkt —— 浮窗层：叠放 / z / 锚点定位，不参与布局。
(require rackunit
         "../../edit-tui/layout/float.rkt"
         "../../core/view/panel.rkt"
         "../../core/view/base/rect.rkt"
         "../../core/editor.rkt")

;; ---------- float 值 / 默认 ----------
(define f (make-float 'completion 'cv (rect 2 1 5 3)))
(check-eq? (float-key f) 'completion)
(check-eq? (float-view f) 'cv)
(check-equal? (float-rect f) (rect 2 1 5 3))
(check-equal? (float-borders f) borders-all)
(check-eq? (float-face f) 'float-border)
(check-equal? (make-float 'x 'v (rect 0 0 3 2) #:borders borders-none #:face 'w)
              (float 'x 'v (rect 0 0 3 2) borders-none 'w))

;; ---------- floats->panels：deep / 顺序 ----------
(define g (make-float 'docs 'dv (rect 3 2 4 2)))
(define ps (floats->panels (list g f)))           ; g 表头 = 最上
(check-equal? (map panel-view ps) '(dv cv))
(check-true (for/and ([p (in-list ps)]) (> (panel-deep p) 0)))   ; 全在平铺(0)之上
(check-true (> (panel-deep (car ps)) (panel-deep (cadr ps))))
(check-equal? (map panel-rect ps) (list (rect 3 2 4 2) (rect 2 1 5 3)))
(check-equal? (map panel-face ps) '(float-border float-border))

;; ---------- 集合操作：同 key 替换并置顶 ----------
(define f* (make-float 'completion 'cv2 (rect 0 0 3 2)))
(define a (floats-add (list g f) f*))             ; 替换 completion，提到表头
(check-equal? (map float-key a) '(completion docs))
(check-eq? (float-view (floats-ref a 'completion)) 'cv2)
(check-equal? (map float-key (floats-remove a 'completion)) '(docs))
(check-false (floats-ref a 'nope))
(check-equal? (floats->panels '()) '())

;; ---------- float-rect-at：下方 / 上翻 / 右夹 / 超大 ----------
(define area (rect 0 0 20 6))
(check-equal? (float-rect-at 0 2 5 3 area) (rect 2 1 5 3))            ; 下方、左对齐
(check-equal? (float-rect-at 5 2 5 3 area) (rect 2 2 5 3))            ; 下方放不下 → 上翻
(check-equal? (float-rect-at 1 18 5 3 area) (rect 15 2 5 3))          ; 右夹
(check-equal? (float-rect-at 0 0 50 50 area) (rect 0 0 20 6))         ; 超大 → 整屏

;; ---------- 与 core 合起来：deep 高 → 命中 / 遮挡浮窗 ----------
(define b (make-buffer "aaaa\nbbbb\ncccc\ndddd"))
(define v (buffer-add-view! b 20 6 #:line-numbers? #f))
(define tile (make-panel v (rect 0 0 20 6) borders-none))
(panels-sync! (list tile))
(define fb (make-buffer "XY\nZ"))
(define fv (buffer-add-view! fb 3 2 #:line-numbers? #f))
(define fl (make-float 'completion fv (rect 2 1 5 3)))   ; 外框 (x2,y1,5x3)
(define all (append (list tile) (floats->panels (list fl))))
(check-eq? (panel-view (panel-at all 2 3)) fv)           ; 命中浮窗，不是 tile
(check-eq? (panel-view (panel-at all 5 0)) v)            ; 浮窗外仍命中 tile
;; 渲染：浮窗在上面（带框）盖住下面的文本
(check-true (regexp-match? #rx"┌" (screen->string (render-display all fv 20 6))))

(displayln "edit-tui/layout/float.rkt: ok")
