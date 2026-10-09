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
         racket/string
         "../command/session.rkt"
         "../command/command.rkt"
         "../command/key.rkt"
         "../core/keymap.rkt"
         "../core/path.rkt"
         "fs.rkt"
         "rules.rkt")

(provide session-open-file session-save session-save-all
         session-new-file session-new-dir session-delete-path
         session-close-doc session-close-view-checked
         document-install document-keys
         (struct-out cmd-save) (struct-out cmd-open-file) (struct-out cmd-open-file-path))

;;; ---------- 工具 ----------

(define (basename p) (path->string (or (file-name-from-path (path->complete-path p)) p)))

;; 资源操作出错 → 记日志（session-log!；prompt 进行中只追加不弹）。
(define (session-error! s what path e)
  (session-log! s (format "~a ~a: ~a" what path (exn-message e))))

;;; ---------- 打开 ----------

;; 打开文件到编辑区：已有同 path → 聚焦已有视图；否则新建文档 + 分屏显示。
;; keys：该文档的默认命令表（assembly 注入）。axis：分屏方向。
(define (session-open-file s path [rules default-rules] [axis 'lr] #:keys [keys (kbd)])
  (with-handlers ([exn:fail? (lambda (e) (session-error! s "open" path e))])
   (define np (normalize path))
   (define existing (session-file-did s np))
   (cond
     [existing
      (define vs (session-view-ids-of s existing))
      (if (pair? vs) (session-show-view s (first vs)) s)]
     [else
      (define text (cond [(directory-exists? np) (error 'open "是一个目录")]
                         [(file-exists? np) (file->string np)]
                         [else ""]))
      (define-values (s1 did nvid) (session-add-document s text 40 18 #:name (basename np)
                                                       #:line-numbers? #t))
      (define base (session-edit-vid s1))
      (define s2 (if (eqv? base nvid) s1 (session-place-view s1 base axis nvid)))
      (define s3 (session-set-file s2 did np))
      (define s4 (session-doc-set-keys s3 did keys))        ; 默认命令表（先全部填默认）
      (define s5 (rules-apply rules s4 did np))             ; 规则层（暂空）可覆盖
      (define s6 (session-mark-saved s5 did))
      (session-show-view s6 nvid)])))

;;; ---------- 保存 ----------

;; 保存某文档（默认活动编辑视图的）。→ session
(define (session-save s [did #f])
  (with-handlers ([exn:fail? (lambda (e) (session-error! s "save" (and did (session-file-path s did)) e))])
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
         (session-mark-saved s d)])])))

;; 全部有路径的文档存盘（错误退出用）。
(define (session-save-all s)
  (for/fold ([s s]) ([d (in-list (session-file-dids s))])
    (session-save s d)))

;;; ---------- 文件操作（tree 的新建 / 删除） ----------

;; 在 dir 下新建文件；已存在 → path = #f。→ (values session path|#f)
(define (session-new-file s dir name)
  (with-handlers ([exn:fail? (lambda (e) (values (session-error! s "new file" (build-path dir name) e) #f))])
   (define p (simplify-path (build-path dir name)))
   (cond
     [(or (file-exists? p) (directory-exists? p))
      (values (session-log! s (format "new file ~a: 已存在" p)) #f)]
     [else (fs-create-file p) (values s p)])))

(define (session-new-dir s dir name)
  (with-handlers ([exn:fail? (lambda (e) (values (session-error! s "new dir" (build-path dir name) e) #f))])
   (define p (simplify-path (build-path dir name)))
   (cond
     [(or (file-exists? p) (directory-exists? p))
      (values (session-log! s (format "new dir ~a: 已存在" p)) #f)]
     [else (fs-create-dir p) (values s p)])))

;; 删除 path（仅文件系统）；**不关任何 document** —— 打开中的缓冲区保留（路径也保留，
;; 之后保存会重建文件）。关文档走关闭入口（脏则问）。→ session
(define (session-delete-path s path)
  (with-handlers ([exn:fail? (lambda (e) (session-error! s "delete" path e))])
   (fs-delete (normalize path))
   s))

;;; ---------- 退出确认（有未保存修改时逐个询问） ----------
;;; 交互用 prompt 回调链实现，不新增会话状态。

;; 解析答案 -> 'yes | 'no | 'all | 'nall | 'invalid
(define (quit-answer ans)
  (define a (string-downcase (string-trim ans)))
  (cond [(member a '("y" "yes")) 'yes]
        [(member a '("n" "no")) 'no]
        [(member a '("all" "a")) 'all]
        [(member a '("nall" "none" "!")) 'nall]
        [else 'invalid]))

;; 有路径且脏的文档（无路径不可能脏）。
(define (dirty-dids s)
  (for/list ([d (in-list (session-file-dids s))] #:when (session-dirty? s d)) d))

(define (session-quit-ask s remaining)
  (cond
    [(null? remaining) (session-quit s)]
    [else
     (define did (first remaining))
     (define more (rest remaining))
     (session-prompt-open s (session-panel-vid s 'input)
       (format "save ~a? (y/n/all/nall) " (session-document-name s did))
       (lambda (s ans)
         (case (quit-answer ans)
           [(yes)  (session-quit-ask (session-save s did) more)]
           [(no)   (session-quit-ask s more)]
           [(all)  (session-quit
                    (for/fold ([s (session-save s did)]) ([d (in-list more)]) (session-save s d)))]
           [(nall) (session-quit s)]
           [else (session-quit-ask s remaining)])))]))   ; 无效输入：重问当前

;; 退出入口：没有脏文档直接退，否则逐个问。
(define (session-quit-confirm s)
  (define ds (dirty-dids s))
  (if (null? ds) (session-quit s) (session-quit-ask s ds)))

;;; ---------- 关闭（统一入口；脏则问） ----------

;; 'yes | 'no | 'invalid
(define (yes-no ans)
  (define a (string-downcase (string-trim ans)))
  (cond [(member a '("y" "yes")) 'yes]
        [(member a '("n" "no")) 'no]
        [else 'invalid]))

;; 关文档：脏则问是否保存。**唯一**的关文档入口。
(define (session-close-doc s did)
  (cond
    [(not (session-dirty? s did)) (session-close-document s did)]
    [else
     (session-prompt-open s (session-panel-vid s 'input)
       (format "save ~a? (y/n) " (session-document-name s did))
       (lambda (s ans)
         (case (yes-no ans)
           [(yes) (session-close-document (session-save s did) did)]
           [(no)  (session-close-document s did)]
           [else  (session-close-doc s did)])))]))

;; 关视图：该文档最后一个视图 → 走关文档（会问）；否则直接关视图。
(define (session-close-view-checked s vid)
  (define did (session-view-did s vid))
  (if (null? (remove vid (session-document-view-list s did)))
      (session-close-doc s did)
      (session-close-view s vid)))

;;; ---------- 命令 + 键 + handler ----------

(struct cmd-save () #:transparent)
(struct cmd-open-file () #:transparent)          ; 询问路径后再打开
(struct cmd-open-file-path (path) #:transparent) ; 直接打开（文件树发来）

;; 本层自带的全局键（assembly 合并进 session.keys）。
;; 注意：C-s 已被 edit-keys 用作「分裂前缀」，所以保存改用 M-s。
(define document-keys
  (kbd (key 's 'alt) (cmd-save)
       (key 'f 'ctrl) (cmd-open-file)))

(define (document-handler default-keys)
  (lambda (s cmd)
    (cond
      [(cmd-quit? cmd) (session-quit-confirm s)]
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
