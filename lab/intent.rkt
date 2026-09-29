#lang racket

;;; intent.rkt —— 意图：用户「想做什么」的纯数据描述
;;;
;;; 这是本层唯一的跨模块词汇。组件 / 键位表只**说**想干什么（产出一个 intent），
;;; 绝不自己去干；真正干活集中在 command.rkt（唯一写口）。
;;;
;;;   tag     动作名（symbol），如 'editor/insert / 'tree/create / 'prompt/confirm
;;;   payload 参数（list），结构由 tag 约定，命令层解释
;;;   origin  发起该意图的视图 id（vid），可能 #f
;;;
;;; 为什么带 origin：命令层常要知道「谁发起的」（焦点是哪个视图），
;;; 让分发层在产出意图时顺手附上，命令层就不必再回头猜焦点。
;;;
;;; intent 是纯值，可比较、可打印、可单测；没有闭包、没有副作用。

(provide (struct-out intent) make-intent)

(struct intent (tag payload origin) #:transparent)
;; tag     : symbol
;; payload : list
;; origin  : (or/c #f exact-nonnegative-integer?)   ; vid

;; 构造糖：payload / origin 可省。
(define (make-intent tag [payload '()] [origin #f])
  (intent tag payload origin))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit)

  (define i (make-intent 'editor/insert (list "a") 3))
  (check-true (intent? i))
  (check-equal? (intent-tag i) 'editor/insert)
  (check-equal? (intent-payload i) '("a"))
  (check-equal? (intent-origin i) 3)

  ;; payload / origin 默认值
  (define j (make-intent 'app/quit))
  (check-equal? (intent-payload j) '())
  (check-false (intent-origin j))

  ;; 纯值：结构相等可比较
  (check-equal? (make-intent 'x '(1) 2) (make-intent 'x '(1) 2))

  (displayln "lab/intent.rkt: all tests passed"))
