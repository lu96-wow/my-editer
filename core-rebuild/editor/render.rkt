#lang racket

;;; editor/render.rkt —— 渲染：display list → screen
;;;
;;;   entry = (view x y deep)        宿主直接给 view 对象与位置
;;;   逐 entry：view → buffer → document，按 view 自己的 viewport 渲染 → pane
;;;   overlay：focus（焦点 view）命中的才传 selections，其余传 #f
;;;   panes->composition 合成（z 序 / 遮挡）；compose 不认识任何 id
;;;
;;; 尺寸属于 view：布局变化由宿主 view-resize!（见 ops.rkt）落进 viewport；
;;; 渲染保持纯，不写回任何状态。

(require "state.rkt" "query.rkt"
         "../view/render.rkt" "../view/patch.rkt" "../view/compose.rkt")

(provide
 (struct-out display-entry)       ; view + x/y/deep
 display-entry-cursor-position    ; display-entry → 主光标绝对屏幕位置 (values row col) | (values #f #f)
 render-display                   ; entries focus w h [decorations] → screen
 render-display-patch)            ; entries focus w h old [decorations] → (values screen render selection)

;; 一条显示项：某个窗口显示哪个 view、贴在哪、多深。
;; 尺寸不在这里——它属于 view 自己（view ≡ 显示槽，至多属于一个窗口），
;; 宿主在布局变化时用 view-resize! 落进 viewport，渲染直接读。
(struct display-entry (view x y deep) #:transparent)

;; 该 entry 的 view 的主光标在合成屏上的**绝对位置**（= view 内坐标 + entry 原点）。
;; 弹窗定位用：宿主拿焦点窗的 display-entry 即可算光标在终端上的位置；
;; 光标不在可见区（坐标 #f）→ 返回 (values #f #f)。
(define (display-entry-cursor-position e)
  (define v (display-entry-view e))
  (define-values (r c) (view-cursor-screen-position v))
  (if r (values (+ (display-entry-y e) r) (+ (display-entry-x e) c))
        (values #f #f)))

;; focus：#f | view | (listof view)。命中的 view 才画 overlay（光标/选区）。
(define (focus-views focus)
  (cond [(not focus) '()]
        [(list? focus) focus]
        [else (list focus)]))

;; display list → screen。纯。
(define (render-display entries focus total-w total-h [decorations '()])
  (define focs (focus-views focus))
  (composition-screen
   (panes->composition total-w total-h
     (append
      (for/list ([e (in-list entries)])
        (define v (display-entry-view e))
        (define sels (and (memq v focs) (view-selections v)))
        (pane (display-entry-y e) (display-entry-x e)
              (render (view-document v) (view-viewport v) sels)
              (display-entry-deep e)))
      decorations))))

;; 增量：旧帧 + 新帧 → (新帧, render pieces, selection pieces)。
(define (render-display-patch entries focus total-w total-h old [decorations '()])
  (define new (render-display entries focus total-w total-h decorations))
  (define-values (render selection) (screen-patch old new))
  (values new render selection))
