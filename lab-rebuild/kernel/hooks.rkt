#lang racket

;;; lab-rebuild/kernel/hooks.rkt —— 生命周期通知。
;;;
;;; hook 是 registry 里 kind='hook 的贡献；proc : (Ctx args) -> (listof effect)。
;;; run-hooks 只收集 effects；施加由 pipeline.run-notify 负责（保持唯一写入点）。
;;; run-hooks-first 是**拦截型**：首个插手的 hook 赢（返回 #f 表示不插手）。

(require "registry.rkt" "runtime.rkt")

(provide (struct-out hook) make-hook run-hooks run-hooks-first)

(struct hook (point proc) #:transparent)
(define (make-hook point proc) (hook point proc))

(define (run-hooks ctx point args)
  (append*
   (for/list ([c (in-list (reg-kind (runtime-registry (ctx-runtime ctx)) 'hook))]
              #:when (eq? point (hook-point (contrib-value c))))
     ((hook-proc (contrib-value c)) ctx args))))

;; 首个非 #f 的 hook 结果（拦截型：「第一个插手的赢」）。
;; '() 是合法结果（插手但不产 effect）且为真值；只有 #f 表示不插手。
(define (run-hooks-first ctx point args)
  (for/or ([c (in-list (reg-kind (runtime-registry (ctx-runtime ctx)) 'hook))]
           #:when (eq? point (hook-point (contrib-value c))))
    (define r ((hook-proc (contrib-value c)) ctx args))
    (and r r)))
