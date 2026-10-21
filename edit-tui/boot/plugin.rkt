#lang racket

;;; edit-tui-rebuild/boot/plugin.rkt —— 最小插件值
;;;
;;; 插件不是 class / registry，只是一个普通值：
;;;
;;;   install   (host state -> state)     启动时执行一次
;;;   teardown  (state engine -> state)   退出时执行
;;;   services  (listof service)          插件贡献的异步 service
;;;
;;; 没有 sync callback：每帧做什么由 boot 的显式循环决定。
;;; 键位 / 布局 / panel rule 仍由 config 与 host 显式组合。

(provide (struct-out plugin)
         make-plugin)

(struct plugin
  (id
   install
   teardown
   services)
  #:transparent)

(define (make-plugin
         #:id id
         #:install [install #f]
         #:teardown [teardown #f]
         #:services [services '()])
  (plugin id install teardown services))
