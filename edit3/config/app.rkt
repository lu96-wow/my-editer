#lang racket

;;; edit3/config/app.rkt —— 应用配置入口（聚合声明式选择）
;;;
;;; core 只 require 本模块取配置值；改配置改这里与 keys.rkt / layout.rkt / floats.rkt。

(require "keys.rkt"
         "layout.rkt"
         "theme.rkt"
         "floats.rkt")

(provide (all-from-out "keys.rkt" "layout.rkt" "theme.rkt" "floats.rkt"))
