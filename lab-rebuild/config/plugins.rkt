#lang racket

;;; lab-rebuild/config/plugins.rkt —— 启用哪些插件（纯数据）
;;;
;;; 只放**名字**，具体实现由插件层的注册表按名字解析（plugin/attr/registry、
;;; plugin/input/registry）。这样 config 不 require 插件实现，插件实现也不
;;; require config（worker 侧解析同样读这里，保证主进程 / 后台一致）。
;;;
;;; 属性插件顺序 = 层叠顺序：后面的后写，同名通道覆盖前面的；
;;; 不同通道（前景 / 背景）同时保留。
;;;   brackets  括号背景（bg）
;;;   words     词前景（fg，持久 词→色号 表）
;;;   syntax    Racket 关键字前景（fg）

(provide attr-plugin-names input-plugin-names)

(define attr-plugin-names
  '(brackets words syntax))

(define input-plugin-names
  '(auto-pair))
