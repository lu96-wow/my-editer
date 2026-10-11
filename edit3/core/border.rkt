#lang racket

;;; edit3/border.rkt —— 纯装饰层：分隔线（含交点）+ 浮窗框
;;;
;;; 平铺缝先收进一个“格集合”，每格看四邻是否也是分隔格 → 查字形表得到 ─│┌┐└┘├┤┬┴┼，
;;; 再把同行连续的格并成 run。这样 C-s/C-v 分出来的线与已存在线的**交点**会正确取 ┬/┴/├/┤/┼。
;;; 浮窗框是另一层（z = 浮窗 z），盖在平铺层之上。
;;; 输出给 adapter.render-layout 的 border run：(row col text face z)。

(provide border-runs)

(require "state.rkt" racket/list)

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

(define (border-runs g)
  (define cells (make-hash))         ; (row . col) -> #t（平铺缝）
  (for ([h (in-list (geometry-handles g))] #:when (eq? 'boundary (handle-kind h)))
    (define axis (car (handle-data h)))
    (define r (handle-rect h))
    (cond
      [(eq? axis 'h)
       (for ([row (in-range (rect-y r) (+ (rect-y r) (rect-h r)))])
         (hash-set! cells (cons row (rect-x r)) #t))]
      [else
       (for ([col (in-range (rect-x r) (+ (rect-x r) (rect-w r)))])
         (hash-set! cells (cons (rect-y r) col) #t))]))

  (append
   (cells->runs cells 0)
   ;; 浮窗框：四角 + 边（各自成 run，z = 浮窗 z）
   (append*
    (for/list ([p (in-list (geometry-placements g))]
               #:when (positive? (placement-z p)))
      (define r (placement-rect p))
      (define x (rect-x r)) (define y (rect-y r))
      (define w (rect-w r)) (define h (rect-h r))
      (define z (placement-z p))
      (define inner (make-string (max 0 (- w 2)) #\─))
      (append
       (list (list y x (string-append "┌" inner "┐") face z)
             (list (+ y h -1) x (string-append "└" inner "┘") face z))
       (for/list ([row (in-range (add1 y) (sub1 (+ y h)))]) (list row x "│" face z))
       (for/list ([row (in-range (add1 y) (sub1 (+ y h)))]) (list row (+ x w -1) "│" face z)))))))
