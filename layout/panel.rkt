#lang racket

;;; edit/layout/panel.rkt —— 面板：外框矩形 + 四条边可选边框 + 深度 + 边框 face
;;;
;;; 布局就是一堆面板，不必布满屏幕。id 不透明（宿主自己映射到 view 等）。
;;; 边框是**每边可选**的：靠屏幕边缘的那条可以不画（如左侧文件树只画右边）。
;;; 方向名用 up / down / left / right。
;;; 内容区 = 外框按「存在的边」各内缩 1 格 —— 取内容区用 panel-content。
;;;
;;; face 只是一个**符号标签**（如 'window-border / 'float-border / 'focused-border），
;;; 具体颜色由后端主题决定 —— 布局不认识颜色。

(require "rect.rkt"
         "../core/editor.rkt")

(provide (struct-out panel)
         make-panel
         borders-all borders-none
         panel-content
         panel-at panel-find
         panels->entries)

;; borders : (listof (or 'up 'down 'left 'right))，顺序无关，可空。
;; deep    : 越大越在上；浮窗 / 弹窗 = deep 高的 panel，没有单独机制。
;; face    : 边框 face 标签（符号），后端主题解析成颜色 / 属性。
(struct panel (id rect borders deep face) #:transparent)

;; 便捷构造（关键字）。face 缺省 'window-border。
(define (make-panel id rect borders #:deep [deep 0] #:face [face 'window-border])
  (panel id rect borders deep face))

(define borders-all  '(up down left right))
(define borders-none '())

;; 内容区：外框按存在的边内缩 1。
(define (panel-content p)
  (define b (panel-borders p))
  (rect-inset-sides (panel-rect p)
                    (if (memq 'up b) 1 0)
                    (if (memq 'right b) 1 0)
                    (if (memq 'down b) 1 0)
                    (if (memq 'left b) 1 0)))

;; 命中：包含 (x,y) 的面板里 deep 最大的。
(define (panel-at ps x y)
  (for/fold ([best #f]) ([p (in-list ps)]
                         #:when (rect-contains? (panel-rect p) x y))
    (if (and best (>= (panel-deep best) (panel-deep p))) best p)))

(define (panel-find ps id)
  (for/first ([p (in-list ps)] #:when (equal? id (panel-id p))) p))

;; 面板 → display-entry（用内容区当 view 位置；view 尺寸由宿主 view-resize! 落进 viewport）。
(define (panels->entries ps id->view)
  (for/list ([p (in-list ps)]
             #:when (id->view (panel-id p)))
    (define c (panel-content p))
    (display-entry (id->view (panel-id p))
                   (rect-x c) (rect-y c) (panel-deep p))))
