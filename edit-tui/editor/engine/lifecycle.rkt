#lang racket

;;; edit-tui/editor/engine/lifecycle.rkt —— Engine 生命周期能力
;;;
;;; 只负责 engine / buffer / view 的创建与删除。
;;; 不导出文本写、UI 写、查询。
;;;
;;; derived buffer 是 plugin-owned 派生文本：无 resource、无 history，
;;; 带 owner / source-doc-id / edit-policy 元数据。

(require "store.rkt")

(provide make-engine
         engine-create-buffer!
         engine-create-derived-buffer!
         engine-create-view!
         engine-create-view-from-view!
         engine-remove-view!
         engine-remove-doc!)

(define (engine-create-derived-buffer! e did name text
                                      #:owner owner
                                      #:source-doc-id [source-doc-id #f]
                                      #:edit-policy [edit-policy 'intent])
  (engine-create-buffer! e did name text
                        #:kind 'derived
                        #:owner owner
                        #:source-doc-id source-doc-id
                        #:edit-policy edit-policy))
