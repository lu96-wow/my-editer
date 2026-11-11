#lang racket

;;; edit-tui-rebuild/editor/host-api.rkt —— 宿主装配面
;;;
;;; 只有 host 能 require 这个文件。它比 editor/api.rkt 多出：
;;;   · engine 生命周期（创建 / 删除 buffer view）
;;;   · engine 原始 action（宿主调试 / 迁移期用；插件不要用）
;;;
;;; 插件仍然只 require editor/api.rkt。

(require "api.rkt"
         "../core/api.rkt"
         "engine/api.rkt")

(provide (all-from-out "api.rkt")

         ;; 初始布局装配：只有 host 使用
         make-editor-layout
         editor-layout-config

         ;; 渲染 / 尺寸同步：只有 host 使用
         panels-sync!
         render-display-patch
         render-display

         ;; engine 生命周期：只有 host 使用
         make-engine
         engine-create-buffer!
         engine-create-view!
         engine-create-view-from-view!
         engine-remove-view!
         engine-remove-doc!

         ;; 迁移期调试口；插件不要用
         engine-apply-view-action!)
