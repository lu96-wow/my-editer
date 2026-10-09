#lang racket

;;; edit/document/document.rkt —— 文档 / 文件逻辑：打开 / 保存 + 脏
;;;
;;; 文件 I/O 与路径登记在这里（不在 session 内核）。
;;;   打开：去重 → 读盘 → add-document → 分屏放置 → 记 path → 默认命令表 → 规则层 → 记 saved
;;;   保存：写盘 → 记 saved 句柄
;;; 脏由 session-dirty? 从句柄身份派生；文件映射走 session-set-file（file-map）。
;;;
;;; 自带 command keys（document-keys）与 handler：assembly 里 document-install + 合并 keys。
;;; 默认命令表由 assembly 注入（document-install 的参数），本层不依赖命令配置。

(require racket/file
         racket/path
         "../command/session.rkt"
         "../command/key.rkt"
         "../core/keymap.rkt"
         "fs.rkt"
         "rules.rkt")

(provide session-open-file session-save session-save-all
         session-new-file session-new-dir session-delete-path
         document-install document-keys
         (struct-out cmd-save) (struct-out cmd-open-file) (struct-out cmd-open-file-path))

;;; ---------- 工具 ----------

(define (normalize p) (simplify-path (path->complete-path p)))
(define (basename p) (path->string (or (file-name-from-path (path->complete-path p)) p)))

;;; ---------- 打开 ----------

;; 打开文件到编辑区：已有同 path → 聚焦已有视图；否则新建文档 + 分屏显示。
;; keys：该文档的默认命令表（assembly 注入）。axis：分屏方向。
(define (session-open-file s path [rules default-rules] [axis 'lr] #:keys [keys (kbd)])
  (define np (normalize path))
  (define existing (session-file-did s np))
  (cond
    [existing
     (define vs (session-view-ids-of s existing))
     (if (pair? vs) (session-show-view s (first vs)) s)]
    [else
     (define text (if (file-exists? np) (file->string np) ""))
     (define-values (s1 did nvid) (session-add-document s text 40 18 #:name (basename np)))
     (define base (session-edit-vid s1))
     (define s2 (if (eqv? base nvid) s1 (session-place-view s1 base axis nvid)))
     (define s3 (session-set-file s2 did np))
     (define s4 (session-doc-set-keys s3 did keys))        ; 默认命令表（先全部填默认）
     (define s5 (rules-apply rules s4 did np))             ; 规则层（暂空）可覆盖
     (define s6 (session-mark-saved s5 did))
     (session-show-view s6 nvid)]))

;;; ---------- 保存 ----------

;; 保存某文档（默认活动编辑视图的）。→ session
(define (session-save s [did #f])
  (define d (or did (let ([v (session-edit-vid s)]) (and v (session-view-did s v)))))
  (cond
    [(not d) s]
    [else
     (define path (session-file-path s d))
     (cond
       [(not path) s]                             ; 无路径：暂不实现另存为
       [else
        (call-with-output-file path #:exists 'replace
          (lambda (out) (display (session-document-string s d) out)))
        (session-mark-saved s d)])]))

;; 全部有路径的文档存盘（错误退出用）。
(define (session-save-all s)
  (for/fold ([s s]) ([d (in-list (session-file-dids s))])
    (session-save s d)))

;;; ---------- 文件操作（tree 的新建 / 删除） ----------

(define (path-under? base p)
  (define b (explode-path (normalize base)))
  (define q (explode-path (normalize p)))
  (and (>= (length q) (length b)) (equal? b (take q (length b)))))

;; 在 dir 下新建文件；已存在 → path = #f。→ (values session path|#f)
(define (session-new-file s dir name)
  (define p (simplify-path (build-path dir name)))
  (cond
    [(or (file-exists? p) (directory-exists? p)) (values s #f)]
    [else (fs-create-file p) (values s p)]))

(define (session-new-dir s dir name)
  (define p (simplify-path (build-path dir name)))
  (cond
    [(or (file-exists? p) (directory-exists? p)) (values s #f)]
    [else (fs-create-dir p) (values s p)]))

;; 删除 path；连带关闭其下已打开的文档。→ session
(define (session-delete-path s path)
  (define np (normalize path))
  (define dids (for/list ([d (in-list (session-file-dids s))]
                          #:when (let ([p (session-file-path s d)])
                                   (and p (path-under? np p))))
                 d))
  (define s1 (for/fold ([s s]) ([d (in-list dids)]) (session-close-document s d)))
  (fs-delete np)
  s1)

;;; ---------- 命令 + 键 + handler ----------

(struct cmd-save () #:transparent)
(struct cmd-open-file () #:transparent)          ; 询问路径后再打开
(struct cmd-open-file-path (path) #:transparent) ; 直接打开（文件树发来）

;; 本层自带的全局键（assembly 合并进 session.keys）。
(define document-keys
  (kbd (key 's 'ctrl) (cmd-save)
       (key 'f 'ctrl) (cmd-open-file)))

(define (document-handler default-keys)
  (lambda (s cmd)
    (cond
      [(cmd-save? cmd) (session-save s)]
      ;; 直接打开（文件树发来）：不再询问路径。
      [(cmd-open-file-path? cmd)
       (session-open-file s (cmd-open-file-path-path cmd) #:keys default-keys)]
      ;; 询问路径后再打开（C-f）。
      [(cmd-open-file? cmd)
       (define iv (session-panel-vid s 'input))
       (if iv
           (session-prompt-open s iv "find file: "
                                (lambda (s path)
                                  (if (string=? path "")
                                      s
                                      (session-open-file s path #:keys default-keys))))
           s)]
      [else #f])))

;; 挂 handler；default-keys 作为打开文件的默认命令表。
(define (document-install s [default-keys (kbd)])
  (session-add-handler s (document-handler default-keys)))
