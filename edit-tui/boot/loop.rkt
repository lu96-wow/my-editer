#lang racket

;;; edit-tui-rebuild/boot/loop.rkt —— 最小事件循环
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
         "../core/skeleton.rkt"
         "../app/state.rkt"
         "../app/step.rkt"
         "../app/event.rkt"
         "../chrome/api.rkt"
         "actions.rkt"
         "frame.rkt"
         "sync.rkt"
         "tui-adapter.rkt")

(provide run-loop
         run-app)

(define (run-loop state engine
                  #:read-event [read-event (λ () (error 'run-loop "no read-event"))]
                  #:write-bytes [write-bytes (λ (b) (void))])
  (let loop ([state state] [cache #f])
    (define state* (sync-ui! state engine))
    (define-values (cache* bytes) (render-frame state* engine cache))
    (unless (zero? (bytes-length bytes))
      (write-bytes bytes))
    (define ev (read-event))
    (define cache** (if (resize-event? ev) #f cache*))
    (define-values (state1 actions) (step state* ev))
    ;; action 也可能产生新 prompt（例如写文件后继续下一个确认），
    ;; 这里再 reconcile 一次；被挤占的插件请求会在这里回调 on-done。
    (define state2 (run-actions state1 engine actions))
    (define-values (state3 more) (input-reconcile state2))
    (define state4 (run-actions state3 engine more))
    (if (app-state-quit? state4)
        state4
        (loop state4 cache**))))

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
       ;; 字节级读入：tag + 原始 bytes，适配层不解码 char / symbol
       (let loop ()
         (define-values (type data mods) (tui:read-event/raw))
         (define e (tui-event->app type data mods))
         (if e e (loop))))
     (run-loop state* engine
               #:read-event read-app-event
               #:write-bytes (λ (b) (tui:put-bytes b) (tui:flush!))))))
