#lang racket

;;; 最终编辑器装配的 headless 检查。

(require rackunit
         racket/string
         "../main.rkt"
         "../host/final.rkt"
         "../demo/completion-docs.rkt")

(define state final-state)
(define engine final-engine)

;; 四个主区域都在。
(define visible (layout-visible-panel-ids (app-state-layout state)))
(check-not-false (memq 'filetree visible))
(check-not-false (memq 'editor visible))
(check-not-false (memq 'docs visible))
(check-not-false (memq 'status visible))

;; 启动不打开默认 buffer：engine 的 editor view 1 已移除，editor panel 为空。
(check-false (engine-view-object engine 1))
(check-equal? (panel-views (layout-panel (app-state-layout state) 'editor)) '())
(check-false (panel-active (layout-panel (app-state-layout state) 'editor)))
(check-equal? (resource-list (app-state-resources state)) '())

;; sidebar 共用 filetree / resources 两个 view。
(define sidebar (layout-panel (app-state-layout state) 'filetree))
(check-equal? (panel-views sidebar) '(10 11))
(check-equal? (panel-active sidebar) 10)

;; filetree 横跨 editor + docs + status 的完整高度。
(define area (app-state-area state))
(define rects (layout-panel-rects (app-state-layout state) area))
(define ft-rect (hash-ref rects 'filetree))
(check-equal? (rect-h ft-rect) (rect-h area))
(check-equal? (rect-bottom ft-rect) (rect-bottom area))
(check-equal? (rect-h (hash-ref rects 'docs)) 1)
(check-equal? (rect-h (hash-ref rects 'status)) 1)

;; docs 上边缘可拖：拖高后 docs 变成 3 行。
(define layout (app-state-layout state))
(define config (app-state-layout-config state))
(define seam (layout-seam-at layout area 21 40))
(check-not-false seam)
(define drag (layout-seam-drag-start layout area 21 40
                                     #:config config #:seam seam))
(check-not-false drag)
(define-values (layout-drag _drag-ok?)
  (layout-seam-drag-move layout area drag 19 40 #:config config))
(check-equal? (rect-h (hash-ref (layout-panel-rects layout-drag area) 'docs)) 3)

;; docs 面板四向边框。
(check-equal? (panel-borders (layout-panel (app-state-layout state) 'docs))
              '(up down left right))

;; docs 初始 1 行，但本身是 flex，seam 可拖动；status 固定 1 行。
(check-false (layout-panel-fixed-size (app-state-layout state) 'docs 'tb))
(check-equal? (layout-panel-fixed-size (app-state-layout state) 'status 'tb) 1)

;; status panel 同时挂 status / input。
(define status (layout-panel (app-state-layout state) 'status))
(check-equal? (panel-views status) '(20 21))
(check-equal? (panel-active status) 20)

;; 三个新 UI view 都已经在 engine 里。
(for ([vid (in-list '(10 11 21))])
  (check-not-false (engine-view-object engine vid)))

;; Tab 是 sidebar 局部绑定：只在 filetree / resources 内轮换。
(define sidebar-focused (app-state-set-focus-panel state 'filetree))
(define-values (tab1 _a1) (step sidebar-focused (key-event (key 'tab))))
(check-equal? (layout-panel-active-view (app-state-layout tab1) 'filetree) 11)
(define-values (tab2 _a2) (step tab1 (key-event (key 'tab))))
(check-equal? (layout-panel-active-view (app-state-layout tab2) 'filetree) 10)

;; 同步 + 渲染一帧不崩；docs 初始 state 只有一行。
(define-values (s1 panels) (sync-ui/panels! state engine))
(define-values (s2 overlays) (prepare-demo! s1 engine))
(check-false (string-contains? (engine-view-text engine 30) "\n"))
(define-values (_cache bytes)
  (render-frame s2 engine #f #:panels panels #:overlays overlays))
(check-true (> (bytes-length bytes) 0))

(displayln "edit-tui-rebuild/test/final.rkt: ok")
