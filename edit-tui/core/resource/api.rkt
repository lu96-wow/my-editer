#lang racket

;;; edit-tui-rebuild/resource/api.rkt —— 资源管理 API

(require "model.rkt")

(provide
 ;; store
 resource-store?
 resource-store-empty
 resource-ref
 resource-list
 resource-pending

 ;; resource
 resource?
 resource-id
 resource-name
 resource-doc-id
 resource-views
 resource-version
 resource-saved-version
 resource-path
 resource-dirty?
 resource-writable?
 resource-view-ids
 resource-of-view
 resource-command-stack
 resource-set-command-stack
 resource-mode
 resource-rebind-mode
 resource-normalize-path
 resource-find-by-path
 resource-root
 resource-set-root
 resource-display-path
 resource-revision
 resource-opened-revision

 ;; open / edit / save
 resource-open
 resource-mark-edited
 resource-sync-version
 resource-reset-version
 resource-save
 resource-save-as
 resource-save-done

 ;; close / quit / prompt
 resource-request-close
 resource-request-quit
 resource-prompt
 resource-submit
 resource-submit-text
 resource-cancel

 ;; action
 resource-action?
 resource-action-kind
 resource-action-data

 ;; prompt / pending
 prompt?
 prompt-id
 prompt-kind
 prompt-resource-id
 prompt-label
 prompt-value
 prompt-choices
 pending?
 pending-kind
 pending-ids
 pending-index
 pending-mode)

;; struct-out 的字段访问器与 query 同名冲突时，用显式 alias。
(define (resource-pending store)
  (resource-store-pending store))
