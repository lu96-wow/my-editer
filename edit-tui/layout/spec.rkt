#lang racket

;;; layout/spec.rkt —— 声明式布局构造器（启动时定义）
;;;
;;; 直接产出 tree.rkt 的值（leaf / split），没有平行的 spec 类型：
;;;
;;;   (lay 'lr
;;;     (pane 'tree   #:view tv #:size 1 #:max 30 #:dock 'left)   ; 弹性，最多 30 列
;;;     (lay 'tb
;;;       (pane 'editor #:view ev #:size 1)
;;;       (pane 'status #:view #f #:fixed 1 #:dock 'down)))        ; 固定 1 行内容
;;;
;;; 尺寸（`#:size` / `#:fixed` / `#:min` / `#:max`）：
;;;   #:size n        弹性权重 n（默认 1）；兼容旧的“全是权重”
;;;   #:fixed n       固定 n 格**内容**（不含边框；与 #:size 二选一）
;;;   #:min n / #:max n   弹性的内容上下限（只在 #:size 时有用）
;;;   #:size (fixed n) / (flex w #:min .. #:max ..)  也可直接给 dim
;;;
;;; 每个面板用 `#:dock` 声明它贴哪边，**边框由位置自动推**：
;;;   left → '(right)    right → '(left)    up → '(down)    down → '(up)
;;;   center / 不写 → 全边
;;; 也可以 `#:borders` 直接覆盖。
;;;
;;; `#:role`：'panel（默认）| 'editor | 'slot | …（见 app/role.rkt）
;;; 编辑区初始 view 可以是 #f（空面板占位），之后用 mount-view / open-doc 装 document。
;;;
;;; 运行期不再动结构 / 边框，只 tree-show / tree-hide / tree-resize-*（在 tree/solve）。

(provide dock-borders
         pane lay)

(require "tree.rkt")

(define (dock-borders dock)
  (case dock
    [(left)   '(right)]
    [(right)  '(left)]
    [(up)     '(down)]
    [(down)   '(up)]
    [else     '(up down left right)]))     ; center / #f → 全边

;; 尺寸关键字 → dim。fixed 优先；否则 size（数字/dim）+ min/max。
(define (size->dim size fixed-n lo hi)
  (cond
    [fixed-n (fixed fixed-n)]
    [(dim? size) size]
    [else (flex size #:min lo #:max hi)]))

;; 叶子面板：dock 决定默认边框；#:borders 覆盖。构造即 tree 的 leaf。
(define (pane id #:view [view #f]
              #:size [size 1]
              #:fixed [fixed-n #f]
              #:min [lo #f]
              #:max [hi #f]
              #:dock [dock #f]
              #:borders [borders #f]
              #:face [face 'window-border]
              #:weight [weight 0]
              #:visible? [visible? #t]
              #:role [role 'panel])
  (make-leaf id view
             #:borders (or borders (dock-borders dock))
             #:face face #:weight weight
             #:size (size->dim size fixed-n lo hi)
             #:visible? visible? #:role role))

;; 分裂：子节点沿 axis 排（'lr 左右 | 'tb 上下）。构造即 tree 的 split。
(define (lay axis #:size [size 1] #:fixed [fixed-n #f] #:min [lo #f] #:max [hi #f]
             . children)
  (split axis children (size->dim size fixed-n lo hi)))
