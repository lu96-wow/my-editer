#lang racket

;;; edit-tui/app/event.rkt —— 事件解释 + 主循环
;;;
;;; 输入栏 / placement 是抢占式模式；普通 key 走 host/input/dispatch。
;;; 这里不创建 engine / 插件，只消费 app/bootstrap 装配好的 ed + state。

(require racket/async-channel
         (prefix-in tui: tui)
         "../editor/host-api.rkt"
         "../editor/error.rkt"
         "../core/job/api.rkt"
         "../host/event.rkt"
         "../host/input/dispatch.rkt"
         "../host/jobs.rkt"
         "../host/timers.rkt"
         "../host/face-jobs.rkt"
         "../features/input/api.rkt"
         "../features/placement/api.rkt"
         "../features/mouse/api.rkt"
         "actions.rkt"
         "frame.rkt")

(provide read-app-event
         handle-editor-event
         handle-job-result
         run-editor)

(define (editor-focused? state)
  (eq? (editor-focus-panel-kind state) 'editor))

(define (read-app-event)
  (let loop ()
    (define-values (type data mods) (tui:read-event/raw))
    (define e (tui-event->app type data mods))
    (if e e (loop))))

;; 单事件处理；返回 state'。host 循环和 headless 测试共用这一条路径。
(define (handle-editor-event ed state0 ev)
  ;; 输入栏是抢占式的：非 key / paste 事件先取消本次输入，再处理事件。
  (define state1
    (if (and (editor-input-active? state0)
             (not (key-event? ev))
             (not (paste-event? ev)))
        (editor-input-close state0)
        state0))
  (define state
    (if (mouse-event? ev)
        state1
        (state-with-select-drag state1 #f)))
  (cond
    [(resize-event? ev)
     (state-with-screen
      state (rect 0 0 (resize-event-cols ev) (resize-event-rows ev)))]
    [(paste-event? ev)
     (cond
       [(editor-input-active? state)
        (define-values (s2 actions) (editor-input-paste! state (paste-event-bytes ev)))
        (run-actions ed s2 actions)]
       [else
        (define vid (editor-focus-view-id state))
        (cond
          [(not vid) (state-with-flash state "paste: no focused editor view")]
          [(not (editor-focused? state))
           (state-with-flash state "paste: focus is not editor")]
          [else
           (define-values (s2 actions)
             (editor-paste! ed state vid (paste-event-bytes ev)))
           (run-actions ed s2 actions)])])]
    [(mouse-event? ev)
     (cond
       [(editor-placement-active? state)
        (define-values (s2 actions2 handled?)
          (editor-placement-mouse! ed state
                                   (mouse-event-row ev)
                                   (mouse-event-col ev)))
        (cond
          [handled? (run-actions ed s2 actions2)]
          [else
           (define-values (s3 actions3)
             (editor-mouse! ed state
                            (mouse-event-token ev)
                            (mouse-event-row ev)
                            (mouse-event-col ev)))
           (run-actions ed s3 actions3)])]
       [else
        (define-values (s2 actions)
          (editor-mouse! ed state
                         (mouse-event-token ev)
                         (mouse-event-row ev)
                         (mouse-event-col ev)))
        (run-actions ed s2 actions)])]
    [(quit-event? ev)
     ;; 窗口关闭按“保存会话”处理；不受之前取消的 C-q q 影响。
     (state-with-quit (state-with-save-session state #t) #t)]
    [(key-event? ev)
     (define-values (s2 actions)
       (dispatch-key ed state (key-event-token ev)))
     (run-actions ed s2 actions)]
    [else state]))

(define (handle-job-result ed state ev)
  (define id (job-result-event-id ev))
  (define result (job-result-event-result ev))
  (define s1 (state-finish-job state id result))
  ;; worker service 抛出的异常统一进 error buffer；插件 handler 仍然收到
  ;; job-error 事件，可以决定自己的提示 / 状态清理。
  (define s1*
    (if (job-error? result)
        (state-record-error
         s1 'error 'job #f
         (list (job-result-event-kind ev) (job-result-event-tag ev))
         (job-error-message result))
        s1))
  (define-values (s2 actions) (run-plugin-job-handlers ed s1* ev))
  (define s3 (run-actions ed s2 actions))
  (state-forget-job s3 id))

(define (run-editor ed state
                    #:read-event [read-event read-app-event]
                    #:write-bytes [write-bytes (λ (b) (void))]
                    #:job-runtime [job-runtime #f]
                    #:timer-runtime [timer-runtime #f]
                    #:face-runtime [face-runtime #f]
                    #:register-source [register-source #f])
  (define state-box (box state))
  (define cache-box (box #f))
  (define quit-box (box #f))

  (define (draw!)
    (when job-runtime
      (dispatch-jobs! job-runtime (state-jobs (unbox state-box))))
    (define-values (s cache bytes)
      (render-frame ed (unbox state-box) (unbox cache-box)))
    (set-box! state-box s)
    (set-box! cache-box cache)
    (unless (zero? (bytes-length bytes))
      (write-bytes bytes))
    ;; sync 里刚提交的 job 也要立刻派发；否则要等下一条输入事件。
    (when job-runtime
      (dispatch-jobs! job-runtime (state-jobs s)))
    (when (state-quit? s) (set-box! quit-box #t)))

  ;; on-source 回调在 TUI 阻塞等待的同一线程执行；属性 worker 完成后只把
  ;; paint channel 打醒，这里统一重绘一次，不经过 job-result / State 提交链。
  (define (handle-job-source ev)
    (set-box! state-box (handle-job-result ed (unbox state-box) ev))
    (draw!))

  (define (handle-timer-source ev)
    (define-values (s actions)
      (run-plugin-timer-handlers ed (unbox state-box) ev))
    (set-box! state-box (run-actions ed s actions))
    (draw!))

  (define (handle-paint-source _ev)
    (when face-runtime (face-runtime-consume-paint! face-runtime))
    (draw!))

  (when register-source
    (when job-runtime
      (register-source (job-runtime-event-channel job-runtime)
                       handle-job-source))
    (when timer-runtime
      (register-source (timer-runtime-event-channel timer-runtime)
                       handle-timer-source))
    (when face-runtime
      (register-source (face-runtime-paint-channel face-runtime)
                       handle-paint-source)))

  (draw!)
  (let loop ()
    (cond
      [(unbox quit-box) (unbox state-box)]
      [else
       (define ev (read-event))
       (define s (unbox state-box))
       (cond
         [(job-result-event? ev)
          (set-box! state-box (handle-job-result ed s ev))]
         [(timer-event? ev)
          (define-values (s2 actions) (run-plugin-timer-handlers ed s ev))
          (set-box! state-box (run-actions ed s2 actions))]
         [else
          (set-box! state-box (handle-editor-event ed s ev))
          (when (resize-event? ev) (set-box! cache-box #f))])
       (draw!)
       (if (unbox quit-box)
           (unbox state-box)
           (loop))])))
