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
;;;   · hook（上色 / 补全 / 文档）在 settle 里跑：一定发生在 effect 解释之后；
;;   · inbox 只在“下一个终端事件”到达时排空（与旧骨架一致）；效果刚 emit 的事件
;;;     会在本批次结束时再排空一次。
;;;   · 渲染缓存由 loop 持有；State 不存 cache / inbox / 线程。

(provide run-app
         run-frame
         process-events
         startup!)

(require tui
         racket/async-channel
         "../base/signal.rkt"
         "../dispatch/hooks.rkt"
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
         "../projection/float.rkt"
         "../projection/render.rkt"
         "tui-adapter.rkt")

;;; ════════════════ 事件 → subject ════════════════

;; 鼠标命中：**先浮层，再平铺面板**（浮层 deep 更高，点上去不该穿透）。
;;   view member  -> view-id（文档命令按它查表）
;;   chrome member-> region-id（chrome 自己决定要不要响应）
(define (subject-for engine state ev)
  (case (app:event-kind ev)
    [(mouse)
     (define ws (state-workspace state))
     (define area (window-area (state-window state)))
     (define row (app:mouse-event-row ev))
     (define col (app:mouse-event-col ev))
     (define float-vid (float-panel-at state (make-engine-view engine) row col))
     (cond
       [float-vid float-vid]
       [else
        (define-values (rps _cuts) (geometry-solve (workspace-layout ws) area))
        (define rp (region-panel-at rps row col))
        (define reg (and rp (workspace-region ws (region-panel-region rp))))
        (and reg
             (let ([active (region-active reg)])
               (or (for/first ([m (in-list (region-members reg))]
                               #:when (equal? (member-key m) active))
                     (and (view-member? m) (member-key m)))
                   (region-key reg))))])]
    [(paste) (state-focus state)]
    [else #f]))

;;; ════════════════ 事件批处理 ════════════════

;; ════════════════ 一批事件 -> 稳定状态 ════════════════
;;
;; settlement = 反复做三件事，直到没有新信号：
;;
;;   1. 解释 effect（写 engine / IO / emit 信号）
;;   2. 排空信号 -> 跑 hook（hook 读的是**写完之后**的 engine-view）
;;   3. hook 可能加新 effect，回到 1
;;
;; 关键是顺序：hook 必须在 effect 解释之后跑，否则“after-edit 后重新上色”会
;; 拿编辑前的文本。轮数上限防 hook 自激。
(define (settle env engine inbox t)
  (let loop ([t t] [round 0])
    ;; 1. 解释 effect（会 emit 信号，engine 已经落盘）
    (define t1 (run-transition-effects engine t inbox))
    ;; 2. 这批 effect 已经消费掉，清空再跑 hook（否则下一轮会重复执行）
    (define t1* (transition (transition-state t1) '()))
    ;; 3. 排空信号 -> 跑 hook；hook 可能加新 effect
    (define t2 (run-hooks env (make-engine-view engine) t1*))
    (cond
      [(null? (transition-effects t2)) t2]
      [(>= round 8) t2]
      [else (loop t2 (add1 round))])))

;; 逐个事件：dispatch → settle → 再下一个。
;; 这样 open-doc 之后的事件能看到新 view，顺序不会被“先折状态、后跑 effect”打乱。
(define (process-events env engine inbox state events)
  (for/fold ([t (transition-pure state)]) ([e (in-list events)])
    (transition-bind
     t
     (λ (s)
       (define subject (subject-for engine s e))
       (define t1 (dispatch env s e
                            #:subject subject
                            #:engine (make-engine-view engine)))
       (settle env engine inbox t1)))))

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

;;; ════════════════ 首帧前的初始化 ════════════════

;; 宿主可能绕过 open-doc-effect 直接建文档（demo 常这样），那样就没有
;; `document-opened` 信号。这里在首帧前给每个已有文档补一次，并把 hook 产生的
;; effect 解释掉（语法高亮就靠它完成初次上色）。
;;
;; 暂定：只跑纯 / 引擎类 effect；startup hook 里不要 spawn / timer。
(define (startup! env engine state)
  (define dids
    (for/list ([(did dm) (in-hash (workspace-docs (state-workspace state)))]
               #:unless (doc-meta-internal? dm))
      did))
  (let loop ([state (for/fold ([s state]) ([did (in-list dids)])
                      (state-emit s 'document-opened (list did)))]
             [round 0])
    ;; run-hooks 的第二个参数是**只读 engine-view**（和命令的 ctx.engine 一样）
    (define s* (transition-state (settle env engine (make-async-channel) (transition-pure state))))
    (if (or (null? (signals-queue (state-signals s*))) (>= round 4))
        s*
        (loop s* (add1 round)))))

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
       (startup! env engine
                 (if (and rows cols (positive? rows) (positive? cols))
                     (state-set-window state (make-window rows cols))
                     state)))
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
