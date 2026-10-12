#lang racket

;;; edit3/border.rkt —— 纯装饰层：分隔线（含交点）+ 浮窗框
;;;
;;; 平铺缝：只有**相邻窗口里至少一个有边框**时，这 1 格缝才画线（每窗口可独立开关边框，
;;; 见 config 的 borders-on? / border-style 与 C-t）。格集合再按四邻查字形表得到
;;; ─│┌┐└┘├┤┬┴┼，相邻格并成 run。
;;; 浮窗框是另一层（z = 浮窗 z），盖在平铺层之上；浮窗无边框则不画。
;;; 输出给 adapter.render-layout 的 border run：(row col text face z)。

(provide border-runs content-placements)

(require "state.rkt" "window.rkt" racket/list)

(define face 'window-border)

;;; ---------- 方向集 → 制表符 ----------

(define glyph-table
  (hash '()        #\space
        '(l)       #\─ '(r)       #\─ '(l r)     #\─
        '(u)       #\│ '(d)       #\│ '(d u)     #\│
        '(d r)     #\┌ '(d l)     #\┐ '(r u)     #\└ '(l u)   #\┘
        '(d r u)   #\├ '(d l u)   #\┤ '(d l r)   #\┬ '(l r u) #\┴
        '(d l r u) #\┼))

(define (dir<? a b) (string<? (symbol->string a) (symbol->string b)))
(define (glyph dirs) (hash-ref glyph-table (sort (remove-duplicates dirs) dir<?) #\space))

;; 格集合 → 合并后的 run（同一行、连续格并成一段）。
(define (cells->runs cells z)
  (define (cell? r c) (hash-has-key? cells (cons r c)))
  (define (g r c)
    (glyph (filter values (list (and (cell? (sub1 r) c) 'u)
                                (and (cell? (add1 r) c) 'd)
                                (and (cell? r (sub1 c)) 'l)
                                (and (cell? r (add1 c)) 'r)))))
  (define entries
    (sort (for/list ([(k _) (in-hash cells)]) k)
          (lambda (a b) (or (< (car a) (car b))
                            (and (= (car a) (car b)) (< (cdr a) (cdr b)))))))
  (let loop ([es entries] [acc '()] [cur #f])
    (cond
      [(null? es) (reverse (if cur (cons cur acc) acc))]
      [else
       (define r (caar es))
       (define c (cdar es))
       (cond
         [(and cur (= r (list-ref cur 0))
               (= c (+ (list-ref cur 1) (string-length (list-ref cur 2)))))
          (loop (cdr es) acc
                (list r (list-ref cur 1)
                      (string-append (list-ref cur 2) (string (g r c)))
                      (list-ref cur 3) (list-ref cur 4)))]
         [else
          (loop (cdr es) (if cur (cons cur acc) acc)
                (list r c (string (g r c)) face z))])])))

;;; ---------- 分隔线 + 浮窗框 ----------

;; 某格四周紧邻的**平铺**窗口里，是否有带边框者。
(define (adjacent-bordered? st tiled row col)
  (for/or ([p (in-list tiled)])
    (define r (placement-rect p))
    (and (wid-border st (placement-wid p))
         (or (and (= (+ (rect-x r) (rect-w r)) col)          ; 窗在左
                  (<= (rect-y r) row) (< row (+ (rect-y r) (rect-h r))))
             (and (= (rect-x r) (add1 col))                   ; 窗在右
                  (<= (rect-y r) row) (< row (+ (rect-y r) (rect-h r))))
             (and (= (+ (rect-y r) (rect-h r)) row)           ; 窗在上
                  (<= (rect-x r) col) (< col (+ (rect-x r) (rect-w r))))
             (and (= (rect-y r) (add1 row))                   ; 窗在下
                  (<= (rect-x r) col) (< col (+ (rect-x r) (rect-w r))))))))

;; 某格四邻（正交）是否是平铺窗口内容（不论边框）。
(define (in-rect? r x y)
  (and (<= (rect-x r) x) (< x (+ (rect-x r) (rect-w r)))
       (<= (rect-y r) y) (< y (+ (rect-y r) (rect-h r)))))

(define (adjacent-tile? tiled row col)
  (for/or ([p (in-list tiled)])
    (define r (placement-rect p))
    (or (in-rect? r col (sub1 row))
        (in-rect? r col (add1 row))
        (in-rect? r (sub1 col) row)
        (in-rect? r (add1 col) row))))

;; 某格四角（对角）紧邻的平铺窗口里是否有带边框者。
;; 只在四窗相交的十字路口用得上：路口格的四个正交邻居都是缝格、没有窗口，
;; 四窗恰好在对角；此时对角任一窗口有边框，这个路口就该连上。
(define (diagonal-bordered? st tiled row col)
  (for/or ([p (in-list tiled)] #:when (wid-border st (placement-wid p)))
    (define r (placement-rect p))
    (or (in-rect? r (sub1 col) (sub1 row))
        (in-rect? r (add1 col) (sub1 row))
        (in-rect? r (sub1 col) (add1 row))
        (in-rect? r (add1 col) (add1 row)))))

;; 一格缝是否该画：通常看正交邻居窗口；四窗相交的路口没有正交窗口，改看对角窗口。
(define (seam-cell? st tiled row col)
  (or (adjacent-bordered? st tiled row col)
      (and (not (adjacent-tile? tiled row col))
           (diagonal-bordered? st tiled row col))))

;; 内容 placements：浮窗有框时四边内缩 1 格（框画在原矩形边上，不压内容）。
;; geometry / 命中 / 拖拽仍用原矩形，只有渲染（view 尺寸）用内缩后的。
(define (content-placements st placements)
  (for/list ([p (in-list placements)])
    (define r (placement-rect p))
    (if (and (positive? (placement-z p)) (wid-border st (placement-wid p)))
        (struct-copy placement p
                     [rect (rect (add1 (rect-x r)) (add1 (rect-y r))
                                 (max 1 (- (rect-w r) 2)) (max 1 (- (rect-h r) 2)))])
        p)))

(define (border-runs st g)
  (define placements (geometry-placements g))
  (define tiled (filter (lambda (p) (zero? (placement-z p))) placements))
  (define cells (make-hash))         ; (row . col) -> #t（平铺缝）
  (for ([h (in-list (geometry-handles g))] #:when (eq? 'boundary (handle-kind h)))
    (define axis (car (handle-data h)))
    (define r (handle-rect h))
    (cond
      [(eq? axis 'h)
       (for ([row (in-range (rect-y r) (+ (rect-y r) (rect-h r)))])
         (when (seam-cell? st tiled row (rect-x r))
           (hash-set! cells (cons row (rect-x r)) #t)))]
      [else
       (for ([col (in-range (rect-x r) (+ (rect-x r) (rect-w r)))])
         (when (seam-cell? st tiled (rect-y r) col)
           (hash-set! cells (cons (rect-y r) col) #t)))]))

  (append
   (cells->runs cells 0)
   ;; 浮窗框：有边框才画；四角 + 边（各自成 run，z = 浮窗 z）
   (append*
    (for/list ([p (in-list placements)]
               #:when (and (positive? (placement-z p)) (wid-border st (placement-wid p))))
      (define r (placement-rect p))
      (define x (rect-x r)) (define y (rect-y r))
      (define w (rect-w r)) (define h (rect-h r))
      (define z (placement-z p))
      (define f (wid-border st (placement-wid p)))
      (define inner (make-string (max 0 (- w 2)) #\─))
      (append
       (list (list y x (string-append "┌" inner "┐") f z)
             (list (+ y h -1) x (string-append "└" inner "┘") f z))
       (for/list ([row (in-range (add1 y) (sub1 (+ y h)))]) (list row x "│" f z))
       (for/list ([row (in-range (add1 y) (sub1 (+ y h)))]) (list row (+ x w -1) "│" f z)))))))
