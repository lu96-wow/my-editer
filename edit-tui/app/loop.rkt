#lang racket

;;; app/loop.rkt —— 事件循环（唯一不纯的模块）
;;;
;;;   read-event → 折叠（终端事件 + inbox 里的内部事件）→ 执行 intent → 重绘
;;;
;;; 这里是整条栈的“外壳”：只有它 require tui 的 read-event / put-bytes /
;;; with-tui，只有它起线程、持 inbox。step 完全不知道终端存在。
;;;
;;; 异步模型（暂定，但接口已为将来留好）：
;;;   · spawn  → 另起线程算，完成后把 (app-event 'task-done …) 塞进 inbox；
;;;   · 当前 inbox 只在“下一个终端事件到达时”排空（你确认过这没问题）；
;;;   · 将来要“立刻处理”，只需换掉下面的 (read-event) 那一句，让等待集合
;;;     也包含 inbox（或走 on-source），world-step / world-step* 一行都不用改。
;;;   · inbox 是 shell 的成员，不是 world 的字段 —— world 保持纯、可复制。
;;;
;;; 重绘节流：一批事件折叠完只画一次（world-dirty? 决定），画完清脏。
;;; 这就是 temp/21 里“每个 handler 手动 draw!”样板与“拖动时一 move 一画”的解。

(require tui
         racket/async-channel
         "world.rkt"
         "intent.rkt"
         "step.rkt"
         "render.rkt"
         "../../core/editor.rkt")

(provide run-app)

;;; ---------- intent 解释器（唯一执行副作用的地方） ----------
;;; 现在穿过 world：open-doc 需要在解释器里造 core 对象后，再用纯变换把 view 装进布局，
;;; 所以把 world 作为折叠值穿下去（其余 intent 原样返回 world）。
(define (run-intents! w intents inbox)
  (for/fold ([w w]) ([i (in-list intents)])
    (match i
      [(edit v op)    (buffer-edit! (view-buffer v) v op) w]
      [(select v sel) (view-set-selections! v sel) w]
      [(scroll v d)   (view-scroll! v d) w]
      [(spawn id thunk)
       (thread (λ ()
                 (define v (thunk))
                 (async-channel-put inbox (app-event 'task-done (list id v)))))
       w]
      [(post e)       (async-channel-put inbox e) w]
      [(invoke thunk) (thunk) w]
      [(open-doc make f)
       (define-values (b v) (make))     ; 不纯：造 document+view
       (f w b v)]                       ; 纯：装进布局 / 切焦点
      [(update _ _)   w]                ; 状态意图已在 step 折叠，这里恒不出现
      [_              w])))

(define (drain-channel ch)
  (let loop ([acc '()])
    (define v (async-channel-try-get ch))
    (if v (loop (cons v acc)) (reverse acc))))

;;; ---------- 主循环 ----------
(define (run-app w0)
  (with-tui
   (λ ()
     (cursor-hide)
     (enable-mouse!)
     (define inbox (make-async-channel))
     (let loop ([w w0] [cache #f])
       (define ev (read-event))
       ;; 异步/外部结果搭这一班车：与终端事件一起折叠。
       (define batch (cons ev (drain-channel inbox)))
       (define-values (w1 intents) (world-step* w batch))
       (define w2 (run-intents! w1 intents inbox))
       (define cache* (if (world-dirty? w2) (draw-world w2 cache) cache))
       (define w3 (mark-clean w2))
       (unless (world-running? w3)
         (loop w3 cache*))))))
