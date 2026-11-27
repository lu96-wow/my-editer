#lang racket

;;; core/view/border.rkt —— 面板边框 → run（固定 Unicode 框线）
;;;
;;; 输入 panel 列表（按宿主给的顺序），输出按行合并的 run `(row col text face deep)`。
;;;
;;; **先分层，再收边**：
;;;   1. 每格归属**最高 deep 那一层**（低的被遮住）；
;;;      同层多个 panel 的 h?/v? 并集 —— 角上不同方向也能接上（不会缺臂）；
;;;      face 取该层里 weight 大者、再列表靠后者；
;;;   2. 同一格低层的边不收（被高 deep 盖住）—— 遮挡与连接一致：被盖住的边
;;;      不会在浮窗外面长出悬空臂；
;;;   3. 字形 = 该格在**可见边格集合**里的同向延续：
;;;        水平边（up/down）→ 看左右；垂直边（left/right）→ 看上下
;;;      共线相接 / 垂直相交连成 T / 十字；平行相邻不连。
;;;
;;; 这样接缝重叠（相邻 panel 共享 1 格）时，同层并集能把竖边和横边在角上接成 ┌ ┘ ├。
;;; 字形表先写死（Unicode 框线），后面再抽成可替换的 border renderer。

(require "base/rect.rkt" "panel.rkt")

(provide panels->border-cells      ; panels -> (hash (cons row col) (list glyph face deep))
         border-cells->runs        ; cells -> (listof (row col text face deep))
         panels->border-runs)      ; panels -> runs

;;; ---------- 字形：方向位掩码 → 制表符 ----------
;;;
;;; 方向位：l=1 r=2 u=4 d=8。用 16 格向量代替「排序 direction 列表 + hash-ref」，
;;; 边框每帧要为每个边格算一次字形，避免每格 sort / cons。

(define glyph-table
  (vector
   #\space                                      ; 0
   #\─ #\─ #\─                                   ; l, r, l r
   #\│ #\┘ #\└ #\┴                              ; u, l u, r u, l r u
   #\│ #\┐ #\┌ #\┬                              ; d, l d, r d, l r d
   #\│ #\┤ #\├ #\┼))                            ; d u, l d u, r d u, all

(define (border-glyph mask)
  (vector-ref glyph-table mask))

;;; ---------- 分层与可见边格 ----------
;;
;; 每格按 deep 分层：只有**最高 deep 那一层**的 panel 能贡献边（低的被遮住）。
;; 同层多个 panel 的 h?/v? **并集**（角上不同方向也能接上）；
;; face 取该层里 weight 大者、再列表靠后者。

;; → (hash (cons row col) (list glyph face deep))。
(define (panels->border-cells panels)
  ;; 收集：cell -> (list (list idx panel h? v?) ...)
  (define raw (make-hash))
  (define (edge! idx p cell h? v?)
    (hash-update! raw cell (λ (l) (cons (list idx p h? v?) l)) '()))
  (for ([p (in-list panels)] [idx (in-naturals)])
    (define r (panel-rect p))
    (define x (rect-x r)) (define y (rect-y r))
    (define w (rect-w r)) (define h (rect-h r))
    (define b (panel-borders p))
    (when (and (> w 0) (> h 0))
      (when (memq 'up b)
        (for ([c (in-range x (+ x w))]) (edge! idx p (cons y c) #t #f)))
      (when (memq 'down b)
        (for ([c (in-range x (+ x w))]) (edge! idx p (cons (sub1 (+ y h)) c) #t #f)))
      (when (memq 'left b)
        (for ([rr (in-range y (+ y h))]) (edge! idx p (cons rr x) #f #t)))
      (when (memq 'right b)
        (for ([rr (in-range y (+ y h))]) (edge! idx p (cons rr (sub1 (+ x w))) #f #t)))))
  ;; 每格：留最高 deep 那层；并 h/v；face 取该层 weight→列表序最大者。
  (define (higher-face? e f)                    ; e 比 f 更优先（同层）
    (define we (panel-weight (cadr e))) (define wf (panel-weight (cadr f)))
    (or (> we wf) (and (= we wf) (> (car e) (car f)))))
  (define info (make-hash))                     ; cell -> (list face deep h? v?)
  (for ([(cell es) (in-hash raw)])
    (define maxd (panel-deep (panel-at panels (car cell) (cdr cell))))
    (define layer (filter (λ (e) (= (panel-deep (cadr e)) maxd)) es))
    ;; 高 deep 的 panel 可能只是“盖住”了这一格，但自己在这一格没有边；
    ;; 此时低层边已被遮住，正确结果是这一格不画边，而不是把 #f 当成 panel。
    (unless (null? layer)
      (define hs (for/or ([e (in-list layer)]) (caddr e)))
      (define vs (for/or ([e (in-list layer)]) (cadddr e)))
      (define best (for/fold ([b #f]) ([e (in-list layer)])
                     (if (or (not b) (higher-face? e b)) e b)))
      (hash-set! info cell (list (panel-face (cadr best)) maxd hs vs))))
  ;; 按行建索引：row -> (cons 最小列 列向量)。相邻行的查找变成 vector-ref，
  ;; 避免每个边格 4 次 cons + hash-ref。
  (define by-row (make-hash))
  (for ([(cell dv) (in-hash info)])
    (hash-update! by-row (car cell)
                 (lambda (l) (cons (cons (cdr cell) dv) l))
                 '()))
  (define rowvecs (make-hash))
  (for ([(r entries) (in-hash by-row)])
    (define lo (for/fold ([m #f]) ([e (in-list entries)])
                 (define c (car e))
                 (if (or (not m) (< c m)) c m)))
    (define hi (for/fold ([m lo]) ([e (in-list entries)])
                 (define c (car e))
                 (if (> c m) c m)))
    (define vec (make-vector (add1 (- hi lo)) #f))
    (for ([e (in-list entries)])
      (vector-set! vec (- (car e) lo) (cdr e)))
    (hash-set! rowvecs r (cons lo vec)))

  (define (row-at rv c)
    (and rv
         (let* ([lo (car rv)] [v (cdr rv)] [i (- c lo)])
           (and (>= i 0) (< i (vector-length v)) (vector-ref v i)))))
  (define (cell-h? cell) (and cell (caddr cell)))
  (define (cell-v? cell) (and cell (cadddr cell)))

  ;; 字形：同向延续出的臂
  (define out (make-hash))
  (for ([(r rv) (in-hash rowvecs)])
    (define lo (car rv))
    (define v (cdr rv))
    (define rv-up (hash-ref rowvecs (sub1 r) #f))
    (define rv-down (hash-ref rowvecs (add1 r) #f))
    (for ([i (in-range (vector-length v))])
      (define cur (vector-ref v i))
      (when cur
        (define c (+ lo i))
        (define hh (cell-h? cur))
        (define vv (cell-v? cur))
        (define mask
          (bitwise-ior
           (if (and hh (cell-h? (row-at rv (sub1 c)))) 1 0)
           (if (and hh (cell-h? (row-at rv (add1 c)))) 2 0)
           (if (and vv (cell-v? (row-at rv-up c))) 4 0)
           (if (and vv (cell-v? (row-at rv-down c))) 8 0)))
        (hash-set! out (cons r c)
                   (list (border-glyph mask) (car cur) (cadr cur))))))
  out)

;;; ---------- 格 map → run（按行、同 deep / 同 face、连续合并） ----------

(define (border-cells->runs cells)
  (define rows (make-hash))                    ; row -> (list (col glyph deep face))
  (for ([(cell gfd) (in-hash cells)])
    (hash-update! rows (car cell)
                 (lambda (l) (cons (list (cdr cell) (car gfd) (caddr gfd) (cadr gfd)) l))
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

(define (panels->border-runs panels)
  (border-cells->runs (panels->border-cells panels)))
