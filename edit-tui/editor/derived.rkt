#lang racket

;;; edit-tui/editor/derived.rkt —— derived view 的插件写入口
;;;
;;; derived 文档是 plugin-owned 派生文本：无 resource / 无 history。
;;; 内容投影只走 derived-write；用户编辑走普通 surface，由 owner 插件协调。

(require "engine/read.rkt"
         "engine/derived-write.rkt"
         "context.rkt")

(provide editor-derived-doc-ids
         editor-derived-view-ids
         editor-set-derived-view-content!
         editor-set-derived-view-cursor!)

(define (editor-derived-doc-ids ed)
  (engine-derived-doc-ids (editor-engine ed)))

(define (editor-derived-view-ids ed)
  (engine-derived-view-ids (editor-engine ed)))

(define (editor-set-derived-view-content! ed vid lines faces
                                          #:base-version [base-version #f])
  (engine-set-derived-content! (editor-engine ed) vid lines faces
                               #:base-version base-version))

(define (editor-set-derived-view-cursor! ed vid line #:column [column 0])
  (engine-set-derived-cursor! (editor-engine ed) vid line #:column column))
