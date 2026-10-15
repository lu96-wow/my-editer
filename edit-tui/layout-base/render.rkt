#lang racket

;;; edit-tui/layout-base/render.rkt —— 布局 → tui 序列（可直接 put-bytes）
;;;
;;; 与 core-render/render.rkt 对称：
;;;   core-render/render.rkt   把 core 渲染值（piece）画成 tui 序列
;;;   layout-base/render.rkt   把布局边框（panel → border-run）画成 tui 序列
;;;
;;; 谁占哪些格、画什么字形、face / deep 都在 border.rkt；这里只做**序列化**：
;;; 每段 run → 光标定位 + face 转义 + 文本 + reset。不输出、不 flush。
;;;
;;; face 的解释在这里：border-run 的 face 是符号（如 'window-border），
;;; 用 style->bytes 取转义序列（主题在 edit-tui/theme 装）。

(require tui
         "border.rkt")

(provide render-border-run      ; (row col text face deep) -> tui 序列
         render-border-runs     ; (listof run) -> tui 序列
         render-panels)         ; (listof panel) -> tui 序列（边框）

;; 序列拼接（滤掉 #f；tui 拼 bytes）。内部工具，不外露。
(define (fragment . parts) (apply bytes-append (filter values parts)))

;; 一段 border-run -> 序列。
(define (render-border-run b)
  (match-define (list row col text face _deep) b)
  (fragment
   (format-cursor-move (add1 row) (add1 col))    ; 1-based
   (and face (style->bytes face))
   (format-content text)
   format-reset))

(define (render-border-runs bs)
  (apply fragment (map render-border-run bs)))

;; 面板布局 -> 边框序列。每格在 border.rkt 里已按 deep 定过归属，run 互不重叠，
;; 直接顺序输出即可（deep 只在跟内容 pane 一起合成时才需要）。
(define (render-panels ps)
  (render-border-runs (panels->border-runs ps)))

(module+ test
  (require rackunit "rect.rkt" "panel.rkt")
  (define bs (render-panels (list (make-panel 'a (rect 0 0 4 3) borders-all))))
  (check-true (bytes? bs))
  (check-true (> (bytes-length bs) 0))
  (check-true (regexp-match? #rx"┌" (bytes->string/utf-8 bs)))
  (displayln "layout-base/render.rkt: ok"))
