#lang racket

(require "layout/main.rkt")

;;; lab-rebuild/app/edit-panes.rkt —— 编辑区的分屏模型
;;;
;;;   tree   : #f | leaf | node          base/layout 的二叉 split 树（#f = 还没打开任何文档）
;;;   active : 当前 active leaf 的 vid  打开 / 焦点 / 拆分都以它为准；tree = #f 时是 #f
;;;
;;; 本模块只管「结构与不变量」，不管事件 / 命令 / 打开哪个 view：
;;;   打开 = 用 vid 替换 active leaf 的内容（tree 空就建一个根 leaf）
;;;   拆分 = 在 active leaf 上加一个 node（tree-split）
;;;   移动 = 交换两个 leaf 的 vid（tree-swap，位置不变只换内容）
;;;   调整 = 沿路径改最近同向 node 的第一段尺寸（tree-resize）
;;;   关闭 = 从树里删掉若干 vid，若 active 被删则回落到第一个剩余 leaf
;;; app 层不用动结构知识。

(provide (struct-out edit-panes)
         edit-panes-empty edit-panes-tree edit-panes-active edit-panes-contains? edit-panes-vids
         edit-panes-open! edit-panes-split! edit-panes-swap! edit-panes-resize! edit-panes-remove!)

(struct edit-panes (tree active) #:mutable #:transparent)

(define (edit-panes-empty) (edit-panes #f #f))

;; vid 是否是当前树里的一个 leaf。
(define (edit-panes-contains? ep vid)
  (define t (edit-panes-tree ep))
  (and t vid (tree-contains? t vid)))

;; 当前编辑区用到的所有 vid（不重复）。
(define (edit-panes-vids ep)
  (define t (edit-panes-tree ep))
  (if t (tree-vids t) '()))

;; 把 active leaf 换成一个新 vid；没有树就建根 leaf。→ 新 active
(define (edit-panes-open! ep vid)
  (define t (edit-panes-tree ep))
  (set-edit-panes-tree! ep
                        (cond [(not t) (leaf vid)]
                              [else (tree-replace t (edit-panes-active ep) vid)]))
  (set-edit-panes-active! ep vid)
  vid)

;; 在 active leaf 上按 dir 分出新窗格 new-vid（新窗格在右 / 下），active 转到新窗格。
;; 树为空（还没打开文档）→ 不做。dir: 'lr 左右 | 'tb 上下。
(define (edit-panes-split! ep dir new-vid)
  (define t (edit-panes-tree ep))
  (when t
    (set-edit-panes-tree! ep (tree-split t (edit-panes-active ep) dir new-vid))
    (set-edit-panes-active! ep new-vid))
  (void))

;; 交换 v1 / v2 两个窗格的内容（位置不变，只换 vid）——“移动窗格”。
;; 两者都必须在树里，否则不动。
(define (edit-panes-swap! ep v1 v2)
  (define t (edit-panes-tree ep))
  (when (and t (tree-contains? t v1) (tree-contains? t v2))
    (set-edit-panes-tree! ep (tree-swap t v1 v2)))
  (void))

;; 沿 vid 所在路径找方向匹配的分割 node，把第一段尺寸调 delta（area = 主区矩形）。
;; delta > 0 = 放大该窗格；< 0 = 缩小。axis: 'width | 'height。
(define (edit-panes-resize! ep vid axis delta area)
  (define t (edit-panes-tree ep))
  (when (and t (tree-contains? t vid))
    (set-edit-panes-tree! ep (tree-resize t vid axis delta area)))
  (void))

;; 从树里删掉 vids。active 被删 → 回落第一个剩余 leaf；树空 → active #f。
(define (edit-panes-remove! ep vids)
  (define t (for/fold ([t (edit-panes-tree ep)]) ([v (in-list vids)])
              (if t (tree-remove t v) #f)))
  (set-edit-panes-tree! ep t)
  (define act (edit-panes-active ep))
  (unless (and t act (tree-contains? t act))
    (set-edit-panes-active! ep (if t (car (tree-vids t)) #f)))
  (void))
