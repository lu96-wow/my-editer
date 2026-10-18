#lang racket

;;; layer  : theme
;;; effect : 无（纯主题数据）

;;; edit-tui/theme/frame.rkt —— 框架主题
;;;
;;; 颜色与 history/edit4/config/palette.rkt 同步（树 / 资源 / 边框 / chrome）。

(require "theme.rkt")

(provide frame-theme)

(define frame-theme
  (list
   ;; 边框：edit4 只有 window-border；focused/float 是宿主追加的强调色。
   (list 'window-border  (style (rgb 105 112 128) #f '()))
   (list 'focused-border (style (rgb 120 180 240) #f '()))
   (list 'float-border   (style (rgb 190 150 240) #f '()))

   ;; 资源列表面板（对应 edit4 的 buf-*）
   (list 'resource-document (style (rgb 200 200 200) #f '()))   ; buf-file
   (list 'resource-untitled (style (rgb 170 170 170) #f '()))
   (list 'resource-view     (style (rgb 140 160 190) #f '()))   ; buf-view
   (list 'resource-focus    (style (rgb 120 210 130) #f '(bold))) ; buf-current
   (list 'resource-pending  (style (rgb 230 160 90) #f '(bold)))  ; buf-dirty

   ;; 文件树（对应 edit4 的 tree-*）
   (list 'filetree-root (style (rgb 120 180 240) #f '(bold)))
   (list 'filetree-dir  (style (rgb 120 180 240) #f '()))
   (list 'filetree-file (style (rgb 200 200 200) #f '()))
   (list 'filetree-hidden (style (rgb 120 120 130) #f '()))
   (list 'filetree-open (style (rgb 120 210 130) #f '(bold)))))
