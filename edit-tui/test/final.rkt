#lang racket

;;; 最终编辑器装配的 headless 检查。

(require rackunit
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

;; sidebar 共用 filetree / resources 两个 view。
(define sidebar (layout-panel (app-state-layout state) 'filetree))
(check-equal? (panel-views sidebar) '(10 11))
(check-equal? (panel-active sidebar) 10)

;; status panel 同时挂 status / input。
(define status (layout-panel (app-state-layout state) 'status))
(check-equal? (panel-views status) '(20 21))
(check-equal? (panel-active status) 20)

;; 三个新 UI view 都已经在 engine 里。
(for ([vid (in-list '(10 11 21))])
  (check-not-false (engine-view-object engine vid)))

;; 同步 + 渲染一帧不崩。
(define-values (s1 panels) (sync-ui/panels! state engine))
(define-values (s2 overlays) (prepare-demo! s1 engine))
(define-values (_cache bytes)
  (render-frame s2 engine #f #:panels panels #:overlays overlays))
(check-true (> (bytes-length bytes) 0))

(displayln "edit-tui-rebuild/test/final.rkt: ok")
