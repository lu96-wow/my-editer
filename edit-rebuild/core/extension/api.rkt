#lang racket

;;; edit-rebuild/core/extension/api.rkt —— 特性门面（白名单）
;;;
;;; 特性（feature）只 require 这一个模块。这里显式列出特性可用的原语，而不是把整个
;;; 会话全盘透出——内核适配（session-ed-*）、渲染（session-patch）、几何手术不进特性层。
;;;
;;; 特性被期望的运行方式：
;;;   · 自带 cmd-* + handler，挂到 handler 链（session-add-handler）
;;;   · 对会话的改动走这里白名单里的原语
;;;   · 需要别的功能时发命令（step 派发）
;;;   · 需要浮窗时造 surface，用 session-add-surface 注册

(require "../session/session.rkt"
         "../session/adapter.rkt"
         "../session/panel.rkt"
         "../session/structure.rkt"
         "../session/focus.rkt"
         "../session/prompt.rkt"
         "../session/bottom.rkt"
         "../session/hook.rkt"
         "../session/refresh.rkt"
         "../session/render.rkt"
         "../session/async.rkt"
         "../surface/surface.rkt"
         "../geometry/layout.rkt"
         "../command/command.rkt"
         "../command/key.rkt"
         "../keymap.rkt"
         "../ids.rkt")

(provide
 ;; 面板 / 面构造 + 注册
 dock-surface float-surface surface? surface-dock? surface-float?
 surface-id surface-vid surface-content surface-placement surface-keys
 dock dock-region dock-axis dock-size float float-pos float-deep
 session-add-surface session-remove-surface
 session-surfaces session-surface-ref session-surface-for-vid
 session-overlays
 session-panel-vid session-panel-dids session-panel-swap
 placed placed? placed-vid placed-x placed-y placed-w placed-h placed-deep

 ;; 文档 / 视图
 session-add-document session-add-view
 session-document-ids session-document-name session-document-string session-document-handle
 session-document-track
 session-view-id-list session-view-ids-of session-view-did
 session-view-point-line session-view-point-column session-view-string
 session-view-width session-view-height session-view-line-numbers?
 session-edit-vid session-focus session-focus-vid session-prefix session-width session-height
 session-visible? session-set-visible session-set-focus session-dock-vid?
 session-show-view session-split-view session-close-document
 session-view-cursor-screen session-view-point->screen session-overlay-dids

 ;; 内容写回 / 局部刷新
 panel-doc input-document session-ed-assign! session-ed-set-point! session-ed-replace!
 session-ed-scroll! session-ed-hscroll!
 session-refresh session-prepare-render session-render
 session-log session-log-add

 ;; 输入行 / 日志 / 状态
 session-prompt session-prompt-open session-prompt-submit session-prompt-cancel
 session-log! session-log
 session-region-select session-fit-panel! session-bottom-pop
 session-add-key

 ;; 事件 / 服务 / 异步
 hook hook? hook-point hook-proc session-add-hook session-add-handler session-run-hooks
 session-service-ref session-service-put
 session-await session-deliver session-awaiting? async-wake

 ;; 文档域查询
 session-file-path session-file-did session-file-dids session-set-file
 session-dirty? session-mark-saved

 ;; 命令数据 / 键 / 键表 / id（整包）
 (all-from-out "../command/command.rkt"
               "../command/key.rkt"
               "../keymap.rkt"
               "../ids.rkt"))
