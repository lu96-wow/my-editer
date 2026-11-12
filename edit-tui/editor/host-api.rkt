#lang racket

;;; edit-tui/editor/host-api.rkt —— 宿主装配面
;;;
;;; 只有 host 能 require 这个文件。它比 editor/api.rkt 多出：
;;;   · state / resource 的完整内部面（constructor、plugin-state 写回、resource 变更）
;;;   · job 账本 / job-result-event constructor
;;;   · engine 生命周期（创建 / 删除 buffer view）
;;;   · engine 原始 action（宿主调试 / 迁移期用；插件不要用）
;;;
;;; 插件仍然只 require editor/api.rkt。

(require "api.rkt"
         "../core/api.rkt"
         "engine/api.rkt"
         "state.rkt"
         "resource.rkt"
         "job.rkt"
         "context.rkt"
         "hooks.rkt"
         "layout.rkt"
         "timer.rkt"
         "plugin.rkt"
         "plugin-runtime.rkt")

(provide (all-from-out "api.rkt")
         ;; State / resource 的完整内部面：constructor、plugin-states、写入口。
         (all-from-out "state.rkt")
         (all-from-out "resource.rkt")

         ;; job 账本 / job-result-event constructor：host runtime 使用。
         (all-from-out "job.rkt")

         ;; host 编排 / 插件聚合
         (all-from-out "plugin.rkt")
         (all-from-out "plugin-runtime.rkt")

         ;; editor 实例 / hook registry / 完整 layout / timer service：host 使用。
         (all-from-out "context.rkt")
         (all-from-out "hooks.rkt")
         (all-from-out "layout.rkt")
         (all-from-out "timer.rkt")

         ;; 渲染 / 尺寸同步：只有 host 使用
         panels-sync!
         render-display-patch
         render-display

         ;; engine 生命周期 / 查询 / raw action：只有 host 使用
         (all-from-out "engine/api.rkt"))
