#lang racket

;;; edit-rebuild/core/session/hook.rkt —— 生命周期事件（作用域 + 优先级）
;;;
;;; 旧：一个「通知点」上一串 opaque 闭包，按**注册顺序**跑。
;;; 新：每个 reaction = 事件 tag + **作用域** + **优先级** + 动作；
;;;
;;;   · 作用域：只在条件满足时生效（不再“焦点一变就关文档”这种脆弱耦合）；
;;;   · 优先级：大者先，取代“注册顺序”（旧 before-render 的 poll/tick 顺序一度踩坑）。
;;;
;;; 动作仍是 `session (listof any/c) -> session`（生命周期是宿主状态变换，不是键路由）。
;;; 事件的路由/顺序由数据显式决定，这就是本层要的“声明式”。

(require "session.rkt"
         "../scope.rkt"
         "../keymap.rkt"          ; prefix-label
         "../surface/surface.rkt")

(provide (struct-out hook) reaction session-add-hook session-run-hooks session-context)

;; 结构构造名改为 make-hook，智能构造子叫 reaction。
(struct hook (point scope priority proc) #:transparent
  #:constructor-name make-hook)
;; point    : symbol
;; scope    : scope        （默认 always）
;; priority : integer      （大者先）
;; proc     : session (listof any/c) -> session

(define (reaction point proc
                  #:when [scope (scope-always)]
                  #:priority [priority 0])
  (make-hook point scope priority proc))

(define (session-add-hook s h)
  (struct-copy session s [hooks (cons h (session-hooks s))]))

;; 会话 → 作用域上下文（宿主投影；引擎与事件共用）。
(define (session-context s)
  (define vid (session-focus-vid s))
  (define sf (and vid (session-surface-for-vid s vid)))
  (define vis (for/hash ([x (in-list (session-surfaces s))])
                (values (surface-id x) (session-visible? s (surface-vid x)))))
  (define p (session-prefix s))
  (context vid
           (and sf (surface-id sf))
           (cond [(not sf) 'editor] [(surface-float? sf) 'float] [else 'dock])
           vis (session-modes s) (and p (prefix-label p))))

(define (session-run-hooks s point args)
  (define ctx (session-context s))
  (define hs (sort (for/list ([h (in-list (session-hooks s))]
                              #:when (and (eq? point (hook-point h))
                                          (scope-satisfied? (hook-scope h) ctx)))
                     h)
                   > #:key hook-priority))
  (for/fold ([s s]) ([h (in-list hs)]) ((hook-proc h) s args)))
