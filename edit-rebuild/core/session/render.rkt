#lang racket

;;; edit-rebuild/core/session/render.rkt —— 统一渲染入口
;;;
;;; 局部问题：渲染前准备 + 取帧。准备步骤各自归各自模块，这里只按序组合：
;;;   session-refresh   刷新面内容（session/refresh.rkt）
;;;   （插件写回待插件层接入后插在这里）
;;;
;;; 后端用 session-render 取帧（它保证先跑准备步骤并把准备好的会话带回来）。

(require "session.rkt"
         "adapter.rkt"
         "refresh.rkt"
         "hook.rkt"
         "plugin.rkt")

(provide session-prepare-render session-render)

;; 渲染前准备：刷面 → 生命周期通知（before-render）→ 应用 document 插件。
(define (session-prepare-render s)
  (session-doc-plugins-apply (session-run-hooks (session-refresh s) 'before-render '())))

;; → (values 准备好的会话 新帧 render selection)
(define (session-render s old)
  (define s1 (session-prepare-render s))
  (define-values (new rends sels) (session-patch s1 old))
  (values s1 new rends sels))
