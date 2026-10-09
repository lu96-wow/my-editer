#lang racket

;;; edit/core/focus.rkt —— 焦点（纯函数）
;;;
;;; 焦点 = 唯一活动目标 + 历史。语义分离（避免方向键 / 鼠标把历史越堆越深）：
;;;     focus-set      普通移动，不动历史
;;;     focus-push     记住当前再移动（模态层 / 侧栏等「用完还原」）
;;;     focus-restore  还原到历史顶端
;;;
;;; 焦点只存 target(vid) + stack，不含几何；方向移动的几何由调用方传
;;; 「已放置的 view 列表」（layout-place 的结果 placed），不落进 focus 值。

(require "layout.rkt")

(struct focus (target stack) #:transparent)
;; target : vid | #f
;; stack  : (listof vid)   焦点历史（LIFO）

(provide (struct-out focus)
         focus-new focus-set focus-push focus-restore
         focus-move)

(define (focus-new target) (focus target '()))

;; 普通移动：只换 target。
(define (focus-set f target) (focus target (focus-stack f)))

;; 记住当前再移动。
(define (focus-push f target)
  (focus target (if (focus-target f) (cons (focus-target f) (focus-stack f)) (focus-stack f))))

;; 还原到历史顶端。
(define (focus-restore f)
  (cond [(null? (focus-stack f)) f]
        [else (focus (car (focus-stack f)) (cdr (focus-stack f)))]))

;;; ---------- 方向移动（几何来自已放置的 view） ----------

(define (rect-v-overlap? a b)
  (and (< (placed-y a) (+ (placed-y b) (placed-h b)))
       (< (placed-y b) (+ (placed-y a) (placed-h a)))))
(define (rect-h-overlap? a b)
  (and (< (placed-x a) (+ (placed-x b) (placed-w b)))
       (< (placed-x b) (+ (placed-x a) (placed-w a)))))

;; dir : 'left 'right 'up 'down
;; 中心点在方向半平面内；正交轴重叠（同排 / 同列）优先 → 避免斜跳。
(define (focus-move views f dir)
  (define cur (focus-target f))
  (define c (for/first ([v (in-list views)] #:when (eqv? cur (placed-vid v))) v))
  (cond
    [(or (not c) (< (length views) 2)) f]
    [else
     (define cx (+ (placed-x c) (quotient (placed-w c) 2)))
     (define cy (+ (placed-y c) (quotient (placed-h c) 2)))
     (define horiz? (memq dir '(left right)))
     (define best
       (for/fold ([best #f]) ([v (in-list views)] #:unless (eqv? cur (placed-vid v)))
         (define vx (+ (placed-x v) (quotient (placed-w v) 2)))
         (define vy (+ (placed-y v) (quotient (placed-h v) 2)))
         (define ok (case dir
                      [(left)  (< vx cx)]
                      [(right) (> vx cx)]
                      [(up)    (< vy cy)]
                      [(down)  (> vy cy)]
                      [else #f]))
         (cond
           [(not ok) best]
           [else
            (define overlap? (if horiz? (rect-v-overlap? c v) (rect-h-overlap? c v)))
            (define primary (if horiz? (abs (- vx cx)) (abs (- vy cy))))
            (define score (+ primary (if overlap? 0 10000)))
            (if (or (not best) (< score (car best)))
                (cons score (placed-vid v))
                best)])))
     (cond [(not best) f]
           [else (focus-set f (cdr best))])]))
