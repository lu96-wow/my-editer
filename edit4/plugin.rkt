#lang racket

;;; edit4/plugin.rkt —— 插件契约（数据包）+ 装配 fold（L5）
;;;
;;; plugin 只是数据：名字 + 命令 / 作用域 / 键表 / 面板 / 区域 / 装饰 /
;;; 输入行 kind / 钩子 / 服务 / 文档匹配层 / boot / on-open。
;;; install 是唯一装配动作：把插件 fold 到 Environment 上（后装覆盖同 slot / 追加列表）。
;;; 于是「加功能」= 新增一个 plugin 值，而不是改核心。
;;;
;;; 需要按名覆盖的（命令 / 作用域 / 键表 / prompt-kind / service）用 registry/keymap；
;;; 本身就是函数/值列表的（面板 / 区域 / 装饰 / 钩子 / 匹配层）直接 append。
;;; boot / on-open 收集成列表，分别在装配末尾 / 打开文档时跑。
;;; 这里不引入额外的装配子（lambda 组合子），保持概念最少。

(provide (struct-out plugin) make-plugin empty-plugin
         install run-boots run-opens)

(require racket/list
         "env.rkt"
         "core/command.rkt" "core/scope.rkt" "core/keymap.rkt" "core/job.rkt"
         "content/prompt.rkt")

(struct plugin
  (name commands scopes keymap panels regions decor prompt-kinds hooks services
        doc-key-matchers boot on-open)
  #:transparent)
;; name             : symbol | #f
;; commands         : command-registry
;; scopes           : scope-registry
;; keymap           : (listof entry)
;; panels           : (listof (World -> projection))
;; regions          : (listof region-spec)
;; decor            : (listof (path text cursor -> (listof (vectorof face))))
;; prompt-kinds     : prompt-kind-registry
;; hooks            : (listof reaction)
;; services         : (listof service)
;; doc-key-matchers : (listof (cons matcher keytable))
;; boot             : (World -> World) | #f
;; on-open          : (World did path -> World) | #f

(define (make-plugin #:name [name #f]
                     #:commands [commands (make-command-registry)]
                     #:scopes [scopes (make-scope-registry)]
                     #:keymap [keymap '()]
                     #:panels [panels '()]
                     #:regions [regions '()]
                     #:decor [decor '()]
                     #:prompt-kinds [prompt-kinds (make-prompt-kind-registry)]
                     #:hooks [hooks '()]
                     #:services [services '()]
                     #:doc-key-matchers [doc-key-matchers '()]
                     #:boot [boot #f]
                     #:on-open [on-open #f])
  (plugin name commands scopes keymap panels regions decor prompt-kinds hooks services
          doc-key-matchers boot on-open))

(define empty-plugin (make-plugin))

;; install : Environment (listof plugin) -> Environment
(define (install env plugins)
  (for/fold ([e env]) ([p (in-list plugins)])
    (environment
     (command-registry-merge (environment-commands e) (plugin-commands p))
     (scope-registry-merge   (environment-scopes e)   (plugin-scopes p))
     (compose-keymaps (list (environment-keymap e) (plugin-keymap p)))
     (append (environment-panels e) (plugin-panels p))
     (append (environment-regions e) (plugin-regions p))
     (append (environment-decor e)  (plugin-decor p))
     (prompt-kind-merge (environment-prompt-kinds e) (plugin-prompt-kinds p))
     (append (environment-hooks e) (plugin-hooks p))
     (service-registry-merge (environment-services e)
                             (make-service-registry (plugin-services p)))
     (append (environment-doc-key-matchers e) (plugin-doc-key-matchers p))
     (append (environment-boots e) (if (plugin-boot p) (list (plugin-boot p)) '()))
     (append (environment-on-opens e) (if (plugin-on-open p) (list (plugin-on-open p)) '())))))

;; 装配末尾各跑一次插件的 boot。
(define (run-boots env w)
  (for/fold ([w w]) ([f (in-list (environment-boots env))]) (f w)))

;; 打开文档时跑各插件的 on-open。
(define (run-opens env w did path)
  (for/fold ([w w]) ([f (in-list (environment-on-opens env))]) (f w did path)))
