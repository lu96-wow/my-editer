#lang racket

;;; lab-re-rebuild/builtin/status.rkt —— 状态栏（bottom dock）。
;;;
;;; 「逻辑独立」：状态行文本怎么算全在本模块；kernel 只提供 dock 机制。
;;; 只经 document-api 读元数据（不 require document 实现）。
;;; 显示**活动编辑视图**（粘性 edit-vid）：名字 + 脏标记 + 行:列 + 路径。

(require racket/path
         "../kernel/api.rkt"
         "document-api.rkt")

(provide register-status! status-text)

(define (status-make root ed w h)
  (define-values (ed2 _did vid) (editor-add-document-view ed (document-open "") w 1 "*status*"))
  (values ed2 vid))

(define status-spec
  (dock-spec 'status 'bottom 1 #t status-make #f))

(define (status-text ctx)
  (define s (ctx-session ctx))
  (define ed (session-editor s))
  (define vid (session-edit-vid s))
  (cond
    [(not vid) " lab-re-rebuild"]
    [else
     (define did (editor-view-document-id ed vid))
     (define path (doc-path ctx did))
     (format " ~a~a  ~a:~a  ~a"
             (editor-document-name ed did)
             (if (doc-dirty? ctx did) " *" "")
             (add1 (editor-view-point-line ed vid))
             (add1 (editor-view-point-column ed vid))
             (if path (path->string path) "(untitled)"))]))

(define (status-hook ctx _args)
  (define vid (workspace-dock-vid (session-workspace (ctx-session ctx)) 'status))
  (if vid (list (e-reload vid (document-open (status-text ctx)))) '()))

(define (register-status! r)
  (for/fold ([r r])
            ([c (in-list (list (contrib 'dock 'status status-spec)
                               (contrib 'hook 'status (make-hook 'before-render status-hook))))])
    (reg-add r c)))
