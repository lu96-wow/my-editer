#lang racket

;;; 鼠标：seam 拖拽 + release 清理。

(require rackunit
         "../editor/host-api.rkt"
         "../core/api.rkt"
         "../core/layout/api.rkt"
         "../core/projection/api.rkt"
         "../features/mouse/api.rkt"
         "../edit.rkt"
         "fixture.rkt")

(define-values (ed state) (make-test-editor))
(define s (state-with-screen state (rect 0 0 40 10)))

(define-values (s-split _a1) (editor-split! ed s 'right))

;; 找一条 lr seam（editor <-> 新 panel）。
(define seams (layout-seams (state-layout s-split)
                            (state-screen s-split)))
(define seam
  (for/first ([seam (in-list seams)]
              #:when (eq? (seam-axis seam) 'lr))
    seam))
(check-not-false seam)

(define r (seam-rect seam))
(define row (+ (rect-y r) (quotient (rect-h r) 2)))
(define col (+ (rect-x r) (quotient (rect-w r) 2)))

(define before (layout-panel-rects (state-layout s-split)
                                  (state-screen s-split)))
(define editor-w-before (rect-w (hash-ref before 'editor)))

(define-values (s-press _a2)
  (editor-mouse! ed s-split 'press row col))
(check-not-false (state-drag s-press))

(define-values (s-move _a3)
  (editor-mouse! ed s-press 'move row (+ col 2)))
(check-not-false (state-drag s-move))

(define after (layout-panel-rects (state-layout s-move)
                                  (state-screen s-move)))
(check-not-equal? (rect-w (hash-ref after 'editor)) editor-w-before)

(define-values (s-release _a4)
  (editor-mouse! ed s-move 'release row col))
(check-false (state-drag s-release))

;; 点 editor 内容区：聚焦 + 光标落点。
;; 先渲染一帧，把 viewport 尺寸写回 view（真实 host 在 read-event 前已经渲染过）。
(define-values (s-rendered _c0 _b0) (render-frame ed s-release #f))
(define rects (layout-panel-rects (state-layout s-rendered)
                                  (state-screen s-rendered)))
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

;; 拖选：press 落 caret，move 扩展 head，release 结束。
(define content (layout-content-rect (state-layout s-click)
                                    (state-screen s-click)
                                    'editor))
(define cr (+ (rect-y content) 0))
(define cc (+ (rect-x content) 2))
(define-values (s-drag-down _ad)
  (editor-mouse! ed s-click 'press cr cc))
(check-not-false (state-select-drag s-drag-down))
(define-values (s-drag-move _am)
  (editor-mouse! ed s-drag-down 'move cr (+ cc 3)))
(define-values (s-drag-up _au)
  (editor-mouse! ed s-drag-move 'release cr (+ cc 3)))
(check-false (state-select-drag s-drag-up))
(check-equal? (view-copy-text (engine-view-object (editor-engine ed)
                                                  (editor-focus-view-id s-drag-up)))
              "ang")

(displayln "edit-tui/test/mouse.rkt: ok")
