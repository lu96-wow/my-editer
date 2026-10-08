#lang racket

;;; lab-rebuild/kernel/policy.rkt —— 动作门控 / 效果变换（跨切面）。
;;;
;;; phase='before : decide Ctx Action -> 'pass | 'abort | (listof effect)
;;; phase='after  : decide Ctx Action (listof effect) -> (listof effect)
;;;
;;; 策略不写在命令里；命令保持单一职责。多个 before 按注册名顺序，首个非 'pass 者定夺。

(provide (struct-out policy) policy-new)

(struct policy (id phase match? decide) #:transparent)
;; id     : symbol（同时是注册名）
;; match? : Ctx Action -> boolean
;; decide : before -> 'pass | 'abort | (listof effect)
;;          after  -> (listof effect) -> (listof effect)

(define (policy-new id phase match? decide)
  (policy id phase match? decide))
