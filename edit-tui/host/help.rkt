#lang racket

;;; edit-tui/host/help.rkt —— 打开默认帮助 buffer
;;;
;;; 帮助 buffer 在 app/bootstrap 里创建：kind = 'ui，整 buffer readonly 标志打开，
;;; 没有 resource。C-x h：
;;;   · 已经挂在某个 panel -> 切过去并聚焦；
;;;   · 未挂载 -> 作为 tab 放进当前（或第一个）editor panel。

(require "../editor/host-api.rkt"
         "../features/placement/api.rkt"
         "../config/help/default.rkt")

(provide editor-open-help!)

(define (target-editor-panel state)
  (define focus (editor-focus-panel-id state))
  (cond
    [(and focus (eq? (editor-focus-panel-kind state) 'editor)) focus]
    [else
     (for/first ([pid (in-list (or (editor-visible-editor-panels state) '()))])
       pid)]))

(define (editor-open-help! ed state)
  (define engine (editor-engine ed))
  (cond
    [(not (engine-view-object engine help-view-id))
     (values (state-with-flash state "help: buffer missing") '())]
    [else
     (define-values (state1 actions1 attached?)
       (editor-focus-view-if-attached! ed state help-view-id))
     (cond
       [attached?
        (values (state-with-flash state1 "help") actions1)]
       [else
        (define pid (target-editor-panel state1))
        (cond
          [(not pid)
           (values (state-with-flash state1 "help: no editor panel") actions1)]
          [else
           (define-values (state2 ok?)
             (editor-place-into-panel! ed state1 pid help-view-id))
           (values (state-with-flash
                    state2
                    (if ok? "help opened" "help: open failed"))
                   actions1)])])]))
