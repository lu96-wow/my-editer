#lang racket

;;; lab-rebuild/builtin/document.rkt —— 文档/文件逻辑：打开、保存、脏标记。
;;;
;;; 文件 I/O 与路径登记在这里（不再在 kernel）。kernel 只提供 e-doc-add / e-doc-show
;;; 这类「装文档 / 显示文档」原语；本模块负责读盘、去重、登记路径、写盘。
;;;
;;; 打开：e-file-open 处理器（去重 → 读盘 → e-doc-add → document-opened 钩子登记路径）。
;;; 保存：save 命令（写盘）+ e-notify 'document-saved 清脏。

(require racket/file
         racket/path
         "../kernel/api.rkt"
         "document-api.rkt")

(provide register-document! e-file-open)

;; 打开一个文件路径（placement/focus? 与 e-doc-show 一致）。特性发这个 effect。
(define (e-file-open path placement focus?) (fx 'file-open path placement focus?))

(define (basename p)
  (path->string (or (file-name-from-path (path->complete-path p)) p)))

(define (pending-box ctx) (service-ref ctx 'pending-path))
(define (pending-init ctx) (service-put ctx 'pending-path (box #f)))

(define (document-init ctx) (doc-init! ctx))

;; ----- after-edit → 脏 -----
(define (edit-hook ctx args)
  (match-define (list vid _changes) args)
  (doc-mark-dirty! ctx (editor-view-document-id (session-editor (ctx-session ctx)) vid))
  '())

;; ----- document-opened：新开文件（pending 有值）才登记路径 + 清脏 -----
(define (opened-hook ctx args)
  (define did (car args))
  (define b (pending-box ctx))
  (when (and b (unbox b))
    (doc-set-path! ctx did (unbox b))
    (doc-clear-dirty! ctx did)
    (set-box! b #f))
  '())

;; ----- document-saved → 清脏 -----
(define (saved-hook ctx args)
  (doc-clear-dirty! ctx (car args))
  '())

;; ----- document-closed → 摘路径 -----
(define (closed-hook ctx args)
  (doc-remove! ctx (car args))
  '())

;; ----- 打开：去重 + 读盘 -----
(define (apply-file-open ctx path placement focus?)
  (define np (simplify-path (path->complete-path path)))
  (define existing (doc-did-for-path ctx np))
  (cond
    [existing (apply-effect ctx (e-doc-show existing placement focus?))]
    [else
     (set-box! (pending-box ctx) np)
     (apply-effect ctx (e-doc-add (if (file-exists? np) (file->string np) "")
                                  (basename np) placement focus?))]))

;; ----- 保存（effect 'save：写盘 → 清脏） -----
(define (apply-save ctx did)
  (define s (ctx-session ctx))
  (define path (doc-path ctx did))
  (cond
    [(not path) ctx]                       ; 没路径：暂不实现「另存为」
    [else
     (call-with-output-file path #:exists 'replace
       (lambda (out) (display (editor-document-string (session-editor s) did) out)))
     (apply-effect ctx (e-notify 'document-saved (list did)))]))

;; ----- 保存命令 -----
(define (cmd-save ctx ev)
  (define s (ctx-session ctx))
  (define vid (session-edit-vid s))
  (if vid (list (e-save (editor-view-document-id (session-editor s) vid))) '()))

(define (cmd-find-file ctx ev)
  (list (e-prompt "find file: "
                  (λ (p) (if (positive? (string-length p))
                             (list (e-file-open p 'replace #t))
                             '())))))

(define (register-document! r)
  (for/fold ([r r])
            ([c (in-list (list (contrib 'init 'document document-init)
                               (contrib 'init 'pending pending-init)
                               (contrib 'effect 'file-open apply-file-open)
                               (contrib 'effect 'save apply-save)
                               (contrib 'hook 'document-dirty (make-hook 'after-edit edit-hook))
                               (contrib 'hook 'document-opened (make-hook 'document-opened opened-hook))
                               (contrib 'hook 'document-saved (make-hook 'document-saved saved-hook))
                               (contrib 'hook 'document-closed (make-hook 'document-closed closed-hook))
                               (contrib 'command 'save cmd-save)
                               (contrib 'command 'find-file cmd-find-file)))])
    (reg-add r c)))
