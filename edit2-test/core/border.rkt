#lang racket

;;; edit2-test/border.rkt —— 窗口边框（原子格组合 + 合并 + 开关）

(require rackunit
         racket/list
         "../../edit2/core/border.rkt"
         "../../edit2/core/layout.rkt"
         "../../edit2/core/state.rkt"
         "../../edit2/core/theme.rkt")

;; 两个都有边框的左右窗：共享一条竖线（中间列只出现一次），顶部 T 字
(define t (split 'h (list (cons 'flex (pane 'w1 'a 'window-border))
                          (cons 'flex (pane 'w2 'b 'window-border)))))
(define ps (layout t (cons 20 5)))
(define-values (content runs) (border-plan t ps))

(define (c-rect cps w)
  (placement-rect (findf (lambda (p) (eqv? w (placement-wid p))) cps)))
(define (runs-at runs r)
  (sort (filter (lambda (b) (= r (border-run-row b))) runs) < #:key border-run-col))

;; 内容内缩：左窗四边 1；右窗左边被抑制（共享线归左窗右边）
(check-equal? (c-rect content 'w1) (rect 1 1 8 3))
(check-equal? (c-rect content 'w2) (rect 10 1 9 3))

;; 顶边：一整条 20 格，第 9 格是 T 字交点
(define top (findf (lambda (b) (= 0 (border-run-row b))) runs))
(check-equal? (border-run-col top) 0)
(check-equal? (string-length (border-run-text top)) 20)
(check-equal? (string-ref (border-run-text top) 9) #\┬)   ; ├ ┤ ┬ ┴ ┼
(check-equal? (string-ref (border-run-text top) 0) #\┌)
(check-equal? (string-ref (border-run-text top) 19) #\┐)

;; 中间行：三条竖线（左窗左、共享、右窗右），共享线只画一次
(define mid (runs-at runs 1))
(check-equal? (map border-run-col mid) '(0 9 19))
(check-equal? (map border-run-text mid) '("│" "│" "│"))

;; 关掉左窗边框：共享线变成右窗自己的左边（col 10），左窗不再有边
(define t2 (layout-set-pane-border t 'w1 #f))
(define-values (content2 runs2) (border-plan t2 ps))
(check-equal? (c-rect content2 'w1) (rect 0 0 10 5))
(check-equal? (c-rect content2 'w2) (rect 11 1 8 3))
(check-equal? (map border-run-col (runs-at runs2 1)) '(10 19))

;; 全部无边框 → 没有边框行、内容不内缩
(define t3 (layout-set-pane-border t2 'w2 #f))
(define-values (content3 runs3) (border-plan t3 ps))
(check-equal? runs3 '())
(check-equal? (c-rect content3 'w1) (rect 0 0 10 5))

;; ---- 矮面板贴着有边框的窗口下方：顶边合并，底边画出来（面板被包进边框） ----
;; 2 行：1 行内容 + 1 行底边；状态栏就是这种情况。
(define tv (split 'v (list (cons 'flex (pane 'w1 'a 'window-border))
                           (cons 2    (pane 'w2 'b 'window-border)))))
(define pv (layout tv (cons 20 6)))
(define-values (cv rv) (border-plan tv pv))
(check-equal? (c-rect cv 'w2) (rect 1 4 18 1))                 ; 只有 1 行内容，顶边被上方窗合并
(check-equal? (map border-run-col (runs-at rv 5)) '(0))        ; 底边一整行
(check-equal? (string-length (border-run-text (car (runs-at rv 5)))) 20)
(check-equal? (map border-run-col (runs-at rv 4)) '(0 19))     ; 两侧竖线，无顶边

;; 孤立矮窗（上下都放不下边框）→ 整个窗口不放边框，内容不内缩
(define tv2 (pane 'w1 'a 'window-border))
(define pv2 (layout tv2 (cons 20 2)))
(define-values (cv2 rv2) (border-plan tv2 pv2))
(check-equal? rv2 '())
(check-equal? (c-rect cv2 'w1) (rect 0 0 20 2))

;; ---- 主题：命名 face → 真彩色 / 256 色 ----
(check-true (regexp-match? #rx"38;2;105;112;128" (face-bytes 'window-border)))   ; 真彩色
(check-true (regexp-match? #rx"38;5;196" (face-bytes (style 196 #f '()))))       ; 256 色
(check-equal? (face-bytes 'no-such-face) #"")                                    ; 未命名 → 无样式
(check-true (> (bytes-length (face-bytes 'status-bar)) 0))
(check-equal? (face-bytes 'input) #"")   ; 输入行提示不加颜色修饰

;; ---- 浮窗边框分层：run 带窗口 z（平铺 0，浮窗 1…），供 adapter 按 2z+1 叠装饰 ----
(define tfl (split 'h (list (cons 'flex (pane 'w1 'a 'window-border))
                            (cons 0 (float 'wf 'f 'window-border (anchor #f 'left 'top 0 0) 6 4)))))
(define-values (_cfl rfl) (border-plan tfl (layout tfl (cons 20 8))))
(check-true (for/or ([b (in-list rfl)]) (= 0 (border-run-z b))))   ; 平铺边框 z=0
(check-true (for/or ([b (in-list rfl)]) (= 1 (border-run-z b))))   ; 浮窗边框 z=1

(displayln "edit2/border.rkt: all tests passed")
