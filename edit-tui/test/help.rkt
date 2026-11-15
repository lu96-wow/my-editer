#lang racket

;;; 默认帮助 buffer：启动时创建，整 buffer 只读，C-x h 打开 / 聚焦。

(require rackunit
         "../editor/host-api.rkt"
         "../core/command/api.rkt"
         "../host/event.rkt"
         "../edit.rkt"
         "../config/help/default.rkt")

(define-values (ed state) (make-editor-app))
(define s0 (state-with-screen state (rect 0 0 80 24)))

(check-equal? (editor-doc-kind ed help-doc-id) 'ui)
(check-equal? (editor-doc-text ed help-doc-id) help-text)
(check-true (editor-doc-readonly? ed help-doc-id))
;; 帮助 buffer 没有 resource，不进入 resources / workspace。
(check-false (state-resource-for-doc state help-doc-id))

;; C-x h 把帮助 view 挂到当前 editor panel 并聚焦。
(define s-x (handle-editor-event ed s0 (key-event (key 'x 'ctrl))))
(define s-help (handle-editor-event ed s-x (key-event (key 'h))))
(check-equal? (editor-focus-view-id s-help) help-view-id)
(check-equal? (editor-focus-panel-kind s-help) 'editor)
(check-equal? (state-flash s-help) "help opened")

;; 帮助 buffer 拒绝用户文本编辑。
(define before (editor-doc-text ed help-doc-id))
(define s-typed (handle-editor-event ed s-help (key-event (key 'z))))
(check-equal? (editor-doc-text ed help-doc-id) before)

;; 再按 C-x h 只是聚焦已有 view，不重复挂载。
(define s-x2 (handle-editor-event ed s-typed (key-event (key 'x 'ctrl))))
(define s-help2 (handle-editor-event ed s-x2 (key-event (key 'h))))
(check-equal? (editor-focus-view-id s-help2) help-view-id)
(check-equal? (state-flash s-help2) "help")

(displayln "edit-tui/test/help.rkt: ok")
