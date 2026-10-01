#lang racket

;; 与 core/editor/layout.rkt 对应的外部测试（set-layout / render-layout / 组合）。
(require rackunit
         "../../core/editor.rkt"
         "../../core/view/base/screen.rkt")

(define ed0 (editor-open "abc\ndef" 20 4 "d"))
(define-values (ed1 _) (editor-add-view ed0 0 20 4))              ; vid1

;; 两窗格：左 (0,0) 20×4，右 x=20 20×3；active = vid0
(define rects (list (rect 0 0 0 20 4) (rect 1 20 0 20 3)))

;; ---------- set-layout：w h 落到 view（x y 忽略） ----------
(define laid (editor-set-layout ed1 rects))
(check-equal? (editor-view-width laid 1) 20)
(check-equal? (editor-view-height laid 1) 3)           ; 被 rect 改成 3
(check-equal? (editor-view-width laid 0) 20)
;; 尺寸没变 → 原样返回（不重锚）
(check-true (eq? (editor-set-layout laid rects) laid))
;; set-layout 不动位置 / 不渲染
(check-equal? (editor-view-height laid 0) 4)

;; ---------- render-layout：纯渲染，按 x y 贴、w h 定本帧视口 ----------
;; set-layout 会就地改 view 尺寸，这里用新的 editor 验证"render 不落尺寸"。
(define edr (let-values ([(e _) (editor-add-view (editor-open "abc\ndef" 20 4 "d") 0 20 4)]) e))
(define comp (editor-render-layout edr rects 0 40 4))
(check-equal? (screen-width comp) 40)
(check-equal? (screen-height comp) 4)
(check-equal? (map (lambda (r) (list (run-col r) (run-text r))) (screen-row comp 0))
              '((0 "abc") (20 "abc")))
(check-equal? (screen-cursors comp) (list (cursor 0 0 #t)))     ; 只 active 的光标
(check-equal? (screen-cursors (editor-render-layout edr rects 1 40 4))
              (list (cursor 0 20 #t)))
;; 纯：不改 view 里存的尺寸（仍是 4）
(check-equal? (editor-view-height edr 1) 4)
;; 本帧尺寸生效：右格高 3 → 第 3 行（index 3）无右格内容
(check-false (for/or ([rn (in-list (screen-row comp 3))]) (>= (run-col rn) 20)))

;; ---------- 组合：返回 (values editor screen) ----------
(define-values (laid2 comp2) (editor-render-layout* edr rects 0 40 4))
(check-equal? (editor-view-height laid2 1) 3)
(check-equal? (screen->string comp2) (screen->string (editor-render-layout laid2 rects 0 40 4)))

(displayln "editor/layout.rkt: all tests passed")
