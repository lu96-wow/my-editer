#lang racket

;;; edit-tui-rebuild/test/hooks.rkt —— 信号 + 钩子
;;;
;;; 覆盖：
;;;   1. 信号队列：emit / take 的 FIFO 语义；
;;;   2. 同一 point 按 priority 降序，同 priority 按注册顺序；
;;;   3. hook 的 when 为假就跳过（when 拿 state / engine-view / args）；
;;;   4. hook 可以再 emit（多轮，直到队列空）；
;;;   5. 自激保护：A→A 的 hook 不会卡死，队列最终被清空；
;;;   6. effect 顺序：命令的 effect 在前，hook 的在后；
;;;   7. 焦点变化由 dispatch 记成 focus-changed 信号；hook 由 runtime 的 settle
;;;      （在 effect 解释之后）跑，所以这里用 process-events 走完整路径。

(require rackunit
         racket/async-channel
         "../base/id.rkt"
         "../base/signal.rkt"
         "../base/transition.rkt"
         "../base/effect.rkt"
         "../../edit-tui/command/key.rkt"
         "../../edit-tui/command/mouse.rkt"
         (prefix-in app: "../base/event.rkt")
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/layout.rkt"
         "../model/chrome.rkt"
         "../model/input.rkt"
         "../effects/engine.rkt"
         "../env/command.rkt"
         "../env/environment.rkt"
         "../env/hook.rkt"
         "../env/mode.rkt"
         "../env/defaults.rkt"
         "../dispatch/pipeline.rkt"
         "../dispatch/hooks.rkt"
         "../runtime/run.rkt")

;;; ════════════════ 夹具 ════════════════

(define did (doc-id 1))
(define vid (view-id 1))
(define vid2 (view-id 2))
(define rid (region-id 1))

(define (make-engine+state)
  (define engine (make-engine))
  (void (engine-create-doc! engine did "m" "abc\n"))
  (void (engine-create-view! engine vid did))
  (void (engine-create-view! engine vid2 did))
  (define ws
    (let* ([ws (workspace-empty)]
           [ws (workspace-add-doc ws did (make-doc-meta "m" #:path "/tmp/m"))]
           [ws (workspace-add-view ws vid (view-meta did (hash)))]
           [ws (workspace-add-view ws vid2 (view-meta did (hash)))]   ; detached，按需挂进 region
           [ws (workspace-add-region ws rid (region rid (list (view-member vid)) vid 'editor))])
      (struct-copy workspace ws [layout (make-leaf rid)])))
  (values engine (state-set-focus (make-state #:workspace ws #:ids (make-id-counter 2 3 2 1)) vid)))

;; hook 跑过的顺序记在 store 的一个槽里
(define (log-of s) (plugin-state s 'test-log '()))
(define (log-add s tag) (plugin-state* s 'test-log (λ (l) (append l (list tag))) '()))

(define (log-hook point tag
                  #:priority [priority 0]
                  #:when [when (λ (s ev args) #t)]
                  #:emit [emit #f])
  (make-hook point
             (λ (s ev args)
               (define s1 (log-add s tag))
               (transition-pure (if emit (state-emit s1 emit '()) s1)))
             #:priority priority
             #:when when))

(define (env-with hooks)
  (environment-merge
   default-environment
   (make-environment
    #:modes (hash 'text (make-mode #:fallback 'insert))
    #:hooks hooks)))

(define (run env s) (run-hooks env (make-engine+state-ignored) (transition-pure s)))
(define (make-engine+state-ignored) (make-engine))

;;; ════════════════ 1. 信号队列 ════════════════

(check-equal? (signals-queue (signals-empty)) '())
(define q1 (signals-add (signals-empty) (make-signal 'x 1)))
(check-equal? (signals-queue q1) (list (signal 'x 1)))
(define q2 (signals-add q1 (make-signal 'y 2)))
(check-equal? (map signal-point (signals-queue q2)) '(x y))     ; FIFO
(define-values (q3 taken) (signals-take q2))
(check-equal? (map signal-point taken) '(x y))
(check-equal? (signals-queue q3) '())

;;; ════════════════ 2. priority 降序 ════════════════

(let-values ([(engine s0) (make-engine+state)])
  (define env (env-with (list (log-hook 'a 'low #:priority 0)
                              (log-hook 'a 'high #:priority 10)
                              (log-hook 'a 'mid #:priority 5))))
  (define t (run-hooks env engine (transition-pure (state-emit s0 'a '()))))
  (check-equal? (log-of (transition-state t)) '(high mid low))
  (check-equal? (signals-queue (state-signals (transition-state t))) '()))

;;; ════════════════ 3. when 为假就跳过 ════════════════

(let-values ([(engine s0) (make-engine+state)])
  (define env (env-with (list (log-hook 'a 'skip #:when (λ (s ev args) #f))
                              (log-hook 'a 'run))))
  (define t (run-hooks env engine (transition-pure (state-emit s0 'a '()))))
  (check-equal? (log-of (transition-state t)) '(run)))

;;; ════════════════ 4. hook 再 emit：多轮 ════════════════

(let-values ([(engine s0) (make-engine+state)])
  (define env (env-with (list (log-hook 'a 'first #:emit 'b)
                              (log-hook 'b 'second))))
  (define t (run-hooks env engine (transition-pure (state-emit s0 'a '()))))
  (check-equal? (log-of (transition-state t)) '(first second)))

;;; ════════════════ 5. 自激保护 ════════════════

(let-values ([(engine s0) (make-engine+state)])
  (define env (env-with (list (log-hook 'a 'loop #:emit 'a))))
  (define t (run-hooks env engine (transition-pure (state-emit s0 'a '()))))
  (check-true (> (length (log-of (transition-state t))) 0))
  (check-equal? (signals-queue (state-signals (transition-state t))) '()))

;;; ════════════════ 6. effect 顺序 ════════════════

(let-values ([(engine s0) (make-engine+state)])
  (define env (env-with
               (list (make-hook 'after-edit
                                (λ (s ev args)
                                  (transition s (list (insert-text-effect vid "H"))))))))
  (define t (run-hooks env engine
                       (transition (state-emit s0 'after-edit (list did))
                                   (list (set-text-effect vid "C")))))
  (define es (transition-effects t))
  (check-equal? (length es) 2)
  (check-true (set-text-effect? (car es)))         ; 命令的 effect 在前
  (check-true (insert-text-effect? (cadr es)))     ; hook 的在后面
  (check-equal? (insert-text-effect-text (cadr es)) "H"))

;;; ════════════════ 6b. 什么算“一次编辑”：set-text / set-faces 不发 after-edit ════════════════

(require "../effects/interpreter.rkt"
         "../../core/text/base/point.rkt"
         "../../core/text/base/range.rkt")

(let-values ([(engine s0) (make-engine+state)])
  (define (signals-of effect)
    (signals-queue (state-signals (transition-state (interpret-effect! engine s0 effect)))))
  ;; 用户编辑 -> after-edit
  (check-not-false (for/first ([g (in-list (signals-of (insert-text-effect vid "x")))]
                               #:when (eq? (signal-point g) 'after-edit))
                     g))
  (check-not-false (for/first ([g (in-list (signals-of (replace-range-effect vid (range-of (point 0 0) (point 0 0)) "y")))]
                               #:when (eq? (signal-point g) 'after-edit))
                     g))
  ;; 整篇展示替换 / 上色 -> 不发 after-edit（否则面板 / 浮层写完就被自己的钩子触发）
  (check-false (for/first ([g (in-list (signals-of (set-text-effect vid "z")))]
                           #:when (eq? (signal-point g) 'after-edit))
                 g))
  (check-false (for/first ([g (in-list (signals-of (set-faces-effect did '())))]
                           #:when (eq? (signal-point g) 'after-edit))
                 g)))

;;; ════════════════ 7. 焦点变化自动发信号并跑 hook ════════════════

(let-values ([(engine s0) (make-engine+state)])
  (define env (env-with
               (list (make-hook 'focus-changed
                                (λ (s ev args)
                                  (transition-pure (plugin-state-set s 'focus-args args)))))))
  ;; vid2 挂进 rid 的成员表（active = vid2），焦点仍在 vid 上
  (define ws (workspace-attach-view (state-workspace s0) rid vid2))
  (define s1 (state-set-focus (state-set-workspace s0 ws) vid))
  (check-equal? (plugin-state s1 'focus-args 'none) 'none)

  (define inbox (make-async-channel))
  (define (feed s . evs)
    (transition-state (process-events env engine inbox s evs)))

  ;; C-x 是前缀，不改焦点 -> 不发信号
  (define s2 (feed s1 (app:key-event (key 'x 'ctrl))))
  (check-equal? (plugin-state s2 'focus-args 'none) 'none)

  ;; 鼠标 press 到 vid2（它已是该 region 的 active view）-> 焦点变化 -> hook 收到 (vid2)
  (define s3 (feed s1 (app:mouse-event (mouse 'press 'left) 1 1)))
  (check-equal? (state-focus s3) vid2)
  (check-equal? (plugin-state s3 'focus-args) (list vid2)))
