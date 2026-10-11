#lang racket

;;; edit2/border.rkt —— 窗口边框（原子格组合 + 自动合并）
;;;
;;; 每个有边框的窗口把自己的四条边作为**原子格**投进一个集合；重合/相邻的格按
;;; 四邻连通推出方向集，再查字形表得到 ─ │ ┌ ┐ └ ┘ ├ ┤ ┬ ┴ ┼。于是：
;;;   · 重合的边框只画一次（同一格）；
;;;   · 共享边自动取 T 字交点，而不是两个角叠在一起；
;;;   · 每个窗口可独立开关（边框 face 存在 pane 节点上）。
;;;
;;; 相邻平铺窗口共享一条边：上/左窗口画底/右边，下/右窗口**抑制**其上/左边
;;; （inset 0），所以两窗之间只有一条线。内容按画出的边内缩 1 格。
;;;
;;; 纯函数：吃 Layout 树 + 外层 placements，吐内容 placements（已内缩）+ 边框行。

(provide (struct-out border-run) border-plan border-insets)

(require "state.rkt" "layout.rkt")

;; 一段同一行、同 face 的边框字符。
(struct border-run (row col text face) #:transparent)

;;; ---------- 字形：方向集 → 一个 Unicode 制表符 ----------

(define glyph-table
  (hash '()          #\space
        '(l)         #\─ (r) #\─ '(l r) #\─
        '(u)         #\│ (d) #\│ '(u d) #\│
        '(d r)       #\┌ '(d l) #\┐ '(r u) #\└ '(l u) #\┘
        '(d r u)     #\├ '(d l u) #\┤ '(d l r) #\┬ '(l r u) #\┴
        '(d l r u)   #\┼))

(define (dir<? a b) (string<? (symbol->string a) (symbol->string b)))

(define (border-glyph dirs)
  (hash-ref glyph-table (sort (remove-duplicates dirs) dir<?) #\space))

;;; ---------- 相邻判定 ----------

(define (overlap? a0 a1 b0 b1) (< (max a0 b0) (min a1 b1)))

;; 平铺窗格（非浮窗）。
(define (tiled placements) (filter (lambda (p) (not (placement-float? p))) placements))

(define (wid-border tree wid) (layout-wid-border tree wid))

;; 某窗口四周内容内缩量：(values left top right bottom)。
(define (border-insets tree placements wid)
  (define p (for/first ([x (in-list placements)] #:when (eqv? wid (placement-wid x))) x))
  (define b (and p (wid-border tree wid)))
  (cond
    [(not b) (values 0 0 0 0)]
    [(placement-float? p) (values 1 1 1 1)]      ; 浮窗不参与平铺共享，四边都画
    [else
     (define r (placement-rect p))
     (define others (filter (lambda (x) (not (eqv? x p))) (tiled placements)))
     ;; 正上方有边框窗 → 自己的上边被抑制（线归上方窗的底边）
     (define above?
       (for/or ([a (in-list others)]
                #:when (wid-border tree (placement-wid a)))
         (define ra (placement-rect a))
         (and (= (+ (rect-y ra) (rect-h ra)) (rect-y r))
              (overlap? (rect-x ra) (+ (rect-x ra) (rect-w ra)) (rect-x r) (+ (rect-x r) (rect-w r))))))
     (define left?
       (for/or ([a (in-list others)]
                #:when (wid-border tree (placement-wid a)))
         (define ra (placement-rect a))
         (and (= (+ (rect-x ra) (rect-w ra)) (rect-x r))
              (overlap? (rect-y ra) (+ (rect-y ra) (rect-h ra)) (rect-y r) (+ (rect-y r) (rect-h r))))))
     (values (if left? 0 1) (if above? 0 1) 1 1)]))

;;; ---------- 规划：内容 placements + 边框行 ----------

(define (border-plan tree placements)
  ;; 内容 placements：按边内缩（至少 1 格）。
  (define content
    (for/list ([p (in-list placements)])
      (define-values (l t r b) (border-insets tree placements (placement-wid p)))
      (define rc (placement-rect p))
      (struct-copy placement p
                   [rect (rect (+ (rect-x rc) l) (+ (rect-y rc) t)
                               (max 1 (- (rect-w rc) l r))
                               (max 1 (- (rect-h rc) t b)))])))
  ;; 原子边框格：坐标 → face。
  (define cells (make-hash))
  (define (add-cell r c face)
    (unless (hash-has-key? cells (cons r c)) (hash-set! cells (cons r c) face)))
  (for ([p (in-list placements)])
    (define face (wid-border tree (placement-wid p)))
    (when face
      (define rc (placement-rect p))
      (define-values (l t r b) (border-insets tree placements (placement-wid p)))
      (define x0 (rect-x rc)) (define y0 (rect-y rc))
      (define x1 (+ x0 (rect-w rc) -1)) (define y1 (+ y0 (rect-h rc) -1))
      (when (= t 1) (for ([c (in-range x0 (add1 x1))]) (add-cell y0 c face)))
      (when (= b 1) (for ([c (in-range x0 (add1 x1))]) (add-cell y1 c face)))
      (when (= l 1) (for ([row (in-range y0 (add1 y1))]) (add-cell row x0 face)))
      (when (= r 1) (for ([row (in-range y0 (add1 y1))]) (add-cell row x1 face)))))
  ;; 边长连通 → 字形；按行、face 合并成连续 run。
  (define (cell? r c) (hash-has-key? cells (cons r c)))
  (define (glyph r c)
    (border-glyph
     (filter values (list (and (cell? (sub1 r) c) 'u)
                          (and (cell? (add1 r) c) 'd)
                          (and (cell? r (sub1 c)) 'l)
                          (and (cell? r (add1 c)) 'r)))))
  (define entries
    (sort (for/list ([(k v) (in-hash cells)]) (list (car k) (cdr k) v))
          (lambda (a b) (or (< (first a) (first b))
                            (and (= (first a) (first b)) (< (second a) (second b)))))))
  (define runs
    (let loop ([es entries] [acc '()] [cur #f])
      (cond
        [(null? es) (reverse (if cur (cons cur acc) acc))]
        [else
         (define r (first (car es))) (define c (second (car es))) (define f (third (car es)))
         (cond
           [(and cur (= r (border-run-row cur)) (equal? f (border-run-face cur))
                 (= c (+ (border-run-col cur) (string-length (border-run-text cur)))))
            (loop (cdr es) acc
                  (struct-copy border-run cur
                               [text (string-append (border-run-text cur) (string (glyph r c)))]))]
           [else (loop (cdr es) (if cur (cons cur acc) acc)
                       (border-run r c (string (glyph r c)) f))])])))
  (values content runs))
