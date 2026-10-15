#lang racket

;;; layout/spec.rkt —— 声明式布局（启动时定义）
;;;
;;; 用一小段数据描述布局，编译成 layout/tree.rkt 的树：
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
;;; 运行期不再动结构 / 边框，只 tree-show / tree-hide（在 tree.rkt）。

(provide (struct-out pane-spec) (struct-out split-spec)
         pane lay
         dock-borders
         spec->tree)

(require "tree.rkt")

(define (dock-borders dock)
  (case dock
    [(left)   '(right)]
    [(right)  '(left)]
    [(top)    '(down)]
    [(bottom) '(up)]
    [else     '(up down left right)]))     ; center / #f → 全边

(struct pane-spec (id view size dock borders face weight) #:transparent)
(struct split-spec (axis size children) #:transparent)

;; 叶子面板。dock 决定默认边框；#:borders 可显式覆盖。
(define (pane id #:view [view #f]
              #:size [size 1]
              #:dock [dock #f]
              #:borders [borders #f]
              #:face [face 'window-border]
              #:weight [weight 0])
  (pane-spec id view size dock (or borders (dock-borders dock)) face weight))

;; 分裂：子节点沿 axis 排（'lr 左右 | 'tb 上下）。每个孩子自带 size。
(define (lay axis #:size [size 1] . children)
  (split-spec axis size children))

(define (spec->tree s)
  (cond
    [(pane-spec? s)
     (leaf (pane-spec-id s) (pane-spec-view s) (pane-spec-borders s)
           (pane-spec-face s) (pane-spec-weight s) (pane-spec-size s) #t)]
    [(split-spec? s)
     (split (split-spec-axis s)
            (map spec->tree (split-spec-children s))
            (split-spec-size s))]
    [else (error 'spec->tree "不是 pane / lay：~a" s)]))
