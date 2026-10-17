#lang racket

;;; bootstrap/filetree-commands.rkt —— 文件树面板命令
;;;
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
         "../base/id.rkt"
         "../base/effect.rkt"
         "../base/transition.rkt"
         "../base/keymap.rkt"
         "../../edit-tui/command/key.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/layout.rkt"
         "../model/chrome.rkt"
         "../model/resources.rkt"
         "../model/filetree.rkt"
         "../effects/engine.rkt"
         "../projection/filetree.rkt"
         "../projection/geometry.rkt"
         "../../core/view/base/rect.rkt"
         "../env/command.rkt"
         "../env/environment.rkt"
         "../env/doc-type.rkt"
         "../env/input-command.rkt"
         "../input.rkt"
         "../dispatch/context.rkt")

(define (message ctx text)
  (transition-pure
   (state-chrome* (ctx-state ctx) (λ (c) (chrome-set-message c text)))))

(define (notice-state s text)
  (transition-pure
   (state-chrome* s (λ (c) (chrome-set-message c text)))))

(define (selected-line ctx)
  (define vid (ctx-subject ctx))
  (define line (and vid (engine-view-view-point-line (ctx-engine ctx) vid)))
  (and line (filetree-line-at (ctx-state ctx) line)))

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
     (define layout (workspace-layout ws1))
     (define anchor (first (tree-regions layout)))
     (define layout*
       (if anchor
           (tree-split layout anchor 'lr rid #:side 'after)
           (make-leaf rid)))
     (values (state-set-workspace s1
                                  (struct-copy workspace ws1 [layout layout*]))
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
        (state-resources* s1 (λ (r) (resources-set-pending r vid)))
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

(define (region-parent-axis layout rid)
  (let loop ([n layout])
    (cond
      [(leaf? n) #f]
      [else
       (define cs (split-children n))
       (cond
         [(for/or ([c (in-list cs)])
            (and (leaf? c) (equal? (leaf-region c) rid)))
          (split-axis n)]
         [else
          (for/or ([c (in-list cs)]) (loop c))])])))

(define (region-content-size layout area rid axis)
  (define-values (rps _cuts) (geometry-solve layout area))
  (define rp (for/first ([p (in-list rps)]
                         #:when (equal? (region-panel-region p) rid))
               p))
  (and rp
       (let ([c (region-panel-content rp)])
         (if (eq? axis 'lr) (rect-w c) (rect-h c)))))

(define (toggle-filetree-command)
  (cmd (λ (ctx)
         (define s (ctx-state ctx))
         (define f (state-filetree s))
         (define rvid (filetree-view f))
         (define ws (state-workspace s))
         (define reg (and rvid (workspace-view-region ws rvid)))
         (cond
           [(not reg) (message ctx "filetree: not installed")]
           [else
            (define rid (region-key reg))
            (define layout (workspace-layout ws))
            (define visible? (tree-visible? layout rid))
            (cond
              [visible?
               ;; 先量当前尺寸，再隐藏
               (define axis (or (region-parent-axis layout rid) 'lr))
               (define w (state-window s))
               (define area (rect 0 0 (window-cols w) (window-rows w)))
               (define size (or (region-content-size layout area rid axis) 0))
               (define s1 (state-filetree* s (λ (f*) (filetree-set-width f* size))))
               (define ws1 (struct-copy workspace ws [layout (tree-hide layout rid)]))
               (define ws2
                 (if (equal? (state-focus s1) rvid)
                     (let ([fb (for/first ([(v vm) (in-hash (workspace-views ws1))]
                                          #:when (and (workspace-view-attached? ws1 v)
                                                      (not (equal? v rvid))
                                                      (let ([dm (workspace-doc ws1 (view-meta-doc vm))])
                                                        (and dm
                                                             (not (memq (doc-meta-mode dm)
                                                                        '(status state input resources filetree)))))))
                                v)])
                       (workspace-set-focus* ws1 fb #:push? #f))
                     ws1))
               (transition-pure
                (state-chrome*
                 (state-set-workspace s1 ws2)
                 (λ (c) (chrome-set-message c (format "filetree hidden (~a)" size)))))]
              [else
               (define recorded (or (filetree-width f) 0))
               (define size (if (positive? recorded) recorded filetree-min-size))
               (define layout* (tree-show (tree-set-dim layout rid (fixed size)) rid))
               (transition-pure
                (state-chrome*
                 (state-set-workspace s (struct-copy workspace ws [layout layout*]))
                 (λ (c) (chrome-set-message c (format "filetree shown (~a)" size)))))] )]))))

(define (filetree-enter-command)
  (cmd (λ (ctx)
         (define l (selected-line ctx))
         (cond
           [(not l) (message ctx "filetree: no line")]
           [(filetree-dir? l)
            (transition-pure
             (state-filetree*
              (ctx-state ctx)
              (λ (f) (filetree-toggle-expand
                      f (filetree-normalize-path (filetree-line-path l))))))]
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
             (input-show ctx (format "Create file in ~a: " dir))))))

(define (create-folder-prompt-command)
  (cmd (λ (ctx)
         (define dir (selected-dir ctx))
         (if (not dir)
             (message ctx "filetree: no directory")
             (input-show ctx (format "Create folder in ~a: " dir))))))

(define (delete-file-command)
  (cmd (λ (ctx)
         (define l (selected-line ctx))
         (cond
           [(not l) (message ctx "filetree: no line")]
           [(not (filetree-file? l)) (message ctx "filetree: select a file")]
           [else
            (define path (filetree-line-path l))
            (transition (ctx-state ctx)
                        (list (delete-file-effect
                               path
                               (λ (s ok?)
                                 (if ok?
                                     (notice-state s (format "deleted: ~a" path))
                                     (notice-state s (format "delete failed: ~a" path)))))))]))))

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
                           (λ (s2 ok?)
                             (if ok?
                                 (notice-state s2 (format "created: ~a" path))
                                 (notice-state s2 (format "create failed: ~a" path)))))))] )]))

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
                           (λ (s2 ok?)
                             (if ok?
                                 (notice-state s2 (format "created: ~a" path))
                                 (notice-state s2 (format "create failed: ~a" path)))))))] )]))

(define filetree-input-commands
  (list
   (make-input-command
    'filetree-create-file
    (input-command-regexp #rx"^Create file in (.*): (.*)$")
    create-file-handler)
   (make-input-command
    'filetree-create-folder
    (input-command-regexp #rx"^Create folder in (.*): (.*)$")
    create-folder-handler)))

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
