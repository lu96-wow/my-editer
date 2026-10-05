#lang racket

(require "../base/brackets.rkt"
         "api.rkt")

;;; lab/plugin/brackets.rkt —— 括号按深度背景高亮（第一个内置插件）
;;;
;;; compute 就是纯扫描：文本 → 整对区间的 (bracket-depth n) 填充。

(provide bracket-plugin)

(define (bracket-compute j)
  (bracket-fills (job-text j)))

(define bracket-plugin
  (plugin 'brackets 0 bracket-compute))
