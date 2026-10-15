#lang racket

;;; layout/main.rkt —— 布局层入口（树 + 生产者）
;;;
;;; core 之上、宿主之下：tree 是纯值，solve 把 tree → (listof panel) 交给 core。
;;; 不 require tui。

(require "tree.rkt"
         "solve.rkt"
         "spec.rkt")

(provide (all-from-out "tree.rkt"
                       "solve.rkt"
                       "spec.rkt"))
