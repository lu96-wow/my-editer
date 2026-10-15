#lang racket

;;; layout/main.rkt —— 布局层入口（树 + 生产者 + 声明式 + 浮窗）
;;;
;;; core 之上、宿主之下：tree 是纯值，solve 把 tree → (listof panel) 交给 core；
;;; float 是不进树的覆盖层（用完即毁）。不 require tui。

(require "tree.rkt"
         "solve.rkt"
         "spec.rkt"
         "float.rkt")

(provide (all-from-out "tree.rkt"
                       "solve.rkt"
                       "spec.rkt"
                       "float.rkt"))
