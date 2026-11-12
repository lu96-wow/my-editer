#lang racket

;;; host 事件路径回归：
;;;   · 鼠标点击 sidebar 不再触发 run-actions arity 错误；
;;;   · 点击后焦点到 sidebar；
;;;   · C-x → 回 editor；
;;;   · editor 里可打印字符正常插入。

(require rackunit
         "../editor/host-api.rkt"
         "../core/command/api.rkt"
         "../host/final.rkt"
         "fixture.rkt"
         "../host/event.rkt")

(define-values (ed state) (make-test-editor))
(define s0 (state-with-area state (rect 0 0 60 15)))

;; 先渲染一帧，同步 viewport / filetree 内容。
(define-values (s1 _c1 _b1) (render-frame ed s0 #f))

;; 鼠标点 sidebar 内容（root 下一行）。
(define s2 (handle-editor-event ed s1 (mouse-event 'press 1 0)))
(check-equal? (editor-focus-panel-kind s2) 'sidebar)

;; release 正常清理 drag。
(define s3 (handle-editor-event ed s2 (mouse-event 'release 1 0)))
(check-false (state-drag s3))

;; sidebar 里打字不应该写进 buffer。
(define before (engine-view-text (editor-engine ed) 3))
(define s4 (handle-editor-event ed s3 (key-event (key 'a))))
(check-equal? (engine-view-text (editor-engine ed) 3) before)
(check-true (string-contains? (state-flash s4) "not editor"))

;; C-x → 回到 editor。
(define s5 (handle-editor-event ed s4 (key-event (key 'x 'ctrl))))
(check-true (pair? (state-pending s5)))
(define s6 (handle-editor-event ed s5 (key-event (key 'right))))
(check-equal? (editor-focus-panel-kind s6) 'editor)

;; editor 里打字正常插入。
(define editor-vid (editor-focus-view-id s6))
(define text-before (engine-view-text (editor-engine ed) editor-vid))
(define s7 (handle-editor-event ed s6 (key-event (key 'a))))
(check-not-equal? (engine-view-text (editor-engine ed) editor-vid) text-before)

(displayln "edit-tui-rebuild/test/host-event.rkt: ok")
