#lang racket

;;; edit-tui-rebuild/layout/api.rkt —— 布局 API
;;;
;;; 聚合三层实现：tree（结构+查询）/ solve（rect+seam）/ ops（结构编辑+拖动）。

(require "tree.rkt"
         "solve.rkt"
         "ops.rkt")

(provide
 ;; 节点 / layout 状态
 make-leaf
 leaf? leaf-panel-id
 split? split-id split-axis split-left split-right split-ratio
 layout? layout-empty? layout-node? layout-tree? layout-root
 make-layout empty-layout

 ;; 焦点
 layout-focus layout-set-focus

 ;; panel 资源
 layout-panel-add layout-panel-add-view layout-panel layout-panel-resources layout-panel-ids
 layout-panel-for-view
 layout-visible-panel-ids layout-panel-update
 layout-panel-visible? layout-panel-fixed-size layout-subtree-visible?

 ;; panel 内 view 切换
 layout-panel-view-ids
 layout-panel-active-view
 layout-panel-set-active-view
 layout-panel-cycle-active-view

 ;; 结构
 layout-split
 layout-panel-attach
 layout-panel-remove
 layout-panel-clear-content
 layout-panel-set-fixed
 layout-split-set-ratio

 ;; 隐藏 / 显示 / 焦点回退
 layout-panel-hide
 layout-panel-show
 layout-focus-fallback

 ;; layout-solve
 layout-solve
 layout-solution? layout-solution-panel-rects
 layout-solution-split-rects layout-solution-seams
 layout-panel-rects layout-split-rects
 layout-seams layout-seam-at layout-panel-id-at

 ;; 接缝 / 拖动
 seam? seam-split-id seam-axis seam-rect
 layout-seam-resize
 drag? drag-split-id drag-axis drag-start-row drag-start-col drag-start-ratio
 layout-seam-drag-start layout-seam-drag-move

 ;; 校验
 layout-validate layout-valid?)
