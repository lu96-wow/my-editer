#lang racket

;;; edit-tui/layout-base/panel.rkt —— 面板：外框矩形 + 四条边可选边框 + 深度 + 边框 face
;;;
;;; 布局就是一堆面板，不必布满屏幕。owner 是**宿主的不透明引用**（如布局树的叶节点），
;;; 只回答「这块几何属于谁」，不携带内容；身份用 eq? 比较，宿主再用自己的访问器
;;; （owner → view）把它解出来。
;;; 边框是**每边可选**的：靠屏幕边缘的那条可以不画（如左侧文件树只画右边）。
;;; 方向名用 up / down / left / right。
;;; 内容区 = 外框按「存在的边」各内缩 1 格 —— 取内容区用 panel-content。
;;;
;;; face 只是一个**符号标签**（如 'window-border / 'float-border / 'focused-border），
;;; 具体颜色由后端主题决定 —— 布局不认识颜色。

(require "rect.rkt"
         "../../core/editor.rkt")

(provide (struct-out panel)
         make-panel
         borders-all borders-none
         panel-content
         panel-at
         panels->entries)

;; owner   : 不透明引用（布局树的叶节点等）。身份用 eq?，不要用 equal? ——
;;           可变的 owner 不能按内容比。panel 本身是每帧几何快照，值语义。
;; borders : (listof (or 'up 'down 'left 'right))，顺序无关，可空。
;; deep    : 越大越在上；浮窗 / 弹窗 = deep 高的 panel，没有单独机制。
;; face    : 边框 face 标签（符号），后端主题解析成颜色 / 属性。
(struct panel (owner rect borders deep face) #:transparent)

;; 便捷构造（关键字）。face 缺省 'window-border。
(define (make-panel owner rect borders #:deep [deep 0] #:face [face 'window-border])
  (panel owner rect borders deep face))

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

;; 面板 → display-entry（用内容区当 view 位置；view 尺寸由宿主 view-resize! 落进 viewport）。
;; node->view : owner → view | #f（宿主提供：从叶节点取当前 view）。
(define (panels->entries ps node->view)
  (for/list ([p (in-list ps)]
             #:when (node->view (panel-owner p)))
    (define c (panel-content p))
    (display-entry (node->view (panel-owner p))
                   (rect-x c) (rect-y c) (panel-deep p))))
