#lang racket

;;; plugins/resource/panel.rkt —— 资源列表面板（buffer 支撑）
;;; layer  : plugins/resource
;;; effect : **IO**：写 *resources* buffer（panel-sync-buffer!）

;;; 只保留三件事，装配动作全在 effects/panel.rkt：
;;;   sync    : 每帧从 workspace.docs / workspace.views 生成行 -> panel-sync-buffer!
;;;   lines   : 委托 projection/resources（纯投影）
;;;   view    : 面板自己的 view-id（插件切片 store['resources]）
;;;
;;; 身份（name / role / mode）与安装动作在 plugins/resource/plugin.rkt。
;;;
;;; 行格式：document 行绿色；view 行蓝色、缩进在 doc 下，显示 region / active /
;;; detached / placing；折叠集合在 state.resources.collapsed。

(provide sync-resource-panel! resource-view)
(provide (all-from-out "lines.rkt"))

(require "../../model/state.rkt"
         "model.rkt"
         "../../effects/engine.rkt"
         "lines.rkt"
         "../../effects/panel.rkt")

(define (resource-view state)
  (resource-panel-view (plugin-state state 'resources (resource-panel-empty))))

(define (sync-resource-panel! state engine)
  (define vid (resource-view state))
  (when (and vid (panel-visible? state vid))
    (define lines (resource-lines state))
    (panel-sync-buffer! engine state vid
                        #:texts (map resource-line-text lines)
                        #:faces (map resource-line-face lines))))
