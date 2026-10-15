#lang racket

;;; core/view/compose.rkt —— 多窗格合成：遮挡（deep/列表序）、裁剪、overlay。
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

;; 左右并排：run 平移；overlay 全部透出（compose 不按 active 过滤，由上游决定传什么）
(define comp (panes->screen 8 2 (list (pane 0 0 sa 0) (pane 0 4 sb 0))))
(check-equal? (screen-row comp 0) (list (run 0 "ab" 'f) (run 4 "XY" 'g)))
(check-equal? (screen-row comp 1) (list (run 0 "cd" 'f) (run 4 "ZW" 'g)))
(check-equal? (screen-cursors comp) (list (cursor 1 1 #t) (cursor 0 4 #t)))
(check-equal? (screen-regions comp) (list (region 0 0 2 #f)))

;; 空 pane 列表 → 空屏
(check-equal? (screen-row (panes->screen 3 2 '()) 0) '())

;; 遮挡：上层整块矩形（含空白格）盖住下层
(define lower (screen 3 1 (vector (list (run 0 "abc" 'f))) '() '()))
(define top   (screen 2 1 (vector (list (run 0 "X" 'g))) '() '()))
(check-equal? (screen-row (panes->screen 3 1 (list (pane 0 0 lower 0) (pane 0 1 top 1))) 0)
              (list (run 0 "a" 'f) (run 1 "X" 'g)))
;; 同 deep → 列表靠后者在上
(check-equal? (screen-row (panes->screen 3 1 (list (pane 0 0 lower 0) (pane 0 1 top 0))) 0)
              (list (run 0 "a" 'f) (run 1 "X" 'g)))
;; 低 deep 不覆盖高 deep（列表顺序无关）
(check-equal? (screen-row (panes->screen 3 1 (list (pane 0 1 top 1) (pane 0 0 lower 0))) 0)
              (list (run 0 "a" 'f) (run 1 "X" 'g)))

;; overlay 也按 owner 遮挡：下层光标 / 选区在重叠处不画
(define lower2 (screen 3 1 (vector (list (run 0 "abc" 'f)))
                       (list (cursor 0 1 #t)) (list (region 0 0 3 #f))))
(define topc (screen 2 1 (vector (list (run 0 "X" 'g))) (list (cursor 0 0 #t)) '()))
(define ov (panes->screen 3 1 (list (pane 0 0 lower2 0) (pane 0 1 topc 1))))
(check-equal? (screen-cursors ov) (list (cursor 0 1 #t)))     ; 上层光标透出
(check-equal? (screen-regions ov) (list (region 0 0 1 #f)))   ; 下层选区只剩 col0

;; 负坐标 / 越界裁剪
(define scr4 (screen 4 1 (vector (list (run 0 "abcd" 'f))) '() '()))
(check-equal? (screen-row (panes->screen 4 1 (list (pane 0 -2 scr4 0))) 0)
              (list (run 0 "cd" 'f)))                          ; 左侧滚出
(check-equal? (screen-row (panes->screen 3 1 (list (pane 0 0 scr4 0))) 0)
              (list (run 0 "abc" 'f)))                         ; 右侧裁掉

;; 宽字符：放不下整字就丢，不切半
(define w (screen 2 1 (vector (list (run 0 "中" 'f))) '() '()))
(check-equal? (screen-row (panes->screen 1 1 (list (pane 0 0 w 0))) 0) '())
(check-equal? (screen-row (panes->screen 2 1 (list (pane 0 0 w 0))) 0) (list (run 0 "中" 'f)))

;; 逐行合成与全量一致；composition 带上屏幕
(check-equal? (compose-row-of 8 (list (pane 0 0 sa 0)) 1) (list (run 0 "cd" 'f)))
(define c (panes->composition 8 2 (list (pane 0 0 sa 0))))
(check-equal? (composition-width c) 8)
(check-equal? (composition-screen c) (panes->screen 8 2 (list (pane 0 0 sa 0))))

(displayln "view/compose.rkt: ok")
