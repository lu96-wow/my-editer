#lang racket

;;; edit/layout/demo.rkt —— 面板 + 边框最小验证（纯文本，不需要 tty）
;;;
;;; 运行：racket layout/demo.rkt
;;; 画三个面板：左边文件树（只画右边框）、两个编辑器（只画右边框），
;;; 打印整帧纯文本，确认内容落在内容区、边框落在框线上。

(require "main.rkt"                    ; 布局：rect / panel
         "../core-render/border.rkt"   ; 边框渲染：panels -> pane
         "../../core/editor.rkt")

(define W 40) (define H 12)

;;; 造视图
(define tree-b (make-buffer "src/\n  main.rkt\n  util.rkt" "*tree*"))
(define tree-v (buffer-add-view! tree-b 11 H))
(define a-b (make-buffer "(define (add1 x)\n  (+ x 1))" "a.rkt"))
(define a-v (buffer-add-view! a-b 13 H))
(define b-b (make-buffer ";; second\n(map add1 '(1 2 3))" "b.rkt"))
(define b-v (buffer-add-view! b-b 13 H))

;;; 面板：外框 + 四边可选的边框 + deep + 边框 face。y=1 留一行上边距，高度要小一行才不出屏。
(define panels
  (list (make-panel 'tree (rect 1 1 12 (- H 1)) '(right))
        (make-panel 'a    (rect 12 1 14 (- H 1)) '(right up down) #:face 'focused-border)
        (make-panel 'b    (rect 26 1 14 (- H 1)) '(right))))

;;; 内容区大小落进 viewport
(for ([p (in-list panels)] [v (in-list (list tree-v a-v b-v))])
  (define c (panel-content p))
  (view-resize! v (rect-w c) (rect-h c)))

;;; 面板 → entry + 边框 → decoration
(define id->view (hash 'tree tree-v 'a a-v 'b b-v))
(define entries (panels->entries panels (lambda (id) (hash-ref id->view id #f))))
(define decorations (panels->decorations panels))

(define frame (render-display entries a-v W H decorations))
(displayln (screen->string frame))
