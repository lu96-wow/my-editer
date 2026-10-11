#lang racket

;;; core/command.rkt —— 声明式命令的**数据模型 + 编译**
;;;
;;; 配置是纯数据（不 require core）：
;;;
;;;   entry   = (binding scope op ...)              命令行
;;;   binding = (key k mod ...) | (cursor kind button) | (text)
;;;   scope   = always | editor | float | prompt | (panel name)
;;;   op      = (insert "x") | (move left) | (region-toggle sidebar) | ...
;;;
;;; 本模块只把 binding 解析成守卫、把 entry 编成 route；op 的**执行**在 core/step.rkt
;;; 的 run-ops（原语解释器）。加一条绑定 = 往表里加一行数据，不需要改 core。

(provide parse-binding compile-routes
         op? op-tag op-args)

(require "event.rkt"
         "route.rkt")

;;; ---------- binding ----------

(define (parse-binding b)
  (cond
    [(and (list? b) (eq? (car b) 'key))
     (on-key (cadr b) (cddr b))]
    [(and (list? b) (eq? (car b) 'cursor) (= (length b) 3))
     (on-cursor (cadr b) (caddr b))]
    [(and (list? b) (eq? (car b) 'cursor) (= (length b) 2))
     (on-cursor (cadr b))]
    [(and (list? b) (eq? (car b) 'text))
     on-text]
    [else (error 'parse-binding "坏 binding: ~a" b)]))

;;; ---------- op（原语） ----------

;; op 就是带 tag 的 list；这里只做访问器，执行在 step.rkt。
(define (op? x) (and (pair? x) (symbol? (car x))))
(define (op-tag x) (car x))
(define (op-args x) (cdr x))

;;; ---------- entry → route ----------

;; table     : (listof entry)
;; scope-of  : symbol/list -> (state event -> boolean)
;; make-runner : (listof op) -> handler（CPS）
(define (compile-routes table scope-of make-runner)
  (for/list ([e (in-list table)])
    (match-define (list binding scope ops ...) e)
    (route (guard-and (scope-of scope) (parse-binding binding))
           (make-runner ops))))
