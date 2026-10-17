#lang racket

;;; runtime/run.rkt —— 事件循环（唯一不纯的装配层）
;;; layer  : runtime
;;; effect : **壳**：read-event / put-bytes / spawn / timer 线程 / 渲染输出
;;;            （唯一从终端输入走到终端输出的模块）

;;;   tui event ──▶ base/event ──▶ dispatch ──▶ transition
;;;                                                   │
;;;                          engine/IO effect ◀──────┤
;;;                          spawn/timer/emit ───────┤
;;;                                                   ▼
;;;                                        State' + inbox
;;;                                                   │
;;;                     project-frame → engine-sync-views! → render-frame → put-bytes
;;;
;;; 说明：
;;;   · dispatch 是纯的；解释 effect 才碰 engine / 文件 / 线程。
;;;   · inbox 只在“下一个终端事件”到达时排空（与旧骨架一致）；效果刚 emit 的事件
;;;     会在本批次结束时再排空一次。
;;;   · 渲染缓存由 loop 持有；State 不存 cache / inbox / 线程。

(provide run-app
         run-frame
         process-events)

(require tui
         racket/async-channel
         (prefix-in app: "../base/event.rkt")
         "../base/effect.rkt"
         "../base/transition.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../effects/engine.rkt"
         "../effects/interpreter.rkt"
         "../env/environment.rkt"
         "../dispatch/pipeline.rkt"
         "../chrome/slot.rkt"
         "../projection/geometry.rkt"
         "../projection/render.rkt"
         "tui-adapter.rkt")

;;; ════════════════ 事件 → subject ════════════════

;; 鼠标命中：region → active member。
;;   view member  -> view-id（文档命令按它查表）
;;   chrome member-> region-id（chrome 自己决定要不要响应）
(define (subject-for state ev)
  (case (app:event-kind ev)
    [(mouse)
     (define ws (state-workspace state))
     (define w (state-window state))
     (define area (window-area w))
     (define-values (rps _cuts) (geometry-solve (workspace-layout ws) area))
     (define rp (region-panel-at rps (app:mouse-event-row ev) (app:mouse-event-col ev)))
     (define reg (and rp (workspace-region ws (region-panel-region rp))))
     (and reg
          (let ([active (region-active reg)])
            (or (for/first ([m (in-list (region-members reg))]
                            #:when (equal? (member-key m) active))
                  (and (view-member? m) (member-key m)))
                (region-key reg))))]
    [(paste) (state-focus state)]
    [else #f]))

;;; ════════════════ 事件批处理 ════════════════

;; 逐个事件：dispatch → 解释 effect → 再下一个。
;; 这样 open-doc 之后的事件能看到新 view，顺序不会被“先折状态、后跑 effect”打乱。
(define (process-events env engine inbox state events)
  (for/fold ([t (transition-pure state)]) ([e (in-list events)])
    (transition-bind
     t
     (λ (s)
       (define subject (subject-for s e))
       (define t1 (dispatch env s e
                            #:subject subject
                            #:engine (make-engine-view engine)))
       (run-transition-effects engine t1 inbox)))))

;; 本批次里 emit 出来的事件也处理掉；spawn/timer 若已就绪也会被带出来。
(define (drain-and-process env engine inbox t)
  (let loop ([t t])
    (define evs (drain-channel inbox))
    (if (null? evs)
        t
        (loop (transition-bind t
                               (λ (s)
                                 (process-events env engine inbox s evs)))))))

;;; ════════════════ effect 解释 ════════════════

(define (run-transition-effects engine t inbox)
  (for/fold ([t2 (transition-pure (transition-state t))])
            ([e (in-list (transition-effects t))])
    (transition-bind t2
                     (λ (s)
                       (define t1 (run-one-effect engine s e inbox))
                       ;; effect 解释时可能产生新 effect（read-file -> open-doc），递归跑完。
                       (run-transition-effects engine t1 inbox)))))

(define (run-one-effect engine state effect inbox)
  (cond
    [(spawn-effect? effect)
     (define job (spawn-effect-job effect))
     (define thunk (spawn-effect-thunk effect))
     (thread (λ ()
               (define v (thunk))
               (async-channel-put inbox
                                  (app:internal-event 'job-done (list job v)))))
     (transition-pure state)]

    [(timer-effect? effect)
     (define delay (timer-effect-delay effect))
     (define ev (timer-effect-event effect))
     (thread (λ () (sleep delay) (async-channel-put inbox ev)))
     (transition-pure state)]

    [(emit-effect? effect)
     (async-channel-put inbox (emit-effect-event effect))
     (transition-pure state)]

    [else (interpret-effect! engine state effect)]))

;;; ════════════════ inbox ════════════════

(define (drain-channel ch)
  (let loop ([acc '()])
    (define v (async-channel-try-get ch))
    (if v (loop (cons v acc)) (reverse acc))))

;;; ════════════════ 渲染 ════════════════

;; 先同步 view 尺寸（唯一写 core 的地方），再投影/输出。
;; 先跑每帧同步（唯一写 core 的地方），再投影/输出。
;;   1. chrome 槽（status 文本，由 environment.status 决定段）
;;   2. environment.panel-syncs（插件面板自己声明的同步器，按注册顺序）
(define (run-frame env state engine cache #:status-parts [status-parts #f])
  (sync-chrome! state engine status-parts)
  (for ([sync (in-list (environment-panel-syncs env))])
    (sync state engine))
  (define-values (_ps _cs placements)
    (project-frame state engine #:status-parts status-parts))
  (engine-sync-views! engine placements)
  (define-values (cache* bytes)
    (render-frame state engine cache #:status-parts status-parts))
  (unless (zero? (bytes-length bytes))
    (put-bytes bytes)
    (flush!))
  cache*)

;;; ════════════════ 主循环 ════════════════

(define (run-app env state engine)
  (with-tui
   (λ ()
     (cursor-hide)
     (enable-mouse!)
     (enable-bracketed-paste!)
     (define inbox (make-async-channel))
     ;; 用真实终端尺寸初始化；拿不到就保留传入的 State.window。
     (define-values (rows cols) (get-window-size))
     (define state0
       (if (and rows cols (positive? rows) (positive? cols))
           (state-set-window state (make-window rows cols))
           state))
     (let loop ([state state0] [cache #f])
       (define cache* (run-frame env state engine cache
                                 #:status-parts (environment-status env)))
       (define ev (read-event))
       (define app-ev (tui-event->app ev))
       (define batch (append (if app-ev (list app-ev) '())
                             (drain-channel inbox)))
       (define t (process-events env engine inbox state batch))
       (define t2 (drain-and-process env engine inbox t))
       (define state* (transition-state t2))
       (unless (runtime-quit? (state-runtime state*))
         (loop state* cache*))))))
