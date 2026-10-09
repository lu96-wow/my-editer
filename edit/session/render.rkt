#lang racket

;;; edit/session/render.rkt —— 统一渲染入口
;;;
;;; 渲染前准备拆成两步（各自归各自模块），这里只按序组合：
;;;   session-refresh            刷新状态窗口（session/panel.rkt）
;;;   session-doc-plugins-apply  应用 document 插件（session/plugin.rkt）
;;;
;;; 后端用 session-render 取帧（它保证先跑准备步骤，并把准备好的会话带回来，
;;; 于是写回缓存跨帧生效）；session-patch 是低层的「只算补丁」。

(require "value.rkt"
         "core.rkt"
         "panel.rkt"
         "plugin.rkt")

(provide session-prepare-render session-render)

;; 渲染前准备：刷面板 + 应用插件。返回准备好的会话（带回写缓存）。
(define (session-prepare-render s)
  (session-doc-plugins-apply (session-refresh s)))

;; 统一渲染入口：准备 → 增量补丁。
;; → (values 准备好的会话 新帧 render pieces selection pieces)
(define (session-render s old)
  (define s1 (session-prepare-render s))
  (define-values (new rends sels) (session-patch s1 old))
  (values s1 new rends sels))
