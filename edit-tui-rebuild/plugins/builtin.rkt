#lang racket

;;; layer  : plugins
;;; effect : 无（纯装配）
;;;
;;; 内置插件集 + 组合好的 default-env。
;;;
;;;   core-env          bootstrap/defaults.rkt（只有框架）
;;;   default-plugins   filetree + resource
;;;   default-env       core-env + default-plugins
;;;
;;; demo / 测试用 default-env；想只要框架就只用 core-env（见 test/plugin-detach.rkt）。
;;; 新插件加进 default-plugins 即可，不需要改 bootstrap。

(provide default-plugins
         default-env)

(require "../bootstrap/defaults.rkt"
         "../env/plugin.rkt"
         "filetree/plugin.rkt"
         "resource/plugin.rkt")

(define (default-plugins)
  (list (filetree-plugin)
        (resource-plugin)))

(define default-env
  (plugins-env core-env (default-plugins)))
