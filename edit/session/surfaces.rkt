#lang racket

;;; edit/session/surfaces.rkt —— 把「面」注册进会话
;;;
;;; 局部问题：surface 是统一的「一块可显示 / 可接键的东西」。会话里现在把它
;;; 当一等值存下来（session-surfaces），其余各处按需要读它：
;;;
;;;   · 几何   session/core.rkt 的 session-panes 读浮动面的 pos 产 placed
;;;   · 键     session/context.rkt 把面的 keys 放进输入上下文栈
;;;   · dock   session/value.rkt 的 session-dock-vid? / session-vid-keys 认面
;;;   · 缓冲区 session/core.rkt 的 session-overlay-dids 排除浮动面
;;;
;;; 于是补全 / 文档这些上层只写一个 surface，不再各手搓
;;; deco（几何）+ overlay（标记）+ layer（键表）三套机制。
;;;
;;; dock 面仍额外登记成 panel：面板的区域互斥 / 尺寸适配 / Tab 互换由面板机制
;;; 复用（后续可把 panel 也收进 surface，见重构步骤）。

(require "value.rkt"
         "../surface/surface.rkt")

(provide session-add-surface session-remove-surface)

;; 注册一个面。
;;   dock  → panel（所在区域 / 尺寸 / 内容刷新由面板机制复用）+ 登记面
;;   float → 登记面 + 登记 overlay vid（dock 语义 / 不入缓冲区）；
;;           几何由 session-panes 按面的 pos 算，键由输入上下文按面的 keys 取
(define (session-add-surface s sf)
  (define s1 (session-surface-add s sf))
  (define pl (surface-placement sf))
  (case (surface-kind sf)
    [(dock)
     (session-add-panel s1
       (panel (surface-id sf) (surface-vid sf) (surface-content sf) (surface-keys sf)
              (dock-region pl) (dock-axis pl) (dock-size pl)))]
    [(float)
     (session-overlay-add s1 (surface-vid sf))]
    [else s1]))

;; 注销一个面（按 id）。
(define (session-remove-surface s id)
  (define sf (session-surface-ref s id))
  (cond
    [(not sf) s]
    [else
     (define s1 (session-surface-remove s id))
     (if (surface-float? sf)
         (session-overlay-remove s1 (surface-vid sf))
         s1)]))
