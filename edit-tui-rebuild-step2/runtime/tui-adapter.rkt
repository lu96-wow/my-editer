#lang racket

;;; runtime/tui-adapter.rkt —— racket-tui 事件 → 应用事件（唯一 tui 解码点）
;;; layer  : runtime
;;; effect : 无（纯适配：tui 事件 -> 应用事件）

;;; 只做两件事：
;;;   · 终端事件 → base/event.rkt 的值；
;;;   · 鼠标 1-based 坐标 → 0-based 屏幕格。
;;;
;;; 键 / 鼠标 token 复用 edit-tui/command 的纯 token 结构。

(provide tui-event->app)

(require tui
         (prefix-in app: "../base/event.rkt")
         "../command/tui.rkt")

(define (tui-event->app ev)
  (cond
    [(key-event? ev)
     (define tok (event->key ev))
     (and tok (app:key-event tok))]

    [(mouse-event? ev)
     (define tok (event->mouse ev))
     (define-values (row col) (mouse-position ev))
     (and tok (app:mouse-event tok row col))]

    [(resize-event? ev)
     (app:resize-event (resize-event-rows ev) (resize-event-cols ev))]

    [(paste-event? ev)
     (app:paste-event (paste-event-text ev))]

    [else #f]))
