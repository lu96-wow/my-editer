#lang racket

;;; 80x24 的三块 panel：
;;;   左侧 filetree | 右侧上 editor（空 panel）
;;;                 | 右侧下 state
;;;
;;; 布局只是一份 (listof core panel)。panel 资源单独保留；
;;; 隐藏 = 从渲染列表里拿掉，不删除 panel 本身。

(require "../../core/editor.rkt")

(define W 80)
(define H 24)
(define sidebar-w 30)

;;; ---------- 两块有内容的 view ----------
(define ft-buffer (make-buffer "workspace\n  src\n  main.rkt"))
(define ft-view (buffer-add-view! ft-buffer 29 H))

(define state-buffer (make-buffer "state focus=editor docs=1 pending=- msg=ready"))
(define state-view (buffer-add-view! state-buffer (- W sidebar-w) 1))

;;; ---------- 三块 panel ----------
(define filetree-panel
  (make-panel ft-view
              (rect 0 0 sidebar-w H)
              '(right)                       ; 只留右侧分隔线
              #:deep 0
              #:face 'window-border))

(define editor-panel
  (empty-panel (rect sidebar-w 0 (- W sidebar-w) (sub1 H))
               '()                           ; 空 panel：view = #f
               #:deep 0
               #:face 'window-border))

(define state-panel
  (make-panel state-view
              (rect sidebar-w (sub1 H) (- W sidebar-w) 1)
              '()
              #:deep 0
              #:face 'status-face))

;;; ---------- panel 资源 vs 渲染列表 ----------
(define panel-resources
  (hash 'filetree filetree-panel
        'editor   editor-panel
        'state    state-panel))

(define render-panels
  (list filetree-panel editor-panel state-panel))

;;; 把 view 的 viewport 落到 panel 内容区尺寸（唯一尺寸写入口）
(panels-sync! render-panels)

(define screen (render-display render-panels #f W H))

(displayln (screen->string screen))
