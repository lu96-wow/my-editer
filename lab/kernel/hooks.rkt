#lang racket

;;; lab-rebuild/kernel/hooks.rkt —— 生命周期通知。
;;;
;;; hook 是 registry 里 kind='hook 的贡献；`name` 必须唯一（否则同点多个 hook 会
;;; 互相 upsert），hook 点放在 value 里。
;;;   hook : (struct hook (point proc))
;;;   proc : (Ctx args) -> (listof effect)
;;; run-hooks 只收集 effects，施加由 pipeline 负责（保持"唯一写入点"）。

(require "registry.rkt" "runtime.rkt")

(provide (struct-out hook) make-hook run-hooks run-hooks-first)

(struct hook (point proc) #:transparent)
(define (make-hook point proc) (hook point proc))

(define (run-hooks ctx point args)
  (define reg (runtime-registry (ctx-runtime ctx)))
  (append* (for/list ([c (in-list (reg-kind reg 'hook))]
                      #:when (eq? point (hook-point (contrib-value c))))
             ((hook-proc (contrib-value c)) ctx args))))

;; 首个非 #f 的 hook 结果（拦截型：「第一个插手的赢」）。
;; '() 是合法结果（插手但不产 effect）且为真值；只有 #f 表示不插手。
(define (run-hooks-first ctx point args)
  (define reg (runtime-registry (ctx-runtime ctx)))
  (for/or ([c (in-list (reg-kind reg 'hook))]
           #:when (eq? point (hook-point (contrib-value c))))
    (define r ((hook-proc (contrib-value c)) ctx args))
    (and r r)))
