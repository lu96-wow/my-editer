#lang racket

;;; completion 手动打开 / overlay / 接受 / docs 更新 / docs 显隐。
;;; 以及 changes -> timer debounce -> 自动打开。

(require rackunit
         racket/async-channel
         racket/string
         "../editor/host-api.rkt"
         "../core/command/api.rkt"
         "../core/layout/api.rkt"
         "../plugins/completion/plugin.rkt"
         "../host/final.rkt"
         "../host/event.rkt")

;;; ════════════════ 手动打开 / 接受 / docs ════════════════

(define-values (ed state) (make-demo-editor))
(define s0 (struct-copy editor-state state [area (rect 0 0 60 15)]))
(define-values (s1 _c1 _b1) (render-frame ed s0 #f))
(engine-set-view-cursor! (editor-engine ed) 1 3 #:column 5)

(define s2 (handle-editor-event ed s1 (key-event (key 'o 'ctrl))))
(define c2 (editor-state-plugin-state s2 'completion))
(check-true (completion-state-open? c2))
(check-not-false (member "map" (completion-state-candidates c2)))

;; 渲染一帧，同步 completion view / popup geometry / docs。
(define-values (s2r _c2r _b2r) (render-frame ed s2 #f))

;; overlay 存在且在 editor 内容区内。
(define ovs (run-plugin-overlays ed s2r))
(check-equal? (length ovs) 1)
(define content (editor-focus-content-rect s2r))
(define ov-rect (editor-overlay-rect (car ovs)))
(check-true (>= (rect-x ov-rect) (rect-x content)))
(check-true (<= (rect-right ov-rect) (rect-right content)))

;; docs 已更新到选中候选。
(check-true (string-contains? (engine-view-text (editor-engine ed) 7) "map"))

;; Enter 接受候选：插入 "p"，菜单关闭。
(define s4 (handle-editor-event ed s2r (key-event (key 'enter))))
(check-false (completion-state-open?
              (editor-state-plugin-state s4 'completion)))
(check-equal? (list-ref (string-split (engine-view-text (editor-engine ed) 1) "\n" #:trim? #f) 3)
              "  (mapp add1 xs))")

;; C-x d 显 / 隐 docs。
(define s5 (handle-editor-event ed s4 (key-event (key 'x 'ctrl))))
(define s6 (handle-editor-event ed s5 (key-event (key 'd))))
(check-false (layout-panel-visible? (editor-state-layout s6) 'docs))
(define s7 (handle-editor-event ed s6 (key-event (key 'x 'ctrl))))
(define s8 (handle-editor-event ed s7 (key-event (key 'd))))
(check-true (layout-panel-visible? (editor-state-layout s8) 'docs))

;;; ════════════════ changes -> timer -> 自动打开 ════════════════

(define-values (ed2 state2) (make-demo-editor))
(define t0 (struct-copy editor-state state2 [area (rect 0 0 60 15)]))
(define-values (t1 _c _b) (render-frame ed2 t0 #f))
(define ch (make-async-channel))
(define trt (start-timer-runtime #:event-channel ch))
(editor-set-timer-runtime! ed2 trt)
(engine-set-view-cursor! (editor-engine ed2) 1 3 #:column 3)
(define-values (t2 _a) (editor-insert! ed2 t1 1 "m"))
(define ct2 (editor-state-plugin-state t2 'completion))
(check-true (exact-nonnegative-integer? (completion-state-timer-id ct2)))

(define tev (async-channel-get ch))
(check-true (timer-event? tev))
(define t3 (run-plugin-timer-handlers ed2 t2 tev))
(define ct3 (editor-state-plugin-state t3 'completion))
(check-true (completion-state-open? ct3))
(check-true (and (pair? (completion-state-candidates ct3))
                 (and (member "mmap" (completion-state-candidates ct3)) #t)))
(stop-timer-runtime trt)

(displayln "edit-tui-rebuild/test/completion-docs.rkt: ok")
