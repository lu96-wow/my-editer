#lang racket

;;; edit-tui/editor/engine/lifecycle.rkt —— Engine 生命周期能力
;;;
;;; 只负责 engine / buffer / view 的创建与删除。
;;; 不导出文本写、UI 写、查询。

(require "store.rkt")

(provide make-engine
         engine-create-buffer!
         engine-create-view!
         engine-create-view-from-view!
         engine-remove-view!
         engine-remove-doc!)
