#lang racket

;;; edit3/config/plugins.rkt —— 本次启用哪些插件（**纯数据：只给名字**）
;;;
;;; 名字由 plugins/catalog.rkt 解析成实现。默认启用语法高亮（对 .rkt 等 Racket 源文件上色）；
;;; 其它插件按需加名字即可（如 'demo）。

(provide enabled-plugins)

(define enabled-plugins
  '(syntax brackets words completion))
