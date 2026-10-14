#lang racket

;;; edit/layout/demo-float.rkt —— 浮窗最小演示（纯文本）
;;;
;;; 运行：racket layout/demo-float.rkt
;;; 底层一块编辑器（无边框，铺满），上面叠一只浮窗（全框，deep 高）。
;;; 浮窗就是 deep 高的 panel：内容盖住底下的内容，边框独立成框。

(require "main.rkt"                    ; 布局：rect / panel
         "../core-render/border.rkt"   ; 边框渲染：panels -> pane
         "../../core/editor.rkt")

(define W 60) (define H 16)

;;; 底层编辑器：无边框，铺满
(define editor-b
  (make-buffer
   (string-join
    (list "(define (fib n)"
          "  (if (< n 2)"
          "      n"
          "      (+ (fib (- n 1))"
          "         (fib (- n 2)))))"
          ""
          "(fib 10)   ; => 55")
    "\n")
   "fib.rkt"))
(define editor-v (buffer-add-view! editor-b W H))

;;; 浮窗：完成列表 / 弹窗
(define popup-b
  (make-buffer
   (string-join
    (list "  fib        proc?"
          "  fibonacci  proc?"
          "  fib-iter   proc?")
    "\n")
   "*completion*"))
(define float-rect (rect 14 4 32 8))
(define popup-panel (make-panel 'popup float-rect borders-all #:deep 10 #:face 'float-border))
(define popup-v (buffer-add-view! popup-b
                                  (rect-w (panel-content popup-panel))
                                  (rect-h (panel-content popup-panel))))

;;; 面板列表：平铺层 deep 0；浮窗 deep 10
(define editor-panel (make-panel 'editor (rect 0 0 W H) '()))
(define panels (list editor-panel popup-panel))

;;; 面板 → entry + 边框 → decoration
(define id->view (hash 'editor editor-v 'popup popup-v))
(define entries (panels->entries panels (lambda (id) (hash-ref id->view id #f))))
(define decorations (panels->decorations panels))

(displayln (screen->string (render-display entries editor-v W H decorations)))
