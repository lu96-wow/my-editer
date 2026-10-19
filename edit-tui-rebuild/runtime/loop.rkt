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

(require (prefix-in tui: tui)
         "../app/state.rkt"
         "../app/step.rkt"
         "../app/event.rkt"
         "../base/api.rkt"
         "actions.rkt"
         "render.rkt"
         "tui-adapter.rkt")

(provide run-loop
         run-app)

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

;; 终端入口：当前 demo / 测试用 run-loop 注入事件；真实终端用 run-app。
(define (run-app state engine)
  (tui:with-tui
   (λ ()
     (tui:cursor-hide)
     (tui:enable-mouse!)
     (tui:enable-bracketed-paste!)
     (define-values (rows cols) (tui:get-window-size))
     (define state*
       (if (and rows cols (positive? rows) (positive? cols))
           (struct-copy app-state state [area (rect 0 0 cols rows)])
           state))
     (define (read-app-event)
       (let loop ()
         (define e (tui-event->app (tui:read-event)))
         (if e e (loop))))
     (run-loop state* engine
               #:read-event read-app-event
               #:write-bytes (λ (b) (tui:put-bytes b) (tui:flush!))))))
