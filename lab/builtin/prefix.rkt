#lang racket

;;; lab-rebuild/builtin/prefix.rkt —— 前缀键（layer 栈）。
;;;
;;; 前缀 = 一个 layer：capture='all'（屏下所有表）、pop='next'（按任意下一键退出）。
;;; 键序列 = 嵌套 push（表里再给一个 prefix 命令描述）。
;;; 状态就是 label + 本层键表（+ 用途 kind）。

(require "../kernel/effect.rkt"
         "../kernel/layer.rkt"
         "../kernel/session.rkt"
         "../kernel/runtime.rkt"
         "../kernel/registry.rkt")

(provide register-prefix! e-prefix (struct-out prefix) active-prefix-label)

(struct prefix (label tables kind) #:transparent)

(define (e-prefix label tables [kind #f])
  (e-input-push 'prefix (prefix label tables kind)))

(define prefix-layer
  (make-layer 'prefix
              #:tables (λ (ctx inst) (prefix-tables (layer-inst-state inst)))
              #:capture 'all
              #:pop 'next))

(define (active-prefix-label ctx)
  (define inst (input-find (session-input (ctx-session ctx)) 'prefix))
  (and inst (prefix-label (layer-inst-state inst))))

;; label + 命名表名（如 'focus）→ 前缀层；表在 session.named 里查。
(define (cmd-prefix ctx ev label table-name [kind #f])
  (define t (hash-ref (session-named (ctx-session ctx)) table-name #f))
  (list (e-prefix label (if t (list t) '()) kind)))

(define (register-prefix! r)
  (reg-add
   (reg-add r (contrib 'layer-spec 'prefix 0 prefix-layer))
   (contrib 'command 'prefix 0 cmd-prefix)))
