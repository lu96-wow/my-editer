#lang racket

;;; base/signal.rkt —— 信号（纯值）：命令 / 效果“发生过什么”的通知
;;;
;;; layer  : base
;;; effect : 无（纯值）
;;;
;;; 信号 = (point . args)，point 是固定的词表，args 是该点的数据。
;;; 它只描述“发生了什么”，不描述“谁应该做什么”——那是 env/hook.rkt 的 hook 表。
;;;
;;; 约定：
;;;   · 信号进 state.signals（FIFO 队列），由 dispatch/hooks.rkt 排空；
;;;   · hook 可以再 emit，排空过程是“跑一轮 -> 有新信号 -> 再跑一轮”；
;;;   · 信号是**纯数据**，所以整个 hook 链可以 headless 重放。
;;;
;;; 词表见 standard-signal-points（下面的 define）。
;;;
;;; 两条约定：
;;;   · **没有** "after-faces"：上色本身不发 after-edit，否则 hook 会自激；
;;;   · `set-text-effect`（整篇展示替换）**不算编辑**，不发 after-edit
;;;     —— 见 effects/interpreter.rkt 的 edit-write?。

(provide (struct-out signal)
         (struct-out signals)
         make-signal
         standard-signal-points
         known-signal-point?
         signals-empty
         signals-add
         signals-take)

;; 标准信号点（词表）。扩展点仍是开放的 symbol：插件可以定义自己的 point，
;; 但**框架发出的**只有下面这些 —— 写在数据里，测试和文档都引用它。
(define standard-signal-points
  '(document-opened   ; (doc-id)                    打开文档完成（engine 已就绪）
    after-edit        ; (doc-id changes)              用户改了文本（insert / edit / undo / redo / replace-range）
    after-nav         ; (view-id)                   光标推进（没改文本）
    focus-changed     ; (view-id|region-id|#f)      焦点变了
    job-done          ; (job-id value)              spawn 的结果回来了（internal 事件）
    tick))            ; (tick-id)                   定时事件

;; 其余点由宿主 / 插件自己定义（`post` 的 internal 事件名就是 point），这个表只是
;; “框架一定会发的那几个”，便于测试与文档引用。

(define (known-signal-point? p) (and (memq p standard-signal-points) #t))

(struct signal (point args) #:transparent)
;; point : symbol（标准点见 standard-signal-points；插件可自定义）
;; args  : any/c

(define (make-signal point args)
  (unless (symbol? point) (error 'make-signal "point 要是 symbol：~a" point))
  (signal point args))

;; 队列：FIFO（先发生的先跑）
(struct signals (queue) #:transparent)

(define (signals-empty) (signals '()))

;; 追加一个信号
(define (signals-add s sig) (signals (append (signals-queue s) (list sig))))

;; 取走全部信号（保持顺序），队列清空
(define (signals-take s) (values (signals '()) (signals-queue s)))
