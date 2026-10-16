#lang racket

;;; layout/spec.rkt —— 声明式布局构造器（启动时定义）
;;;
;;; 直接产出 tree.rkt 的值（leaf / split），没有平行的 spec 类型：
;;;
;;;   (lay 'lr
;;;     (pane 'tree   #:view tv #:size 4 #:dock 'left)
;;;     (lay 'tb
;;;       (pane 'editor #:view ev #:size 3)
;;;       (pane 'status #:view #f #:size 1 #:dock 'bottom)))
;;;
;;; 每个面板用 `#:dock` 声明它贴哪边，**边框由位置自动推**：
;;;   left → '(right)    right → '(left)    top → '(down)    bottom → '(up)
;;;   center / 不写 → 全边
;;; 也可以 `#:borders` 直接覆盖。
;;;
;;; `#:role`
;;;   'panel （默认）—— 面板：固定区域，不参与 split 切分（如文件树 / 状态栏）
;;;   'editor         —— 编辑区：可被 split-left/right/up/down 切分（见 app/ops.rkt）
;;; 编辑区初始 view 可以是 #f（空面板占位），之后用 mount-view / open-doc 装 document。
;;;
;;; 运行期不再动结构 / 边框，只 tree-show / tree-hide / tree-resize-at（在 tree.rkt）。

(provide dock-borders
         pane lay)

(require "tree.rkt")

(define (dock-borders dock)
  (case dock
    [(left)   '(right)]
    [(right)  '(left)]
    [(top)    '(down)]
    [(bottom) '(up)]
    [else     '(up down left right)]))     ; center / #f → 全边

;; 叶子面板：dock 决定默认边框；#:borders 覆盖。构造即 tree 的 leaf。
(define (pane id #:view [view #f]
              #:size [size 1]
              #:dock [dock #f]
              #:borders [borders #f]
              #:face [face 'window-border]
              #:weight [weight 0]
              #:visible? [visible? #t]
              #:role [role 'panel])
  (make-leaf id view
             #:borders (or borders (dock-borders dock))
             #:face face #:weight weight #:size size #:visible? visible? #:role role))

;; 分裂：子节点沿 axis 排（'lr 左右 | 'tb 上下）。构造即 tree 的 split。
(define (lay axis #:size [size 1] . children)
  (split axis children size))
