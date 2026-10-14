#lang racket

;;; edit/core-render/border.rkt —— 布局边框 → 装饰 pane（渲染后端的一部分）
;;;
;;; 每块面板**自己画自己的框**：只用直线 ─ │ 和角 ┌ ┐ └ ┘。
;;; 不做跨框邻接判定、不出 T/十字 —— 邻接就是两块框挨着，各画各的。
;;; 同一格被多块框覆盖时，**deep 高的盖住低的**（边覆盖）。
;;;
;;; 每块框的 face 由 panel 带（符号标签），输出 run 里带上 → 由 theme 解析成颜色。
;;; 这里是“画”：字形 + face + 深度都在这；layout 只给几何（panel）。
;;;
;;; 遮挡由 core 的合成按 deep 决定：边框作为 decoration 进同一张 screen，
;;; screen-patch 逐格 diff，框移动 / 消失的旧格自动清掉（增量 + 清旧位置由 core 负责）。

(require "../layout-base/rect.rkt" "../layout-base/panel.rkt"
         "../../core/editor.rkt")

(provide panels->border-runs      ; (listof panel) -> (listof (row col text face deep))
         panels->decorations)     ; (listof panel) -> (listof pane)

;; 一个格出现在它所属框的哪些边（up/down/left/right）→ 字形。只认直线 + 角。
(define (edge-glyph es)
  (define u (and (memq 'up es) #t))
  (define d (and (memq 'down es) #t))
  (define l (and (memq 'left es) #t))
  (define r (and (memq 'right es) #t))
  (cond
    [(and u l (not d) (not r)) #\┌]
    [(and u r (not d) (not l)) #\┐]
    [(and d l (not u) (not r)) #\└]
    [(and d r (not u) (not l)) #\┘]
    [(and (or u d) (or l r))   #\┼]     ; 退化（1×1 / 宽高 1 的角）
    [(or u d) #\─]
    [(or l r) #\│]
    [else #\space]))

;; 一块面板的边框格 → (listof (list (cons r c) glyph))。按存在的边铺；角由边组合决定。
(define (panel-border-cells p)
  (define r (panel-rect p))
  (define x (rect-x r)) (define y (rect-y r))
  (define w (rect-w r)) (define h (rect-h r))
  (define b (panel-borders p))
  (define cells (make-hash))                 ; (cons r c) -> (listof edge)
  (define (add! rr cc e)
    (hash-update! cells (cons rr cc)
                 (lambda (old) (if (memq e old) old (cons e old))) '()))
  (when (and (> w 0) (> h 0))
    (when (memq 'up b)
      (for ([c (in-range x (+ x w))]) (add! y c 'up)))
    (when (memq 'down b)
      (for ([c (in-range x (+ x w))]) (add! (sub1 (+ y h)) c 'down)))
    (when (memq 'left b)
      (for ([rr (in-range y (+ y h))]) (add! rr x 'left)))
    (when (memq 'right b)
      (for ([rr (in-range y (+ y h))]) (add! rr (sub1 (+ x w)) 'right))))
  (for/list ([(cell es) (in-hash cells)]) (list cell (edge-glyph es))))

;; → (listof (list row col text face deep))。同格 deep 高者胜（同 deep 保留先出现的）；
;; 同一行连续、同 deep、同 face 的格合成一段。
(define (panels->border-runs ps)
  (define cell-val (make-hash))               ; (cons r c) -> (list deep face glyph)
  (for ([p (in-list ps)])
    (define dp (panel-deep p))
    (define fc (panel-face p))
    (for ([cg (in-list (panel-border-cells p))])
      (match-define (list cell g) cg)
      (hash-update! cell-val cell
                   (lambda (old) (if (and old (>= (car old) dp)) old (list dp fc g)))
                   #f)))
  (define rows (make-hash))                   ; row -> (list (list col glyph deep face))
  (for ([(cell dv) (in-hash cell-val)])
    (hash-update! rows (car cell)
                 (lambda (l) (cons (list (cdr cell) (caddr dv) (car dv) (cadr dv)) l)) '()))
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
