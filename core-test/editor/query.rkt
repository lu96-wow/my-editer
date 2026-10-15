#lang racket

;;; core/editor/query.rkt —— 按对象读：文本 / 端口 / 选区 / 坐标 / 视口 / 历史。
(require rackunit
         "../../core/editor.rkt")

(define b (make-buffer "hello\nworld\n"))
(define v (buffer-add-view! b 18 4 #:line-numbers? #f))
(define p (make-panel v (rect 5 2 20 6) borders-all))     ; 内容原点 = (6,3)

;;; ---------- 文本 / 名称 ----------
(check-equal? (buffer-string b) "hello\nworld\n")
(check-equal? (view-string v) "hello\nworld\n")
(check-equal? (buffer-range-text b (range (point 0 1) (point 1 3))) "ello\nwor")
(check-equal? (view-range-text v (range (point 0 0) (point 0 5))) "hello")
(check-equal? (buffer-char-at b 0 1) #\e)
(check-false (buffer-char-at b 0 99))                     ; 列越界
(check-false (buffer-char-at b 99 0))                     ; 行越界
(check-equal? (view-char-at v 1 0) #\w)
(check-equal? (buffer-line b 1) "world")
(check-false (buffer-line b 99))
(check-equal? (view-line v 0) "hello")

;;; ---------- 端口（face / readonly 读写读） ----------
(buffer-face-range! b (range (point 0 0) (point 0 2)) 'kw)
(check-equal? (buffer-face-at b 0 0) 'kw)
(check-false (buffer-face-at b 0 2))
(check-equal? (view-face-at v 0 1) 'kw)
(check-equal? (buffer-face-row b 0) (vector 'kw 'kw #f #f #f))
(check-true (buffer-face-any? b 0 0 0 1))
(check-false (buffer-face-any? b 1 0 1 5))
(buffer-readonly-range! b (range (point 1 0) (point 1 2)) #t)
(check-equal? (buffer-readonly-row b 1) (vector #t #t #f #f #f))
(check-true (view-readonly-at? v 1 1))
(check-true (buffer-readonly-any? b 1 0 1 3))
(check-false (buffer-readonly-any? b 0 0 0 5))
(check-false (buffer-editable? b 1 0 1 1))                ; 区间含只读格
(check-true (buffer-editable? b 0 0 0 5))

;;; ---------- 点 / 选区 ----------
(view-set-point! v (point 1 2))
(check-equal? (view-point v) (point 1 2))
(check-equal? (view-point-line v) 1)
(check-equal? (view-point-column v) 2)
(check-equal? (view-selection-count v) 1)
(check-equal? (view-primary v) (caret (point 1 2)))
(check-equal? (view-primary-range v) (range (point 1 2) (point 1 2)))

;;; ---------- 坐标换算 ----------
;; view 内：点 ↔ 屏幕，主光标
(check-equal? (call-with-values (λ () (view-point->screen-position v (point 1 2))) list) '(1 2))
(check-equal? (call-with-values (λ () (view-screen-position->point v 1 2)) list) '(1 2))
(check-equal? (call-with-values (λ () (view-cursor-screen-position v)) list) '(1 2))
;; panel 层：屏坐标 ↔ 文档点（内容原点由边框决定）
(check-equal? (call-with-values (λ () (panel-screen-position->point p 3 6)) list) '(0 0))
(check-equal? (call-with-values (λ () (panel-screen-position->point p 3 8)) list) '(0 2))
(check-equal? (call-with-values (λ () (panel-point->screen-position p (point 0 0))) list) '(3 6))
;; 内容外 / 越界 → (values #f #f)
(check-equal? (call-with-values (λ () (panel-screen-position->point p 100 100)) list) '(#f #f))
(check-equal? (call-with-values (λ () (panel-screen-position->point p 0 0)) list) '(#f #f))

;;; ---------- 视口状态 ----------
(check-equal? (view-mode v) 'clip)
(check-false (view-line-numbers? v))
(check-equal? (view-width v) 18)
(check-equal? (view-height v) 4)
(check-equal? (view-anchor-point v) (point 0 0))
(check-equal? (view-visible-range v) (range (point 0 0) (point 2 0)))   ; 末行空行
;; 行号栏占正文宽（栏 2 → 正文 8）
(define vg (buffer-add-view! (make-buffer "abcdefghij\nklmnopqrst") 10 2 #:line-numbers? #t))
(check-equal? (view-visible-range vg) (range (point 0 0) (point 1 8)))

;;; ---------- 历史 ----------
(check-false (buffer-can-undo? b))
(check-false (buffer-can-redo? b))
(check-equal? (buffer-depth b) 0)
(check-true (buffer-history-enabled? b))
(check-equal? (buffer-history-limit b) 1000)
(check-false (buffer-undo-target b))
(check-false (buffer-redo-target b))
;; 编辑后：预览撤销 / 重做目标文本（不推进栈）
(view-set-point! v (point 1 2))
(void (buffer-edit! b v (op-type "Z")))                          ; hello\nwoZrld\n
(check-true (buffer-can-undo? b))
(check-equal? (buffer-depth b) 1)
(check-equal? (buffer-undo-target b) "hello\nworld\n")
(check-false (buffer-redo-target b))
(check-true (buffer-undo! b))
(check-false (buffer-can-undo? b))
(check-equal? (buffer-redo-target b) "hello\nwoZrld\n")

(displayln "core/editor/query.rkt: ok")
