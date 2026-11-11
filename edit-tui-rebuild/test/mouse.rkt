#lang racket

;;; 鼠标：seam 拖拽 + release 清理。

(require rackunit
         "../editor/host-api.rkt"
         "../core/layout/api.rkt"
         "../host/final.rkt")

(define-values (ed state) (make-demo-editor))
(define s (struct-copy editor-state state [area (rect 0 0 40 10)]))

(define-values (s-split _a1) (editor-split! ed s 'right))

;; 找一条 lr seam（editor <-> 新 panel）。
(define seams (layout-seams (editor-state-layout s-split)
                            (editor-state-area s-split)))
(define seam
  (for/first ([seam (in-list seams)]
              #:when (eq? (seam-axis seam) 'lr))
    seam))
(check-not-false seam)

(define r (seam-rect seam))
(define row (+ (rect-y r) (quotient (rect-h r) 2)))
(define col (+ (rect-x r) (quotient (rect-w r) 2)))

(define before (layout-panel-rects (editor-state-layout s-split)
                                  (editor-state-area s-split)))
(define editor-w-before (rect-w (hash-ref before 'editor)))

(define-values (s-press _a2)
  (editor-mouse! ed s-split 'press row col))
(check-not-false (editor-state-drag s-press))

(define-values (s-move _a3)
  (editor-mouse! ed s-press 'move row (+ col 2)))
(check-not-false (editor-state-drag s-move))

(define after (layout-panel-rects (editor-state-layout s-move)
                                  (editor-state-area s-move)))
(check-not-equal? (rect-w (hash-ref after 'editor)) editor-w-before)

(define-values (s-release _a4)
  (editor-mouse! ed s-move 'release row col))
(check-false (editor-state-drag s-release))

;; 点 editor 内容区：聚焦 + 光标落点。
;; 先渲染一帧，把 viewport 尺寸写回 view（真实 host 在 read-event 前已经渲染过）。
(define-values (s-rendered _c0 _b0) (render-frame ed s-release #f))
(define rects (layout-panel-rects (editor-state-layout s-rendered)
                                  (editor-state-area s-rendered)))
(define er (hash-ref rects 'editor))
(define click-row (+ (rect-y er) 1))
(define click-col (+ (rect-x er) 1))
(define-values (s-click _a5)
  (editor-mouse! ed s-rendered 'press click-row click-col))
(check-equal? (editor-focus-panel-id s-click) 'editor)
(check-equal? (engine-view-point-line (editor-engine ed)
                                      (editor-focus-view-id s-click))
              0)
(check-equal? (engine-view-point-column (editor-engine ed)
                                        (editor-focus-view-id s-click))
              1)

(displayln "edit-tui-rebuild/test/mouse.rkt: ok")
