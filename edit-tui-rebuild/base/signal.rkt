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
;;; 词表（暂定，够三个插件用）：
;;;
;;;   document-opened  (list doc-id)          打开文档完成（engine 已就绪）
;;;   after-edit       (list doc-id)          文档文本被改（插入 / 删除 / 替换 / undo）
;;;   after-nav        (list view-id)         光标推进（没有改文本）
;;;   focus-changed    (list view-id|region-id|#f)
;;;   interact         (list view-id)         用户刚按了一个命令键（给补全/文档消隐用）
;;;
;;; 注意：**没有** "after-faces" —— 上色本身不发 after-edit，否则 hook 会自激。

(provide (struct-out signal)
         (struct-out signals)
         make-signal
         signals-empty
         signals-add
         signals-take)

(struct signal (point args) #:transparent)
;; point : symbol
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
