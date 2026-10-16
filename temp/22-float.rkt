#lang racket
;;; 22 —— 浮窗：不参与布局，叠在平铺上面，用完即毁
;;;
;;; 运行：racket temp/22-float.rkt
;;;
;;; 一个编辑区 + 底部状态栏；在编辑区光标附近弹一个“补全”浮窗，打印三帧
;;; （无浮窗 / 有浮窗 / 关闭后）。浮窗只是 panel（deep 高），宿主把
;;; (tree->panels) 和 (floats->panels) 拼起来，其余照旧。

(require "../core/editor.rkt"
         "../edit-tui/layout/main.rkt")

(define W 50)
(define H 10)

(define eb (make-buffer "(define (f x)\n  (+ x 1))\n\n(f 41)\n" "main.rkt"))
(define ev (buffer-add-view! eb))

(define tree
  (lay 'tb
       (pane 'editor #:view ev #:size 8 #:dock 'up)
       (pane 'status #:view #f #:size 1 #:dock 'down)))
(define (area) (rect 0 0 W H))

(define cb (make-buffer "add\napply\nappend\narity" "*completion*"))
(define cv (buffer-add-view! cb 10 5 #:line-numbers? #f))

(define floats '())

(define (draw label)
  (define ps (append (tree->panels tree (area)) (floats->panels floats)))
  (panels-sync! ps)
  (printf "── ~a（panels=~a）──\n~a\n\n"
          label (length ps)
          (screen->string (render-display ps ev W H))))

(draw "无浮窗")

;; 在编辑区第 1 行附近弹补全浮窗（deep 自动 > 平铺）
(set! floats (floats-add floats (make-float 'completion cv (float-rect-at 1 2 10 5 (area)))))
(draw "补全浮窗")

;; 用完即毁
(set! floats (floats-remove floats 'completion))
(draw "关闭后")

(displayln "float demo: OK")
