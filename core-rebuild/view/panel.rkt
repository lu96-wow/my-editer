#lang racket

;;; core-rebuild/view/panel.rkt —— 面板：外框矩形 + 四条边可选边框 + 深度 + 边框 face + 内容区
;;;
;;; panel 是**值**（每帧的显示项）：view + 外框 rect + 存在的边 + deep + 边框 face。
;;;   view    : 显示槽，可替换（换 view = 造一个新 panel 值）
;;;   rect    : 外框矩形（尺寸真相在这里）
;;;   borders : 存在的边（每边可选）；不存在的那条边，内容顶到外框
;;;   deep    : 越大越在上；浮窗 = deep 高的 panel
;;;   face    : 边框 face（#f | symbol | face），宿主设；core 不解释颜色
;;;
;;; 内容区 = 外框按存在的边各内缩 1。view 的 viewport 尺寸由 editor/layout.rkt 的
;;; panels-sync! 从 panel-content 落进去 —— 渲染保持纯，绝不 resize。
;;;
;;; 身份不在这里（view 可替换，不能拿 view 当身份）：命中 / 布局树在 core 外，
;;; 宿主自己用 id / owner 记「这是哪块面板」。render-display 只吃值。

(require "base/rect.rkt")

(provide (struct-out panel)
         make-panel
         borders-all borders-none
         panel-content)

(struct panel (view rect borders deep face) #:transparent)

;; 便捷构造（关键字）。face 缺省 'window-border。
(define (make-panel view rect borders #:deep [deep 0] #:face [face 'window-border])
  (panel view rect borders deep face))

(define borders-all  '(up down left right))
(define borders-none '())

;; 内容区：外框按存在的边内缩 1。
(define (panel-content p)
  (define b (panel-borders p))
  (rect-inset-sides (panel-rect p)
                    (if (memq 'up b)    1 0)
                    (if (memq 'right b) 1 0)
                    (if (memq 'down b)  1 0)
                    (if (memq 'left b)  1 0)))
