#lang racket

;;; edit-tui-rebuild/panel/api.rkt —— panel 资源 API
;;;
;;; 只导出功能面；不导出内部构造细节之外的布局函数。

(require "model.rkt")

(provide
 ;; 类型判断 / 读
 panel?
 panel-id
 panel-kind
 panel-views
 panel-active
 panel-fixed-w
 panel-fixed-h
 panel-hidden?
 panel-restore
 panel-borders
 panel-face
 panel-weight
 panel-view
 panel-visible?

 ;; restore
 restore?
 restore-rect
 restore-parent-rect

 ;; 构造
 make-panel
 make-empty-editor-panel

 ;; 纯更新
 panel-set-views
 panel-set-active
 panel-set-fixed
 panel-set-hidden
 panel-set-restore)
