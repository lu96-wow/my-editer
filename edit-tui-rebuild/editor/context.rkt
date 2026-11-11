#lang racket

;;; edit-tui-rebuild/editor/context.rkt —— editor 实例
;;;
;;; editor = 可变 engine + 不可变 hook registry + 插件列表。
;;; State 不放在这里：State 是纯值，由 host 在每帧传入操作面。

(provide (struct-out editor)
         make-editor
         editor-engine
         editor-registry
         editor-plugins)

(struct editor
  (engine
   registry
   plugins)
  #:transparent)

(define (make-editor #:engine engine
                     #:registry registry
                     #:plugins [plugins '()])
  (editor engine registry plugins))
