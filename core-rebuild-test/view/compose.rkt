#lang racket

;; 由 core/view/compose.rkt 的测试外移而来（core/ 只留实现）。
(require rackunit
       "../../core-rebuild/view/compose.rkt"
       "../../core-rebuild/view/base/screen.rkt")

(define sa (screen 4 2
                   (vector (list (run 0 "ab" 'f)) (list (run 0 "cd" 'f)))
                   (list (cursor 1 1 #t))
                   (list (region 0 0 2 #f))))
(define sb (screen 4 2
                   (vector (list (run 0 "XY" 'g)) (list (run 0 "ZW" 'g)))
                   (list (cursor 0 0 #t))
                   '()))

;; 左右并排（大屏 8×2）；只有 active 命中的 pane 的光标 / 选区才透出
(define comp (panes->screen 8 2 (list (pane 'a 0 0 sa 0) (pane 'b 0 4 sb 0)) 'b))
(check-equal? (screen-row comp 0) (list (run 0 "ab" 'f) (run 4 "XY" 'g)))
(check-equal? (screen-row comp 1) (list (run 0 "cd" 'f) (run 4 "ZW" 'g)))
(check-equal? (screen-cursors comp) (list (cursor 0 4 #t)))      ; 只 active(b) 的光标
(check-equal? (screen-regions comp) '())                         ; b 无选区 → 无；a 非 active → 不画
;; active='a → 画 a 的光标 + 选区（b 都不画）
(define comp-a (panes->screen 8 2 (list (pane 'a 0 0 sa 0) (pane 'b 0 4 sb 0)) 'a))
(check-equal? (screen-cursors comp-a) (list (cursor 1 1 #t)))
(check-equal? (screen-regions comp-a) (list (region 0 0 2 #f)))

;; active 不存在 → 光标 / 选区都不画
(check-equal? (screen-cursors (panes->screen 8 2 (list (pane 'a 0 0 sa 0)) 'x)) '())
(check-equal? (screen-regions (panes->screen 8 2 (list (pane 'a 0 0 sa 0)) 'x)) '())

;; active 为列表 → 多个 pane 的光标 / 选区都透出（按 pane 顺序）
(check-equal? (screen-cursors (panes->screen 8 2 (list (pane 'a 0 0 sa 0) (pane 'b 0 4 sb 0)) '(a b)))
              (list (cursor 1 1 #t) (cursor 0 4 #t)))
(check-equal? (screen-regions (panes->screen 8 2 (list (pane 'a 0 0 sa 0) (pane 'b 0 4 sb 0)) '(a b)))
              (list (region 0 0 2 #f)))
;; #f / '() → 光标 / 选区都不画
(check-equal? (screen-cursors (panes->screen 8 2 (list (pane 'a 0 0 sa 0) (pane 'b 0 4 sb 0)) #f)) '())
(check-equal? (screen-regions (panes->screen 8 2 (list (pane 'a 0 0 sa 0) (pane 'b 0 4 sb 0)) #f)) '())

;; 平移：pane 贴到 (2,1)
(define comp2 (panes->screen 8 4 (list (pane 'a 1 2 sa 0)) 'a))
(check-equal? (screen-row comp2 1) (list (run 2 "ab" 'f)))
(check-equal? (screen-row comp2 0) '())
(check-equal? (screen-cursors comp2) (list (cursor 2 3 #t)))

;; ---------- 深度 / 不透明覆盖 ----------
(define lower (screen 3 1 (vector (list (run 0 "abc" 'f))) '() '()))
(define top   (screen 2 1 (vector (list (run 0 "X" 'g))) '() '()))

;; 上层矩形覆盖 col1-2：col1 画 X，col2 是上层空白 → 下层 c 被遮挡
(define occl (panes->screen 3 1 (list (pane 'l 0 0 lower 0) (pane 'u 0 1 top 1)) '()))
(check-equal? (screen-row occl 0) (list (run 0 "a" 'f) (run 1 "X" 'g)))

;; 同 deep → 列表靠后者在上（同覆盖结果）
(check-equal? (screen-row (panes->screen 3 1 (list (pane 'l 0 0 lower 0) (pane 'u 0 1 top 0)) '()) 0)
              (list (run 0 "a" 'f) (run 1 "X" 'g)))
;; 顺序无关，由 deep 决定（低 deep 不覆盖高 deep）
(check-equal? (screen-row (panes->screen 3 1 (list (pane 'u 0 1 top 1) (pane 'l 0 0 lower 0)) '()) 0)
              (list (run 0 "a" 'f) (run 1 "X" 'g)))

;; overlay 也被上层遮挡：下层光标 / 选区在重叠处不画
(define lower2 (screen 3 1 (vector (list (run 0 "abc" 'f)))
                       (list (cursor 0 1 #t)) (list (region 0 0 3 #f))))
(define topc   (screen 2 1 (vector (list (run 0 "X" 'g)))
                       (list (cursor 0 0 #t)) '()))
(define ov (panes->screen 3 1 (list (pane 'l 0 0 lower2 0) (pane 'u 0 1 topc 1)) '(l u)))
(check-equal? (screen-cursors ov) (list (cursor 0 1 #t)))        ; 下层光标(col1)被盖；上层光标(col1)透出
(check-equal? (screen-regions ov) (list (region 0 0 1 #f)))      ; 下层选区只剩 col0

;; panes->composition 返回 composition（含屏幕）
(define c (panes->composition 8 2 (list (pane 'a 0 0 sa 0)) 'a))
(check-equal? (composition-active c) 'a)
(check-equal? (composition-screen c) (panes->screen 8 2 (list (pane 'a 0 0 sa 0)) 'a))

(displayln "compose.rkt: all tests passed")
