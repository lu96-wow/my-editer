#lang racket

;;; edit-rebuild/core/effect.rkt —— 动作 / 效果 + 宿主协议（纯数据）
;;;
;;; 旧 handler 只能返回 session | #f，表达不了「替换事件 / 再派发 / 广播 / 顺序组合」。
;;; 这里定义一小组结构化效果，派发器解释它们（见 dispatch.rkt）。
;;;
;;; 引擎**不认识具体状态**：所有读写都经 host 协议。于是这一层可以脱离编辑器单测。

(require "key.rkt"
         "scope.rkt")

(provide (struct-out addressed) (struct-out focus-to) (struct-out set-mode)
         (struct-out begin-prefix) (struct-out cancel-prefix)
         (struct-out forward) (struct-out broadcast) (struct-out seq-effect)
         (struct-out session-effect) (struct-out handler-effect)
         effect?
         (struct-out host))

;;; ---------- 效果 ----------

(struct addressed (target cmd) #:transparent)
;; 把 cmd 发往 target（不再隐含「作用于焦点」）。

(struct focus-to (target) #:transparent)
(struct set-mode (name val) #:transparent)
(struct begin-prefix (id) #:transparent)
(struct cancel-prefix () #:transparent)
(struct forward (value) #:transparent)
;; 用另一次**输入 / 命令 / 事件**替换当前事件，重新派发（“按键事件被替换”）。
;; value 类型决定重新进入哪个入口：input → dispatch；event → emit；其它 → execute。

(struct broadcast (targets cmd) #:transparent)
(struct seq-effect (effects) #:transparent)

(struct session-effect (proc) #:transparent)
;; 迁移用：动作是一个会话变换 proc : session -> (values session result)。
;; 让旧 handler 能以“命令路由 + 作用域 + 优先级”声明式挂上去，同时路由是数据。

(struct handler-effect (proc) #:transparent)
;; proc : session trigger -> (values session result)
;; 与 session-effect 类似，但把**触发它的命令**一并交给处理器（参数化命令用）。

(define (effect? x)
  (or (addressed? x) (focus-to? x) (set-mode? x) (begin-prefix? x)
      (cancel-prefix? x) (forward? x) (broadcast? x) (seq-effect? x)
      (session-effect? x) (handler-effect? x)))

;;; ---------- 宿主协议 ----------
;;;
;;; result = 'pass | 'handled | action/effect
;;;   'pass    没接住（继续下一条候选）
;;;   'handled 接住了
;;;   effect   接住了并请求一个结构化效果（如 forward / broadcast）

(struct host (make-context   ; st -> context
              run-command    ; st target cmd      -> (values st result)
              run-focus      ; st target          -> (values st result)
              run-mode       ; st name val        -> (values st result)
              run-prefix     ; st prefix|#f       -> (values st result)
              spec->action)  ; input spec         -> cmd/effect
  #:transparent)
