#lang racket

;;; 由 core/editor/render.rkt 的测试外移而来（core 只留实现）。
;;; 需要 render.rkt 的缓存内部字段（render-cache-layout / render-cache-content /
;;; content-entry-data）来验证「布局 / 内容层复用」，这些访问器随 render-cache
;;; 一并 provide，但不经 editor.rkt 使用层再导出。
(require rackunit
         "../../core/editor.rkt"
         "../../core/editor/render.rkt")

(define b (make-buffer "hi\nthere\n"))
(define v (buffer-add-view! b))
(define p  (make-panel v (rect 0 0 10 5) borders-all))
(define ps (list p))
(panels-sync! ps)

(define (content-data c) (content-entry-data (hash-ref (render-cache-content c) v)))

(define-values (c1 a1 b1) (render-display-patch ps v 12 6 #f))
(define-values (c2 a2 b2) (render-display-patch ps v 12 6 c1))
(check-true (eq? (render-cache-layout c1) (render-cache-layout c2)))
(check-true (eq? (content-data c1) (content-data c2)))
(check-equal? (length a2) 0)          ; 无变化 → 空差量
(check-equal? (length b2) 0)

(define p2 (make-panel v (rect 1 0 10 5) borders-all))
(define-values (c3 a3 b3) (render-display-patch (list p2) v 12 6 c2))
(check-false (eq? (render-cache-layout c2) (render-cache-layout c3)))

;; 内容变：layout 复用，内容重算，只 patch 变化行
(void (buffer-edit! b v (op-type "X")))
(define-values (c4 r4 b4) (render-display-patch (list p2) v 12 6 c3))
(check-true (eq? (render-cache-layout c3) (render-cache-layout c4)))
(check-false (eq? (content-data c3) (content-data c4)))
(check-true (> (length r4) 0))

;; 只动光标：内容层复用（文本重渲跳过）；diff 只涉及 overlay 行
(define p3 (make-panel v (rect 1 0 10 5) borders-all))
(view-set-point! v (point 1 0))          ; 移到另一行（插入后光标在 (0 1)）
(define-values (c5 r5 s5) (render-display-patch (list p3) v 12 6 c4))
(check-true (eq? (content-data c4) (content-data c5)))
(check-true (> (+ (length r5) (length s5)) 0))   ; 旧光标格回文本 + 新光标格

;; 脏区不改变画面：与全量一致
(define full (render-display (list p3) v 12 6))
(check-equal? (screen->string (render-cache-screen c5)) (screen->string full))

;; 定位（单焦点）：panel 几何位置 == 合成屏主光标位置 == 可见位置
(define scr5 (render-cache-screen c5))
(define-values (cr cc) (panel-cursor-position p3))
(define pc (screen-primary-cursor scr5))
(check-equal? (list cr cc) (list (cursor-row pc) (cursor-column pc)))
(check-equal? (call-with-values (λ () (panel-cursor-position/visible scr5 p3)) list)
              (list cr cc))

;; 边框 weight 变化 → panels 值变了 → 必须重算布局（不能复用旧 border-runs）
(define pw (make-panel v (rect 0 0 10 5) borders-all #:weight 1))
(define-values (c6 r6 b6) (render-display-patch (list pw) v 12 6 c5))
(check-false (eq? (render-cache-layout c5) (render-cache-layout c6)))

;; 空面板：渲染不崩；只有边框，内部透明
(define pe (empty-panel (rect 0 0 8 4) borders-all))
(check-true (regexp-match? #rx"┌" (screen->string (render-display (list pe) #f 8 4))))
(check-equal? (call-with-values (λ () (panel-cursor-position pe)) list) '(#f #f))
;; 空面板的增量：无变化 → 空差量，且屏幕一致
(define-values (ce _r _s) (render-display-patch (list pe) #f 8 4 #f))
(define-values (ce2 dr ds) (render-display-patch (list pe) #f 8 4 ce))
(check-equal? (length dr) 0)
(check-equal? (length ds) 0)
(check-equal? (screen->string (render-cache-screen ce2))
              (screen->string (render-display (list pe) #f 8 4)))
;; 叠在内容上：空面板无内容 pane → 内容透出（与不叠加同屏）
(define eb (make-buffer "hello\nworld\n"))
(define ev (buffer-add-view! eb 8 4 #:line-numbers? #f))
(define pv (make-panel ev (rect 0 0 8 4) borders-none))
(define base (render-display (list pv) #f 8 4))
(define over (render-display (list pv (empty-panel (rect 0 0 8 4) borders-none #:deep 5)) #f 8 4))
(check-equal? (screen->string over) (screen->string base))

;; panel-set-point!：屏幕格 → 该 panel 主光标（鼠标点哪落哪）
(define pset (make-panel v (rect 0 0 10 5) borders-all))
(panels-sync! (list pset))
(check-true (panel-set-point! pset 2 3))      ; 内容原点 (1,1) → 文档 (1,2)
(check-equal? (view-point v) (point 1 2))
(check-false (panel-set-point! pset 0 0))     ; 边框上 → 不动
(check-false (panel-set-point! pe 2 2))       ; 空面板 → 不动

(displayln "core/editor/render.rkt: ok")
