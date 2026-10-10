#lang racket

;;; edit-rebuild/plugins/ui/document.rkt —— 文档 / 文件特征：打开 / 保存 + 脏
;;;
;;; 裸文件系统 I/O 在 fs.rkt，路径工具在 path.rkt；本层只编排会话：
;;;   打开：去重 → 读盘 → add-document → 分屏放置 → 记 path → 默认命令表 → 规则层 → 记 saved
;;;   保存：写盘 → 记 saved 句柄
;;; 脏由 session-dirty? 从句柄身份派生；文件映射走 session-set-file。
;;;
;;; 自带 command keys（document-keys）与 handler；关闭 / 退出策略在 lifecycle.rkt。
;;; 默认命令表由 assembly 注入（document-handler 的参数）。

(require racket/string
         "../../core/session/session.rkt"
         "../../core/session/adapter.rkt"
         "../../core/session/structure.rkt"
         "../../core/session/prompt.rkt"
         "../../core/session/panel.rkt"
         "../../core/session/bottom.rkt"
         "../../core/command/command.rkt"
         "../../core/command/key.rkt"
         "../../core/command/tables.rkt"
         "../../core/extension/spec.rkt"
         "../../core/keymap.rkt"
         "../../core/path.rkt"
         "../../core/document/fs.rkt"
         "../../core/document/rules.rkt")

(provide document-spec session-open-file session-save
         session-new-file session-new-dir session-delete-path
         document-handler document-keys
         (struct-out cmd-save) (struct-out cmd-open-file) (struct-out cmd-open-file-path))

;; 资源操作出错 → 记日志（prompt 进行中只追加不弹）。
(define (session-error! s what path e)
  (session-log! s (format "~a ~a: ~a" what path (exn-message e))))

;;; ---------- 打开 ----------

(define (session-open-file s path [rules (session-rules s)] [axis 'lr]
                           #:keys [keys edit-keys])
  (with-handlers ([exn:fail? (lambda (e) (session-error! s "open" path e))])
   (define np (normalize path))
   (define existing (session-file-did s np))
   (cond
     [existing
      (define vs (session-view-ids-of s existing))
      (if (pair? vs) (session-show-view s (first vs)) s)]
     [else
      (define text (fs-read-file np))
      (define-values (s1 did nvid) (session-add-document s text 40 18 #:name (basename np)
                                                         #:line-numbers? #t))
      (define base (session-edit-vid s1))
      (define s2 (if (eqv? base nvid) s1 (session-place-view s1 base axis nvid)))
      (define s3 (session-set-file s2 did np))
      (define s4 (session-set-doc-keymap s3 did keys))
      (define s5 (rules-apply rules s4 did np))
      (define s6 (session-mark-saved s5 did))
      (session-show-view s6 nvid)])))

;;; ---------- 保存 ----------

(define (session-save s [did #f])
  (with-handlers ([exn:fail? (lambda (e) (session-error! s "save" (and did (session-file-path s did)) e))])
   (define d (or did (let ([v (session-edit-vid s)]) (and v (session-view-did s v)))))
   (cond
     [(not d) s]
     [else
      (define path (session-file-path s d))
      (cond
        [(not path) s]
        [else
         (fs-write-file path (session-document-string s d))
         (session-mark-saved s d)])])))

;;; ---------- 文件操作（tree 的新建 / 删除） ----------

(define (session-new-file s dir name)
  (with-handlers ([exn:fail? (lambda (e) (values (session-error! s "new file" (join dir name) e) #f))])
   (define p (join dir name))
   (cond
     [(fs-path-kind p) (values (session-log! s (format "new file ~a: 已存在" p)) #f)]
     [else (fs-create-file p) (values s p)])))

(define (session-new-dir s dir name)
  (with-handlers ([exn:fail? (lambda (e) (values (session-error! s "new dir" (join dir name) e) #f))])
   (define p (join dir name))
   (cond
     [(fs-path-kind p) (values (session-log! s (format "new dir ~a: 已存在" p)) #f)]
     [else (fs-create-dir p) (values s p)])))

(define (session-delete-path s path)
  (with-handlers ([exn:fail? (lambda (e) (session-error! s "delete" path e))])
   (fs-delete (normalize path))
   s))

;;; ---------- 命令 + 键 + handler ----------

(struct cmd-save () #:transparent)
(struct cmd-open-file () #:transparent)
(struct cmd-open-file-path (path) #:transparent)

;; C-s 被编辑键表用作分裂前缀，所以保存用 M-s。
(define document-keys
  (kbd (key 's 'alt) (cmd-save)
       (key 'f 'ctrl) (cmd-open-file)))

(define (document-handler default-keys)
  (lambda (s cmd)
    (cond
      [(cmd-save? cmd) (session-save s)]
      [(cmd-open-file-path? cmd)
       (session-open-file s (cmd-open-file-path-path cmd) #:keys default-keys)]
      [(cmd-open-file? cmd)
       (step s (cmd-prompt-open "find file: "
                   (lambda (s path)
                     (if (string=? path "") s (session-open-file s path #:keys default-keys)))))]
      [else #f])))

;;; ---------- 插件装配 ----------

(define (document-install s)
  (session-add-key (session-add-handler s (document-handler edit-keys)) document-keys))

(define document-spec (plugin-spec 'document document-install '()))
