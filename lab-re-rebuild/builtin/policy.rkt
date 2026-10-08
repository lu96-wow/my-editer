#lang racket

;;; lab-re-rebuild/builtin/policy.rkt —— 跨切面策略（功能包）。
;;;
;;;   undo-merge  : after 变换 —— 连续打字合并成一步撤销，遇空白断开
;;;   quit-confirm: before 门控 —— 有未保存文档时先询问（走 e-prompt）
;;;
;;; 两者都是「策略」，不写进命令。只 require kernel/api 与 document-api（接口），
;;; 询问走 e-prompt（effect），不 require prompt 实现。

(require racket/string
         racket/path
         racket/file
         "../kernel/api.rkt"
         "document-api.rkt")

(provide register-policies!)

;;; ================= 撤销合并 =================

(define (break-text? s)
  (for/or ([ch (in-string s)]) (char-whitespace? ch)))

;; 连续插入若不含空白 → 打上 'lab-typing（与上一步合并）；含空白 → #f（断一步）。
(define undo-merge-policy
  (policy-new 'undo-merge 'after
              (lambda (ctx a) (eq? (action-name a) 'insert))
              (lambda (ctx a effs)
                (for/list ([e (in-list effs)])
                  (if (eq? (effect-tag e) 'type)
                      (let* ([args (effect-args e)]
                             [text (list-ref args 1)])
                        (e-type (list-ref args 0) text (if (break-text? text) #f 'lab-typing)))
                      e)))))

;;; ================= 退出前保存确认 =================

;; 有路径、且内容与磁盘不一致的 did。
(define (modified-dids ctx)
  (define s (ctx-session ctx))
  (define ed (session-editor s))
  (for/list ([did (in-list (editor-document-id-list ed))]
             #:when (let ([p (doc-path ctx did)])
                      (and p (file-exists? p)
                           (not (string=? (editor-document-string ed did)
                                          (with-handlers ([exn? (lambda (_) "")])
                                            (file->string p)))))))
    did))

(define quit-confirm-policy
  (policy-new 'quit-confirm 'before
              (lambda (ctx a) (eq? (action-name a) 'quit))
              (lambda (ctx a)
                (define mods (modified-dids ctx))
                (cond
                  [(null? mods) 'pass]
                  [else
                   (list (e-prompt
                          (format "unsaved changes (~a); save all? (y/n) " (length mods))
                          (lambda (ans)
                            (define a* (string-downcase (string-trim ans)))
                            (cond
                              [(member a* '("y" "yes"))
                               (append (for/list ([d (in-list mods)]) (e-save d))
                                       (list e-quit))]
                              [(member a* '("n" "no")) (list e-quit)]
                              [else '()]))))]))))

;;; ================= 注册 =================

(define (register-policies! r)
  (reg-add (reg-add r (contrib 'policy 'undo-merge undo-merge-policy))
           (contrib 'policy 'quit-confirm quit-confirm-policy)))
