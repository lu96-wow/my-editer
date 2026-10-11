#lang racket

;;; edit-rebuild/core/dispatch.rkt —— 事件引擎：输入 / 命令 / 生命周期事件
;;;
;;; 三种触发，共用同一套「作用域 + 优先级 + 效果」：
;;;
;;;   dispatch 输入事件：binding 命中路由；前缀（route.prefix）；载荷型 spec
;;;   execute  命令：      command 命中路由（插件 handler）；无命中则落宿主原语
;;;   emit     生命周期：  event tag 命中路由；**所有命中都跑**（纯通知语义）
;;;
;;; 执行一条 action：
;;;   command ─▶ host.run-command ─▶ result
;;;     ├─ 'pass     继续下一条候选；（命令路由全 pass 则回落宿主原语）
;;;     ├─ 'handled  policy='stop 停；policy='continue 继续
;;;     └─ effect    解释（forward / broadcast / seq / focus / mode / prefix / handler）
;;;
;;; 前缀：命中后先清除（动作可再 begin-prefix 开下一个）；未命中即取消。
;;; trigger：把“触发本次派发的键 / 命令 / 事件”贯穿到效果，参数化命令需要它。

(require "key.rkt"
         "scope.rkt"
         "route.rkt"
         "effect.rkt")

(provide dispatch execute emit)

;;; ---------- 入口 ----------

;; 输入事件（键 / 文本 / 鼠标 / resize）。
(define (dispatch host rss st in)
  (define ctx (context-of host st))
  (define b (input-binding in))
  (define cands (resolve rss ctx b))
  (cond
    [(null? cands)
     (cond [(context-prefix ctx) (clear-prefix host rss st)]   ; 未命中 → 取消前缀
           [else st])]
    [else
     (define st* (if (context-prefix ctx) (clear-prefix host rss st) st))
     (define-values (st** _h) (run-candidates host rss st* 'focus cands in b))
     st**]))

;; 命令：先查 command 路由（插件 handler），全 pass / 无命中则落宿主原语。
(define (execute host rss st target cmd)
  (define ctx (context-of host st))
  (define cands (resolve rss ctx cmd))
  (cond
    [(null? cands)
     (run-host-thunk host rss st target cmd
                     (lambda (st) ((host-run-command host) st target cmd)))]
    [else
     (define-values (st* h) (run-candidates host rss st target cands #f cmd))
     (cond
       [h (values st* #t)]
       [else (run-host-thunk host rss st* target cmd
                             (lambda (st) ((host-run-command host) st target cmd)))])]))

;; 生命周期事件：命中的 reaction **全部**按 priority 跑（串接状态）。
(define (emit host rss st ev)
  (define ctx (context-of host st))
  (for/fold ([st st]) ([r (in-list (resolve rss ctx (event-tag ev)))])
    (define action (route-action-of host r #f))
    (define-values (st* _h) (run-action host rss st 'focus (event-tag ev) action))
    st*))

;;; ---------- 执行候选 ----------

(define (run-candidates host rss st target cands env trigger)
  (let loop ([st st] [cands cands] [h? #f])
    (cond
      [(null? cands) (values st h?)]
      [else
       (define r (car cands))
       (define action (route-action-of host r env))
       (define-values (st* handled?) (run-action host rss st target trigger action))
       (cond
         [(and handled? (eq? 'stop (route-policy r))) (values st* #t)]
         [else (loop st* (cdr cands) (or h? handled?))])])))

;; 路由动作：符号是载荷型 spec → 用输入载荷换具体命令（仅输入有载荷）。
(define (route-action-of host r env)
  (define a (route-action r))
  (if (and (symbol? a) env)
      ((host-spec->action host) env a)
      a))

(define (context-of host st) ((host-make-context host) st))

(define (clear-prefix host rss st)
  (define-values (st* _h) (run-action host rss st 'focus #f (cancel-prefix)))
  st*)

;;; ---------- 解释器 ----------
;;; run-action : host routes st target trigger action -> (values st handled?)

(define (run-action host rss st target trigger x)
  (cond
    [(addressed? x) (run-action host rss st (addressed-target x) trigger (addressed-cmd x))]
    [(focus-to? x)
     (run-host-thunk host rss st target trigger (lambda (st) ((host-run-focus host) st (focus-to-target x))))]
    [(set-mode? x)
     (run-host-thunk host rss st target trigger
                     (lambda (st) ((host-run-mode host) st (set-mode-name x) (set-mode-val x))))]
    [(begin-prefix? x)
     (run-host-thunk host rss st target trigger (lambda (st) ((host-run-prefix host) st (begin-prefix-id x))))]
    [(cancel-prefix? x)
     (run-host-thunk host rss st target trigger (lambda (st) ((host-run-prefix host) st #f)))]
    [(forward? x)
     (define v (forward-value x))
     (define st* (cond [(input? v) (dispatch host rss st v)]
                       [(event? v) (emit host rss st v)]
                       [else (call-with-values (lambda () (execute host rss st target v))
                                               (lambda (s _h) s))]))
     (values st* #t)]
    [(broadcast? x)
     (for/fold ([st st] [h? #f]) ([tg (in-list (broadcast-targets x))])
       (define-values (st* h) (run-action host rss st tg trigger (broadcast-cmd x)))
       (values st* (or h? h)))]
    [(seq-effect? x)
     (for/fold ([st st] [h? #f]) ([e (in-list (seq-effect-effects x))])
       (define-values (st* h) (run-action host rss st target trigger e))
       (values st* (or h? h)))]
    [(session-effect? x)
     (call-with-values (lambda () ((session-effect-proc x) st))
       (lambda (st* res) (interpret-result host rss st* target trigger res)))]
    [(handler-effect? x)
     (call-with-values (lambda () ((handler-effect-proc x) st trigger))
       (lambda (st* res) (interpret-result host rss st* target trigger res)))]
    [else
     ;; 普通命令：先进 command 路由（插件 handler），无命中落宿主原语。
     (execute host rss st target x)]))

(define (interpret-result host rss st target trigger res)
  (cond
    [(eq? res 'pass) (values st #f)]
    [(eq? res 'handled) (values st #t)]
    [(effect? res) (run-action host rss st target trigger res)]
    [else (values st #t)]))

;; 宿主过程返回 (values st result)；result 再解释。
(define (run-host-thunk host rss st target trigger thunk)
  (call-with-values (lambda () (thunk st))
    (lambda (st* res) (interpret-result host rss st* target trigger res))))
