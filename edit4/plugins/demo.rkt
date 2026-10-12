#lang racket

;;; edit4/plugins/demo.rkt —— 插件契约演示包（op / 键表 / 钩子 / 匹配层 / boot / on-open）
;;;
;;; 它做四件事（用于验证契约，不默认启用）：
;;;   · 贡献一个命令 demo-bump：把 store 里的计数加一；
;;;   · 贡献 M-y 绑定；
;;;   · 贡献一个 after-insert 钩子：累计插入次数；
;;;   · 给 *.demo 文档挂一张匹配键表（M-g 也 bump），并在打开时记下路径；
;;;   · boot 初始化计数。

(provide demo-plugin)

(require "../plugin.rkt"
         "../core/world.rkt" "../core/store.rkt"
         "../core/command.rkt" "../core/hook.rkt"
         racket/path)

(define (count w) (store-ref (world-store w) 'demo-count 0))

(define (h-demo-bump _ctx w _args)
  (cons (world-set-store w (store-set (world-store w) 'demo-count (add1 (count w)))) '()))

(define (demo-on-open w _did path)
  (world-set-store w (store-set (world-store w) 'demo-opened (format "~a" path))))

(define (demo-on-insert w _args)
  (world-set-store w (store-set (world-store w) 'demo-inserts
                                (add1 (store-ref (world-store w) 'demo-inserts 0)))))

(define demo-commands
  (make-command-registry (list (cons 'demo-bump h-demo-bump))))

(define (demo-applies? path)
  (equal? (path-get-extension path) #".demo"))

(define demo-plugin
  (make-plugin
   #:name 'demo
   #:applies? demo-applies?                    ; on-open / decor 只对 *.demo 生效
   #:commands demo-commands
   #:keymap (list (list '(key y alt) 'always (cmd 'demo-bump)))
   #:hooks (list (reaction* 'after-insert demo-on-insert))
   #:doc-key-matchers (list (cons '(ext "demo")
                                  (list (list '(key g alt) 'always (cmd 'demo-bump)))))
   #:boot (lambda (w) (world-set-store w (store-set (world-store w) 'demo-count 0)))
   #:on-open demo-on-open))
