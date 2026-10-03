#lang racket

;; 由 core/view/base/viewport.rkt 的测试外移而来（core/ 只留实现）。
(require rackunit
       "../../../core-rebuild/view/base/viewport.rkt"
       "../../../core-rebuild/text/base/point.rkt"
       "../../../core-rebuild/text/base/track.rkt"
       "../../../core-rebuild/text/base/width.rkt"
       "../../../core-rebuild/view/base/layout.rkt")

(define t (track-of-list (list "abc" "def" "ghi")))
(define v0 (viewport-open 10 2))

;; clip：点映射
(check-equal? (call-with-values (lambda () (viewport-point->screen-pos t v0 (point 1 2))) list) '(1 2))
(check-equal? (call-with-values (lambda () (viewport-point->screen-pos t v0 (point 2 0))) list) '(#f #f))
(check-equal? (viewport-top-line (viewport-scroll t v0 2)) 2)
(check-equal? (viewport-top-line (viewport-ensure t v0 (point 2 0))) 1)
;; 吸附 + 不夹行尾
(define tw (track-of-list (list "中a中")))
(check-equal? (viewport-left-col (viewport-ensure tw (viewport-open 3 1) (point 0 2))) 2)
(check-equal? (viewport-left-col (viewport-set-left-col tw (viewport-open 3 1) 99)) 99)

;; wrap：一行折成多屏幕行 / 视觉行移动 / ensure
(define t2 (track-of-list (list "aaaaa" "b")))
(define vw (viewport-open 4 2 'wrap))
(check-equal? (map (lambda (vr) (list (vrow-line vr) (vrow-start-col vr) (vrow-end-col vr)))
                   (vector->list (viewport-vrows t2 vw)))
              '((0 0 4) (0 4 5)))
;; 点 (0,4) 落在第 2 段 → 屏幕行 1
(check-equal? (call-with-values (lambda () (viewport-point->screen-pos t2 vw (point 0 4))) list) '(1 0))
;; 上下移动走折行段
(check-equal? (point-down t2 vw (point 0 0)) (point 0 4))
(check-equal? (point-down t2 vw (point 0 4)) (point 1 0))
(check-equal? (point-up t2 vw (point 1 0)) (point 0 4))
;; ensure：行 1 在最底部之外 → 下滚一段
(define vw2 (viewport-ensure t2 vw (point 1 0)))
(check-equal? (list (viewport-top-line vw2) (viewport-top-seg vw2)) '(0 1))

;; ---------- 逆向映射：screen-pos -> point ----------

;; clip：正反向一致
(check-equal? (call-with-values (lambda () (viewport-screen-pos->point t v0 1 2)) list) '(1 2))
(check-equal? (call-with-values (lambda () (viewport-screen-pos->point t v0 0 0)) list) '(0 0))
;; 行越界 / 文末之后 → #f
(check-equal? (call-with-values (lambda () (viewport-screen-pos->point t v0 5 0)) list) '(#f #f))
(check-equal? (call-with-values (lambda () (viewport-screen-pos->point t v0 -1 0)) list) '(#f #f))
(check-equal? (call-with-values (lambda () (viewport-screen-pos->point t (viewport-open 10 5) 3 0)) list) '(#f #f))
;; 点过行尾 → 行尾；负列 → 行首
(check-equal? (call-with-values (lambda () (viewport-screen-pos->point t v0 0 99)) list) '(0 3))
(check-equal? (call-with-values (lambda () (viewport-screen-pos->point t v0 0 -5)) list) '(0 0))
;; clip 水平滚动后正反向一致
(define vc (viewport-set-left-col (track-of-list (list "abcdef")) (viewport-open 3 1) 2))
(check-equal? (call-with-values (lambda () (viewport-screen-pos->point (track-of-list (list "abcdef")) vc 0 0)) list) '(0 2))
(check-equal? (call-with-values (lambda () (viewport-screen-pos->point (track-of-list (list "abcdef")) vc 0 2)) list) '(0 4))

;; wrap：第 2 屏幕行对应 (0,4)；点过段尾 → 行尾
(check-equal? (call-with-values (lambda () (viewport-screen-pos->point t2 vw 1 0)) list) '(0 4))
(check-equal? (call-with-values (lambda () (viewport-screen-pos->point t2 vw 1 99)) list) '(0 5))
(define vw3 (viewport-open 4 3 'wrap))
(check-equal? (call-with-values (lambda () (viewport-screen-pos->point t2 vw3 2 0)) list) '(1 0))   ; 第 3 行 = 第 2 buffer 行

;; 宽字符：点右半格命中同一字符；正反向一致
(define twc (track-of-list (list "中a")))
(define vwc (viewport-open 10 1))
(check-equal? (call-with-values (lambda () (viewport-screen-pos->point twc vwc 0 0)) list) '(0 0))
(check-equal? (call-with-values (lambda () (viewport-screen-pos->point twc vwc 0 1)) list) '(0 0))   ; 右半格
(check-equal? (call-with-values (lambda () (viewport-screen-pos->point twc vwc 0 2)) list) '(0 1))
(check-equal? (call-with-values (lambda () (viewport-screen-pos->point twc vwc 0 3)) list) '(0 2))
;; 对每个字符起点，正向再逆向回到同一显示列
(for ([i (in-range 0 3)])
  (define-values (rr cc) (viewport-point->screen-pos twc vwc (point 0 i)))
  (check-equal? (call-with-values (lambda () (viewport-screen-pos->point twc vwc rr cc)) list) (list 0 i)))

;; ---------- 行号栏（gutter）----------
(define tlg (track-of-list (list "a" "b" "c" "d" "e")))            ; 5 行
(check-equal? (viewport-gutter-width tlg (viewport-open 10 2 'clip #t)) 2)   ; last=2 → 1位+1
(check-equal? (viewport-gutter-width tlg (viewport-open 10 12 'clip #t)) 2)  ; last=5 → 1位+1
(define tl12 (track-of-list (for/list ([i (in-range 12)]) (number->string i))))
(check-equal? (viewport-gutter-width tl12 (viewport-open 10 12 'clip #t)) 3) ; last=12 → 2位+1
(check-equal? (viewport-gutter-width tlg (viewport-open 10 2 'clip #f)) 0)     ; 关
;; 栏宽不超过总宽-1（正文至少 1 列）
(check-equal? (viewport-gutter-width tlg (viewport-open 1 2 'clip #t)) 0)
(check-equal? (viewport-gutter-width tlg (viewport-open 2 2 'clip #t)) 1)
(check-equal? (viewport-content-width tlg (viewport-open 10 2 'clip #t)) 8)

;; 点 ↔ 屏 含栏偏移
(define vpg (viewport-open 10 2 'clip #t))                                   ; gutter 2
(check-equal? (call-with-values (lambda () (viewport-point->screen-pos tlg vpg (point 0 0))) list) '(0 2))
(check-equal? (call-with-values (lambda () (viewport-point->screen-pos tlg vpg (point 1 0))) list) '(1 2))
(check-equal? (call-with-values (lambda () (viewport-screen-pos->point tlg vpg 0 0)) list) '(0 0))  ; 栏上 → 行首
(check-equal? (call-with-values (lambda () (viewport-screen-pos->point tlg vpg 0 3)) list) '(0 1))

;; wrap 用**正文宽**（含栏）：总宽 5、栏 2 → 正文 3
(define t2g (track-of-list (list "aaaaa" "b")))
(define vwg (viewport-open 5 2 'wrap #t))
(check-equal? (viewport-content-width t2g vwg) 3)
(check-equal? (map (lambda (vr) (list (vrow-line vr) (vrow-start-col vr) (vrow-end-col vr)))
                   (vector->list (viewport-vrows t2g vwg)))
              '((0 0 3) (0 3 5)))
(check-equal? (point-down t2g vwg (point 0 0)) (point 0 3))                ; 按正文宽折行

;; ---------- /vrows 变体（与标量一致、不重复派生）----------
(define vrs0 (viewport-vrows t v0))
(check-equal? (call-with-values (lambda () (viewport-point->screen-pos/vrows t v0 vrs0 (point 1 2))) list) '(1 2))
(check-equal? (call-with-values (lambda () (viewport-screen-pos->point/vrows t v0 vrs0 1 2)) list) '(1 2))
(define vrs2 (viewport-vrows t2 vw))
(check-equal? (call-with-values (lambda () (viewport-point->screen-pos/vrows t2 vw vrs2 (point 0 4))) list) '(1 0))
(check-equal? (call-with-values (lambda () (viewport-screen-pos->point/vrows t2 vw vrs2 1 0)) list) '(0 4))
;; wrap 行尾插入点
(check-equal? (call-with-values (lambda () (viewport-point->screen-pos/vrows t2 vw vrs2 (point 0 5))) list) '(1 1))
(check-equal? (call-with-values (lambda () (viewport-screen-pos->point/vrows t2 vw vrs2 1 1)) list) '(0 5))

;; ---------- 锚点（视口间同步） ----------

;; clip：锚列 = left-col
(define ta (track-of-list (list "abcdefghij" "short" "xxxxxxxxxx")))
(check-equal? (call-with-values (lambda () (viewport-anchor ta (viewport-open 4 2))) list) '(0 0))
(check-equal? (call-with-values (lambda () (viewport-anchor ta (viewport-set-left-col ta (viewport-open 4 2) 6))) list) '(0 6))
(check-equal? (call-with-values (lambda () (viewport-anchor ta (viewport-set-top-line (viewport-open 4 2) 2))) list) '(2 0))
;; 越界 top-line 先夹
(check-equal? (call-with-values (lambda () (viewport-anchor ta (viewport-set-top-line (viewport-open 4 2) 99))) list) '(2 0))

;; wrap：锚列 = 顶段起点
(define twa (track-of-list (list "abcdefghij" "short")))
(define vwa (viewport-set-top-seg (viewport-open 4 2 'wrap) 1))       ; 段 1 起点 = 4
(check-equal? (call-with-values (lambda () (viewport-anchor twa vwa)) list) '(0 4))
;; 段号越界 → 夹到末段
(check-equal? (call-with-values (lambda () (viewport-anchor twa (viewport-set-top-seg (viewport-open 4 2 'wrap) 99))) list) '(0 8))

;; set-anchor：clip 落 left-col；wrap 落 top-seg
(define va-clip (viewport-set-anchor ta (viewport-open 4 2) 1 7))
(check-equal? (list (viewport-top-line va-clip) (viewport-left-col va-clip)) '(1 7))
(define va-wrap (viewport-set-anchor twa (viewport-open 4 2 'wrap) 0 6))
(check-equal? (list (viewport-top-line va-wrap) (viewport-top-seg va-wrap)) '(0 1))
;; 行越界夹回
(check-equal? (viewport-top-line (viewport-set-anchor ta (viewport-open 4 2) 99 0)) 2)

;; 跨 mode：同一个锚 (0,6) —— clip 得 left-col 6，wrap 得段 1
(check-equal? (viewport-left-col (viewport-set-anchor ta (viewport-open 4 2) 0 6)) 6)
(check-equal? (viewport-top-seg (viewport-set-anchor twa (viewport-open 4 2 'wrap) 0 6)) 1)
;; 取 / 放往返
(check-equal? (call-with-values
               (lambda ()
                 (viewport-anchor twa (viewport-set-anchor twa (viewport-open 4 2 'wrap) 1 5)))
               list)
              '(1 4))

;; viewport-mirror：跨文档按锚行显示宽比例缩放列；行号固定 + 夹；源空行 → 列 0
(define ma (track-of-list (list "aaaaaaaaaa" "second")))
(define mb (track-of-list (list "bbbbb" "second line")))
(check-equal? (viewport-left-col
               (viewport-mirror ma (viewport-set-left-col ma (viewport-open 4 2) 6) mb (viewport-open 4 2)))
              3)                                                     ; 6 * 5/10
(check-equal? (viewport-top-line
               (viewport-mirror ma (viewport-set-top-line (viewport-open 4 2) 1) (track-of-list (list "x")) (viewport-open 4 2)))
              0)                                                     ; 目标更短 → 夹最近
(define me (track-of-list (list "" "abc")))
(check-equal? (viewport-left-col
               (viewport-mirror me (viewport-set-left-col me (viewport-open 4 2) 5) mb (viewport-open 4 2)))
              0)                                                     ; 源锚行空 → 无法定比例，取 0
;; 跨文档 + 目标 wrap：比例后的列落到段
(define mlong (track-of-list (list "bbbbbbbbbb")))
(check-equal? (viewport-top-seg
               (viewport-mirror ma (viewport-set-left-col ma (viewport-open 4 2) 6) mlong (viewport-open 4 2 'wrap)))
              1)                                                     ; 6 → 列 6，段 1

;; ---------- 回归：ensure 的水平吸附用**光标行**，不用顶行 ----------
;; 顶行在显示列 [39,41) 有宽字符；光标在另一行（全窄）的列 40，left-col=41。
;; 用顶行吸附会把 left=40 推到 41（光标跑到视口左外）；用光标行则保持 40。
(define top-wide (string-append (make-string 39 #\a) "中"))
(define cur-narrow (make-string 41 #\b))
(define tml (track-of-list (list top-wide cur-narrow)))
(define vml (struct-copy viewport (viewport-open 10 2) [left-col 41]))
(define vml* (viewport-ensure tml vml (point 1 40)))
(check-equal? (viewport-left-col vml*) 40)
(check-true (>= (- (index->display-col cur-narrow 40) (viewport-left-col vml*)) 0))

;; ---------- 回归：ensure 的正文宽必须用**新顶行**（换顶行后行号栏位数会变）----------
;; 12 行、总宽 8、高 4、开行号：顶行 0 时栏宽 2（正文 6）；滚到顶行 6 后栏宽 3（正文 5）。
(define t12 (track-of-list (for/list ([i (in-range 12)]) "aaaaaaaaaa")))
(define v12 (viewport-open 8 4 'clip #t))
(check-equal? (viewport-content-width t12 v12) 6)
(define v12* (viewport-ensure t12 v12 (point 9 10)))           ; 行 9、行尾（dc=10）
(check-equal? (viewport-top-line v12*) 6)
(check-equal? (viewport-gutter-width t12 v12*) 3)
(check-equal? (viewport-left-col v12*) 6)                     ; 用新宽 5 → left=6（旧宽 6 会得 5，光标挤出）
(check-equal? (call-with-values (lambda () (viewport-point->screen-pos t12 v12* (point 9 10))) list)
              '(3 7))                                                     ; 屏幕列 = 栏宽 3 + 正文列 4
;; wrap 下同一条不变量：ensure 后光标必可见
(define v12w (viewport-ensure t12 (viewport-open 8 4 'wrap #t) (point 9 10)))
(check-true (let-values ([(r _) (viewport-point->screen-pos t12 v12w (point 9 10))]) (and r (< r 4))))

;; ---------- 回归：越界的 top-line / top-seg（文档变短后其它视图可能残留）不应让 wrap 滚动崩 ----------
(define tshort (track-of-list (list "a" "b")))
(define vstale (struct-copy viewport (viewport-open 4 2 'wrap #t) [top-line 9]))
(check-true (viewport? (viewport-scroll tshort vstale 2)))
(check-true (viewport? (viewport-scroll tshort vstale -2)))
(define vstale2 (struct-copy viewport (viewport-open 4 2 'wrap) [top-line 1] [top-seg 9]))
(check-true (viewport? (viewport-scroll tshort vstale2 -1)))
(check-true (viewport? (viewport-scroll tshort vstale2 1)))

(displayln "viewport.rkt: all tests passed")
