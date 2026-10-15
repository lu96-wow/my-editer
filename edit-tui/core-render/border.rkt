#lang racket

;;; edit-tui/core-render/border.rkt —— 布局边框 → 装饰 pane（渲染后端的一部分）
;;;
;;; **跨 panel 的边收集**：把所有 panel 的边框格投进同一张集合，某格画什么字形
;;; 由它在集合里的**四邻连接**决定，而不是由单块 panel 自己的边决定。于是相邻 /
;;; 相接的边自动收成 T 与十字：├ ┤ ┬ ┴ ┼。每块 panel 只声明自己哪几条边存在
;;; （borders，每边可选）——「哪块框画哪条边」在布局层，「边怎么接」在这一层。
;;;
;;; 同一格被多块框覆盖时，face / deep 取 **deep 高者**（同 deep 先出现者胜）。
;;; 字形只由格集合决定，与 face / deep 无关。
;;;
;;; face 由 panel 带（符号标签），输出 run 里带上 → 由 theme 解析成颜色。
;;; 遮挡由 core 的合成按 deep 决定：边框作为 decoration 进同一张 screen，
;;; screen-patch 逐格 diff，框移动 / 消失的旧格自动清掉。
;;;
;;; 注意这是 **per-panel 逐边** 模型：两块 panel 紧挨且都画共享那条边时会产生两条
;;; 相邻平行线（读成 ├ ┤），不会自动并线；不想并就由调用方用 borders 抑制一条
;;; （布局不猜）。要单线共享边，就让「缝」只由一侧声明。

(require "../layout-base/rect.rkt" "../layout-base/panel.rkt"
         "../../core/editor.rkt")

(provide panels->border-runs      ; (listof panel) -> (listof (row col text face deep))
         panels->decorations)     ; (listof panel) -> (listof pane)

;;; ---------- 字形：方向集 → 制表符 ----------
;;;
;;; 方向是「从这个格往外伸出的臂」：u / d / l / r。方向集由四邻连接算出，
;;; 不是由边标签直接算出——所以共享边 / 相交处自然得到 T 与十字。

(define glyph-table
  (hash '()        #\space
        '(l)       #\─ '(r)       #\─ '(l r)     #\─
        '(u)       #\│ '(d)       #\│ '(d u)     #\│
        '(d r)     #\┌ '(d l)     #\┐ '(r u)     #\└ '(l u)   #\┘
        '(d r u)   #\├ '(d l u)   #\┤ '(d l r)   #\┬ '(l r u) #\┴
        '(d l r u) #\┼))

(define (dir<? a b) (string<? (symbol->string a) (symbol->string b)))

(define (border-glyph dirs)
  (hash-ref glyph-table (sort (remove-duplicates dirs) dir<?) #\space))

;;; ---------- 边收集 ----------

;; 一块 panel 的边框格 → (listof (cons row col))。按存在的边铺；角 / T / 十字由
;; 全局四邻连接决定，这里只负责「这块框占了哪些格」。
(define (panel-edge-cells p)
  (define r (panel-rect p))
  (define x (rect-x r)) (define y (rect-y r))
  (define w (rect-w r)) (define h (rect-h r))
  (define b (panel-borders p))
  (if (or (<= w 0) (<= h 0))
      '()
      (append
       (if (memq 'up b)    (for/list ([c  (in-range x (+ x w))]) (cons y c)) '())
       (if (memq 'down b)  (for/list ([c  (in-range x (+ x w))]) (cons (sub1 (+ y h)) c)) '())
       (if (memq 'left b)  (for/list ([rr (in-range y (+ y h))]) (cons rr x)) '())
       (if (memq 'right b) (for/list ([rr (in-range y (+ y h))]) (cons rr (sub1 (+ x w)))) '()))))

;; → (listof (list row col text face deep))。同格 deep 高者胜（同 deep 先出现者胜）；
;; 同一行连续、同 deep、同 face 的格合成一段。
(define (panels->border-runs ps)
  ;; 1. 全局边收集：格 -> (list deep face)。
  (define cell-info (make-hash))
  (for ([p (in-list ps)])
    (define dp (panel-deep p))
    (define fc (panel-face p))
    (for ([cell (in-list (panel-edge-cells p))])
      (define old (hash-ref cell-info cell #f))
      (when (or (not old) (> dp (car old)))       ; 同 deep 保留先出现者
        (hash-set! cell-info cell (list dp fc)))))
  ;; 2. 字形 = 该格在全局集合里的四邻连接。
  (define (cell? r c) (hash-has-key? cell-info (cons r c)))
  (define (glyph-at r c)
    (border-glyph
     (filter values
             (list (and (cell? (sub1 r) c)      'u)
                   (and (cell? (add1 r) c)      'd)
                   (and (cell? r      (sub1 c)) 'l)
                   (and (cell? r      (add1 c)) 'r)))))
  ;; 3. 逐行、同 deep / 同 face、连续 → run。
  (define rows (make-hash))                   ; row -> (list (list col glyph deep face))
  (for ([(cell dv) (in-hash cell-info)])
    (hash-update! rows (car cell)
                 (lambda (l) (cons (list (cdr cell)
                                         (glyph-at (car cell) (cdr cell))
                                         (car dv) (cadr dv))
                                   l))
                 '()))
  (append*
   (for/list ([(r cs) (in-hash rows)])
     (define sorted (sort cs < #:key car))
     (let loop ([cs sorted] [cur #f] [acc '()])   ; cur = (row col text face deep)
       (cond
         [(null? cs) (reverse (if cur (cons cur acc) acc))]
         [else
          (match-define (list c g dp fc) (car cs))
          (cond
            [(and cur
                  (= dp (list-ref cur 4))
                  (equal? fc (list-ref cur 3))
                  (= c (+ (list-ref cur 1) (string-length (list-ref cur 2)))))
             (loop (cdr cs)
                   (list r (list-ref cur 1)
                         (string-append (list-ref cur 2) (string g)) fc dp)
                   acc)]
            [else
             (loop (cdr cs) (list r c (string g) fc dp)
                   (if cur (cons cur acc) acc))])])))))

;; → (listof pane)，每段一个 1×N 的 pane（face / deep 都来自该框）。
(define (panels->decorations ps)
  (for/list ([b (in-list (panels->border-runs ps))])
    (match-define (list row col text face deep) b)
    (pane row col
          (screen (string-length text) 1
                  (vector (list (run 0 text face))) '() '())
          deep)))

(module+ test
  (require rackunit)
  (define (texts ps) (map (lambda (r) (list-ref r 2)) (panels->border-runs ps)))
  (define (has? ps ch)
    (for/or ([t (in-list (texts ps))]) (regexp-match? (regexp (string ch)) t)))

  ;; 单框：四角 + 直线（连接法对正常尺寸退化成矩形框）
  (define one (list (make-panel 'a (rect 0 0 4 3) borders-all)))
  (check-true (has? one #\┌))
  (check-true (has? one #\┐))
  (check-true (has? one #\└))
  (check-true (has? one #\┘))

  ;; 跨 panel 的 T：A 缺底边，B 在下方接上；在共享列上收成 ├
  (define t
    (list (make-panel 'a (rect 0 0 5 3) '(up left right))
          (make-panel 'b (rect 0 3 5 3) borders-all)))
  (check-true (has? t #\├))

  ;; 全无边框 → 无 run
  (check-equal? (panels->border-runs (list (make-panel 'a (rect 0 0 4 3) borders-none))) '())
  (displayln "border.rkt: ok"))
