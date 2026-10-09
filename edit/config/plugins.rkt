#lang racket

;;; edit/config/plugins.rkt —— 启用哪些插件（纯数据）
;;;
;;; 只放**名字**，具体实现由 plugin/catalog.rkt 按名字解析。config 不认识插件实现，
;;; 插件实现也不必 require config。

(provide enabled-plugin-names)

(define enabled-plugin-names
  '(words syntax completion))
