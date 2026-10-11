#lang racket

;;; edit3/hook.rkt —— 生命周期钩子（edit2 风格：react 于事件 tag）
;;;
;;; reaction : 事件点 + 谓词 scope + 优先级 + proc。
;;;   point    : 事件 tag（见下）
;;;   when     : (state -> boolean)   只在该状态下跑（默认总是）
;;;   priority : 大者先（同 edit/ 的 reaction）
;;;   proc     : (state args -> state)  纯状态转移；args 是事件相关数据（列表）
;;;
;;; 事件点：
;;;   before-render / after-edit / after-insert / after-nav /
;;;   focus-changed / document-opened / document-closed / log-appended /
;;;   job / tick
;;;
;;; 'job 的 args = (list id kind result tag)：后台 job 完成后 step 在 job-finish 后 emit。
;;;
;;; 插件通过 plugin 的 #:hooks 贡献；boot 把它们存进 feature 'hooks，emit 从 State 读。

(provide (struct-out reaction) reaction* emit)

(require "state.rkt" racket/list)

(struct reaction (point when priority proc) #:transparent)

(define (reaction* point proc #:when [when (lambda (st) #t)] #:priority [priority 0])
  (reaction point when priority proc))

;; 跑该事件点的所有 reaction（按 priority 降序；when 不满足则跳过）。
(define (emit st point args)
  (define rs (for/list ([r (in-list (feature-ref st 'hooks '()))]
                        #:when (eq? point (reaction-point r)))
               r))
  (for/fold ([s st]) ([r (in-list (sort rs > #:key reaction-priority))])
    (if ((reaction-when r) s) ((reaction-proc r) s args) s)))
