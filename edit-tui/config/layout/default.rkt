#lang racket

;;; edit-tui/config/layout/default.rkt —— 默认各 kind 的布局规则
;;;
;;; 这是 configuration，不是 editor 骨架。宿主选择它，并把值放进
;;; editor-state.layout-config；editor 的布局操作只读 state 里的 config。

(require "../../core/layout/config.rkt")

(provide default-layout-config)

(define default-layout-config
  (make-layout-config
   #:rules
   (hash
    'editor
    (make-panel-rule #:splittable? #t
                     #:hideable? #f
                     #:deletable? #t
                     #:focusable? #t
                     #:min-w 1 #:max-w #f
                     #:min-h 1 #:max-h #f)
    'status
    (make-panel-rule #:splittable? #f
                     #:hideable? #f
                     #:deletable? #f
                     #:focusable? #f
                     #:min-w 1 #:max-w #f
                     #:min-h 1 #:max-h #f)
    'sidebar
    (make-panel-rule #:splittable? #f
                     #:hideable? #t
                     #:deletable? #f
                     #:focusable? #t
                     #:min-w 8 #:max-w #f
                     #:min-h 1 #:max-h #f)
    'docs
    (make-panel-rule #:splittable? #f
                     #:hideable? #t
                     #:deletable? #f
                     #:focusable? #t
                     #:min-w 1 #:max-w #f
                     #:min-h 3 #:max-h #f))))
