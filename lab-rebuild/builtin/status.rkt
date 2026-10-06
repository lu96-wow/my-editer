#lang racket

;;; lab-rebuild/builtin/status.rkt —— 状态行（before-render 钩子 + slot 内容）。
;;;
;;; 演示：装饰内容由 hook 产出 effect（reload）写回 slot 视图，而不是 render 里硬编码。

(require "../kernel/editor-api.rkt"
         "../kernel/effect.rkt"
         "../kernel/session.rkt"
         "../kernel/runtime.rkt"
         "../kernel/hooks.rkt"
         "../kernel/registry.rkt"
         "prefix.rkt")

(provide register-status! status-text)

(define (status-text ctx)
  (define s (ctx-session ctx))
  (define ed (session-editor s))
  (define vid (session-focus-vid s))
  (define base
    (cond
      [(not vid) " lab-rebuild"]
      [else
       (define did (editor-view-document-id ed vid))
       (format " edit  ~a:~a  ~a"
               (add1 (editor-view-point-line ed vid))
               (add1 (editor-view-point-column ed vid))
               (editor-document-name ed did))]))
  (define pl (active-prefix-label ctx))
  (if pl (format "~a  [~a-]" base pl) base))

(define (status-hook ctx _args)
  (define s (ctx-session ctx))
  (list (e-reload (session-status-vid s) (document-open (status-text ctx)))))

(define (register-status! r)
  (reg-add r (contrib 'hook 'status 0 (make-hook 'before-render status-hook))))
