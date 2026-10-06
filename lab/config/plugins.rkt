#lang racket

;;; lab-rebuild/config/plugins.rkt —— 启用哪些插件（纯数据）
;;;
;;; 只放**名字**，具体实现由各插件注册表按名字解析。这样 config 不认识插件实现，
;;; 插件实现也不必 require config（worker 侧解析同样读这里，保证主进程 / 后台一致）。

(provide attr-plugin-names input-plugin-names)

;; 属性插件（font-lock 类）：brackets 背景 / words 词色 / syntax 关键字
(define attr-plugin-names
  '(brackets words syntax))

;; 输入插件（electric-pair 类）
(define input-plugin-names
  '(auto-pair))
