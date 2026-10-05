#lang racket

(require "../base/layout/main.rkt")

;;; lab/app/edit-panes.rkt —— 编辑区的分屏模型
;;;
;;;   tree   : #f | leaf | node          base/layout 的二叉 split 树（#f = 还没打开任何文档）
;;;   active : 当前 active leaf 的 vid  打开 / 焦点 / 拆分都以它为准；tree = #f 时是 #f
;;;
;;; 本模块只管「结构与不变量」，不管事件 / 命令 / 打开哪个 view：
;;;   打开 = 用 vid 替换 active leaf 的内容（tree 空就建一个根 leaf）
;;;   关闭 = 从树里删掉若干 vid，若 active 被删则回落到第一个剩余 leaf
;;; 之后要加「拆分」时，只需在这里加 split!（tree-split），app 层不用动结构知识。

(provide (struct-out edit-panes)
         edit-panes-empty edit-panes-tree edit-panes-active edit-panes-contains? edit-panes-vids
         edit-panes-open! edit-panes-split! edit-panes-remove!)

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

;; 从树里删掉 vids。active 被删 → 回落第一个剩余 leaf；树空 → active #f。
(define (edit-panes-remove! ep vids)
  (define t (for/fold ([t (edit-panes-tree ep)]) ([v (in-list vids)])
              (if t (tree-remove t v) #f)))
  (set-edit-panes-tree! ep t)
  (define act (edit-panes-active ep))
  (unless (and t act (tree-contains? t act))
    (set-edit-panes-active! ep (if t (car (tree-vids t)) #f)))
  (void))
