#lang racket

;;; edit-tui/compat/source/api.rkt —— 解析来源统一入口

(require "model.rkt"
         "store.rkt")

(provide (all-from-out "model.rkt"
                       "store.rkt"))
