#lang racket

;;; edit4/layout/float.rkt —— 浮窗（正交覆盖层，不参与切分）
;;;
;;; 浮窗不进布局树：先解树，再用树的结果解浮窗。几何只由 anchor + size 决定。
;;; 这里只做「锚点解析 / 浮窗 → 矩形 / 移动 / 缩放 / 命中」的纯计算。

(provide (struct-out anchor) (struct-out float)
         float-rect resolve-anchor-rel place-floats
         float-by-id set-float move-float* resize-float* float-hit)

(require "rect.rkt" racket/list)

;; rel : 'screen | wid（锚到某个平铺窗）
;; h   : left | right | center ; v : top | bottom | center
(struct anchor (rel h v dx dy) #:transparent)
(struct float (id anchor size) #:transparent)   ; size = (cons w h)

(define min-float-w 3)
(define min-float-h 2)
(define (clamp v lo hi) (max lo (min hi v)))

;; 锚点参照矩形：'screen → 整屏；wid → 该平铺窗矩形（找不到退化为整屏）。
(define (resolve-anchor-rel rel tiled-rects area)
  (cond
    [(eq? rel 'screen) area]
    [(hash-ref tiled-rects rel #f)]
    [else area]))

;; float-rect : rel-rect float W H -> rect
(define (float-rect rel f W H)
  (define a (float-anchor f))
  (define sz (float-size f))
  (define w (min (car sz) W))
  (define h (min (cdr sz) H))
  (define bx (case (anchor-h a)
               [(left)   (rect-x rel)]
               [(right)  (- (rect-right rel) w)]
               [(center) (+ (rect-x rel) (quotient (- (rect-w rel) w) 2))]
               [else     (rect-x rel)]))
  (define by (case (anchor-v a)
               [(top)    (rect-y rel)]
               [(bottom) (- (rect-bottom rel) h)]
               [(center) (+ (rect-y rel) (quotient (- (rect-h rel) h) 2))]
               [else     (rect-y rel)]))
  (rect (clamp (+ bx (anchor-dx a)) 0 (max 0 (- W w)))
        (clamp (+ by (anchor-dy a)) 0 (max 0 (- H h)))
        w h))

;; place-floats : tiled-rects floats area -> (listof (cons float-id rect))
;;   顺序与 floats 相同（表头在前 = 最上）；z 由位置决定。
(define (place-floats tiled-rects floats area)
  (for/list ([f (in-list floats)])
    (cons (float-id f)
          (float-rect (resolve-anchor-rel (anchor-rel (float-anchor f)) tiled-rects area)
                      f (rect-w area) (rect-h area)))))

;;; ---------- 表操作 ----------

(define (float-by-id floats id)
  (findf (lambda (f) (eqv? id (float-id f))) floats))

(define (set-float floats id f)
  (for/list ([x (in-list floats)]) (if (eqv? id (float-id x)) f x)))

;;; ---------- 移动 / 缩放 ----------

(define (move-float* f dx dy)
  (define a (float-anchor f))
  (struct-copy float f
               [anchor (struct-copy anchor a
                                    [dx (+ (anchor-dx a) dx)]
                                    [dy (+ (anchor-dy a) dy)])]))

;; 角缩放：改 size，**对边不动**（回算 anchor 的 dx/dy）。
;; edge = 'nw | 'ne | 'sw | 'se；rel = 按下时参照矩形。
(define (resize-float* f edge dx dy rel W H)
  (define r (float-rect rel f W H))
  (define x0 (rect-x r)) (define y0 (rect-y r))
  (define w0 (rect-w r)) (define h0 (rect-h r))
  (define left?  (memq edge '(nw sw)))
  (define right? (memq edge '(ne se)))
  (define top?   (memq edge '(nw ne)))
  (define bot?   (memq edge '(sw se)))
  (define nx (if left?  (clamp (+ x0 dx) 0 (- (+ x0 w0) min-float-w)) x0))
  (define ny (if top?   (clamp (+ y0 dy) 0 (- (+ y0 h0) min-float-h)) y0))
  (define nw (cond [left?  (- (+ x0 w0) nx)]
                   [right? (max min-float-w (+ w0 dx))]
                   [else   w0]))
  (define nh (cond [top?  (- (+ y0 h0) ny)]
                   [bot?  (max min-float-h (+ h0 dy))]
                   [else  h0]))
  (define a (float-anchor f))
  (define base-x (case (anchor-h a)
                   [(left)   (rect-x rel)]
                   [(right)  (- (rect-right rel) nw)]
                   [(center) (+ (rect-x rel) (quotient (- (rect-w rel) nw) 2))]
                   [else     (rect-x rel)]))
  (define base-y (case (anchor-v a)
                   [(top)    (rect-y rel)]
                   [(bottom) (- (rect-bottom rel) nh)]
                   [(center) (+ (rect-y rel) (quotient (- (rect-h rel) nh) 2))]
                   [else     (rect-y rel)]))
  (struct-copy float f
               [size (cons nw nh)]
               [anchor (struct-copy anchor a
                                    [dx (- nx base-x)]
                                    [dy (- ny base-y)])]))

;;; ---------- 命中 ----------

;; float-hit : frects(表头在前) x y -> (list id action) | #f
;;   action = 'nw | 'ne | 'sw | 'se（角）| 'move
(define (float-hit frects x y)
  (for/or ([fr (in-list frects)])
    (define r (cdr fr))
    (and (rect-contains? r x y) (list (car fr) (corner-action r x y)))))

(define (corner-action r x y)
  (define l  (= x (rect-x r)))
  (define rr (= x (sub1 (rect-right r))))
  (define t  (= y (rect-y r)))
  (define b  (= y (sub1 (rect-bottom r))))
  (cond [(and l t) 'nw] [(and rr t) 'ne] [(and l b) 'sw] [(and rr b) 'se] [else 'move]))
