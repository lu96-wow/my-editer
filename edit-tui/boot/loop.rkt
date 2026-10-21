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
         racket/async-channel
         "../core/skeleton.rkt"
         "../app/state.rkt"
         "../app/step.rkt"
         "../app/event.rkt"
         "../chrome/api.rkt"
         "../edit/api.rkt"
         "../filetree/api.rkt"
         "actions.rkt"
         "frame.rkt"
         "jobs.rkt"
         "start.rkt"
         "sync.rkt"
         "tui-adapter.rkt")

(provide run-loop
         run-app)

;; layout-solve 只依赖结构 key（root + panel-map）和 area。
;; key 的两个字段用 eq? 比较：焦点 / active view 变化不会让 solve 失效。
(struct layout-cache (key area solution) #:transparent)

(define (layout-key=? a b)
  (and a b
       (eq? (car a) (car b))
       (eq? (cdr a) (cdr b))))

(define (cached-layout-solution cache layout area)
  (define key (layout-solve-key layout))
  (cond
    [(or (not key) (not area)) (values #f #f)]
    [(and cache
          (layout-key=? (layout-cache-key cache) key)
          (equal? (layout-cache-area cache) area))
     (values cache (layout-cache-solution cache))]
    [else
     (define solution (layout-solve layout area))
     (values (layout-cache key area solution) solution)]))

(define (run-loop state engine
                  #:read-event [read-event (λ () (error 'run-loop "no read-event"))]
                  #:write-bytes [write-bytes (λ (b) (void))]
                  #:job-runtime [job-runtime #f])
  (let loop ([state state] [cache #f] [layout-cache #f])
    ;; 先派发上一轮 step/actions 产生的 job；结果会回到 read-event 的事件源。
    (when job-runtime
      (dispatch-jobs! job-runtime (app-state-jobs state)))
    ;; solve 放在 sync 之前：sync 里的 input reconcile 只改焦点 / active view，
    ;; 不改几何；真正的结构变化会在下一帧因 layout-solve-key 变化而重新 solve。
    (define layout (app-state-layout state))
    (define area (app-state-area state))
    (define-values (layout-cache* solution)
      (cached-layout-solution layout-cache layout area))
    (define-values (state* panels)
      (sync-ui/panels! state engine #:solution solution
                       #:async-filetree? #t))
    ;; 本帧所有派生阶段都已读取过 pending-doc-changes（color 等）；
    ;; 清掉，避免生产路径里无限累积。demo 的自定义循环由 prepare-demo! 自己消费。
    (define state** (app-state-clear-doc-changes state*))
    (define-values (cache* bytes)
      (render-frame state** engine cache #:solution solution #:panels panels))
    (unless (zero? (bytes-length bytes))
      (write-bytes bytes))
    (define ev (read-event))
    (define cache** (if (resize-event? ev) #f cache*))
    (cond
      [(job-result-event? ev)
       (when job-runtime
         (forget-dispatched-job! job-runtime (job-result-event-id ev)))
       (define state***
         (handle-filetree-job-result
          (handle-color-job-result
           (app-state-finish-job state**
                                 (job-result-event-id ev)
                                 (job-result-event-result ev))
           ev)
          ev))
       (loop state*** cache** layout-cache*)]
      [else
       (define-values (state1 actions) (step state** ev #:solution solution))
       ;; action 也可能产生新 prompt（例如写文件后继续下一个确认），
       ;; 这里再 reconcile 一次；被挤占的插件请求会在这里回调 on-done。
       (define state2 (run-actions state1 engine actions))
       (define-values (state3 more) (input-reconcile state2))
       (define state4 (run-actions state3 engine more))
       (if (app-state-quit? state4)
           state4
           (loop state4 cache** layout-cache*))])))

;; 边界：run-app 总是注册内置后台 service；外部 services 可以是 list 或 registry。
(define (merge-runtime-services services)
  (define built-in (append color-services filetree-services))
  (if (service-registry? services)
      (service-registry-merge services (make-service-registry built-in))
      (append services built-in)))

;; 终端入口：当前 demo / 测试用 run-loop 注入事件；真实终端用 run-app。
;; 传 #:host 时先 install 所有插件，退出时逆序 teardown。
;; terminal reader thread 与 job worker 共享同一个 event channel，run-loop 只读它。
(define (run-app state engine
                 #:host [host #f]
                 #:services [services '()]
                 #:job-workers [job-workers 2])
  (define state0 (if host (start-app host state) state))
  (define result
    (tui:with-tui
     (λ ()
       (tui:cursor-hide)
       (tui:enable-mouse!)
       (tui:enable-bracketed-paste!)
       (define-values (rows cols) (tui:get-window-size))
       (define state*
         (if (and rows cols (positive? rows) (positive? cols))
             (struct-copy app-state state0 [area (rect 0 0 cols rows)])
             state0))
       (define (read-app-event)
         ;; 字节级读入：tag + 原始 bytes，适配层不解码 char / symbol
         (let loop ()
           (define-values (type data mods) (tui:read-event/raw))
           (define e (tui-event->app type data mods))
           (if e e (loop))))
       (define event-channel (make-async-channel))
       (define input-thread
         (thread (λ ()
                   (let loop ()
                     (async-channel-put event-channel (read-app-event))
                     (loop)))))
       (define runtime
         (start-job-runtime (merge-runtime-services services)
                            #:event-channel event-channel
                            #:workers job-workers))
       (dynamic-wind
        void
        (λ ()
          (run-loop state* engine
                    #:read-event (λ () (async-channel-get event-channel))
                    #:write-bytes (λ (b) (tui:put-bytes b) (tui:flush!))
                    #:job-runtime runtime))
        (λ ()
          (kill-thread input-thread)
          (stop-job-runtime runtime))))))
  (if host (host-teardown host result engine) result))
