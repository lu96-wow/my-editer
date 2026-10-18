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
;;   · inbox 通过 racket-tui 的 `on-source` 并进 `read-event` 的等待集合：后台结果
;;;     一到就唤醒回调，处理 + 重绘都在回调里完成（不用等下一次按键）。
;;;   · 效果刚 emit 的事件会在本批次结束时再排空一次。
;;;   · 渲染缓存由 loop / 回调共享的 box 持有；State 不存 cache / inbox / 线程。
;;;
;;; 事件循环 / resize / on-source 的特殊约束见 CONSTRAINTS.md §7。

(provide run-app
         run-frame
         process-events
         startup!
         settle)

(require tui
         racket/async-channel
         "../base/signal.rkt"
         "../dispatch/hooks.rkt"
         (prefix-in app: "../base/event.rkt")
         "../base/effect.rkt"
         "../base/transition.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/chrome.rkt"
         "../model/face-decor.rkt"
         "../effects/engine.rkt"
         "../effects/interpreter.rkt"
         "../env/environment.rkt"
         "../dispatch/pipeline.rkt"
         "../chrome/slot.rkt"
         "../projection/geometry.rkt"
         "../projection/float.rkt"
         "../projection/render.rkt"
         "tui-adapter.rkt"
         "worker.rkt")

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
                               #:when (equal? (region-member-key m) active))
                     (and (view-region-member? m) (region-member-key m)))
                   (region-key reg))))])]
    [(paste) (state-focus state)]
    [else #f]))

;; 打开 / 创建文档后，把 env 里适用该文档的增量 decor 挂到 engine。
;; 幂等：已挂过的 doc 不重复 open。
(define (ensure-doc-decors! env engine state)
  (for ([(did dm) (in-hash (workspace-docs (state-workspace state)))]
        #:unless (doc-meta-internal? dm))
    (unless (engine-decors-attached? engine did)
      (define decors
        (for/list ([d (in-list (environment-decors env))]
                   #:when ((face-decor-applies? d) dm))
          d))
      (engine-attach-decors! engine did decors (doc-meta-path dm)))))

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
(define (settle env engine inbox t #:worker [worker #f])
  (let loop ([t t] [round 0])
    ;; 1. 解释 effect（会 emit 信号，engine 已经落盘）
    (define t1 (run-transition-effects engine t inbox #:worker worker))
    ;; 新文档：在 hook 跑之前挂上 decor（open 整篇 + 写回 face）。
    (ensure-doc-decors! env engine (transition-state t1))
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
(define (process-events env engine inbox state events #:worker [worker #f])
  (for/fold ([t (transition-pure state)]) ([e (in-list events)])
    (transition-bind
     t
     (λ (s)
       (define subject (subject-for engine s e))
       (define t1 (dispatch env s e
                            #:subject subject
                            #:engine (make-engine-view engine)))
       (settle env engine inbox t1 #:worker worker)))))

;; 本批次里 emit 出来的事件也处理掉；spawn/timer 若已就绪也会被带出来。
(define (drain-and-process env engine inbox t #:worker [worker #f])
  (let loop ([t t])
    (define evs (drain-channel inbox))
    (if (null? evs)
        t
        (loop (transition-bind t
                               (λ (s)
                                 (process-events env engine inbox s evs #:worker worker)))))))

;;; ════════════════ effect 解释 ════════════════

(define (run-transition-effects engine t inbox #:worker [worker #f])
  (for/fold ([t2 (transition-pure (transition-state t))])
            ([e (in-list (transition-effects t))])
    (transition-bind t2
                     (λ (s)
                       (define t1 (run-one-effect engine s e inbox #:worker worker))
                       ;; effect 解释时可能产生新 effect（read-file -> open-doc），递归跑完。
                       (run-transition-effects engine t1 inbox #:worker worker)))))

(define (run-one-effect engine state effect inbox #:worker [worker #f])
  (cond
    ;; 纯计算交给后台（独立进程）；结果以 job-done 信号回来。
    ;; 没有 worker（place 起不来）→ 同步内联，语义相同、只是不换进程。
    [(or (submit-service-effect? effect) (query-effect? effect))
     (define job (if (query-effect? effect)
                     (query-effect-job effect)
                     (submit-service-effect-job effect)))
     (define kind (if (query-effect? effect)
                      (query-effect-kind effect)
                      (submit-service-effect-kind effect)))
     (define payload (if (query-effect? effect)
                         (query-effect-payload effect)
                         (submit-service-effect-payload effect)))
     (cond
       [worker (worker-submit! worker job kind payload) (transition-pure state)]
       [else
        (define result (inline-service-run kind payload))
        (transition-pure (state-emit state 'job-done (list job result)))])]

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

;;; ════════════════ 后台服务（无 worker 时的同步降级） ════════════════

;; 懒加载 plugins/worker.rkt 的 service-run（同一个纯函数，同一个分派表）
(define inline-service-run
  (let ([run #f])
    (λ (kind payload)
      (unless run (set! run (dynamic-require (string->path (worker-entry-path)) 'service-run)))
      (run kind payload))))

;;; ════════════════ inbox ════════════════

(define (drain-channel ch)
  (let loop ([acc '()])
    (define v (async-channel-try-get ch))
    (if v (loop (cons v acc)) (reverse acc))))

;;; ════════════════ 首帧前的初始化 ════════════════

;; 宿主可能绕过 open-doc-effect 直接建文档（demo 常这样），那样就没有
;; `document-opened` 信号。这里在首帧前给每个已有文档补一次，并把 hook 产生的
;; effect 解释掉（decor 也会在 settle 里按 doc-meta 挂上）。
;;
;; 暂定：只跑纯 / 引擎类 effect；startup hook 里不要 spawn / timer。
(define (ensure-service-kinds! env)
  (define declared (environment-service-kinds env))
  (unless (null? declared)
    (define known (worker-known-service-kinds))
    (for ([k (in-list declared)] #:unless (memq k known))
      (error 'startup! "service kind 未在 worker 实现：~a（可用：~a）" k known))))

(define (startup! env engine state #:worker [worker #f])
  ;; 插件声明的 service kind 必须能在 worker 里找到实现。
  (ensure-service-kinds! env)
  ;; face 层序是 env 数据：启动时交给引擎（引擎负责合成 / 写回 core）
  (engine-set-face-layers! engine (environment-face-layers env))
  (define dids
    (for/list ([(did dm) (in-hash (workspace-docs (state-workspace state)))]
               #:unless (doc-meta-internal? dm))
      did))
  (let loop ([state (for/fold ([s state]) ([did (in-list dids)])
                      (state-emit s 'document-opened (list did)))]
             [round 0])
    ;; run-hooks 的第二个参数是**只读 engine-view**（和命令的 ctx.engine 一样）
    (define s* (transition-state (settle env engine (make-async-channel)
                                         (transition-pure state) #:worker worker)))
    (if (or (null? (signals-queue (state-signals s*))) (>= round 4))
        s*
        (loop s* (add1 round)))))

;;; ════════════════ 渲染 ════════════════

;; 每帧同步：这是**唯一**写 core 的时机（面板文本 / 状态栏文本 / 光标 decor）。
;;
;;   (frame-syncs env state) = 插件注册的同步器 + 框架自己的
;;
;; 框架自己的只有状态栏，而且是否装由 State 决定（chrome.slot-info 是安装时写下的事实），
;; runtime 不认识任何具体面板名；要加一个新的“每帧投影到 view”的东西，
;; 走 environment-add-panel-sync（插件）或往 state-frame-syncs 里加（框架）。
;; 框架自带的每帧同步器：签名与插件的一致（state engine -> any），
;; 需要的额外参数（status 段）在这里闭包住。
(define (state-frame-syncs state [status-parts #f])
  (if (chrome-slot-info (state-chrome state))
      (list (λ (s e) (sync-chrome! s e status-parts)))
      '()))

(define (run-frame env state engine cache #:status-parts [status-parts #f])
  (for ([sync (in-list (append (environment-panel-syncs env)
                               (state-frame-syncs state status-parts)))])
    (sync state engine))
  ;; 光标相关 decor（同词高亮等）：每帧对焦点 view 推进一次；光标没变时是 no-op。
  (engine-paint-advance! engine (state-focus state))
  ;; 一帧只投影一次：panels 交给 render-frame*，placements 交给 engine-sync-views!。
  (define-values (panels placements) (project-frame state engine))
  (engine-sync-views! engine placements)
  (define-values (cache* bytes) (render-frame* state engine cache panels))
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
     ;; 一个 place = 一条队列：同一时刻只跑一个 job，按提交顺序执行
     (define worker (worker-start! inbox))
     ;; 用真实终端尺寸初始化；拿不到就保留传入的 State.window。
     (define-values (rows cols) (get-window-size))
     (define state0
       (startup! env engine
                 (if (and rows cols (positive? rows) (positive? cols))
                     (state-set-window state (make-window rows cols))
                     state)
                 #:worker worker))

     ;; CONSTRAINT: 后台结果要能自己唤醒重绘；回调里不能再 read-event（CONSTRAINTS §7）。
     ;; 后台结果（worker job-done / 文档查询 / 补全模块导出）要能自己唤醒重绘。
     ;; racket-tui 的 on-source 把 inbox 并进 read-event 的等待集合；read-event 处理完源
     ;; 事件后继续等终端事件，所以处理 + 重绘放在回调里，用 box 共享 state / cache。
     (define state-box (box state0))
     (define cache-box (box #f))
     (define (render! s)
       (set-box! cache-box
                 (run-frame env s engine (unbox cache-box)
                            #:status-parts (environment-status env))))
     (define (handle! events)
       (cond
         [(null? events) (void)]
         [else
          ;; resize 会改变终端网格：丢掉上一帧 cache，让 render-frame 先清一次屏再全量重画。
          (when (for/or ([e (in-list events)]) (app:resize-event? e))
            (set-box! cache-box #f))
          (define t (process-events env engine inbox (unbox state-box) events
                                    #:worker worker))
          (define t2 (drain-and-process env engine inbox t #:worker worker))
          (define s (transition-state t2))
          (set-box! state-box s)
          (render! s)]))
     (on-source inbox (λ (_ready) (handle! (drain-channel inbox))))

     (let loop ()
       (render! (unbox state-box))
       (define ev (read-event))
       (handle! (filter values (list (tui-event->app ev))))
       (if (runtime-quit? (state-runtime (unbox state-box)))
           (worker-stop! worker)
           (loop))))))
