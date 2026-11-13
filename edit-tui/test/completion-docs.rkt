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
         "../edit.rkt"
         "fixture.rkt"
         "../host/event.rkt"
         "../host/timers.rkt")

;;; ════════════════ 手动打开 / 接受 / docs ════════════════

(define-values (ed state) (make-test-editor))
(define s0 (state-with-area state (rect 0 0 60 15)))
(define-values (s1 _c1 _b1) (render-frame ed s0 #f))
(engine-set-view-cursor! (editor-engine ed) 1 3 #:column 5)

(define s2 (handle-editor-event ed s1 (key-event (key 'o 'ctrl))))
(define c2 (state-plugin-state s2 'completion))
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

;; 菜单内移动选中项只改 face，不重写 popup 文本。
(define popup-version (engine-doc-version (editor-engine ed) 6))
(define s-down (handle-editor-event ed s2r (key-event (key 'down))))
(define-values (s-down-r _c-down _b-down) (render-frame ed s-down #f))
(check-eq? (engine-doc-version (editor-engine ed) 6) popup-version)
(define s-back (handle-editor-event ed s-down-r (key-event (key 'up))))
(define-values (s-back-r _c-back _b-back) (render-frame ed s-back #f))
(check-eq? (engine-doc-version (editor-engine ed) 6) popup-version)

;; Enter 接受候选：插入 "p"，菜单关闭。
(define s4 (handle-editor-event ed s-back-r (key-event (key 'enter))))
(check-false (completion-state-open?
              (state-plugin-state s4 'completion)))
(check-equal? (list-ref (string-split (engine-view-text (editor-engine ed) 1) "\n" #:trim? #f) 3)
              "  (mapp add1 xs))")

;; C-x d 显 / 隐 docs。
(define s5 (handle-editor-event ed s4 (key-event (key 'x 'ctrl))))
(define s6 (handle-editor-event ed s5 (key-event (key 'd))))
(check-false (layout-panel-visible? (state-layout s6) 'docs))
(define s7 (handle-editor-event ed s6 (key-event (key 'x 'ctrl))))
(define s8 (handle-editor-event ed s7 (key-event (key 'd))))
(check-true (layout-panel-visible? (state-layout s8) 'docs))

;;; ════════════════ 完全等于 prefix 的候选也保留 ════════════════

(define-values (edx statex) (make-test-editor))
(define x0 (state-with-area statex (rect 0 0 60 15)))
(define-values (x1 _cx _bx) (render-frame edx x0 #f))
;; 光标在 "map" 之后，prefix = "map"。
(engine-set-view-cursor! (editor-engine edx) 1 3 #:column 6)
(define x2 (handle-editor-event edx x1 (key-event (key 'o 'ctrl))))
(define cx2 (state-plugin-state x2 'completion))
;; prefix 本身保留在候选列表里，但没有其他候选时不显示 popup。
(check-not-false (member "map" (completion-state-candidates cx2)))
(check-false (completion-state-open? cx2))
(define-values (x2r _cx2r _bx2r) (render-frame edx x2 #f))
(check-equal? (run-plugin-overlays edx x2r) '())

;; 没有打开菜单时 Enter 是普通换行，不会被补全吞掉。
(define before-enter (engine-view-text (editor-engine edx) 1))
(define x3 (handle-editor-event edx x2r (key-event (key 'enter))))
(check-not-equal? (engine-view-text (editor-engine edx) 1)
                  before-enter)
(check-false (completion-state-open?
              (state-plugin-state x3 'completion)))

;;; ════════════════ changes -> timer -> 自动打开 ════════════════

(define-values (ed2 state2) (make-test-editor))
(define t0 (state-with-area state2 (rect 0 0 60 15)))
(define-values (t1 _c _b) (render-frame ed2 t0 #f))
(define ch (make-async-channel))
(define trt (start-timer-runtime #:event-channel ch))
(editor-set-timer-service! ed2 (timer-runtime-service trt))
(engine-set-view-cursor! (editor-engine ed2) 1 3 #:column 3)
(define-values (t2 _a) (editor-insert! ed2 t1 1 "m"))
(define ct2 (state-plugin-state t2 'completion))
(check-true (exact-nonnegative-integer? (completion-state-timer-id ct2)))

(define tev (async-channel-get ch))
(check-true (timer-event? tev))
(define-values (t3 _timer-actions) (run-plugin-timer-handlers ed2 t2 tev))
(define ct3 (state-plugin-state t3 'completion))
(check-true (completion-state-open? ct3))
(check-true (and (pair? (completion-state-candidates ct3))
                 (and (member "mmap" (completion-state-candidates ct3)) #t)))
(stop-timer-runtime trt)

(displayln "edit-tui/test/completion-docs.rkt: ok")
