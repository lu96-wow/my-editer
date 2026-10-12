#lang racket

;;; edit4/config/plugins.rkt —— 本次启用哪些插件（纯数据：只给名字）
;;;
;;; 名字由 plugins/catalog.rkt 解析成实现。顺序 = 层叠顺序（前 = 底层）：
;;; 括号背景 → 同词着色 → 语法前景（覆盖词色）→ 当前词 → 配对括号。
;;; 默认启用高亮 + 自动配对；demo / async-demo 供测试或显式启用。

(provide enabled-plugins)

(define enabled-plugins
  '(brackets word-color syntax words bracket-match auto-pair completion docs))
