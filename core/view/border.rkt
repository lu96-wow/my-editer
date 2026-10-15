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

;;; ---------- 字形：方向集 → 制表符 ----------

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
    (define hs (for/or ([e (in-list layer)]) (caddr e)))
    (define vs (for/or ([e (in-list layer)]) (cadddr e)))
    (define best (for/fold ([b #f]) ([e (in-list layer)])
                   (if (or (not b) (higher-face? e b)) e b)))
    (hash-set! info cell (list (panel-face (cadr best)) maxd hs vs)))
  ;; 字形：同向延续出的臂
  (define (at r c) (hash-ref info (cons r c) #f))
  (define (h? r c) (and (at r c) (caddr (at r c))))
  (define (v? r c) (and (at r c) (cadddr (at r c))))
  (define (glyph-at r c)
    (define cur (at r c))
    (define hh (caddr cur)) (define vv (cadddr cur))
    (border-glyph
     (filter values
             (list (and hh (h? r      (sub1 c)) 'l)
                   (and hh (h? r      (add1 c)) 'r)
                   (and vv (v? (sub1 r) c)      'u)
                   (and vv (v? (add1 r) c)      'd)))))
  (for/hash ([(cell _) (in-hash info)])
    (define dv (hash-ref info cell))
    (values cell (list (glyph-at (car cell) (cdr cell)) (car dv) (cadr dv)))))

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

(module+ test
  (require rackunit)
  (define (texts panels) (map (lambda (r) (list-ref r 2)) (panels->border-runs panels)))
  (define (has? panels ch)
    (for/or ([t (in-list (texts panels))]) (regexp-match? (regexp (string ch)) t)))
  (define (mk v x y w h b #:deep [d 0]) (make-panel v (rect x y w h) b #:deep d))

  ;; 单框：四角
  (define one (list (mk 'a 0 0 4 3 borders-all)))
  (check-true (has? one #\┌)) (check-true (has? one #\┐))
  (check-true (has? one #\└)) (check-true (has? one #\┘))

  ;; 共线 + 垂直相交：A 缺底边，B 在下接上 → ├
  (check-true (has? (list (mk 'a 0 0 5 3 '(up left right))
                          (mk 'b 0 3 5 3 borders-all)) #\├))

  ;; 平行相邻不连
  (check-false (has? (list (mk 'a 0 0 5 3 borders-all) (mk 'b 5 0 5 3 borders-all)) #\├))
  (check-false (has? (list (mk 'a 0 0 5 3 borders-all) (mk 'b 5 0 5 3 borders-all)) #\┤))

  ;; 遮挡：高 deep 浮窗盖住低层边框格 → 该格不收（无悬空臂）
  ;; 低层横线 row2 cols0..7（face lo-face），浮窗 (2,2,4,2) 盖住 row2 cols2..5
  (define occl (list (make-panel 'lo (rect 0 2 8 1) '(up) #:face 'lo-face)
                     (make-panel 'hi (rect 2 2 4 2) borders-all #:deep 10 #:face 'hi-face)))
  (define (lo-run-covers? r)
    (and (eq? (list-ref r 3) 'lo-face)
         (= (car r) 2) (<= (cadr r) 2)
         (> (+ (cadr r) (string-length (caddr r))) 2)))
  (check-false (for/or ([r (in-list (panels->border-runs occl))]) (lo-run-covers? r)))
  ;; 未被盖住的左端仍在
  (check-true (for/or ([r (in-list (panels->border-runs occl))])
                (and (eq? (list-ref r 3) 'lo-face) (= (car r) 2) (= (cadr r) 0))))

  ;; weight：同 deep 时边框 face 由 big weight 决定（默认 0 → 列表靠后）
  (define (cell-face ps r c) (list-ref (hash-ref (panels->border-cells ps) (cons r c)) 1))
  (define p0 (make-panel 'a (rect 0 0 10 6) borders-all #:face 'a-face #:weight 0))
  (define p1 (make-panel 'b (rect 9 0 10 6) borders-all #:face 'b-face #:weight 1))
  (check-equal? (cell-face (list p0 p1) 1 9) 'b-face)        ; weight 1 赢
  (check-equal? (cell-face (list p1 p0) 1 9) 'b-face)        ; 与列表序无关
  (define p0* (make-panel 'a (rect 0 0 10 6) borders-all #:face 'a-face #:weight 2))
  (check-equal? (cell-face (list p0* p1) 1 9) 'a-face)       ; 更大的 weight 赢
  ;; deep 仍然压过 weight：高 deep 浮窗（weight 0）盖住 weight 高的低层
  (define f (make-panel 'f (rect 9 2 5 2) borders-all #:deep 10 #:face 'f-face #:weight 0))
  (check-equal? (cell-face (list p0* f) 3 9) 'f-face)

  (displayln "border.rkt: ok"))
