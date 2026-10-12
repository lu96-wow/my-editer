#lang racket

;;; edit4/view/border.rkt —— 装饰层：缝（含交点字形）+ 浮窗框
;;;
;;; 输入 frame；输出 run 列表 (row col text face deep)。
;;; 平铺缝来自 cuts（同一条线上多段）；浮窗框按 z 分层。渲染只读 frame，不改状态。

(provide border-runs)

(require racket/list "../layout.rkt")

(define glyph-table
  (hash '()        #\space
        '(l)       #\─ '(r)       #\─ '(l r)     #\─
        '(u)       #\│ '(d)       #\│ '(d u)     #\│
        '(d r)     #\┌ '(d l)     #\┐ '(r u)     #\└ '(l u)   #\┘
        '(d r u)   #\├ '(d l u)   #\┤ '(d l r)   #\┬ '(l r u) #\┴
        '(d l r u) #\┼))

(define (dir<? a b) (string<? (symbol->string a) (symbol->string b)))
(define (glyph ds) (hash-ref glyph-table (sort (remove-duplicates ds) dir<?) #\space))

(define (cells->runs cells face deep)
  (define (cell? r c) (hash-has-key? cells (cons r c)))
  (define (g r c)
    (glyph (filter values (list (and (cell? (sub1 r) c) 'u)
                                (and (cell? (add1 r) c) 'd)
                                (and (cell? r (sub1 c)) 'l)
                                (and (cell? r (add1 c)) 'r)))))
  (define entries
    (sort (hash-keys cells)
          (lambda (a b) (or (< (car a) (car b)) (and (= (car a) (car b)) (< (cdr a) (cdr b)))))))
  (let loop ([es entries] [acc '()] [cur #f])
    (cond
      [(null? es) (reverse (if cur (cons cur acc) acc))]
      [else
       (define r (caar es)) (define c (cdar es))
       (cond
         [(and cur (= r (list-ref cur 0)) (= c (+ (list-ref cur 1) (string-length (list-ref cur 2)))))
          (loop (cdr es) acc
                (list r (list-ref cur 1) (string-append (list-ref cur 2) (string (g r c)))
                      (list-ref cur 3) (list-ref cur 4)))]
         [else (loop (cdr es) (if cur (cons cur acc) acc) (list r c (string (g r c)) face deep))])])))

(define (border-runs fr)
  ;; 平铺缝：所有 cut 的所有格
  (define cells (make-hash))
  (for ([cut (in-list (geometry-cuts (frame-tiled fr)))])
    (for ([seg (in-list (cut-segs cut))])
      (for ([t (in-range (seg-span-lo seg) (seg-span-hi seg))])
        (hash-set! cells (if (eq? 'x (cut-axis cut)) (cons t (cut-offset cut)) (cons (cut-offset cut) t)) #t))))
  (define fs (frame-float-rects fr))
  (define n (length fs))
  (append
   (cells->runs cells 'window-border 0)
   (append*
    (for/list ([p (in-list fs)] [i (in-naturals)])
      (define r (cdr p))
      (define z (- n i))                       ; 表头最上
      (define x (rect-x r)) (define y (rect-y r))
      (define w (rect-w r)) (define h (rect-h r))
      (define deep (+ 1 (* 2 z)))              ; 框在自身内容之上
      (define inner (make-string (max 0 (- w 2)) #\─))
      (append
       (list (list y x (string-append "┌" inner "┐") 'window-border deep)
             (list (+ y h -1) x (string-append "└" inner "┘") 'window-border deep))
       (for/list ([row (in-range (add1 y) (sub1 (+ y h)))]) (list row x "│" 'window-border deep))
       (for/list ([row (in-range (add1 y) (sub1 (+ y h)))]) (list row (+ x w -1) "│" 'window-border deep)))))))
