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

(provide parse-binding compile-routes binding-label
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
     (apply on-text (cdr b))]   ; (text) | (text "f")
    [else (error 'parse-binding "坏 binding: ~a" b)]))

;;; ---------- binding → 显示标签（给「正在输入的命令序列」用） ----------

(define (key-name k)
  (case k
    [(up) "↑"] [(down) "↓"] [(left) "←"] [(right) "→"]
    [(enter) "Enter"] [(escape) "Esc"] [(tab) "Tab"] [(space) "Space"]
    [(backspace) "BS"] [(delete) "Del"] [(home) "Home"] [(end) "End"]
    [else (symbol->string k)]))

;; binding → 字符串 | #f（#f = 不值得回显，如任意文本 (text)）
(define (binding-label b)
  (case (car b)
    [(key)    (string-append (if (memq 'ctrl  (cddr b)) "C-" "")
                             (if (memq 'alt   (cddr b)) "M-" "")
                             (if (memq 'shift (cddr b)) "S-" "")
                             (key-name (cadr b)))]
    [(cursor) (format "Mouse:~a" (cadr b))]
    [(text)   (and (pair? (cdr b)) (cadr b))]   ; (text "f") → "f"； (text) → #f
    [else #f]))

;;; ---------- op（原语） ----------

;; op 就是带 tag 的 list；这里只做访问器，执行在 step.rkt。
(define (op? x) (and (pair? x) (symbol? (car x))))
(define (op-tag x) (car x))
(define (op-args x) (cdr x))

;;; ---------- entry → route ----------

;; table     : (listof entry)
;; scope-of  : symbol/list -> (state event -> boolean)
;; make-runner : binding (listof op) -> handler（CPS）
(define (compile-routes table scope-of make-runner)
  (for/list ([e (in-list table)])
    (match-define (list binding scope ops ...) e)
    (route (guard-and (scope-of scope) (parse-binding binding))
           (make-runner binding ops))))
