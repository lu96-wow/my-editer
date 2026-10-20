#lang racket

;;; edit-tui-rebuild/boot/plugin.rkt —— 最小插件值
;;;
;;; 插件不是 class / registry，只是一个普通值：
;;;
;;;   install   (host state -> state)     启动时执行一次
;;;   teardown  (state engine -> state)   退出时执行
;;;
;;; 没有 sync callback：每帧做什么由 boot 的显式循环决定。
;;; 键位、panel rule、action handler 等贡献也先不塞进来。

(provide (struct-out plugin)
         make-plugin)

(struct plugin
  (id
   install
   teardown)
  #:transparent)

(define (make-plugin
         #:id id
         #:install [install #f]
         #:teardown [teardown #f])
  (plugin id install teardown))
