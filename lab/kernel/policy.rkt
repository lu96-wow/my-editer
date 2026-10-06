#lang racket

;;; lab-rebuild/kernel/policy.rkt —— 动作门控 / 效果变换。
;;;
;;; phase='before : decide Ctx Action -> BeforeDecision
;;;     BeforeDecision = 'pass | 'abort | (listof effect) | interaction?
;;; phase='after  : decide Ctx Action (listof effect) -> (listof effect)

(provide (struct-out policy) policy-new
         (struct-out interaction) interaction-new
         (struct-out suspension) suspension-new)

(struct policy (id priority phase match? decide) #:transparent)

(struct interaction (start resume) #:transparent)
;; start  : Ctx sid -> (listof effect)
;; resume : Ctx sid response -> (listof effect)

(define (policy-new id priority phase match? decide)
  (policy id priority phase match? decide))
(define (interaction-new start resume) (interaction start resume))

;; 被挂起的 interaction 的登记项（session.interactions 里）。resume : Ctx sid response -> effects
(struct suspension (id resume) #:transparent)
(define (suspension-new id resume) (suspension id resume))
