#lang racket

;;; edit-rebuild/core/scope.rkt —— 作用域（纯）：什么时候一条键路由生效
;;;
;;; 作用域是**数据**，不是闭包：可组合、可打印、可测。判定输入是一个纯 context，
;;; 由宿主从会话状态投影出来（本模块不认识 session / editor）。
;;;
;;; 作用域判定只读 context，不产生副作用；「输入 = 收集所有 live 路由」由此成立。

(provide (struct-out context) (struct-out scope)
         context-empty
         scope-always scope-focus scope-focus-id scope-focus-kind scope-visible
         scope-mode= scope-prefix
         scope-and scope-or scope-not
         scope-satisfied?)

;;; ---------- 上下文（宿主投影） ----------

(struct context (focus focus-id focus-kind visible modes prefix) #:transparent)
;; focus      : any/c                       当前焦点目标（vid）
;; focus-id   : symbol | #f                 焦点面的身份 id（'tree 'docs 'input …）
;; focus-kind : symbol | #f                 目标种类（'editor 'dock 'float …）
;; visible    : (hash any/c -> boolean)     目标 / 面板是否可见
;; modes      : (hash symbol -> any/c)      交互模式（纯值，非 box）
;; prefix     : any/c | #f                  活动前缀 id

(define context-empty (context #f #f #f (hash) (hash) #f))

;;; ---------- 作用域 ----------

(struct scope (kind arg) #:transparent)
;; kind: 'always | 'focus | 'focus-kind | 'visible | 'mode= | 'prefix | 'and | 'or | 'not
;; arg : 随 kind；'and / 'or 是 (listof scope)，'not 是 scope

(define (scope-always) (scope 'always #f))
(define (scope-focus target) (scope 'focus target))
(define (scope-focus-id id) (scope 'focus-id id))
(define (scope-focus-kind kind) (scope 'focus-kind kind))
(define (scope-visible id) (scope 'visible id))
(define (scope-mode= name val) (scope 'mode= (cons name val)))
(define (scope-prefix) (scope 'prefix #f))
(define (scope-and . ss) (scope 'and ss))
(define (scope-or . ss) (scope 'or ss))
(define (scope-not s) (scope 'not s))

(define (scope-satisfied? sc ctx)
  (case (scope-kind sc)
    [(always) #t]
    [(focus) (equal? (scope-arg sc) (context-focus ctx))]
    [(focus-id) (eq? (scope-arg sc) (context-focus-id ctx))]
    [(focus-kind) (eq? (scope-arg sc) (context-focus-kind ctx))]
    [(visible) (hash-ref (context-visible ctx) (scope-arg sc) #f)]
    [(mode=) (define p (scope-arg sc))
             (equal? (hash-ref (context-modes ctx) (car p) #f) (cdr p))]
    [(prefix) (and (context-prefix ctx) #t)]
    [(and) (for/and ([s (in-list (scope-arg sc))]) (scope-satisfied? s ctx))]
    [(or) (for/or ([s (in-list (scope-arg sc))]) (scope-satisfied? s ctx))]
    [(not) (not (scope-satisfied? (scope-arg sc) ctx))]
    [else (error 'scope-satisfied? "未知作用域: ~a" (scope-kind sc))]))
