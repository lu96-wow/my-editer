#lang racket

;;; edit-tui/core-render/border.rkt —— 布局边框 → 装饰 pane（渲染后端的一部分）
;;;
;;; 每块 panel 按自己的 `borders` 把边框格投进一张**全局集合**（跨 panel 收集）。
;;; 每格记两件事：它属于**水平边**（up/down）还是**垂直边**（left/right）——角上两者都真。
;;;
;;; 字形由「这个格有没有臂」决定，而臂只在**同向延续**时才产生：
;;;   水平边 → 看左右邻居是不是也属于水平边
;;;   垂直边 → 看上下邻居是不是也属于垂直边
;;; 于是：
;;;   · 共线相接的边连起来（两块框的顶边接成一条线）；
;;;   · 垂直相交处出 T / 十字（├ ┤ ┬ ┴ ┼）；
;;;   · **平行相邻的边不连**——两条并排竖线各自是 │，不会合成 ├ ┤。
;;;
;;; 同一格被多块框覆盖时，face / deep 取 **deep 高者**（同 deep 先出现者胜）；
;;; 水平/垂直标记是所有框的并集（这样跨框的相交仍能成 T/十字）。
;;;
;;; face 由 panel 带（符号标签），输出 run 里带上 → 由 theme 解析成颜色。
;;; 遮挡由 core 的合成按 deep 决定：边框作为 decoration 进同一张 screen，
;;; screen-patch 逐格 diff，框移动 / 消失的旧格自动清掉。

(require "../layout-base/rect.rkt" "../layout-base/panel.rkt"
         "../../core/editor.rkt")

(provide panels->border-runs      ; (listof panel) -> (listof (row col text face deep))
         panels->decorations)     ; (listof panel) -> (listof pane)

;;; ---------- 字形：方向集 → 制表符 ----------
;;;
;;; 方向是「从这个格往外伸出的臂」：u / d / l / r。

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

;; 一块 panel 的边格 → (listof (list (cons row col) h? v?))。
;; up/down 是水平边（h），left/right 是垂直边（v）；角上同一格 h 和 v 都真。
(define (panel-edge-cells p)
  (define r (panel-rect p))
  (define x (rect-x r)) (define y (rect-y r))
  (define w (rect-w r)) (define h (rect-h r))
  (define b (panel-borders p))
  (if (or (<= w 0) (<= h 0))
      '()
      (append
       (if (memq 'up b)    (for/list ([c  (in-range x (+ x w))]) (list (cons y c) #t #f)) '())
       (if (memq 'down b)  (for/list ([c  (in-range x (+ x w))]) (list (cons (sub1 (+ y h)) c) #t #f)) '())
       (if (memq 'left b)  (for/list ([rr (in-range y (+ y h))]) (list (cons rr x) #f #t)) '())
       (if (memq 'right b) (for/list ([rr (in-range y (+ y h))]) (list (cons rr (sub1 (+ x w))) #f #t)) '()))))

;; → (listof (list row col text face deep))。同格 deep 高者胜（同 deep 先出现者胜）；
;; 同一行连续、同 deep、同 face 的格合成一段。
(define (panels->border-runs ps)
  ;; 1. 全局边收集：格 -> (list deep face h? v?)。
  (define cell-info (make-hash))
  (for ([p (in-list ps)])
    (define dp (panel-deep p))
    (define fc (panel-face p))
    (for ([e (in-list (panel-edge-cells p))])
      (match-define (list cell eh ev) e)
      (define old (hash-ref cell-info cell #f))
      (cond
        [(not old) (hash-set! cell-info cell (list dp fc eh ev))]
        [else
         (define higher? (> dp (car old)))          ; 同 deep 保留先出现者
         (hash-set! cell-info cell
                    (list (if higher? dp (car old))
                          (if higher? fc (cadr old))
                          (or eh (caddr old))           ; 水平/垂直标记取并集
                          (or ev (cadddr old))))])))
  ;; 2. 字形 = 同向延续出的臂（水平看左右、垂直看上下）。
  (define (info r c) (hash-ref cell-info (cons r c) #f))
  (define (h? r c) (and (info r c) (caddr (info r c))))
  (define (v? r c) (and (info r c) (cadddr (info r c))))
  (define (glyph-at r c)
    (define cur (info r c))
    (define h (caddr cur)) (define v (cadddr cur))
    (border-glyph
     (filter values
             (list (and h (h? r      (sub1 c)) 'l)
                   (and h (h? r      (add1 c)) 'r)
                   (and v (v? (sub1 r) c)      'u)
                   (and v (v? (add1 r) c)      'd)))))
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

  ;; 单框：四角 + 直线
  (define one (list (make-panel 'a (rect 0 0 4 3) borders-all)))
  (check-true (has? one #\┌))
  (check-true (has? one #\┐))
  (check-true (has? one #\└))
  (check-true (has? one #\┘))

  ;; 共线延续 + 垂直相交：A 缺底边，B 在下方接上 → ├
  (define t
    (list (make-panel 'a (rect 0 0 5 3) '(up left right))
          (make-panel 'b (rect 0 3 5 3) borders-all)))
  (check-true (has? t #\├))

  ;; 平行相邻不连：两块并排、都画满 → 两条竖线各自 │，不合成 ├ / ┤
  (define side-by-side
    (list (make-panel 'a (rect 0 0 5 3) borders-all)
          (make-panel 'b (rect 5 0 5 3) borders-all)))
  (check-false (has? side-by-side #\├))
  (check-false (has? side-by-side #\┤))

  ;; 上下相贴的两条平行横边也不连：A 底边与 B 顶边各自 ─，不合成 ┬ / ┴
  (define stacked
    (list (make-panel 'a (rect 0 0 5 3) borders-all)
          (make-panel 'b (rect 0 3 5 3) borders-all)))
  (check-false (has? stacked #\┬))
  (check-false (has? stacked #\┴))

  ;; 全无边框 → 无 run
  (check-equal? (panels->border-runs (list (make-panel 'a (rect 0 0 4 3) borders-none))) '())
  (displayln "border.rkt: ok"))
