#lang racket

;;; core-rebuild/view/border.rkt —— 面板边框 → run（固定 Unicode 框线）
;;;
;;; 输入 panel 列表（按宿主给的顺序），输出按行合并的 run `(row col text face deep)`。
;;;
;;; **先 owner，再收边**：
;;;   1. 每格归属 = 覆盖它的 deep 最大的 panel（同 deep 列表靠后者胜）；
;;;   2. 某 panel 的边格，只有它是该格 owner 时才收（被高 deep 浮窗盖住的不收）；
;;;   3. 字形 = 该格在**可见边格集合**里的同向延续：
;;;        水平边（up/down）→ 看左右；垂直边（left/right）→ 看上下
;;;      共线相接 / 垂直相交连成 T / 十字；平行相邻不连。
;;; 这样遮挡和连接一致：被盖住的边不会在浮窗外面长出悬空臂。
;;;
;;; face / deep 取 owner 的；同一格 owner 唯一，所以不冲突。
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

;;; ---------- owner ----------

; 覆盖 (r,c)（r=行, c=列）的 panel：deep 最大，同 deep 列表靠后者胜；都没有 → #f。
(define (owner-at panels r c)
  (for/fold ([best #f]) ([p (in-list panels)])
    (if (and (rect-contains? (panel-rect p) c r)      ; rect-contains? 收 (x=列, y=行)
             (or (not best) (>= (panel-deep p) (panel-deep best))))
        p best)))

;;; ---------- 可见边格 ----------

;; → (hash (cons row col) (list glyph face deep))。
(define (panels->border-cells panels)
  (define info (make-hash))                    ; cell -> (list face deep h? v?)
  (define (add! p cell h? v?)
    (define old (hash-ref info cell #f))
    (if old
        (hash-set! info cell (list (car old) (cadr old)
                                   (or h? (caddr old)) (or v? (cadddr old))))
        (hash-set! info cell (list (panel-face p) (panel-deep p) h? v?))))
  (for ([p (in-list panels)])
    (define r (panel-rect p))
    (define x (rect-x r)) (define y (rect-y r))
    (define w (rect-w r)) (define h (rect-h r))
    (define b (panel-borders p))
    (when (and (> w 0) (> h 0))
      (when (memq 'up b)
        (for ([c (in-range x (+ x w))] #:when (eq? (owner-at panels y c) p))
          (add! p (cons y c) #t #f)))
      (when (memq 'down b)
        (for ([c (in-range x (+ x w))] #:when (eq? (owner-at panels (sub1 (+ y h)) c) p))
          (add! p (cons (sub1 (+ y h)) c) #t #f)))
      (when (memq 'left b)
        (for ([rr (in-range y (+ y h))] #:when (eq? (owner-at panels rr x) p))
          (add! p (cons rr x) #f #t)))
      (when (memq 'right b)
        (for ([rr (in-range y (+ y h))] #:when (eq? (owner-at panels rr (sub1 (+ x w))) p))
          (add! p (cons rr (sub1 (+ x w))) #f #t)))))
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
  (displayln "border.rkt: ok"))
