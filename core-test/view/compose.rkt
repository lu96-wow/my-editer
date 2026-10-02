#lang racket

;; 由 core/view/compose.rkt 的测试外移而来（core/ 只留实现）。
(require rackunit
       "../../core/view/compose.rkt"
       "../../core/view/base/screen.rkt")

(define sa (screen 4 2
                   (vector (list (run 0 "ab" 'f)) (list (run 0 "cd" 'f)))
                   (list (cursor 1 1 #t))
                   (list (region 0 0 2 #f))))
(define sb (screen 4 2
                   (vector (list (run 0 "XY" 'g)) (list (run 0 "ZW" 'g)))
                   (list (cursor 0 0 #t))
                   '()))

;; 左右并排（大屏 8×2）；只有 active 命中的 pane 的光标 / 选区才透出
(define comp (panes->screen 8 2 (list (pane 'a 0 0 sa) (pane 'b 0 4 sb)) 'b))
(check-equal? (screen-row comp 0) (list (run 0 "ab" 'f) (run 4 "XY" 'g)))
(check-equal? (screen-row comp 1) (list (run 0 "cd" 'f) (run 4 "ZW" 'g)))
(check-equal? (screen-cursors comp) (list (cursor 0 4 #t)))      ; 只 active(b) 的光标
(check-equal? (screen-regions comp) '())                         ; b 无选区 → 无；a 非 active → 不画
;; active='a → 画 a 的光标 + 选区（b 都不画）
(define comp-a (panes->screen 8 2 (list (pane 'a 0 0 sa) (pane 'b 0 4 sb)) 'a))
(check-equal? (screen-cursors comp-a) (list (cursor 1 1 #t)))
(check-equal? (screen-regions comp-a) (list (region 0 0 2 #f)))

;; active 不存在 → 光标 / 选区都不画
(check-equal? (screen-cursors (panes->screen 8 2 (list (pane 'a 0 0 sa)) 'x)) '())
(check-equal? (screen-regions (panes->screen 8 2 (list (pane 'a 0 0 sa)) 'x)) '())

;; active 为列表 → 多个 pane 的光标 / 选区都透出（按 pane 顺序）
(check-equal? (screen-cursors (panes->screen 8 2 (list (pane 'a 0 0 sa) (pane 'b 0 4 sb)) '(a b)))
              (list (cursor 1 1 #t) (cursor 0 4 #t)))
(check-equal? (screen-regions (panes->screen 8 2 (list (pane 'a 0 0 sa) (pane 'b 0 4 sb)) '(a b)))
              (list (region 0 0 2 #f)))
;; #f / '() → 光标 / 选区都不画
(check-equal? (screen-cursors (panes->screen 8 2 (list (pane 'a 0 0 sa) (pane 'b 0 4 sb)) #f)) '())
(check-equal? (screen-regions (panes->screen 8 2 (list (pane 'a 0 0 sa) (pane 'b 0 4 sb)) #f)) '())

;; 平移：pane 贴到 (2,1)
(define comp2 (panes->screen 8 4 (list (pane 'a 1 2 sa)) 'a))
(check-equal? (screen-row comp2 1) (list (run 2 "ab" 'f)))
(check-equal? (screen-row comp2 0) '())
(check-equal? (screen-cursors comp2) (list (cursor 2 3 #t)))

;; panes->composition 返回 composition（含屏幕）
(define c (panes->composition 8 2 (list (pane 'a 0 0 sa)) 'a))
(check-equal? (composition-active c) 'a)
(check-equal? (composition-screen c) (panes->screen 8 2 (list (pane 'a 0 0 sa)) 'a))

(displayln "compose.rkt: all tests passed")
