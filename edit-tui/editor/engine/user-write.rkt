#lang racket

;;; edit-tui/editor/engine/user-write.rkt —— 用户文档写能力
;;;
;;; 只导出 view-action 类型和用户编辑解释器。
;;; 用户可见编辑仍必须经 editor/ops/surface.rkt。

(require "action.rkt"
         "apply.rkt")

(provide (all-from-out "action.rkt")
         engine-apply-view-action!
         (rename-out [engine-apply-view-action! engine-apply-user-action!]))
