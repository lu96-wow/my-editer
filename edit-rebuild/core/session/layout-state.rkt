#lang racket

;;; edit-rebuild/core/session/layout-state.rkt —— 布局状态（纯）
;;;
;;; 局部问题：骨架（frame）/ 洞绑定（bindings）/ 编辑区子树（editor），以及由三者
;;; fill 出来的**派生布局树**（layout）。换骨架、换编辑区子树、加面板子树都只动这里。
;;;
;;; layout = fill(frame, bindings + {editor slot ← editor})，是几何求值的输入。

(require "../geometry/layout.rkt"
         "../ids.rkt")

(provide (struct-out layout-state)
         layout-state-new
         layout-state-set-editor
         layout-state-set-frame
         layout-state-set-binding)

(struct layout-state (frame bindings editor layout) #:transparent)
;; frame    : 骨架 slot 树（#f = 未装配）
;; bindings : slot-id -> node（面板子树）
;; editor   : 编辑区运行时子树（起于 (blank)）
;; layout   : 派生 = fill(frame, bindings + editor)

(define (layout-state-fill frame bindings editor)
  (and frame
       (layout-fill frame
                    (hash-set (or bindings (hash)) slot-editor editor))))

(define (layout-state-new frame bindings editor)
  (layout-state frame bindings editor (layout-state-fill frame bindings editor)))

(define (layout-state-set-editor l editor)
  (layout-state-new (layout-state-frame l) (layout-state-bindings l) editor))

(define (layout-state-set-frame l frame)
  (layout-state-new frame (layout-state-bindings l) (layout-state-editor l)))

(define (layout-state-set-binding l slot node)
  (layout-state-new (layout-state-frame l)
                    (hash-set (layout-state-bindings l) slot node)
                    (layout-state-editor l)))
