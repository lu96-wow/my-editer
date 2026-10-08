#lang racket

;;; lab-rebuild/kernel/focus.rkt —— 焦点：唯一活动目标 + 历史。
;;;
;;; 三根柱子之一「焦点管理」。语义分离（避免方向键 / 鼠标把历史越堆越深）：
;;;   focus-set      普通移动，不动历史
;;;   focus-push     记住当前 + 移动（模态层 / 侧栏等「用完还原」的场景）
;;;   focus-restore  还原到历史顶端
;;;
;;; focus 只存 target（vid）+ stack，不含几何；方向移动的几何在 pipeline（将来配 frame）。

(provide (struct-out focus) focus-new focus-set focus-push focus-restore)

(struct focus (target stack) #:transparent)
;; target : vid / #f
;; stack  : (listof vid)   焦点历史（LIFO）

(define (focus-new target) (focus target '()))

;; 普通移动：只换 target。
(define (focus-set f target)
  (focus target (focus-stack f)))

;; 记住当前再移动。
(define (focus-push f target)
  (focus target (if (focus-target f) (cons (focus-target f) (focus-stack f)) (focus-stack f))))

;; 还原到历史顶端。
(define (focus-restore f)
  (cond [(null? (focus-stack f)) f]
        [else (focus (car (focus-stack f)) (cdr (focus-stack f)))]))
