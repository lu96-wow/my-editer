#lang racket

;;; lab-rebuild/plugin/input/api.rkt —— 输入插件协议（主进程同步）
;;;
;;; 与 plugin/attr/ 的区别：那边在后台进程里跑、只写属性、**不改文本**；
;;; 输入插件在**每次按键同步**执行，会改编辑，所以在主进程。
;;;
;;; 一个插件 = 两个可选钩子；返回 #f = 不插手（交给下一个插件 / 默认行为）：
;;;   on-text      : (app string) -> #f | (listof change)   '() = 插手但不改文本
;;;   on-backspace : (app)        -> #f | (listof change)
;;; 多个插件按列表顺序问，**第一个插手的赢**。钩子自己做编辑并返回 core 的 change，
;;; 由 command/registry 统一 note 给属性插件层（保持影子文本同步）。
;;;
;;; 启用哪些插件是配置（config/plugins.rkt）；本文件的函数接收**已解析的插件列表**。

(provide (struct-out input-plugin)
         input-plugins-text! input-plugins-backspace!)

(struct input-plugin (name on-text on-backspace) #:transparent)
;; on-text / on-backspace : 见上；用不到的方向给 #f

(define (input-plugins-text! plugins a text)
  (for/or ([p (in-list plugins)])
    (define h (input-plugin-on-text p))
    (and h (h a text))))

(define (input-plugins-backspace! plugins a)
  (for/or ([p (in-list plugins)])
    (define h (input-plugin-on-backspace p))
    (and h (h a))))
