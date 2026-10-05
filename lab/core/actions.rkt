#lang racket

(require "actions/core.rkt"
         "actions/tree.rkt"
         "actions/modal.rkt"
         "actions/file.rkt"
         "actions/focus.rkt")

;;; lab-rebuild/app/actions.rkt —— 业务动作**聚合出口**
;;;
;;; 动作按域拆在 actions/ 下，本文件只 re-export，保持外部 `(require "actions.rkt")` 不变：
;;;
;;;   actions/core.rkt    枢纽：打开 / 关闭 / 显示 / 分屏 / 文档列表（共享不变量）
;;;   actions/tree.rkt    文件树动作（依赖 core + modal）
;;;   actions/modal.rkt   前缀键 / prompt（不依赖其它动作）
;;;   actions/file.rkt    保存 / 退出 / 尺寸
;;;   actions/focus.rkt   焦点移动 / 左栏切换（依赖 core）
;;;
;;; 依赖方向是 DAG：spoke → core，core 不 require 任何 spoke（没有环）。

(provide (all-from-out "actions/core.rkt")
         (all-from-out "actions/tree.rkt")
         (all-from-out "actions/modal.rkt")
         (all-from-out "actions/file.rkt")
         (all-from-out "actions/focus.rkt"))
