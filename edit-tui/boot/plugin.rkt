#lang racket

;;; edit-tui-rebuild/boot/plugin.rkt —— 最小插件值
;;;
;;; 插件不是 class / registry，只是一个普通值：
;;;
;;;   install   (host state -> state)     启动时执行一次
;;;   sync      (state engine -> state)   每帧执行
;;;   teardown  (state engine -> state)   退出时执行
;;;
;;; 键位、panel rule、action handler 等贡献先不塞进来；
;;; 等 boot 的安装流程稳定后再加字段。

(provide (struct-out plugin)
         make-plugin)

(struct plugin
  (id
   install
   sync
   teardown)
  #:transparent)

(define (make-plugin
         #:id id
         #:install [install #f]
         #:sync [sync #f]
         #:teardown [teardown #f])
  (plugin id install sync teardown))
