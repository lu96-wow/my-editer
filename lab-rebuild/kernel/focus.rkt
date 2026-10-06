#lang racket

;;; lab-rebuild/kernel/focus.rkt —— 焦点：唯一活动目标 + 历史。
;;;
;;; 语义分离（避免方向键/鼠标把历史越堆越深）：
;;;   focus-set     普通移动，不动历史
;;;   focus-push    记住当前 + 移动（侧栏 / prompt 用）
;;;   focus-restore 还原到历史顶端

(provide (struct-out focus) focus-new focus-set focus-push focus-restore)

(struct focus (target stack) #:transparent)
;; target : pane-id / #f
;; stack  : (listof pane-id)   焦点历史（LIFO）

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
