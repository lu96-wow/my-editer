#lang racket
;;; 13 —— core：panel 进 core（rect 驱动 view + 内置边框 + 一次 diff）
;;;
;;; 运行：racket temp/13-panel-core.rkt
;;;
;;; 对照旧的「两半」：这里只有一个 display list（panels），一次合成、一次 diff。
;;;   panel = (view rect borders deep face)；panels-sync! 把 panel.content 尺寸落进 view
;;;   render-display / render-display-patch 形状不变，只是 entries → panels，边框内置

(require "../core/editor.rkt")

;;; ---------- 内容 ----------

(define tree-b (make-buffer "src/\n  main.rkt\n  util.rkt\n  panel.rkt\nREADME.md" "*tree*"))
(define doc-b  (make-buffer "(define (f x)\n  (+ x 1))\n\n(f 41)\n" "main.rkt"))
(define pop-b  (make-buffer "popup\non top\n(deep 10)\n" "*popup*"))

;;; ---------- 布局：一步 buffer → panel（含 view，自动 sync）----------

(define tree-p (buffer-add-panel! tree-b (rect 0 0 20 12) '(up down left right)
                                  #:line-numbers? #t))
(define doc-p  (buffer-add-panel! doc-b  (rect 20 0 52 12) '(up down right)
                                  #:line-numbers? #t))
(define pop-p  (buffer-add-panel! pop-b  (rect 30 2 22 6)  borders-all
                                  #:deep 10 #:face 'float-border))

(define panels (list tree-p doc-p pop-p))
(define tree-v (panel-view tree-p))
(define doc-v  (panel-view doc-p))
(define pop-v  (panel-view pop-p))

;; buffer-add-panel! 已经 sync 过；这里只是展示再 sync 一次是幂等的
(panels-sync! panels)
(printf "sync 后 view 尺寸：tree=~ax~a doc=~ax~a pop=~ax~a\n\n"
        (view-width tree-v) (view-height tree-v)
        (view-width doc-v) (view-height doc-v)
        (view-width pop-v) (view-height pop-v))

(define W 72) (define H 12)

(displayln "======== 全量一帧（内容 + 边框，按 deep 合成）========")
(define-values (cache0 r0 s0) (render-display-patch panels doc-v W H #f))
(displayln (screen->string (render-cache-screen cache0)))

;;; ---------- 增量：编辑 doc ----------

(void (buffer-edit! doc-b doc-v (op-type ";; hi\n")))
(define-values (cache1 rends sels)
  (render-display-patch panels doc-v W H cache0))
(displayln "======== 编辑后（一次 diff，内容+边框一起）========")
(displayln (screen->string (render-cache-screen cache1)))
(printf "增量片：render=~a / selection=~a\n\n" (length rends) (length sels))

;;; ---------- 浮窗移动（换 rect）+ 遮挡 ----------

(define pop-p2 (make-panel pop-v (rect 40 3 22 6) borders-all
                           #:deep 10 #:face 'float-border))
(define panels2 (list tree-p doc-p pop-p2))
(panels-sync! panels2)
(define-values (cache2 rends3 sels3)
  (render-display-patch panels2 doc-v W H cache1))
(displayln "======== 浮窗右移（一次 diff）========")
(displayln (screen->string (render-cache-screen cache2)))
(printf "增量片：render=~a / selection=~a\n\n" (length rends3) (length sels3))

;;; ---------- 换 view（view 可替换）----------

(define doc2-b (make-buffer "second buffer\nsame slot\n" "other.rkt"))
(define doc2-v (buffer-add-view! doc2-b #:line-numbers? #t))
(define doc-p2 (make-panel doc2-v (rect 20 0 52 12) '(up down right)))
(define panels3 (list tree-p doc-p2 pop-p2))
(panels-sync! panels3)                     ; 新 view 落到内容尺寸
(define-values (cache3 r4 s4) (render-display-patch panels3 doc2-v W H cache2))
(displayln "======== 换 view（同一 slot）========")
(displayln (screen->string (render-cache-screen cache3)))
(printf "换 view 后增量：render=~a\n" (length r4))

;;; ---------- 光标绝对位置（弹窗定位用）----------

(printf "focus(doc) 光标绝对位置：~a\n"
        (call-with-values (lambda () (panel-cursor-position doc-p2)) list))
