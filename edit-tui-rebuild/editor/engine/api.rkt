#lang racket

;;; edit-tui-rebuild/editor/engine/api.rkt —— core buffer / view 的唯一拥有者
;;;
;;; 这是 editor 层的可变内核。只有 editor/ops/raw.rkt 允许直接调用它；
;;; 插件只能通过 editor/api.rkt 的操作面和查询面访问。

(require "action.rkt"
         "store.rkt")

(provide (all-from-out "action.rkt"
                       "store.rkt"))
