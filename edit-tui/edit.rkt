#lang racket

;;; edit-tui/edit.rkt —— 可运行入口
;;;
;;; 具体装配在 app/bootstrap.rkt，事件在 app/event.rkt，渲染在 app/frame.rkt，
;;; action 解释在 app/actions.rkt。这里只负责终端生命周期和对外 re-export，
;;; 让测试 / headless 入口继续 require edit-tui/edit.rkt。

(require racket/async-channel
         (prefix-in tui: tui)
         "editor/host-api.rkt"
         "app/bootstrap.rkt"
         "app/event.rkt"
         "app/frame.rkt"
         "host/jobs.rkt"
         "host/timers.rkt"
         "compat/theme/default.rkt")

(provide run-editor
         make-editor-app
         run-demo-editor
         render-frame
         sync-status!
         handle-editor-event
         handle-job-result)

;;; ════════════════ 终端入口 ════════════════

(define (run-demo-editor)
  (define-values (ed state) (make-editor-app))
  (tui:with-tui
   (lambda ()
     (tui:cursor-hide)
     (tui:enable-mouse!)
     (tui:enable-bracketed-paste!)
     (define-values (rows cols) (tui:get-window-size))
     (define area
       (if (and rows cols (positive? rows) (positive? cols))
           (rect 0 0 cols rows)
           (rect 0 0 80 24)))
     (define event-channel (make-async-channel))
     (define input-thread
       (thread (λ ()
                 (let loop ()
                   (async-channel-put event-channel (read-app-event))
                   (loop)))))
     (define runtime
       (start-job-runtime (editor-services ed)
                          #:event-channel event-channel
                          #:workers 2))
     (define timer-runtime
       (start-timer-runtime #:event-channel event-channel))
     (editor-set-timer-service! ed (timer-runtime-service timer-runtime))
     (dynamic-wind
      void
      (λ ()
        (run-editor ed
                    (state-with-async (state-with-area state area) #t)
                    #:read-event (λ () (async-channel-get event-channel))
                    #:write-bytes (λ (b) (tui:put-bytes b) (tui:flush!))
                    #:job-runtime runtime))
      (λ ()
        (kill-thread input-thread)
        (stop-job-runtime runtime)
        (stop-timer-runtime timer-runtime))))))

(module+ main
  (void (run-demo-editor)))
