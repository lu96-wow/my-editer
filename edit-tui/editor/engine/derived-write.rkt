#lang racket

;;; edit-tui/editor/engine/derived-write.rkt —— derived view 内容写能力
;;;
;;; 只允许 'derived view。内容写不产生 changes / history；
;;; 用户编辑 derived 走 user-write，产生 changes，由 owner 插件负责协调。
;;;
;;; #:base-version 是 CAS：异步投影结果不能覆盖已经变化的文本。

(require "store.rkt"
         "projection-write.rkt")

(provide engine-set-derived-content!
         engine-set-derived-cursor!)

(define (engine-set-derived-content! e vid lines faces
                                     #:base-version [base-version #f])
  (and (eq? (engine-view-kind e vid) 'derived)
       (begin
         ;; derived 是整篇投影；强制 full write 避免大 face track 的增量 rebase。
         (projection-forget-content! e vid)
         (projection-set-content! e vid lines faces
                                  #:base-version base-version))))

(define (engine-set-derived-cursor! e vid line #:column [column 0])
  (and (eq? (engine-view-kind e vid) 'derived)
       (begin
         (projection-set-cursor! e vid line #:column column)
         #t)))
