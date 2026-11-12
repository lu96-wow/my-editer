#lang racket

;;; edit-tui/editor/overlay.rkt —— 插件浮层描述（纯值）
;;;
;;; 插件不构造 core panel；host 把 overlay 转成 core panel 后交给 renderer。

(require "../core/api.rkt")

(provide (struct-out editor-overlay)
         make-editor-overlay)

(struct editor-overlay
  (view-id
   rect
   borders
   face
   weight
   deep)
  #:transparent)

(define (make-editor-overlay view-id rect
                             #:borders [borders '(up down left right)]
                             #:face [face 'float-border]
                             #:weight [weight 100]
                             #:deep [deep 100])
  (editor-overlay view-id rect borders face weight deep))
