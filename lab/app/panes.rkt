#lang racket

;;; lab/app/panes.rkt —— pane 身份 registry
;;;
;;; 一个 pane = 一块屏幕格；用 **role → vid** 一处登记，替掉散落的 tree-vid/tree-did/…。
;;;   tree / bufs  左侧面板（谁显示由 app.left 决定）
;;;   edit         主编辑格（可以为 #f：还没打开任何文档）
;;;   state / input 底部共享槽位（谁显示由 mode 决定）
;;;
;;; did 不再另存：需要时用 (editor-view-document-id ed vid) 现推。
;;; 内部 pane（树 / 文档列表 / 底槽）需要排除时，用 panes-internal。

(provide (struct-out panes)
         panes-left panes-internal)

(struct panes (tree bufs edit state input) #:mutable #:transparent)

;; 左侧当前显示哪个 pane。
(define (panes-left p left)
  (if (eq? left 'tree) (panes-tree p) (panes-bufs p)))

;; 不该出现在「已打开文档」列表里的内部 view。
(define (panes-internal p)
  (list (panes-tree p) (panes-bufs p) (panes-state p) (panes-input p)))
