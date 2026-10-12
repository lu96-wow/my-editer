#lang racket

;;; edit4/layout/validate.rkt —— 不变量自检（开发/测试期用）
;;;
;;; validate : node area -> (listof string)   （空表 = 全部通过）
;;;
;;; 检查：
;;;   · 结构：split >= 2 孩子；叶子 min >= (1 . 1)；basis 非负
;;;   · 几何：每个 pane 在区域内、不小于自身 min、两两不重叠
;;; 通过它把 I1/I2/I6（守恒 / 硬底 / 确定）钉在测试里。

(provide validate)

(require "rect.rkt" "size.rkt" "tree.rkt" "geometry.rkt" racket/list)

(define (overlap-rect? a b)
  (and (< (max (rect-x a) (rect-x b)) (min (rect-right a) (rect-right b)))
       (< (max (rect-y a) (rect-y b)) (min (rect-bottom a) (rect-bottom b)))))

(define (find-leaf-min n id)
  (cond
    [(not n) #f]
    [(leaf? n) (and (eqv? id (leaf-id n)) (leaf-min n))]
    [else (for/or ([c (in-list (split-kids n))]) (find-leaf-min (child-node c) id))]))

(define (id<? a b) (string<? (format "~a" a) (format "~a" b)))

(define (validate node area)
  (define errs '())
  (define (err fmt . args) (set! errs (cons (apply format fmt args) errs)))

  ;; ---- 结构 ----
  (let walk ([n node])
    (cond
      [(not n) (void)]
      [(leaf? n)
       (define m (leaf-min n))
       (when (or (< (car m) 1) (< (cdr m) 1))
         (err "leaf ~a: min ~a < (1 . 1)" (leaf-id n) m))]
      [else
       (define kids (split-kids n))
       (when (< (length kids) 2)
         (err "split: 只有 ~a 个孩子" (length kids)))
       (for ([c (in-list kids)])
         (when (< (size-basis (child-size c)) 0)
           (err "child: basis ~a < 0" (size-basis (child-size c))))
         (walk (child-node c)))]))

  ;; ---- 几何 ----
  (define g (layout node area))
  (define rects (geometry-rects g))
  (for ([(id r) (in-hash rects)])
    (when (or (< (rect-x r) 0) (< (rect-y r) 0)
              (> (rect-right r) (rect-w area)) (> (rect-bottom r) (rect-h area)))
      (err "~a: rect ~a 超出区域 ~a" id r area))
    (define m (find-leaf-min node id))
    (when (and m (or (< (rect-w r) (car m)) (< (rect-h r) (cdr m))))
      (err "~a: rect ~a 小于 min ~a" id r m)))

  ;; 两两不重叠
  (define ids (hash-keys rects))
  (for ([a (in-list ids)] [b (in-list ids)]
        #:when (and (not (eqv? a b)) (id<? a b)))
    (define ra (hash-ref rects a))
    (define rb (hash-ref rects b))
    (when (overlap-rect? ra rb)
      (err "~a 与 ~a 重叠" a b)))

  (reverse errs))
