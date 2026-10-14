#lang racket
;;; 04 —— 导航与视口
;;;
;;; 运行：racket temp/04-navigation.rkt
;;;
;;; 导航算子都会改 view 的 selections：
;;;   extend? = #f  坍缩到 head 再移动（普通方向键）
;;;   extend? = #t  只动 head（Shift+方向，扩选/缩选）
;;; 默认还会 ensure（让光标滚进可见区）。

(require "../core/editor.rkt")

(define text (string-join (for/list ([i (in-range 1 21)]) (format "line ~a" i)) "\n"))
(define b (make-buffer text))
(define v (buffer-add-view! b 20 5))     ; 小窗：高 5 行

(define (title s) (printf "\n==== ~a ====\n" s))

(title "基本移动")
(view-set-point! v (point 2 0))
(view-right! v)
(view-right! v)
(printf "右移两次: ~a\n" (view-point v))
(view-down! v)
(printf "下移:     ~a\n" (view-point v))
(view-home! v)
(printf "home:     ~a\n" (view-point v))
(view-end! v)
(printf "end:      ~a\n" (view-point v))

(title "extend：Shift+方向 = 只动 head")
(view-set-point! v (point 0 0))
(view-down! v #t)
(view-right! v #t)
(printf "扩选区间: ~a\n" (view-primary-range v))
(printf "选区数:   ~a\n" (view-selection-count v))

(title "自定义导航：view-nav! 传 point -> point")
(view-nav! v (lambda (p) (point 7 2)))
(printf "跳到 (7,2): ~a\n" (view-point v))

(title "ensure：让光标滚进可见区")
(view-scroll-to-line! v 0)
(view-set-point! v (point 15 0))         ; 默认 ensure? #t，会自动滚动
(printf "首可见行: ~a（光标 15 已可见）\n"
        (point-line (range-start (view-visible-range v))))

(title "视口查询")
(printf "mode=~a size=~ax~a\n" (view-mode v) (view-width v) (view-height v))
(printf "visible-range: ~a\n" (view-visible-range v))
(printf "锚点(左上角点): ~a\n" (view-anchor-point v))

(title "滚动")
(view-scroll! v 3)
(printf "scroll 3  后首可见行: ~a\n" (point-line (range-start (view-visible-range v))))
(view-scroll! v -1)
(printf "scroll -1 后首可见行: ~a\n" (point-line (range-start (view-visible-range v))))

(title "wrap 模式：长行折成多个视觉行")
(view-set-mode! v 'wrap)
(view-resize! v 8 5)
(view-set-point! v (point 0 0))
(printf "mode=~a visible-range: ~a\n" (view-mode v) (view-visible-range v))
