#lang racket

;;; bootstrap/filetree-commands.rkt —— 文件树面板命令
;;; layer  : plugins/filetree
;;; effect : 命令：显隐只改 State；创建/删除文件发 IO effect；
;;;            面板内导航发 engine effect

;;; Enter:
;;;   root/dir -> 展开/折叠
;;;   file     -> 打开文件；已有 editor panel 时进入 placement，让用户选 panel；
;;;               没有 editor panel 时自动创建并放入。
;;;
;;; C-n f      -> 创建文件（input 栏输入文件名）
;;; C-n C-n f  -> 创建文件夹
;;; C-d        -> 删除文件
;;;
;;; 文件树面板本身是 buffer view；选中项 = buffer 光标行。

(provide filetree-keys filetree-command-table filetree-input-commands)

(require racket/path
         racket/string
         "../../base/id.rkt"
         "../../base/effect.rkt"
         "../../base/transition.rkt"
         "../../base/keymap.rkt"
         "../../command/key.rkt"
         "../../model/state.rkt"
         "../../model/workspace.rkt"
         "../../model/layout.rkt"
         "../../model/chrome.rkt"
         "../resource/model.rkt"
         "model.rkt"
         "../../effects/engine.rkt"
         "lines.rkt"
         "scan.rkt"
         "../../projection/geometry.rkt"
         "../../env/command.rkt"
         "../../env/environment.rkt"
         "../../env/doc-type.rkt"
         "../../env/input-command.rkt"
         "../../chrome/input.rkt"
         "../../dispatch/context.rkt"
         "../../bootstrap/commands/layout.rkt"
         (only-in "../../bootstrap/commands/placement.rkt" set-placement)
         (only-in "../../bootstrap/commands/util.rkt" notice-result-continuation))

(define (message ctx text)
  (transition-pure
   (state-chrome* (ctx-state ctx) (λ (c) (chrome-set-message c text)))))

(define (notice-state s text)
  (transition-pure
   (state-chrome* s (λ (c) (chrome-set-message c text)))))

(define (selected-line ctx)
  (define vid (ctx-subject ctx))
  (define line (and vid (engine-view-view-point-line (ctx-engine ctx) vid)))
  (and line (filetree-line-at (ctx-state ctx) line dir-entries)))

(define (selected-dir ctx)
  (define l (selected-line ctx))
  (cond
    [(not l) #f]
    [(filetree-dir? l) (filetree-normalize-path (filetree-line-path l))]
    [else
     (filetree-normalize-path
      (build-path (filetree-line-path l) 'up))]))

(define (doc-views ws did)
  (sort (for/list ([(vid vm) (in-hash (workspace-views ws))]
                   #:when (equal? (view-meta-doc vm) did))
          vid)
        string<? #:key id->string))

(define (find-doc-by-path ws path)
  (define pn (filetree-normalize-path path))
  (for/first ([(did dm) (in-hash (workspace-docs ws))]
              #:when (and (doc-meta-path dm)
                          (equal? pn (filetree-normalize-path (doc-meta-path dm)))))
    did))

;; 如果没有 editor region，就在 layout 里创建一个。
(define (ensure-editor-region state)
  (define ws (state-workspace state))
  (define existing
    (for/first ([r (in-hash-values (workspace-regions ws))]
                #:when (eq? (region-role r) 'editor))
      r))
  (cond
    [existing (values state (region-key existing) #f)]
    [else
     (define-values (rid s1) (state-next-id state 'region))
     (define reg (region rid '() #f 'editor))
     (define ws1 (workspace-add-region (state-workspace s1) rid reg))
     (define base (workspace-layout ws1))
     (define anchor (first (tree-regions base)))
     (define layout
       (if anchor
           ;; 目标 leaf 一定在（anchor 来自 tree-regions）；ok? 仍显式接住。
           (let-values ([(t ok?) (tree-split base anchor 'lr rid #:side 'after)])
             (if ok? t (make-leaf rid)))
           (make-leaf rid)))
     (values (state-set-workspace s1
                                  (struct-copy workspace ws1 [layout layout]))
             rid #t)]))

(define (attach-and-focus s rid vid)
  (define ws (state-workspace s))
  (define ws* (workspace-attach-view ws rid vid))
  (transition-pure
   (state-chrome*
    (state-set-focus (state-set-workspace s ws*) vid)
    (λ (c) (chrome-set-message c "file opened")))))

;; 打开新 view：有 editor region -> placement；没有 -> 创建 + 放入。
(define (begin-open-placement state vid)
  (define-values (s1 rid created?) (ensure-editor-region state))
  (if created?
      (attach-and-focus s1 rid vid)
      (transition-pure
       (state-chrome*
        (set-placement s1 vid)
        (λ (c) (chrome-set-message c "open file: choose target panel"))))))

(define (open-file-placement ctx state path)
  (define ws (state-workspace state))
  (define did (find-doc-by-path ws path))
  (cond
    [did
     (define vids (doc-views ws did))
     (define attached
       (for/list ([v (in-list vids)] #:when (workspace-view-attached? ws v)) v))
     (define detached
       (for/list ([v (in-list vids)] #:unless (workspace-view-attached? ws v)) v))
     (cond
       [(pair? attached)
        (define vid (car attached))
        (define reg (workspace-view-region ws vid))
        (attach-and-focus state (region-key reg) vid)]
       [(pair? detached) (begin-open-placement state (car detached))]
       [else
        (transition state
                    (list (open-view-effect did
                                            (λ (s vid)
                                              (begin-open-placement s vid)))) )])]
    [else
     (transition state
                 (list (read-file-effect
                        path
                        (λ (s text)
                          (if (not text)
                              (notice-state s (format "open failed: ~a" path))
                              (let* ([env (ctx-env ctx)]
                                     [dt (environment-doc-type-for-path env path)]
                                     [mode (if dt (doc-type-mode dt) 'text)]
                                     [keymaps (if dt (doc-type-keymaps dt) '())]
                                     [name (let ([n (file-name-from-path path)])
                                             (if n (path->string n) path))])
                                (transition
                                 s
                                 (list (open-doc-effect
                                        (make-open-doc-spec name text
                                                            #:path path
                                                            #:mode mode
                                                            #:keymaps keymaps)
                                        (λ (s* _did vid)
                                          (begin-open-placement s* vid)))))))))))]))

;; C-b：显示 / 隐藏文件树面板。
;; 隐藏时记录当前 region 在父轴上的内容尺寸；显示时用该宽度恢复（fixed），
;; 若记录为 0 / 未记录，则使用最小值 20。
(define filetree-min-size 20)

(define (toggle-filetree-command)
  (cmd (λ (ctx)
         (define s (ctx-state ctx))
         (if (state-input-active? s)
             (message ctx "filetree: input active")
             (let ()
               (define f (plugin-state s 'filetree (empty-filetree)))
               (define rvid (filetree-view f))
               (define ws (state-workspace s))
               (define reg (and rvid (workspace-view-region ws rvid)))
               (cond
                 [(not reg) (message ctx "filetree: not installed")]
                 [else
                  (define rid (region-key reg))
                  (define-values (s* visible? size)
                    (toggle-region! s rid #:min filetree-min-size))
                  (if visible?
                      (transition-pure
                       (state-chrome*
                        s* (λ (c) (chrome-set-message c (format "filetree shown (~a)" size)))))
                      (transition-pure
                       (state-chrome*
                        s* (λ (c) (chrome-set-message c (format "filetree hidden (~a)" size))))))]))))))
(define (filetree-enter-command)
  (cmd (λ (ctx)
         (define l (selected-line ctx))
         (cond
           [(not l) (message ctx "filetree: no line")]
           [(filetree-dir? l)
            (transition-pure
             (plugin-state*
              (ctx-state ctx) 'filetree
              (λ (f) (filetree-toggle-expand
                      f (filetree-normalize-path (filetree-line-path l))))
              (empty-filetree)))]
           [else
            (open-file-placement ctx (ctx-state ctx) (filetree-line-path l))]))))

;;; ════════════════ 创建 / 删除 ════════════════

(define (resolve-path dir name)
  (filetree-normalize-path
   (if (absolute-path? name) name (build-path dir name))))

(define (create-file-prompt-command)
  (cmd (λ (ctx)
         (define dir (selected-dir ctx))
         (if (not dir)
             (message ctx "filetree: no directory")
             (input-show ctx (format "Create file in ~a: " dir)
                        #:tag 'filetree-create-file
                        #:data dir)))))

(define (create-folder-prompt-command)
  (cmd (λ (ctx)
         (define dir (selected-dir ctx))
         (if (not dir)
             (message ctx "filetree: no directory")
             (input-show ctx (format "Create folder in ~a: " dir)
                        #:tag 'filetree-create-folder
                        #:data dir)))))

(define (delete-file-command)
  ;; C-d 先进入 input 栏确认 y/n，不直接删。
  (cmd (λ (ctx)
         (define l (selected-line ctx))
         (cond
           [(not l) (message ctx "filetree: no line")]
           [(not (filetree-file? l)) (message ctx "filetree: select a file")]
           [else
            (define path (filetree-line-path l))
            (input-show ctx (format "Delete file: ~a (y/n) " path)
                        #:tag 'filetree-delete-confirm
                        #:data path)]))))

(define (create-file-handler ctx matched)
  (define dir (cadr matched))
  (define name (caddr matched))
  (define s (input-finish (ctx-state ctx)))
  (cond
    [(string=? (string-trim name) "")
     (notice-state s "create file: empty name")]
    [else
     (define path (resolve-path dir (string-trim name)))
     (cond
       [(or (file-exists? path) (directory-exists? path))
        (notice-state s (format "already exists: ~a" path))]
       [else
        (transition s
                    (list (write-file-effect
                           path ""
                           (notice-result-continuation
                            (format "created: ~a" path)
                            (format "create failed: ~a" path)))))] )]))

(define (delete-file-handler ctx matched)
  (define path (cadr matched))
  (define answer (string-trim (caddr matched)))
  (define s (input-finish (ctx-state ctx)))
  (cond
    [(string=? answer "y")
     (transition s
                 (list (delete-file-effect
                        path
                        (notice-result-continuation
                         (format "deleted: ~a" path)
                         (format "delete failed: ~a" path)))))]
    [(string=? answer "n")
     (notice-state s (format "cancelled: ~a" path))]
    [else
     ;; 非法答案：重新显示确认 prompt
     (input-show-state s (format "Delete file: ~a (y/n) " path)
                              #:tag 'filetree-delete-confirm
                              #:data path)]))

(define (create-folder-handler ctx matched)
  (define dir (cadr matched))
  (define name (caddr matched))
  (define s (input-finish (ctx-state ctx)))
  (cond
    [(string=? (string-trim name) "")
     (notice-state s "create folder: empty name")]
    [else
     (define path (resolve-path dir (string-trim name)))
     (cond
       [(or (file-exists? path) (directory-exists? path))
        (notice-state s (format "already exists: ~a" path))]
       [else
        (transition s
                    (list (make-directory-effect
                           path
                           (notice-result-continuation
                            (format "created: ~a" path)
                            (format "create failed: ~a" path)))))] )]))

(define filetree-input-commands
  (list
   (make-input-command
    'filetree-create-file
    (input-command-regexp #rx"^Create file in (.*): (.*)$")
    create-file-handler)
   (make-input-command
    'filetree-create-folder
    (input-command-regexp #rx"^Create folder in (.*): (.*)$")
    create-folder-handler)
   (make-input-command
    'filetree-delete-confirm
    (input-command-regexp #rx"^Delete file: (.*) \\(y/n\\) (.*)$")
    delete-file-handler)))

(define filetree-keys
  (keys
   [(key 'left)   'filetree-left]
   [(key 'right)  'filetree-right]
   [(key 'up)     'filetree-up]
   [(key 'down)   'filetree-down]
   [(key 'home)   'filetree-home]
   [(key 'end)    'filetree-end]
   [(key 'enter)  'filetree-enter]
   [(key 'n 'ctrl) (key 'f) 'filetree-create-file]
   [(key 'n 'ctrl) (key 'n 'ctrl) (key 'f) 'filetree-create-folder]
   [(key 'd 'ctrl) 'filetree-delete]))

(define (nav-command dir)
  (cmd (λ (ctx)
         (define vid (ctx-subject ctx))
         (if vid
             (transition (ctx-state ctx) (list (nav-effect vid dir)))
             (message ctx "filetree: no view")))))

(define (filetree-command-table)
  (hash 'filetree-left  (nav-command 'left)
        'filetree-right (nav-command 'right)
        'filetree-up    (nav-command 'up)
        'filetree-down  (nav-command 'down)
        'filetree-home  (nav-command 'home)
        'filetree-end   (nav-command 'end)
        'filetree-enter (filetree-enter-command)
        'toggle-filetree (toggle-filetree-command)
        'filetree-create-file (create-file-prompt-command)
        'filetree-create-folder (create-folder-prompt-command)
        'filetree-delete (delete-file-command)))
