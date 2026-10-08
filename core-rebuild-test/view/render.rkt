#lang racket

;; 由 core/view/render.rkt 的测试外移而来（core/ 只留实现）。
(require rackunit
       "../../core-rebuild/view/render.rkt"
       "../../core-rebuild/view/base/screen.rkt"
       "../../core-rebuild/view/base/viewport.rkt"
       "../../core-rebuild/view/base/layout.rkt"
       "../../core-rebuild/text/document.rkt"
       "../../core-rebuild/text/base/point.rkt"
       "../../core-rebuild/text/base/selection.rkt"
       "../../core-rebuild/text/base/track.rkt"
       "../../core-rebuild/text/base/line.rkt"
       "../../core-rebuild/text/base/width.rkt")

(define bd (document-open "abc\ndef"))
(define vp (viewport-open 10 2))

(define s (render bd vp))
(check-equal? (screen->string s) "abc\ndef")
(check-equal? (screen-row s 0) (list (run 0 "abc" #f)))
(check-equal? (screen-cursors s) '())
(check-equal? (screen-regions s) '())

(check-equal? (screen-cursors (render bd vp (selections-one (caret (point 0 1)))))
              (list (cursor 0 1 #t)))

;; 属性编辑是**就地**改 box：用独立文档，避免影响上面复用的 bd
(define bd-hl (document-face-fill (document-open "abc\ndef") 0 1 0 3 'kw))
(check-equal? (screen-row (render bd-hl vp) 0)
              (list (run 0 "a" #f) (run 1 "bc" 'kw)))

(define ss (selections-of (list (selection (point 0 0) (point 0 2)) (caret (point 1 1))) 0))
(define ssel (render bd vp ss))
(check-equal? (screen-regions ssel) (list (region 0 0 2 #t)))
(check-equal? (screen-cursors ssel) (list (cursor 0 2 #t) (cursor 1 1 #f)))
(check-equal? (screen-regions (render bd vp (selections-one (selection (point 0 1) (point 1 2)))))
              (list (region 0 1 3 #t) (region 1 0 2 #t)))

;; clip 水平滚动 / 裁剪
(check-equal? (screen-row (render bd (viewport-set-left-column (document-text bd) vp 1)) 0)
              (list (run 0 "bc" #f)))
(check-equal? (screen-row (render bd (viewport-open 2 2)) 0) (list (run 0 "ab" #f)))

;; 宽字符
(define bd2 (document-open "中abc"))
(check-equal? (screen-row (render bd2 (viewport-open 10 1)) 0) (list (run 0 "中abc" #f)))
(define bd3 (document-face-fill bd2 0 0 0 1 'w))
(check-equal? (screen-row (render bd3 (viewport-open 10 1)) 0)
              (list (run 0 "中" 'w) (run 2 "abc" #f)))

;; wrap：一行折成多屏幕行；光标/选区按屏幕行切
(define bd4 (document-open "aaaaa\nb"))
(define vw (viewport-open 4 2 'wrap))
(check-equal? (screen->string (render bd4 vw)) "aaaa\na")
(check-equal? (screen-cursors (render bd4 vw (selections-one (caret (point 0 4)))))
              (list (cursor 1 0 #t)))
(check-equal? (screen-regions (render bd4 vw (selections-one (selection (point 0 1) (point 0 5)))))
              (list (region 0 1 4 #t) (region 1 0 1 #t)))

;; ---------- 行号栏（gutter）----------
;; clip：栏 + 文本
(define bd-n (document-open "abc\ndef"))
(define vp-n (viewport-open 6 2 'clip #t))                     ; gutter 2
(check-equal? (screen->string (render bd-n vp-n)) "1 abc\n2 def")
(check-equal? (screen-row (render bd-n vp-n) 0)
              (list (run 0 "1 " 'line-number) (run 2 "abc" #f)))
;; 光标 / 选区列都含栏偏移
(check-equal? (screen-cursors (render bd-n vp-n (selections-one (caret (point 0 0)))))
              (list (cursor 0 2 #t)))
(check-equal? (screen-regions (render bd-n vp-n (selections-one (selection (point 0 0) (point 0 2)))))
              (list (region 0 2 4 #t)))

;; wrap：续段行号列留空，文本仍右移栏宽
(define bd-w (document-open "aaaaa\nb"))
(define vp-w (viewport-open 5 3 'wrap #t))                     ; gutter 2 → 正文 3
(check-equal? (screen->string (render bd-w vp-w)) "1 aaa\n  aa\n2 b")
(check-equal? (screen-cursors (render bd-w vp-w (selections-one (caret (point 0 3)))))
              (list (cursor 1 2 #t)))

;; 文末空行：栏也留空
(check-equal? (screen-row (render (document-open "a") (viewport-open 6 3 'clip #t)) 2) '())

(displayln "render.rkt: all tests passed")
