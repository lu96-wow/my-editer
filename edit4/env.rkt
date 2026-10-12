#lang racket

;;; edit4/env.rkt —— Environment：装配期只读的注册表集合（L5）
;;;
;;; World 只装「可变状态」；路由 / 作用域 / 键表 / 面板 / 装饰都是「这次运行的配置」，
;;; 装进 Environment，作为参数一路传下去，不进 World。
;;; （edit3 把这些全塞在 State.features 里；edit4 的接口是「数据 + fold」，见 plugin.rkt。）
;;;
;;; 面板与装饰本身就是函数表（listof function），组合就是 append / map，没有额外的注册表类型。

(provide (struct-out environment) base-environment)

(require "core/command.rkt" "core/scope.rkt")

(struct environment (commands scopes keymap panels decor) #:transparent)
;; commands : command-registry
;; scopes   : scope-registry
;; keymap   : (listof entry)       已按优先级排好（后者覆盖同 slot）
;; panels   : (listof (World -> projection))
;; decor    : (listof (path text cursor -> (listof (vectorof face))))

(define (base-environment)
  (environment (make-command-registry) (make-scope-registry) '() '() '()))
