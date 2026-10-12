#lang racket

;;; edit4/config/plugins.rkt —— 本次启用哪些插件（纯数据：只给名字）
;;;
;;; 名字由 plugins/catalog.rkt 解析成实现。顺序 = 层叠顺序（前 = 底层）。
;;; 默认启用高亮与自动配对；demo / async-demo 供测试或显式启用。

(provide enabled-plugins)

(define enabled-plugins
  '(syntax words brackets auto-pair))
