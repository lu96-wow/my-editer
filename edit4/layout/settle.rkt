#lang racket

;;; edit4/layout/settle.rkt —— 把解算结果写回树（规范化）
;;;
;;; settle : node area -> node
;;;   对每个 split 用当前 extent 解一次，把解出的长度写回孩子的 basis（elastic? 不变），
;;;   递归下去。于是整棵树满足 content == Σbasis，之后任何 layout 都走**精确快路径**。
;;;
;;; 它是纯函数：resize 命令里跑一次，得到规范化的树；几何从此只是「走路 + 摆矩形」。
;;; 幂等：settle(settle(t)) == settle(t)。

(provide settle)

(require "rect.rkt" "size.rkt" "tree.rkt" racket/list)

(define (settle node area)
  (cond
    [(not node) node]
    [(leaf? node) node]
    [else
     (define axis (split-axis node))
     (define gut (split-gutter node))
     (define kids (split-kids node))
     (define sizes (map child-size kids))
     (define mins (map (lambda (c) (axis-min (child-node c) axis)) kids))
     (define act (map (lambda (c) (not (collapsed-child? c))) kids))
     (define nvis (count values act))
     (define extent (if (eq? axis 'h) (rect-w area) (rect-h area)))
     (define lens (solve-axis extent gut sizes mins act))
     (define x0 (rect-x area))
     (define y0 (rect-y area))
     (define off 0)
     (define vi 0)
     (define new-kids
       (for/list ([c (in-list kids)] [len (in-list lens)] [i (in-naturals)])
         (define visible? (list-ref act i))
         (define cr (if (eq? axis 'h)
                        (rect (+ x0 off) y0 len (rect-h area))
                        (rect x0 (+ y0 off) (rect-w area) len)))
         (set! off (+ off len))
         (when (and visible? (< vi (sub1 nvis))) (set! off (+ off gut)))
         (when visible? (set! vi (add1 vi)))
         (child (size len (size-elastic? (child-size c)))
                (if visible? (settle (child-node c) cr) (child-node c)))))
     (split axis gut new-kids)]))
