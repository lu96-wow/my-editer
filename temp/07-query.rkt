#lang racket
;;; 07 —— 查询与坐标换算
;;;
;;; 运行：racket temp/07-query.rkt
;;;
;;; 读一律不碰状态。坐标有两套：
;;;   point.column  字符索引（行字符串下标）
;;;   显示列        宽字符算 2 列，屏幕/视口用这套
;;; 换算用 view-screen-position->point / view-point->screen-position（内部已换算）。

(require "../core/editor.rkt")

(define b (make-buffer "hello\nworld\n你好世界"))
(define v (buffer-add-view! b 20 10 #:line-numbers? #t))

(define (title s) (printf "\n==== ~a ====\n" s))

(title "文本")
(printf "buffer-string: ~s\n" (buffer-string b))
(printf "view-string:   ~s\n" (view-string v))
(printf "range-text [1:0)-(1:5): ~s\n"
        (buffer-range-text b (range-of (point 1 0) (point 1 5))))
(printf "view-range-text [0:0)-(0:5): ~s\n"
        (view-range-text v (range-of (point 0 0) (point 0 5))))
(printf "char-at (2,0)=~a  (2,10)=~a\n"
        (buffer-char-at b 2 0) (buffer-char-at b 2 10))

(title "点 / 选区")
(view-set-point! v (point 2 2))
(printf "point=~a line=~a column=~a\n"
        (view-point v) (view-point-line v) (view-point-column v))
(printf "primary=~a  count=~a  primary-range=~a\n"
        (view-primary v) (view-selection-count v) (view-primary-range v))

(title "坐标换算：point <-> 屏幕")
(define-values (rw cw) (view-cursor-screen-position v))
(printf "光标屏幕位置: row=~a col=~a\n" rw cw)
(define-values (rt ct) (view-point->screen-position v (point 0 0)))
(printf "point(0,0) 屏幕: row=~a col=~a（col 含行号栏）\n" rt ct)
(define-values (l c) (view-screen-position->point v rt ct))
(printf "屏幕 -> point: line=~a col=~a\n" l c)

(title "视口状态")
(printf "mode=~a line-numbers?=~a size=~ax~a top-line=~a left-column=~a\n"
        (view-mode v) (view-line-numbers? v)
        (view-width v) (view-height v) (view-top-line v) (view-left-column v))
(printf "anchor(line dc)=~a\n" (call-with-values (lambda () (view-anchor v)) list))
(printf "anchor-point=~a\n" (view-anchor-point v))
(printf "visible-range=~a\n" (view-visible-range v))

(title "历史查询")
(printf "can-undo?=~a can-redo?=~a depth=~a enabled?=~a\n"
        (buffer-can-undo? b) (buffer-can-redo? b)
        (buffer-depth b) (buffer-history-enabled? b))
