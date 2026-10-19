#lang racket

;;; edit-tui-rebuild/runtime/loop.rkt —— 最小事件循环
;;;
;;; 主循环：
;;;   render
;;;   read-event
;;;   step  -> state + actions
;;;   run-actions
;;;   quit? -> exit
;;;
;;; IO 可注入，方便 headless 测试 / 换终端。

(require "../app/state.rkt"
         "../app/step.rkt"
         "../app/event.rkt"
         "actions.rkt"
         "render.rkt")

(provide run-loop)

(define (run-loop state engine
                  #:read-event [read-event (λ () (error 'run-loop "no read-event"))]
                  #:write-bytes [write-bytes (λ (b) (void))])
  (let loop ([state state] [cache #f])
    (define-values (cache* bytes) (render-frame state engine cache))
    (unless (zero? (bytes-length bytes))
      (write-bytes bytes))
    (define ev (read-event))
    (define cache** (if (resize-event? ev) #f cache*))
    (define-values (state1 actions) (step state ev))
    (define state2 (run-actions state1 engine actions))
    (if (app-state-quit? state2)
        state2
        (loop state2 cache**))))
