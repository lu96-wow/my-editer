#lang racket

;;; core/view/panel.rkt —— 面板：外框矩形 + 四条边可选边框 + 深度 + 边框 face + 内容区
;;;
;;; panel 是**值**（每帧的显示项）：view + 外框 rect + 存在的边 + deep + 边框 face。
;;;   view    : 显示槽，可替换（换 view = 造一个新 panel 值）
;;;   rect    : 外框矩形（尺寸真相在这里）
;;;   borders : 存在的边（每边可选）；不存在的那条边，内容顶到外框
;;;   deep    : 越大越在上；浮窗 = deep 高的 panel
;;;   face    : 边框 face（#f | symbol | face），宿主设；core 不解释颜色
;;;
;;; 内容区 = 外框按存在的边各内缩 1。view 的 viewport 尺寸由 editor/sync.rkt 的
;;; panels-sync! 从 panel-content 落进去 —— 渲染保持纯，绝不 resize。
;;;
;;; 身份不在这里（view 可替换，不能拿 view 当身份）：命中 / 布局树在 core 外，
;;; 宿主自己用 id / owner 记「这是哪块面板」。render-display 只吃值。

(require "base/rect.rkt")

(provide (struct-out panel)
         make-panel
         borders-all borders-none
         panel-content
         panel-at)

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

;;; ---------- 命中 ----------

;; 覆盖屏幕格 (row, col) 的 panel：deep 最大者胜；同 deep 列表靠后者胜；都无 → #f。
;; 与边框遮挡同一套规则（见 border.rkt）：渲染吃的 panels，就是这里查的 panels。
;; rect 是 (x=列, y=行)；这里按屏幕坐标收参，方便鼠标直接换算（x→col, y→row）。
(define (panel-at panels row col)
  (for/fold ([best #f]) ([p (in-list panels)])
    (if (and (rect-contains? (panel-rect p) col row)
             (or (not best) (>= (panel-deep p) (panel-deep best))))
        p
        best)))

(module+ test
  (require rackunit)
  (define (mk owner x y w h #:deep [d 0]) (make-panel owner (rect x y w h) borders-all #:deep d))
  (define lo (mk 'lo 0 0 10 10))
  (define hi (mk 'hi 2 2 4 4 #:deep 5))
  (define ps (list lo hi))

  ;; 命中 / 落空
  (check-eq? (panel-at ps 0 0) lo)
  (check-eq? (panel-at ps 3 3) hi)          ; 高 deep 浮窗盖住
  (check-eq? (panel-at ps 9 9) lo)
  (check-false (panel-at ps 10 0))          ; 右边界开
  (check-false (panel-at ps 0 10))

  ;; 同 deep：列表靠后者胜
  (define a (mk 'a 0 0 5 5))
  (define b (mk 'b 0 0 5 5))
  (check-eq? (panel-at (list a b) 1 1) b)
  (check-eq? (panel-at (list b a) 1 1) a)

  ;; 零尺寸 / 空表
  (check-false (panel-at (list (make-panel 'z (rect 0 0 0 0) borders-none)) 0 0))
  (check-false (panel-at '() 0 0))

  (displayln "panel.rkt: ok"))
