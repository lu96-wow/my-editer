#lang racket

;;; base/transition.rkt —— 一次状态转移：新 State + 有序效果（纯）
;;; layer  : base
;;; effect : 无（纯值 + 纯组合子）

;;; 命令的统一返回类型：
;;;
;;;     command : ctx -> transition
;;;
;;; 好处（相对旧的 update/effect 两套 intent）：
;;;   · State 已经在命令里改完，不存在“先折叠 update、再跑 effect”的顺序重排；
;;;   · effects 按书写顺序解释；
;;;   · 组合子让多条命令 / 多步操作保持顺序。
;;;
;;; 纯命令用 (transition-pure s)；只发效果用 (transition-with-effects s es)；
;;; 先做 A 再做 B 用 (transition-bind A (λ (s) B))。

(provide (struct-out transition)
         transition?
         transition-pure
         transition-with-effects
         transition-bind
         transition-all
         transition-map-state
         transition-map-effects)

(require "effect.rkt")

(struct transition (state effects) #:transparent)
;; state   : state?（model/state.rkt；本模块不依赖它，保持 base 在底部）
;; effects : (listof effect?)

(define (transition-pure s) (transition s '()))

(define (transition-with-effects s es)
  (for ([e (in-list es)])
    (unless (effect? e)
      (error 'transition-with-effects "不是 effect：~a" e)))
  (transition s es))

;; 先 t，再把结果 state 交给 f。效果顺序 = t.effects ++ t2.effects。
(define (transition-bind t f)
  (define t2 (f (transition-state t)))
  (transition (transition-state t2)
              (append (transition-effects t) (transition-effects t2))))

;; 依次执行多个 transition（左折）。
(define (transition-all . ts)
  (cond
    [(null? ts) (error 'transition-all "至少需要一个 transition")]
    [else
     (for/fold ([t (car ts)]) ([t* (in-list (cdr ts))])
       (transition-bind t (λ (_) t*)))]))

(define (transition-map-state t f)
  (transition (f (transition-state t)) (transition-effects t)))

(define (transition-map-effects t f)
  (transition (transition-state t) (f (transition-effects t))))
