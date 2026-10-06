#lang racket

(require racket/file
         racket/path
         racket/string
         "../../core/editor.rkt"
         "../platform/layout/main.rkt"
         "../platform/state.rkt"
         "../platform/panes.rkt"
         "../platform/edit-panes.rkt"
         "../platform/paths.rkt"
         "../platform/mode.rkt"
         "../platform/hooks.rkt"
         "../platform/path.rkt"
         "../platform/input.rkt"
         "../platform/command.rkt")

;;; lab-rebuild/builtin/edit.rkt —— 内置「编辑 / 文件 / 分屏 / 模态」命令包
;;;
;;; 这是平台自带的**内置包**（不是平台本身）：它只通过公开接口使用平台
;;; （state 的 setter、panes registry、command-register!），命令用 `define-command`
;;; 注册。以后树 / 列表 / 补全 / 高亮也都按这个模式各自成包。
;;;
;;; 提供的动作（app-open-path! 等）也是包对外的 API；app / main 通过它打开文件。
;;;
;;; 边界：本包会改 editor（插入 / 删除 / 选区），但不认识键位、不认识插件实现。
;;; 文本编辑后的跨层副作用（属性插件同步 / 补全过滤）以钩子形式发出：
;;;   'after-edit     (vid changes)
;;;   'document-closed (did)
;;;
;;; 关文档 / 退出会先做**保存确认**：改过的文档（内容 != 磁盘）逐个弹底部输入框，
;;; ⏎/y 保存、n 跳过、all 剩余全部保存、esc 放弃整个关闭 / 退出。

(provide app-open-path! app-close-path! app-close-view! app-close-document!
         app-show-view! app-show-document! app-split! app-pane-close!
         app-save! app-save-document! document-modified? app-quit! app-resize! app-insert-typed!
         app-move-focus! app-toggle-sidebar! app-toggle-left!
         app-prefix-begin! app-prefix-end! app-begin!
         app-commit! app-answer! app-cancel!)

;;; ================= 小工具 =================

(define (ed a) (app-ed a))
(define (focus a) (app-focus a))

(define (event-text e)
  (cond [(key-event? e) (string (key-event-key e))]
        [(paste-event? e) (paste-event-text e)]
        [else ""]))

;; 跑一次编辑，把产生的增量以钩子广播：
;;   'after-edit   任何文本变更（属性插件同步用）
;;   'after-insert 用户打字 / 退格 / 粘贴（补全 refine 用，接受候选时不算）
(define (edit! a thunk [typing? #f])
  (define vid (focus a))
  (define-values (changes _ok?) (thunk))
  (when (and vid (pair? changes))
    (hook-run! a 'after-edit vid changes)
    (when typing? (hook-run! a 'after-insert vid changes))))

;;; ================= 打开 / 关闭 / 显示 =================

(define (app-internal-dids a)
  (for/list ([vid (in-list (app-internal-vids a))])
    (editor-view-document-id (app-ed a) vid)))

(define (app-open-path! a path)
  (define np (simplify-path (path->complete-path path)))
  (define did
    (or (path-table-did (app-paths a) np)
        (let-values ([(ed2 d2) (editor-add-document (app-ed a)
                                                    (if (file-exists? np) (file->string np) "")
                                                    (basename np))])
          (set-app-ed! a ed2)
          (path-table-add! (app-paths a) d2 np)
          d2)))
  (app-show-document! a did #t)
  (hook-run! a 'document-opened did))

(define (app-show-view! a vid [focus? #t])
  (define did (editor-view-document-id (app-ed a) vid))
  (define active (app-edit-active a))
  (define vid*
    (if (and (edit-panes-contains? (app-edit a) vid) (not (eqv? vid active)))
        (let-values ([(ed2 v2) (editor-add-view (app-ed a) did (app-main-w a) (app-main-h a)
                                                #:line-numbers? #t)])
          (set-app-ed! a ed2) v2)
        vid))
  (app-edit-open! a vid*)
  (when focus? (set-app-focus! a vid*)))

(define (app-show-document! a did [focus? #t])
  (define used (edit-panes-vids (app-edit a)))
  (define free (for/first ([v (in-list (editor-document-view-list (app-ed a) did))]
                           #:unless (memv v used)) v))
  (define vid (or free
                  (let-values ([(ed2 v2) (editor-add-view (app-ed a) did (app-main-w a) (app-main-h a)
                                                          #:line-numbers? #t)])
                    (set-app-ed! a ed2) v2)))
  (app-show-view! a vid focus?))

(define (app-pick-edit-vid a)
  (define internal (app-internal-dids a))
  (for/or ([did (in-list (editor-document-id-list (app-ed a)))]
           #:unless (memv did internal))
    (define vids (editor-document-view-list (app-ed a) did))
    (and (pair? vids) (car vids))))

(define (app-edit-recover! a)
  (unless (app-edit-active a)
    (define v (app-pick-edit-vid a))
    (when v (app-edit-open! a v))))

(define (app-forget-document! a did)
  (define vids (editor-document-view-list (app-ed a) did))
  (set-app-ed! a (editor-close-document (app-ed a) did))
  (path-table-remove! (app-paths a) did)
  (hook-run! a 'document-closed did)
  vids)

;;; ---------- 关闭：修改过先问保存 ----------
;;;
;;; 任何「关文档」都从这里走：改过的文档（内容 != 磁盘）逐个弹底部输入框问
;;;   ⏎ / y     保存这个
;;;   n / 其它  不保存这个
;;;   all / a   剩下全部保存
;;;   esc       放弃整个关闭 / 退出操作
;;; 全部问完才真正关。Ctrl+Q 退出也走这条，所以退出前会逐个确认。

;; 文档内容与磁盘不一致（或磁盘上还没有、但已有内容）→ 需要问。
(define (document-modified? a did)
  (define p (path-table-path (app-paths a) did))
  (and p
       (let ([text (editor-document-string (app-ed a) did)])
         (cond
           [(not (file-exists? p)) (positive? (string-length text))]
           [else
            (define disk (with-handlers ([exn:fail? (lambda (_) #f)]) (file->string p)))
            (or (not disk) (not (string=? text disk)))]))))

(define (app-save-document! a did)
  (define p (and did (path-table-path (app-paths a) did)))
  (when p
    (call-with-output-file p #:exists 'replace
      (lambda (out) (display (editor-document-string (app-ed a) did) out)))))

(define (document-display-name a did)
  (define p (path-table-path (app-paths a) did))
  (if p (path->string p) (editor-document-name (app-ed a) did)))

;; 正在逐个询问的关闭流程（防止嵌套 / 重复触发，如提示框里再按 Ctrl+Q）。
(define closing? (make-weak-hasheq))

;; 依次询问 pending 里的文档；空表直接 on-done。
(define (ask-save-each! a pending on-done on-cancel)
  (cond
    [(null? pending) (on-done)]
    [else
     (define did (car pending))
     (define rest (cdr pending))
     (define label (format "save ~a? (y/n/all, esc abort) " (document-display-name a did)))
     (app-begin! a label #t
                 (lambda (ans)
                   (define s (string-downcase (string-trim ans)))
                   (cond
                     [(member s '("all" "a"))
                      (for ([d (in-list pending)]) (app-save-document! a d))
                      (on-done)]
                     [(member s '("" "y" "yes"))
                      (app-save-document! a did)
                      (ask-save-each! a rest on-done on-cancel)]
                     [else
                      (ask-save-each! a rest on-done on-cancel)]))
                 on-cancel)]))

;; 关闭 dids 里所有文档：修改过的先逐个问，处理完再统一关。
;; on-cancel 在 esc 放弃时调用（此时什么都不关）。
(define (close-documents! a dids [on-done void] [on-cancel #f])
  (cond
    [(null? dids) (on-done)]
    [(hash-ref closing? a #f) (void)]
    [else
     (hash-set! closing? a #t)
     (define (finish!) (hash-remove! closing? a))
     (define pending (filter (lambda (d) (document-modified? a d)) dids))
     (ask-save-each! a pending
                     (lambda ()
                       (app-edit-remove! a (append* (for/list ([did (in-list dids)])
                                                      (app-forget-document! a did))))
                       (app-edit-recover! a)
                       (finish!)
                       (on-done))
                     (lambda () (finish!) (when on-cancel (on-cancel))))]))

;; 关 path 下所有已打开文档。save? #f = 已删盘等场景，不再问保存。
(define (app-close-path! a path #:save? [save? #t])
  (define closed (path-table-dids-under (app-paths a) path))
  (cond
    [(null? closed) (void)]
    [save? (close-documents! a closed)]
    [else
     (app-edit-remove! a (append* (for/list ([did (in-list closed)])
                                    (app-forget-document! a did))))
     (app-edit-recover! a)]))

(define (app-close-document! a did)
  (close-documents! a (list did)))

(define (app-close-view! a vid)
  (set-app-ed! a (editor-close-view (app-ed a) vid))
  (app-edit-remove! a (list vid))
  (app-edit-recover! a))

;;; ================= 分屏 =================

(define (app-split! a dir)
  (define vid (app-edit-active a))
  (when vid
    (define did (editor-view-document-id (app-ed a) vid))
    (define-values (ed2 v2) (editor-add-view (app-ed a) did (app-main-w a) (app-main-h a)
                                             #:line-numbers? #t))
    (set-app-ed! a ed2)
    (app-edit-split! a dir v2)
    (set-app-focus! a v2)))

(define (app-pane-close! a)
  (define f (app-focus a))
  (define vid (if (and f (edit-panes-contains? (app-edit a) f)) f (app-edit-active a)))
  (when vid
    (define was-focus? (eqv? f vid))
    (app-edit-remove! a (list vid))
    (when was-focus? (set-app-focus! a (app-edit-active a)))))

;;; ================= 文件 =================

;; Ctrl+Q：先把所有已打开的用户文档走一遍「要不要保存」，全部处理完再退出；
;; 提示中按 esc 则放弃退出（什么都不关）。
(define (app-quit! a)
  (define dids (for/list ([did (in-list (editor-document-id-list (app-ed a)))]
                          #:when (path-table-path (app-paths a) did))
                 did))
  (close-documents! a dids (lambda () (set-app-quit?! a #t))))

(define (app-save! a) (app-save-document! a (focused-did a)))

(define (app-resize! a w h)
  (app-size-set! a (max 20 w) (max 5 h))
  (set-app-prev! a #f))

;;; ================= 焦点 =================

(define (app-move-focus! a dir)
  (define vid (pane-dir (app-focus-panes a) (app-focus a) dir))
  (when vid (set-app-focus! a vid)))

;;; ================= 左栏面板 / 侧栏 =================

(define (sidebar-focus? a)
  (eqv? (app-focus a) (app-left-vid a)))

(define (app-toggle-sidebar! a)
  (define show? (not (app-sidebar? a)))
  (app-sidebar-set! a show?)
  (cond
    [show? (set-app-focus! a (app-left-vid a))]
    [(sidebar-focus? a) (set-app-focus! a (app-edit-active a))]
    [else (void)]))

;; 在已注册面板间轮换（文件树 ↔ 文档列表 …）。
(define (app-toggle-left! a)
  (define names (app-panel-names a))
  (when (pair? names)
    (unless (app-sidebar? a) (app-sidebar-set! a #t))
    (define cur (app-left a))
    (define idx (or (for/first ([n (in-list names)] [i (in-naturals)] #:when (eq? n cur)) i) -1))
    (app-left-set! a (list-ref names (modulo (add1 idx) (length names))))
    (set-app-focus! a (app-left-vid a))))

;;; ================= 模态（前缀 / prompt） =================

(define (app-prefix-begin! a label tables)
  (app-mode-set! a (prefix-begin label tables)))

(define (app-prefix-end! a)
  (when (prefix? (app-mode a)) (app-mode-set! a #f)))

(define (app-begin! a label editable? on-commit [on-cancel #f])
  (define p (input-begin label editable? (app-focus a) on-commit on-cancel))
  (app-mode-set! a p)
  (define vid (app-modal-vid a))
  (editor-view-assign! (app-ed a) vid (prompt-document p ""))
  (editor-view-set-point! (app-ed a) vid (point 0 (string-length label)))
  (set-app-focus! a vid))

(define (app-commit! a)
  (define p (app-mode a))
  (when (and (prompt? p) (prompt-editable? p))
    (define s (editor-view-string (app-ed a) (app-modal-vid a)))
    (app-mode-set! a #f)
    (set-app-focus! a (prompt-prev-focus p))
    (input-commit p s)))

(define (app-answer! a yes?)
  (define p (app-mode a))
  (when (prompt? p)
    (app-mode-set! a #f)
    (set-app-focus! a (prompt-prev-focus p))
    (input-answer p yes?)))

(define (app-cancel! a)
  (define p (app-mode a))
  (when (prompt? p)
    (app-mode-set! a #f)
    (set-app-focus! a (prompt-prev-focus p))
    (input-cancel p)))

;;; ================= 撤销粒度（合并策略） =================

(define (break-text? text)
  (for/or ([ch (in-string text)]) (char-whitespace? ch)))

(define (undo-typing-policy text)
  (values 'lab-typing #f (break-text? text)))

;; 以「打字」方式插入一段文本：带合并 tag，并广播 after-edit / after-insert。
;; 插件（如缩进）复用这个入口，不重复 undo / 钩子逻辑。
(define (app-insert-typed! a s)
  (define-values (tag seal-before? seal-after?) (undo-typing-policy s))
  (when seal-before? (editor-view-seal! (ed a) (focus a)))
  (edit! a (lambda () (editor-view-insert! (ed a) (focus a) s tag)) #t)
  (when seal-after? (editor-view-seal! (ed a) (focus a))))

;;; ================= 编辑命令 =================

(define (cmd-insert e a)
  (define text (event-text e))
  (define handled (hook-run-first! a 'before-insert text))
  (cond
    [(not handled)
     (define-values (tag seal-before? seal-after?) (undo-typing-policy text))
     (when seal-before? (editor-view-seal! (ed a) (focus a)))
     (edit! a (lambda () (editor-view-insert! (ed a) (focus a) text tag)) #t)
     (when seal-after? (editor-view-seal! (ed a) (focus a)))]
    [(pair? handled)
     (hook-run! a 'after-edit (focus a) handled)
     (hook-run! a 'after-insert (focus a) handled)]
    [else (void)]))

(define (cmd-paste-text e a)
  (edit! a (lambda () (editor-view-paste-text! (ed a) (focus a) (event-text e))) #t))

(define (cmd-insert-string e a s)
  (app-insert-typed! a s))

;; 普通换行（缩进插件会覆盖成 syntax-aware 版本；未加载插件时回落到纯换行）。
(define (cmd-newline-and-indent e a) (app-insert-typed! a "\n"))

(define (cmd-backspace e a)
  (define handled (hook-run-first! a 'before-backspace))
  (cond
    [(not handled) (edit! a (lambda () (editor-view-backspace! (ed a) (focus a))) #t)]
    [(pair? handled)
     (hook-run! a 'after-edit (focus a) handled)
     (hook-run! a 'after-insert (focus a) handled)]
    [else (void)]))

(define (cmd-delete e a)
  (edit! a (lambda () (editor-view-delete! (ed a) (focus a))) #t))

(define (cmd-nav e a dir extend?)
  (define p (hash-ref (hash 'left  editor-view-left!  'right editor-view-right!
                            'up    editor-view-up!    'down  editor-view-down!
                            'home  editor-view-home!  'end   editor-view-end!)
                     dir))
  (p (ed a) (focus a) extend?)
  (hook-run! a 'after-nav))

(define (cmd-select-all e a) (editor-view-select-all! (ed a) (focus a)))
(define (cmd-copy e a)       (editor-view-copy! (ed a) (focus a)))
(define (cmd-cut e a)        (edit! a (lambda () (editor-view-cut! (ed a) (focus a))) #t))
(define (cmd-paste e a)      (edit! a (lambda () (editor-view-paste! (ed a) (focus a))) #t))
(define (cmd-undo e a)       (editor-view-undo! (ed a) (focus a)))
(define (cmd-redo e a)       (editor-view-redo! (ed a) (focus a)))

;;; ================= app 命令 =================

(define (cmd-focus e a dir) (app-move-focus! a dir))
(define (cmd-quit e a) (app-quit! a))
(define (cmd-save e a) (app-save! a))
(define (cmd-split-tb e a) (app-split! a 'tb))
(define (cmd-split-lr e a) (app-split! a 'lr))
(define (cmd-pane-close e a) (app-pane-close! a))
(define (cmd-prefix e a label tables) (app-prefix-begin! a label tables))
(define (cmd-toggle-sidebar e a) (app-toggle-sidebar! a))
(define (cmd-toggle-left e a) (app-toggle-left! a))

;;; ================= 模态命令 =================

(define (cmd-commit e a) (app-commit! a))
(define (cmd-cancel e a) (app-cancel! a))

(define (cmd-answer e a)
  (define k (and (key-event? e) (key-event-key e)))
  (cond [(eqv? k #\y) (app-answer! a #t)]
        [(eqv? k #\n) (app-answer! a #f)]
        [else (void)]))

(define (cmd-noop e a) (void))

;;; ================= 注册 =================

(define-command insert        cmd-insert)
(define-command paste-text    cmd-paste-text)
(define-command insert-string cmd-insert-string)
(define-command newline-and-indent cmd-newline-and-indent)
(define-command backspace     cmd-backspace)
(define-command delete        cmd-delete)
(define-command nav           cmd-nav)
(define-command select-all    cmd-select-all)
(define-command copy          cmd-copy)
(define-command cut           cmd-cut)
(define-command paste         cmd-paste)
(define-command undo          cmd-undo)
(define-command redo          cmd-redo)
(define-command focus         cmd-focus)
(define-command quit          cmd-quit)
(define-command save          cmd-save)
(define-command split-tb      cmd-split-tb)
(define-command split-lr      cmd-split-lr)
(define-command pane-close    cmd-pane-close)
(define-command prefix        cmd-prefix)
(define-command toggle-sidebar cmd-toggle-sidebar)
(define-command toggle-left   cmd-toggle-left)
(define-command commit        cmd-commit)
(define-command cancel        cmd-cancel)
(define-command answer        cmd-answer)
(define-command noop          cmd-noop)
