#lang racket

;;; edit-tui/editor/engine/read.rkt —— Engine 只读能力
;;;
;;; 只导出查询函数：document / view / point / face。
;;; 不导出创建、删除、用户文本写、UI 写。

(require "store.rkt")

(provide engine-view-object
         engine-view-text
         engine-doc-text
         engine-doc-version
         engine-view-doc-id
         engine-doc-kind
         engine-view-kind
         engine-doc-ids
         engine-user-doc-ids
         engine-ui-doc-ids
         engine-derived-doc-ids
         engine-user-view-ids
         engine-ui-view-ids
         engine-derived-view-ids
         engine-view-ids-for-doc
         engine-derived-doc-owner
         engine-derived-doc-source
         engine-derived-doc-edit-policy
         engine-view-point-line
         engine-view-point-column
         engine-view-cursor-screen-position
         engine-view-face-at)
