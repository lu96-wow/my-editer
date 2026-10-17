#lang racket

;;; bootstrap/resource-panel.rkt —— 资源列表面板（buffer 支撑）
;;;
;;; 只保留三件事，装配动作全在 bootstrap/panel.rkt：
;;;   install : 建 *resources* view + region，把 view-id 写进 state.resources
;;;   sync    : 每帧从 workspace.docs / workspace.views 生成行 -> panel-sync-buffer!
;;;   lines   : 委托 projection/resources（纯投影）
;;;
;;; 行格式：document 行绿色；view 行蓝色、缩进在 doc 下，显示 region / active /
;;; detached / placing；折叠集合在 state.resources.collapsed。

(provide install-resource-panel! sync-resource-panel! resource-view)
(provide (all-from-out "../projection/resources.rkt"))

(require "../model/state.rkt"
         "../model/resources.rkt"
         "../effects/engine.rkt"
         "../projection/resources.rkt"
         "panel.rkt")

(define (resource-view state)
  (resources-view (state-resources state)))

(define (install-resource-panel! engine state region-id)
  (define-values (s1 vid)
    (panel-install! engine state region-id
                    #:name "*resources*"
                    #:mode 'resources
                    #:role 'resource))
  (state-resources* s1 (λ (r) (resources-set-view r vid))))

(define (sync-resource-panel! state engine)
  (define vid (resource-view state))
  (when vid
    (define lines (resource-lines state))
    (panel-sync-buffer! engine state vid
                        #:texts (map resource-line-text lines)
                        #:faces (map resource-line-face lines))))
