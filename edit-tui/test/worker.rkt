#lang racket

;;; edit-tui/test/worker.rkt —— 后台 worker（place / 多进程）
;;;
;;; 覆盖：
;;;   1. worker 起来之后，提交的 job 结果以 `job-done` internal 事件回到 inbox；
;;;   2. **顺序**：同一个 worker 的多个 job 按提交顺序返回（多插件协作的前提）；
;;;   3. payload / result 只需可跨 place 传递（vector / string / number / prefab face）；
;;;   4. 起不来时（这里用显式 #f 模拟）runtime 走同步内联，语义相同。

(require rackunit
         racket/async-channel
         "../base/event.rkt"
         "../base/effect.rkt"
         "../base/transition.rkt"
         "../base/signal.rkt"
         "../base/id.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/face-layer.rkt"
         "../effects/engine.rkt"
         "../effects/interpreter.rkt"
         "../dispatch/hooks.rkt"
         "../env/environment.rkt"
         "../env/hook.rkt"
         "../env/defaults.rkt"
         "../runtime/worker.rkt"
         "../runtime/run.rkt"
         "../base/face.rkt")

;;; ════════════════ 1-3. 真 worker：结果回来、顺序正确 ════════════════

(let ()
  (define inbox (make-async-channel))
  (define w (worker-start! inbox))
  (check-not-false w "place 起不来就没法测多进程；见下方内联降级用例")

  (when w
    ;; 提交两个 job：先语法（前景）后深度（背景）——正对应两个高亮插件
    (worker-submit! w 1 'syntax-fills (vector 'doc-1 "(define x 1)"))
    (worker-submit! w 2 'depth-fills (vector 'doc-1 "(a (b))"))

    (define ev1 (async-channel-get inbox))
    (define ev2 (async-channel-get inbox))

    ;; 顺序：先提交先回
    (check-equal? (internal-event-kind ev1) 'job-done)
    (check-equal? (car (internal-event-payload ev1)) 1)
    (check-equal? (internal-event-kind ev2) 'job-done)
    (check-equal? (car (internal-event-payload ev2)) 2)

    ;; 结果形状：value = (vector doc-id fills)；fills 里的 face 是 prefab，能跨 place
    (define v1 (cadr (internal-event-payload ev1)))
    (check-equal? (vector-ref v1 0) 'doc-1)
    (define fills1 (vector-ref v1 1))
    (check-true (pair? fills1))
    (check-equal? (face-fg (list-ref (car fills1) 4)) 'fg-syntax-def)

    (define v2 (cadr (internal-event-payload ev2)))
    (check-true (for/or ([f (in-list (vector-ref v2 1))])
                  (eq? (face-bg (list-ref f 4)) 'bg-depth-2)) "最内层括号 = 深度 2")

    (worker-stop! w)))

;;; ════════════════ 4. 没有 worker 时：runtime 同步内联 ════════════════

;; 用一个最小的 env + hook：提交一个 job，期望在 settle 里立刻拿到 job-done
(let ()
  (define did (doc-id 1))
  (define rid (region-id 1))
  (define engine (make-engine))
  (void (engine-create-doc! engine did "m" "(define x 1)"))
  (define ws0 (workspace-empty))
  (define ws1 (workspace-add-doc ws0 did (make-doc-meta "m" #:path "/tmp/m.rkt")))
  (define ws2 (workspace-add-region ws1 rid (region rid '() #f 'editor)))
  (define s0 (make-state #:workspace ws2))

  (define got (box #f))
  (define env
    (environment-add-hook
     (environment-add-hook default-environment
                           (make-hook 'job-done
                                      (λ (s ev args)
                                        (set-box! got (cadr args))
                                        (transition-pure s))))
     (make-hook 'after-edit
                (λ (s ev args)
                  (transition s (list (submit-service-effect
                                       7 'syntax-fills (vector (car args) "(define y 2)"))))))))

  ;; 手动跑一次 settle（worker = #f → 内联执行 → job-done 信号 → hook 在同一轮 settle 里跑）
  (define s1 (state-emit s0 'after-edit (list did)))
  (define t (settle env engine (make-async-channel) (transition-pure s1)))
  (define result (unbox got))
  (check-not-false result "内联降级也要回 job-done")
  (check-equal? (vector-ref result 0) did)
  (check-equal? (face-fg (list-ref (car (vector-ref result 1)) 4)) 'fg-syntax-def)
  ;; settle 结束时不残留信号
  (check-equal? (state-signals (transition-state t)) (signals-empty)))
