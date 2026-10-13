#lang racket

;;; edit4/env.rkt —— Environment：装配期只读的注册表集合（L5/L6）
;;;
;;; World 只装「可变状态」；路由 / 作用域 / 键表 / 面板 / 装饰 / 钩子 / 服务 /
;;; 文档匹配层 / 插件启动与打开回调，都是「这次运行的配置」，装进 Environment，
;;; 作为参数一路传下去，不进 World。
;;; （edit3 把这些全塞在 State.features 里；edit4 的接口是「数据 + fold」，见 plugin.rkt。）

(provide (struct-out environment) base-environment)

(require "core/command.rkt" "core/scope.rkt" "core/job.rkt" "content/prompt.rkt")

(struct environment
  (commands scopes keymap panels regions decor prompt-kinds hooks services
            doc-key-matchers boots on-opens)
  #:transparent)
;; commands          : command-registry
;; scopes            : scope-registry
;; keymap            : (listof entry)               已按优先级排好（后者覆盖同 slot）
;; panels            : (listof (World -> projection))
;; regions           : (listof region-spec)         插件声明的面板槽
;; decor             : (listof (path text cursor -> (listof (vectorof face))))
;; prompt-kinds      : prompt-kind-registry
;; hooks             : (listof reaction)
;; services          : service-registry
;; doc-key-matchers  : (listof (cons matcher keytable))
;; boots             : (listof (World -> World))
;; on-opens          : (listof (World did path -> World))

(define (base-environment)
  (environment (make-command-registry) (make-scope-registry) '() '() '() '()
               base-prompt-kinds '() (make-service-registry) '() '() '()))
