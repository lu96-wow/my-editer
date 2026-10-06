#lang racket

;;; lab-rebuild/builtin/policy.rkt —— 跨切面策略（功能包）。
;;;
;;;   undo-merge  : after 变换 —— 连续打字合并成一步撤销
;;;   quit-confirm: before + Interaction —— 有未保存文档时先询问（挂起 / 续做）
;;;
;;; 两者都是"策略"，不写在命令里。

(require racket/file
         racket/string
         racket/path
         "../kernel/editor-api.rkt"
         "../kernel/action.rkt"
         "../kernel/effect.rkt"
         "../kernel/policy.rkt"
         "../kernel/session.rkt"
         "../kernel/runtime.rkt"
         "../kernel/paths.rkt"
         "../kernel/registry.rkt"
         "prompt.rkt")

(provide register-policies!)

;;; ================= 撤销合并 =================

(define (break-text? s)
  (for/or ([ch (in-string s)]) (char-whitespace? ch)))

(define undo-merge-policy
  (policy-new 'undo-merge 10 'after
              (λ (ctx a) (eq? (action-name a) 'insert))
              (λ (ctx a effs)
                (for/list ([e (in-list effs)])
                  (if (eq? (effect-tag e) 'type)
                      (let* ([args (effect-args e)]
                             [text (list-ref args 1)])
                        (e-type (list-ref args 0) text (if (break-text? text) #f 'lab-typing)))
                      e)))))

;;; ================= 退出前保存确认（Interaction） =================

;; 有路径、且内容与磁盘不一致的 did。
(define (modified-dids ctx)
  (define s (ctx-session ctx))
  (define ed (session-editor s))
  (for/list ([did (in-list (editor-document-id-list ed))]
             #:when (let ([p (path-table-path (session-paths s) did)])
                      (and p (file-exists? p)
                           (not (string=? (editor-document-string ed did)
                                          (with-handlers ([exn? (λ (_) "")])
                                            (file->string p)))))))
    did))

(define (doc-name ctx did)
  (define s (ctx-session ctx))
  (define p (path-table-path (session-paths s) did))
  (if p (path->string p) (editor-document-name (session-editor s) did)))

;; pending : 还没问的 did（第一个就是当前在问的）。
(define (ask-next ctx sid pending)
  (cond
    [(null? pending) (list (e-interaction-end sid) (e-quit))]
    [else
     (define did (car pending))
     (list (e-prompt (format "save ~a? (y/n/all/esc) " (doc-name ctx did)) #t
                     (λ (ans) (list (e-resume sid (list pending ans))))
                     (λ () (list (e-interaction-end sid)))))]))

(define (save-step ctx sid resp)
  (match-define (list pending ans) resp)
  (define a (string-downcase (string-trim ans)))
  (cond
    [(member a '("all" "a"))
     (append (for/list ([d (in-list pending)]) (e-save d))
             (list (e-interaction-end sid) (e-quit)))]
    [(member a '("" "y" "yes"))
     (append (list (e-save (car pending))) (ask-next ctx sid (cdr pending)))]
    [else (ask-next ctx sid (cdr pending))]))

(define quit-confirm-policy
  (policy-new 'quit-confirm 100 'before
              (λ (ctx a) (eq? (action-name a) 'quit))
              (λ (ctx a)
                (define mods (modified-dids ctx))
                (if (null? mods)
                    'pass
                    (interaction-new (λ (ctx sid) (ask-next ctx sid mods))
                                     (λ (ctx sid resp) (save-step ctx sid resp)))))))

;;; ================= 注册 =================

(define (register-policies! r)
  (reg-add (reg-add r (contrib 'policy 'undo-merge 10 undo-merge-policy))
           (contrib 'policy 'quit-confirm 100 quit-confirm-policy)))
