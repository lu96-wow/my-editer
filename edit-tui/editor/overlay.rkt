#lang racket

;;; edit-tui/editor/overlay.rkt —— 插件浮层描述（纯值）
;;;
;;; 插件不构造 core panel；host 把 overlay 转成 core panel 后交给 renderer。
;;; anchor-view-id 表示该 overlay 依赖的编辑区 view；不在当前 area 时 host 会丢弃。

(require "../core/api.rkt")

(provide (struct-out editor-overlay)
         make-editor-overlay)

(struct editor-overlay
  (view-id
   anchor-view-id  ; 依赖的编辑区 view | #f：非当前 area 时不渲染
   rect
   borders
   face
   weight
   deep)
  #:transparent)

(define (make-editor-overlay view-id rect
                             #:anchor-view-id [anchor-view-id #f]
                             #:borders [borders '(up down left right)]
                             #:face [face 'float-border]
                             #:weight [weight 100]
                             #:deep [deep 100])
  (editor-overlay view-id anchor-view-id rect borders face weight deep))
