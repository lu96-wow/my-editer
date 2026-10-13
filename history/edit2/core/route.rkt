#lang racket

;;; edit2/route.rkt —— CPS 声明式路由
;;;
;;; 路由表是数据（guard + handler）。处理器是 CPS 函数：
;;;     guard   : State Event -> Boolean
;;;     handler : Ctx State Event Cont -> (values State (listof Effect))
;;;     Cont    : Ctx State Event -> (values State (listof Effect))
;;; 第三个参数就是「下一个处理器」。调用 k = 交接；直接返回 = 处理完毕。
;;;
;;; Ctx 是本次输入的**派生上下文**：当前尺寸与上一帧的 placements。
;;; 需要几何的输入（指针/光标事件）用它做命中定位；不需要的处理器忽略它。

(provide
 (struct-out route)
 (struct-out ctx)
 ctx-placements ctx-size
 route-input route-input/k
 guard-and guard-or guard-not always
 handled pass)

(struct ctx (size placements) #:transparent)
;; size       : (cons w h)
;; placements : (listof placement)   上一帧的布局结果（命中定位用）

(struct route (guard handler) #:transparent)

;;; ---------- 运行 ----------

;; 带「落空续延」的输入：所有 route 的守卫都不命中时，把控制交给 k。
(define (route-input/k routes ctx st ev k)
  (define (chain rs)
    (cond
      [(null? rs) k]
      [else
       (define r (car rs))
       (define g (route-guard r))
       (define h (route-handler r))
       (define k2 (chain (cdr rs)))
       (lambda (ctx st ev)
         (if (g st ev) (h ctx st ev k2) (k2 ctx st ev)))]))
  ((chain routes) ctx st ev))

(define (route-input routes ctx st ev)
  (route-input/k routes ctx st ev (lambda (ctx st ev) (values st '()))))

;;; ---------- 守卫组合子 ----------

(define (guard-and . gs) (lambda (st ev) (for/and ([g (in-list gs)]) (g st ev))))
(define (guard-or . gs)  (lambda (st ev) (for/or  ([g (in-list gs)]) (g st ev))))
(define (guard-not g)    (lambda (st ev) (not (g st ev))))
(define (always st ev) #t)

;;; ---------- 处理器便捷构造 ----------

;; 处理并终止：f : State Event -> (values State (listof Effect))（忽略 ctx）
(define (handled f)
  (lambda (ctx st ev k) (f st ev)))

;; 交接给下一条
(define (pass ctx st ev k) (k ctx st ev))

