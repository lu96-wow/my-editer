#lang racket

;;; lab-rebuild/platform/panes.rkt —— 单值 pane 身份 registry（平台核心）
;;;
;;; 一个 pane = 一块屏幕格；用 **role → vid** 一处登记。
;;;   state / input  底部共享槽位（谁显示由 mode 决定）
;;;
;;; 左侧面板（文件树 / 文档列表）是**内置包**，不属于平台；等 Phase 3 用面板
;;; 扩展点接进来（届时这里会变成 role → vid 的开放表）。
;;; 编辑区可能有多个窗格（分屏），所以**不在这里**：见 platform/edit-panes.rkt。
;;; did 不再另存：需要时用 (editor-view-document-id ed vid) 现推。

(provide (struct-out panes)
         panes-internal)

(struct panes (state input) #:mutable #:transparent)

;; 不该出现在「已打开文档」列表里的内部 view。
(define (panes-internal p)
  (list (panes-state p) (panes-input p)))
