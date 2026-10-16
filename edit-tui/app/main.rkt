#lang racket

;;; app/main.rkt —— app 骨架入口
;;;
;;; 事件循环 + 世界状态 + 纯转移 + 渲染投影，一次全部拿到：
;;;
;;;   (require "../edit-tui/app/main.rkt")
;;;
;;;   (define w (make-world #:area (rect 0 0 80 24)
;;;                         #:layout my-layout
;;;                         #:focus my-view
;;;                         #:keytable (make-keytable my-keys)))
;;;   (run-app w)
;;;
;;; 命令约定：(λ (ctx) (listof intent))。intent 见 intent.rkt。
;;; 分层说明与扩展点见 app/README.md。

(require "world.rkt"
         "intent.rkt"
         "panel-ref.rkt"
         "doc-kind.rkt"
         "base-keys.rkt"
         "ops.rkt"
         "resource.rkt"
         "step.rkt"
         "render.rkt"
         "loop.rkt")

(provide (all-from-out "world.rkt"
                       "intent.rkt"
                       "panel-ref.rkt"
                       "doc-kind.rkt"
                       "base-keys.rkt"
                       "ops.rkt"
                       "resource.rkt"
                       "step.rkt"
                       "render.rkt"
                       "loop.rkt"))
