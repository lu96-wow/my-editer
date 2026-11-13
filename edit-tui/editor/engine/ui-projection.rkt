#lang racket

;;; edit-tui/editor/engine/ui-projection.rkt —— UI view 写回能力
;;;
;;; 内容写只允许 'ui view；face / cursor 是通用 view 属性，
;;; 也用于 user view 的语法着色和光标设置。
;;;
;;; derived 文档的内容写入口在 derived-write.rkt。

(require "store.rkt"
         "projection-write.rkt")

(provide engine-set-view-content!
         engine-set-view-cursor!
         engine-set-view-face-track!
         engine-set-view-face-lines!
         engine-set-view-lines!)

(define (engine-set-view-content! e vid lines faces
                                  #:readonly-prefix [readonly-prefix 0]
                                  #:prefix-face [prefix-face #f])
  (and (eq? (engine-view-kind e vid) 'ui)
       (projection-set-content! e vid lines faces
                                #:readonly-prefix readonly-prefix
                                #:prefix-face prefix-face)))

;; 光标是 view 属性：user / derived / ui 都可设置。
(define (engine-set-view-cursor! e vid line #:column [column 0])
  (projection-set-cursor! e vid line #:column column))

;; face track / face lines 是 view 属性：语法着色会写 user view。
(define (engine-set-view-face-track! e vid face-track
                                     #:key [key #f]
                                     #:base-version [base-version #f])
  (projection-set-face-track! e vid face-track
                              #:key key
                              #:base-version base-version))

(define (engine-set-view-face-lines! e vid face-lines
                                     #:key [key #f]
                                     #:base-version [base-version #f])
  (projection-set-face-lines! e vid face-lines
                              #:key key
                              #:base-version base-version))

(define (engine-set-view-lines! e vid lines faces line
                                #:column [column 0]
                                #:readonly-prefix [readonly-prefix 0]
                                #:prefix-face [prefix-face #f])
  (when (eq? (engine-view-kind e vid) 'ui)
    (projection-set-content! e vid lines faces
                             #:readonly-prefix readonly-prefix
                             #:prefix-face prefix-face)
    (engine-set-view-cursor! e vid line #:column column))
  (void))
