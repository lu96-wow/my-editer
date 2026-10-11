#lang racket

;;; edit3/resize.rkt —— 纯 resize 手术（浮窗移动 / 缩放）
;;;
;;; 平铺缝的 resize 在 layout.rkt（只改相邻 basis）。
;;; 这里只处理浮窗：几何 = anchor + size，所以“移动”改 anchor 的 dx/dy，
;;; “缩放”改 size，并回算 dx/dy 让**被拖边的对边保持不动**。

(provide float-by-id set-float
         move-float* resize-float* move-float resize-float)

(require "state.rkt" "layout.rkt" racket/list)

(define min-float-w 3)
(define min-float-h 2)
(define (clamp v lo hi) (max lo (min hi v)))

(define (float-by-id floats wid)
  (findf (lambda (f) (eqv? wid (float-wid f))) floats))

(define (set-float floats wid f)
  (for/list ([x (in-list floats)]) (if (eqv? wid (float-wid x)) f x)))

;; 移动：anchor.dx/dy += (dx,dy)
(define (move-float* f dx dy)
  (define a (float-anchor f))
  (struct-copy float f
               [anchor (struct-copy anchor a
                                    [dx (+ (anchor-dx a) dx)]
                                    [dy (+ (anchor-dy a) dy)])]))

;; 缩放：edge ∈ 'l 'r 't 'b 'tl 'tr 'bl 'br；rel-rect = 锚点解析后的矩形。
;; 用当前 rect + 总位移算新 rect，再回算 anchor 的 dx/dy（保证对边不动）。
(define (resize-float* f edge dx dy rel-rect W H)
  (define r (float-rect rel-rect f W H))
  (define x0 (rect-x r)) (define y0 (rect-y r))
  (define w0 (rect-w r)) (define h0 (rect-h r))
  (define left?  (and (memq edge '(l nw sw)) #t))
  (define right? (and (memq edge '(r ne se)) #t))
  (define top?   (and (memq edge '(t nw ne)) #t))
  (define bot?   (and (memq edge '(b sw se)) #t))
  (define nx (if left? (clamp (+ x0 dx) 0 (- (+ x0 w0) min-float-w)) x0))
  (define ny (if top?  (clamp (+ y0 dy) 0 (- (+ y0 h0) min-float-h)) y0))
  (define nw (cond [left?  (- (+ x0 w0) nx)]
                   [right? (max min-float-w (+ w0 dx))]
                   [else   w0]))
  (define nh (cond [top?  (- (+ y0 h0) ny)]
                   [bot?  (max min-float-h (+ h0 dy))]
                   [else  h0]))
  (define a (float-anchor f))
  (define base-x (case (anchor-h a)
                   [(left)   (rect-x rel-rect)]
                   [(right)  (- (+ (rect-x rel-rect) (rect-w rel-rect)) nw)]
                   [(center) (+ (rect-x rel-rect) (quotient (- (rect-w rel-rect) nw) 2))]
                   [else     (rect-x rel-rect)]))
  (define base-y (case (anchor-v a)
                   [(top)    (rect-y rel-rect)]
                   [(bottom) (- (+ (rect-y rel-rect) (rect-h rel-rect)) nh)]
                   [(center) (+ (rect-y rel-rect) (quotient (- (rect-h rel-rect) nh) 2))]
                   [else     (rect-y rel-rect)]))
  (struct-copy float f
               [size (cons nw nh)]
               [anchor (struct-copy anchor a
                                    [dx (- nx base-x)]
                                    [dy (- ny base-y)])]))

;; 列表级：按 wid 找到并更新（move 用增量；resize 用当前 rect + 增量）。
(define (move-float floats wid dx dy)
  (define f (float-by-id floats wid))
  (if f (set-float floats wid (move-float* f dx dy)) floats))

;; resize 的列表级入口（增量，rel-rect 由调用方解析）
(define (resize-float floats wid edge dx dy rel-rect W H)
  (define f (float-by-id floats wid))
  (if f (set-float floats wid (resize-float* f edge dx dy rel-rect W H)) floats))
