#lang racket
;;; 08 —— 渲染：display list -> screen（全量 + 增量 + 装饰）
;;;
;;; 运行：racket temp/08-render.rkt
;;;
;;;   display-entry = (view x y deep)   宿主布局：哪个 view、贴在哪、多深
;;;   尺寸不进 entry：布局变化由 view-resize! 落进 view.viewport
;;;   focus          = 谁画 cursor/选区 overlay（宿主状态，渲染时传入）
;;;   decorations    = 额外叠加的一批 pane（弹窗等）

(require "../core/editor.rkt"
         "../core/view/render.rkt"          ; render
         "../core/view/base/viewport.rkt"   ; viewport-open
         (only-in "../core/editor/state.rkt" buffer-document))  ; 高级：decorations 需要 document

(define tree-b (make-buffer "src/\n  main.rkt\n  util.rkt\nREADME.md" "*tree*"))
(define tree-v (buffer-add-view! tree-b 24 10))
(define doc-b (make-buffer "hello\nworld" "main.rkt"))
(define doc-v (buffer-add-view! doc-b 56 10 #:line-numbers? #t))

;; 布局：尺寸落进 view
(view-resize! tree-v 24 10)
(view-resize! doc-v 56 10)

;; 可见集：display-entry
(define (entries)
  (list (display-entry tree-v 0 0 0)
        (display-entry doc-v 24 0 0)))

(displayln "======== 第一帧（全量） ========")
(define frame (render-display (entries) doc-v 80 10))
(displayln (screen->string frame))

;; 编辑后增量
(displayln "======== 第二帧（增量） ========")
(view-set-selections! doc-v (selections-one (caret (point 1 0))))
(void (buffer-edit! doc-b doc-v (op-type ">> ")))
(define-values (frame2 rends sels)
  (render-display-patch (entries) doc-v 80 10 frame))
(displayln (screen->string frame2))
(printf "render 差分片 ~a 个 / selection 差分片 ~a 个\n" (length rends) (length sels))

;; 光标绝对屏幕位置（弹窗定位用）
(define e-doc (display-entry doc-v 24 0 0))
(printf "光标绝对屏幕位置: ~a\n"
        (call-with-values (lambda () (display-entry-cursor-position e-doc)) list))

;; decorations：额外叠一个 pane（弹窗）
(define popup (pane 3 30 (render (buffer-document doc-b) (viewport-open 20 3) #f) 10))
(displayln "======== 带 decoration 的帧 ========")
(displayln (screen->string (render-display (entries) doc-v 80 10 (list popup))))
