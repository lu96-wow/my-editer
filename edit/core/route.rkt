#lang racket

;;; edit-rebuild/core/route.rkt —— 键路由（纯）：keymap 的升级形态
;;;
;;; 旧 keymap 是「binding -> spec」的平表，靠一叠栈 + 焦点决定谁生效。
;;; 这里升级成「binding -> action，带作用域 / 优先级 / 策略 / 前缀」：
;;;
;;;   route  = key + action + scope + priority + policy + prefix
;;;
;;; resolve 只做**收集与排序**（key 相等 + scope 命中 + prefix 一致，priority 降序），
;;; 不执行、不判断「是否接住」——「停 / 继续」由 policy 在派发时决定（见 dispatch.rkt）。
;;; 于是「一键同时管两个窗」= 两条 scope 都命中的 route；
;;;「按键含义随状态替换」= 不同 scope 下的同 key route。

(require "scope.rkt"
         "key.rkt")

(provide (struct-out route) (struct-out command-pred)
         route* routes route-list-add route-list-merge
         resolve trigger-match?)

;; key      : 绑定键
;; action   : cmd（宿主解释）| 结构化效果 | 载荷型 spec（符号，见 key.rkt）
;; scope    : scope
;; priority : integer，大者先（取代“注册顺序”）
;; policy   : 'stop（接了就停）| 'continue（接了继续往下）
;; prefix   : any/c | #f   属于哪个前缀（#f = 顶层）
(struct route (key action scope priority policy prefix) #:transparent)

(define (route* key action
                #:when [scope (scope-always)]
                #:priority [priority 0]
                #:policy [policy 'stop]
                #:prefix [prefix #f])
  (route key action scope priority policy prefix))

;; 路由表就是列表；提供几个组合子（保持纯、顺序稳定）。
(define (routes . rs) rs)
(define (route-list-add rs r) (cons r rs))
(define (route-list-merge . rss) (append* rss))

;; 参数化命令的触发谓词：`(command-pred pred)` 作为 route 的 key，
;; resolve 用 pred 匹配命令（否则用 equal?）。见 trigger-match?。
(struct command-pred (pred) #:transparent)

(define (trigger-match? route-key trigger)
  (cond
    [(command-pred? route-key) (and ((command-pred-pred route-key) trigger) #t)]
    [else (equal? route-key trigger)]))

;; 命中路由：key 匹配 + scope 满足 + prefix 与 context 一致；按 priority 降序。
;; priority 相同则由 sort 的稳定性保持原顺序（先声明的先）。
(define (resolve rss ctx binding)
  (define p (context-prefix ctx))
  (sort (for/list ([r (in-list rss)]
                   #:when (and (equal? p (route-prefix r))
                               (trigger-match? (route-key r) binding)
                               (scope-satisfied? (route-scope r) ctx)))
          r)
        > #:key route-priority))
