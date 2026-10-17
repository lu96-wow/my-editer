#lang racket

;;; bootstrap/commands.rkt —— 默认命令（纯 transition 构造器）
;;;
;;; 命令只吃 ctx，返回 transition；需要写 core 的地方发 effect。
;;; 这一块是“可替换的默认值”，不是框架核心：用户/插件可以覆盖同名 command-id。

(provide default-command-table
         split-view-command
         close-view-command
         close-region-command
         request-close-doc
         detach-view-command
         attach-detached-command
         cycle-region-view-command
         default-input-commands
         focus-move-command)

(require racket/path
         "../base/id.rkt"
         "../base/effect.rkt"
         "../base/transition.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/layout.rkt"
         "../model/chrome.rkt"
         "../model/input.rkt"
         "../model/resources.rkt"
         "../env/command.rkt"
         "../env/environment.rkt"
         "../env/doc-type.rkt"
         "../env/input-command.rkt"
         "../env/role.rkt"
         "../projection/geometry.rkt"
         "../effects/engine.rkt"
         "../../core/editor/ops.rkt"
         "../../core/text/base/point.rkt"
         "../../core/text/base/selection.rkt"
         "../../core/view/panel.rkt"
         "../../core/view/base/rect.rkt"
         "../dispatch/context.rkt"
         (except-in "../bootstrap/chrome.rkt" input-show)
         "../input.rkt"
         "../bootstrap/resource-commands.rkt"
         "../bootstrap/filetree-commands.rkt"
         (prefix-in app: "../base/event.rkt"))

;;; ════════════════ 小工具 ════════════════

(define (message ctx text)
  (transition-pure
   (state-chrome* (ctx-state ctx) (λ (c) (chrome-set-message c text)))))

(define (view-subject ctx)
  (define s (ctx-subject ctx))
  (and (view-id? s) s))

(define (input-busy? ctx) (state-input-active? (ctx-state ctx)))

(define (frame-area state)
  (rect 0 0 (window-cols (state-window state)) (window-rows (state-window state))))

;;; ════════════════ 基础命令 ════════════════

(define (nav-command dir)
  (cmd (λ (ctx)
         (define vid (view-subject ctx))
         (if vid
             (transition (ctx-state ctx) (list (nav-effect vid dir)))
             (message ctx "nav: no view")))))

(define (insert-command text)
  (cmd (λ (ctx)
         (define vid (view-subject ctx))
         (if vid
             (transition (ctx-state ctx) (list (insert-text-effect vid text)))
             (message ctx "insert: no view")))))

(define (edit-command op)
  (cmd (λ (ctx)
         (define vid (view-subject ctx))
         (if vid
             (transition (ctx-state ctx) (list (edit-effect vid op)))
             (message ctx "edit: no view")))))

(define (undo-command)
  (cmd (λ (ctx)
         (define vid (view-subject ctx))
         (if vid (transition (ctx-state ctx) (list (undo-effect vid)))
             (message ctx "undo: no view")))))

(define (redo-command)
  (cmd (λ (ctx)
         (define vid (view-subject ctx))
         (if vid (transition (ctx-state ctx) (list (redo-effect vid)))
             (message ctx "redo: no view")))))

(define (quit-command)
  (cmd (λ (ctx) (transition-pure (state-mark-quit (ctx-state ctx))))))

;;; ════════════════ 切分 / 关闭 ════════════════

(define (split-view-command dir)
  (cmd (λ (ctx) (split-view ctx dir))))

(define (split-view ctx dir)
  (define s (ctx-state ctx))
  (define vid (view-subject ctx))
  (define ws (state-workspace s))
  (define did (and vid (workspace-doc-of-view ws vid)))
  (define reg (and vid (workspace-view-region ws vid)))
  (define role (and reg (region-role reg)))
  (cond
    [(input-busy? ctx) (message ctx "split: input active")]
    [(not (and did reg)) (message ctx "split: no view")]
    [(not (role-splittable? (environment-role (ctx-env ctx) role)))
     (message ctx "split: region not splittable")]
    [else
     (define rid (region-key reg))
     (define leaf (tree-find (workspace-layout ws) rid))
     (define borders (if leaf (leaf-borders leaf) leaf-borders-all))
     (transition s
                 (list (open-view-effect did
                                          (λ (s* nvid)
                                            (mount-split s* rid borders nvid dir)))))]))
(define (axis/side dir)
  (case dir
    [(left)  (values 'lr 'before)]
    [(right) (values 'lr 'after)]
    [(up)    (values 'tb 'before)]
    [(down)  (values 'tb 'after)]
    [else (error 'split-view "未知方向：~a" dir)]))

(define (mount-split s source-rid borders nvid dir)
  (define-values (axis side) (axis/side dir))
  (define-values (nrid s1) (state-next-id s 'region))
  (define ws (state-workspace s1))
  (define source-reg (workspace-region ws source-rid))
  (define new-reg (region nrid
                          (list (view-member nvid))
                          nvid
                          (if source-reg (region-role source-reg) 'editor)))
  (define ws* (workspace-add-region ws nrid new-reg))
  (define layout* (tree-split (workspace-layout ws*) source-rid axis nrid
                              #:side side #:borders borders))
  (define s2 (state-set-workspace s1 (struct-copy workspace ws* [layout layout*])))
  (transition-pure (state-set-focus s2 nvid)))

(define (close-view-command)
  (cmd (λ (ctx) (close-view ctx))))

(define (close-view ctx)
  (define s (ctx-state ctx))
  (define vid (view-subject ctx))
  (define ws (state-workspace s))
  (define reg (and vid (workspace-view-region ws vid)))
  (define role (and reg (region-role reg)))
  (define policy (if role (role-close-policy (environment-role (ctx-env ctx) role)) 'ignore))
  (cond
    [(not vid) (message ctx "close: no view")]
    [(eq? policy 'ignore) (message ctx "close: region ignores close")]
    [else
     (define source-rid (and reg (region-key reg)))
     (define ws* (workspace-remove-view ws vid))
     ;; 优先同 region 里的其它真实 document view，其次任意 attached 真实 view。
     (define fallback
       (or (and source-rid
                (for/first ([v (in-list (workspace-region-views ws* source-rid))]
                            #:when (let ([vm (workspace-view ws* v)])
                                     (and vm (real-view? ws* vm))))
                  v))
           (fallback-attached-view ws*)))
     (define ws** (workspace-set-focus* ws* fallback #:push? #f))
     (transition (state-set-workspace s ws**)
                 (list (close-view-effect vid)))]))

;;; ════════════════ 新建 view / document ════════════════

(define (region-has-view? reg)
  (for/or ([m (in-list (region-members reg))]) (view-member? m)))

;; 目标 region：当前 view 所在 region；没有 view 时找第一个空的 editor region。
(define (target-region-for-new-view* s subj)
  (define ws (state-workspace s))
  (cond
    [(and (view-id? subj) (workspace-view-region ws subj))]
    [else
     (for/first ([r (in-hash-values (workspace-regions ws))]
                 #:when (and (eq? (region-role r) 'editor)
                             (not (region-has-view? r))))
       r)]))

(define (target-region-for-new-view ctx)
  (target-region-for-new-view* (ctx-state ctx) (ctx-subject ctx)))

(define (mount-view-in-region s rid vid)
  (define ws (state-workspace s))
  (cond
    [(not (workspace-region ws rid)) (transition-pure s)]
    [else
     (define ws* (workspace-attach-view ws rid vid))
     (transition-pure (state-set-focus (state-set-workspace s ws*) vid))]))

(define (new-document-command)
  (cmd (λ (ctx)
         (define s (ctx-state ctx))
         (define target (target-region-for-new-view ctx))
         (cond
           [(input-busy? ctx) (message ctx "new: input active")]
           [(not target) (message ctx "new: no editor region")]
           [else
            (transition
             s
             (list (open-doc-effect
                    (make-open-doc-spec "*scratch*" "")
                    (λ (s* _did vid)
                      (mount-view-in-region s* (region-key target) vid)))))]))))

;;; ════════════════ 打开 / 关闭文件 ════════════════

(define (notice-state-value s text)
  (state-chrome* s (λ (c) (chrome-set-message c text))))

(define (notice-state s text)
  (transition-pure (notice-state-value s text)))

;; 把新打开的 doc/view 装进当前 region（或空 editor region）。
(define (mount-opened-document s vid)
  (define target (target-region-for-new-view* s (state-focus s)))
  (cond
    [(not target) (notice-state s "open: no editor region")]
    [else (mount-view-in-region s (region-key target) vid)]))

;; 打开文件：读盘成功 -> open-doc-effect（携带 mode + per-doc keymaps）。
(define (open-file-from-path ctx s path)
  (define env (ctx-env ctx))
  (define dt (environment-doc-type-for-path env path))
  (define mode (if dt (doc-type-mode dt) 'text))
  (define keymaps (if dt (doc-type-keymaps dt) '()))
  (define name (let ([n (file-name-from-path path)])
                 (if n (path->string n) path)))
  (transition
   s
   (list (read-file-effect
          path
          (λ (s* text)
            (if text
                (transition
                 s*
                 (list (open-doc-effect
                        (make-open-doc-spec name text
                                            #:path path
                                            #:mode mode
                                            #:keymaps keymaps)
                        (λ (s** _did vid)
                          (mount-opened-document s** vid)))))
                (notice-state s* (format "open failed: ~a" path))))))))

(define (open-file-prompt-command)
  (cmd (λ (ctx)
         (input-show ctx "Open file: "))))

(define (close-doc-action* state did)
  (close-doc-action state did))

;;; ════════════════ dirty / save-confirm ════════════════

(define (doc-dirty? state ev did)
  (define dm (workspace-doc (state-workspace state) did))
  (define saved (and dm (doc-meta-saved-version dm)))
  (define cur (engine-view-doc-version ev did))
  (and dm cur
       (or (not saved) (not (engine-version=? saved cur)))))

(define (saveable-doc? dm)
  (not (memq (doc-meta-mode dm) '(status state input resources filetree))))

(define (dirty-docs state ev)
  (sort (for/list ([(did dm) (in-hash (workspace-docs (state-workspace state)))]
                   #:when (and (saveable-doc? dm) (doc-dirty? state ev did)))
          did)
        string<? #:key id->string))

(define (doc-label state did)
  (define dm (workspace-doc (state-workspace state) did))
  (and dm (or (doc-meta-path dm) (doc-meta-name dm) "*untitled*")))

(define (save-confirm-label state did)
  (format "Save ~a? (y/n/yall/nall) " (or (doc-label state did) "*untitled*")))

(define (close-doc-action state did)
  (define ws (state-workspace state))
  (define doomed
    (for/list ([(v vm) (in-hash (workspace-views ws))]
               #:when (equal? (view-meta-doc vm) did))
      v))
  (define (doomed? v)
    (for/or ([x (in-list doomed)]) (equal? v x)))
  (define (real-view? v vm)
    (define dm (workspace-doc ws (view-meta-doc vm)))
    (and dm (saveable-doc? dm)))
  (define fallback
    (for/first ([(v vm) (in-hash (workspace-views ws))]
                #:when (real-view? v vm)
                #:unless (doomed? v))
      v))
  (define ws* (workspace-set-focus* ws fallback #:push? #f))
  (transition (state-set-workspace state ws*)
              (list (close-doc-effect did))))

;; 当前 confirm 的 doc。
(define (confirm-current-doc state)
  (define c (resources-confirm (state-resources state)))
  (and c
       (let ([idx (save-confirm-index c)])
         (and (< idx (length (save-confirm-docs c)))
              (list-ref (save-confirm-docs c) idx)))))

;; 显示当前 confirm 项的 prompt（input document）。
(define (save-confirm-show ctx did)
  (input-show ctx (save-confirm-label (ctx-state ctx) did)))

(define (save-confirm-show-state state did)
  (input-show-state state (save-confirm-label state did)))

(define (save-confirm-start ctx docs action)
  (define s1 (state-resources*
              (ctx-state ctx)
              (λ (r) (resources-set-confirm r (make-save-confirm docs action)))))
  (define ctx* (make-ctx (ctx-env ctx) s1 (ctx-event ctx) (ctx-subject ctx) (ctx-engine ctx)))
  (save-confirm-show ctx* (car docs)))

;; 当前项处理完：还有下一个 -> 显示下一项；否则执行 action。
(define (confirm-next state)
  (define c (resources-confirm (state-resources state)))
  (cond
    [(not c) (transition-pure state)]
    [else
     (define docs (save-confirm-docs c))
     (define idx* (add1 (save-confirm-index c)))
     (if (< idx* (length docs))
         (let* ([did (list-ref docs idx*)]
                [s1 (state-resources*
                     state
                     (λ (r)
                       (resources-set-confirm
                        r (struct-copy save-confirm c [index idx*]))))])
           (save-confirm-show-state s1 did))
         (confirm-finish state))]))

(define (confirm-finish state)
  (define c (resources-confirm (state-resources state)))
  (define action (and c (save-confirm-action c)))
  (define s1 (state-resources* state (λ (r) (resources-set-confirm r #f))))
  (cond
    [(eq? action 'quit) (transition-pure (state-mark-quit s1))]
    [(and (pair? action) (eq? (car action) 'close-doc))
     (close-doc-action s1 (cdr action))]
    [else (transition-pure s1)]))

(define (confirm-save-current ctx state did)
  (define dm (and did (workspace-doc (state-workspace state) did)))
  (cond
    [(not did) (confirm-finish state)]
    ;; 没有 path：先进入 save-as 输入；保存成功后继续 confirm-next。
    [(not (doc-meta-path dm))
     (input-show (make-ctx (ctx-env ctx) state (ctx-event ctx)
                           (ctx-subject ctx) (ctx-engine ctx))
                 "Save as: ")]
    [else
     (transition state
                 (list (save-doc-effect
                        did
                        (λ (s ok?)
                          (if ok?
                              (confirm-next s)
                              (save-confirm-show-state
                               (notice-state-value
                                s (format "save failed: ~a"
                                          (or (doc-label s did) did)))
                               did))))))]))

;; 保存当前 + 后面所有 dirty docs，然后执行 action。
(define (save-docs-then state docs [offset 0])
  (cond
    [(null? docs) (confirm-finish state)]
    [else
     (define did (car docs))
     (define dm (workspace-doc (state-workspace state) did))
     (cond
       ;; 没有 path：停在当前项，提示用户 y 走 Save as。
       [(not (doc-meta-path dm))
        (define c (resources-confirm (state-resources state)))
        (define idx (+ (save-confirm-index c) offset))
        (define s1 (state-resources*
                    state
                    (λ (r)
                      (resources-set-confirm
                       r (struct-copy save-confirm c [index idx])))))
        (save-confirm-show-state
         (notice-state-value s1 (format "no path; press y to Save as: ~a"
                                        (doc-label s1 did)))
         did)]
       [else
        (transition state
                    (list (save-doc-effect
                           did
                           (λ (s ok?)
                             (if ok?
                                 (save-docs-then s (cdr docs) (add1 offset))
                                 (save-confirm-show-state
                                  (notice-state-value
                                   s (format "save failed: ~a"
                                             (or (doc-label s did) did)))
                                  did))))))])]))

;; ════════════════ 输入栏提交 ════════════════

(define (input-submit-command)
  (cmd (λ (ctx)
         (define s (ctx-state ctx))
         (define text (input-read-text s (ctx-engine ctx)))
         (define hit (and text
                          (input-command-list
                           (environment-input-commands (ctx-env ctx))
                           text)))
         (cond
           [(not hit)
            (transition-pure
             (state-chrome* (input-finish s)
                            (λ (c) (chrome-set-message c "input: no matching command"))))]
           [else
            ((input-command-handler (car hit)) ctx (cdr hit))]))))

(define (input-cancel-command)
  (cmd (λ (ctx) (transition-pure (input-cancel ctx)))))

;; 把整串输入（prompt + answer）交给 handler。
(define (handle-save-answer ctx state answer)
  (define a (string-trim answer))
  (define c (resources-confirm (state-resources state)))
  (cond
    [(not c) (transition-pure state)]
    [(string=? a "y") (confirm-save-current ctx state (confirm-current-doc state))]
    [(string=? a "n") (confirm-next state)]
    [(string=? a "yall")
     (save-docs-then state
                     (drop (save-confirm-docs c) (save-confirm-index c))
                     0)]
    [(string=? a "nall") (confirm-finish state)]
    [else
     (define did (confirm-current-doc state))
     (if did
         (save-confirm-show-state
          (notice-state-value state "answer must be y/n/yall/nall")
          did)
         (notice-state state "answer must be y/n/yall/nall"))]))

;; 把当前 document 存到指定 path；成功后若在 confirm 流程里就继续下一项。
(define (save-doc-to-path ctx state path)
  (define vid (state-focus state))
  (define ws (state-workspace state))
  (define did (and vid (workspace-doc-of-view ws vid)))
  (define dm (and did (workspace-doc ws did)))
  (cond
    [(not did) (notice-state state "save-as: no document")]
    [else
     (define dm* (struct-copy doc-meta dm [path path]))
     (define ws* (workspace-add-doc ws did dm*))
     (define s1 (state-set-workspace state ws*))
     (transition s1
                 (list (save-doc-effect
                        did
                        (λ (s ok?)
                          (cond
                            [(not ok?)
                             (input-show-state
                              (notice-state-value s (format "save failed: ~a" path))
                              "Save as: ")]
                            [(resources-confirm (state-resources s)) (confirm-next s)]
                            [else (notice-state s (format "saved: ~a" path))])))))]))

(define (save-current-command)
  (cmd (λ (ctx)
         (define s (ctx-state ctx))
         (define vid (state-focus s))
         (define ws (state-workspace s))
         (define did (and vid (workspace-doc-of-view ws vid)))
         (define dm (and did (workspace-doc ws did)))
         (define path (and dm (doc-meta-path dm)))
         (cond
           [(input-busy? ctx) (message ctx "save: input active")]
           [(not did) (message ctx "save: no document")]
           [(not path) (input-show ctx "Save as: ")]
           [else
            (transition
             s
             (list (save-doc-effect
                    did
                    (λ (s* ok?)
                      (if ok?
                          (notice-state s* (format "saved: ~a" path))
                          (notice-state s* (format "save failed: ~a" path)))))))]))))

;; 输入栏默认命令：open-file / save-confirm / save-as。
(define (default-input-commands)
  (list
   (make-input-command
    'open-file
    (input-command-prefix "Open file: ")
    (λ (ctx path)
      (define s1 (input-finish (ctx-state ctx)))
      (open-file-from-path ctx s1 path)))
   (make-input-command
    'save-confirm
    (input-command-regexp #rx"^Save (.*)\\? \\(y/n/yall/nall\\) (.*)$")
    (λ (ctx matched)
      ;; matched = (full path answer)
      (define state (input-finish (ctx-state ctx)))
      (handle-save-answer ctx state (caddr matched)))
    #:cancel (λ (s)
               (state-resources* s (λ (r) (resources-set-confirm r #f)))))
   (make-input-command
    'save-as
    (input-command-prefix "Save as: ")
    (λ (ctx path)
      (define state (input-finish (ctx-state ctx)))
      (save-doc-to-path ctx state path))
    #:cancel (λ (s)
               (state-resources* s (λ (r) (resources-set-confirm r #f)))))))

(define (request-quit-command)
  (cmd (λ (ctx)
         (define s (ctx-state ctx))
         (define docs (dirty-docs s (ctx-engine ctx)))
         (if (null? docs)
             (transition-pure (state-mark-quit s))
             (save-confirm-start ctx docs 'quit)))))

;; 统一的“请求关闭 document”入口：所有关闭 doc 的命令都应走这里。
(define (request-close-doc ctx did)
  (define s (ctx-state ctx))
  (cond
    [(input-busy? ctx) (message ctx "close-doc: input active")]
    [(not did) (message ctx "close-doc: no document")]
    [(doc-dirty? s (ctx-engine ctx) did)
     (save-confirm-start ctx (list did) (cons 'close-doc did))]
    [else (close-doc-action s did)]))

(define (request-close-file-command)
  (cmd (λ (ctx)
         (define s (ctx-state ctx))
         (define vid (view-subject ctx))
         (define ws (state-workspace s))
         (define did (and vid (workspace-doc-of-view ws vid)))
         (request-close-doc ctx did))))

;; 强制关闭（不走确认）；保留给内部 / 测试。
(define (close-file-command)
  (cmd (λ (ctx)
         (define s (ctx-state ctx))
         (define vid (view-subject ctx))
         (define did (and vid (workspace-doc-of-view (state-workspace s) vid)))
         (if did (close-doc-action s did)
             (message ctx "close-file: no document")))))

;;; ════════════════ detach / attach view（资源层，不关 view） ════════════════

(define (real-view? ws vm)
  (define dm (workspace-doc ws (view-meta-doc vm)))
  (and dm (saveable-doc? dm)))

(define (fallback-attached-view ws [exclude #f])
  (for/first ([(v vm) (in-hash (workspace-views ws))]
              #:when (and (real-view? ws vm)
                          (workspace-view-attached? ws v)
                          (not (equal? v exclude))))
    v))

;; 把当前 view 从 panel 里拿出来，但保留 view + engine view + document。
(define (detach-view-command)
  (cmd (λ (ctx)
         (cond
           [(input-busy? ctx) (message ctx "detach: input active")]
           [else
            (define s (ctx-state ctx))
            (define vid (view-subject ctx))
            (cond
              [(not vid) (message ctx "detach: no view")]
              [else
               (define ws (state-workspace s))
               (define ws* (workspace-detach-view ws vid))
               (define focus* (fallback-attached-view ws* vid))
               (define ws** (workspace-set-focus* ws* focus* #:push? #f))
               (transition-pure (state-set-workspace s ws**))])]))))

;; 把第一个 detached view 挂到当前 region（演示 / 临时入口）。
(define (attach-detached-command)
  (cmd (λ (ctx)
         (cond
           [(input-busy? ctx) (message ctx "attach: input active")]
           [else
            (define s (ctx-state ctx))
            (define ws (state-workspace s))
            (define detached (workspace-detached-views ws))
            (define fallback-region
              (or (and (state-focus s)
                       (workspace-view-region ws (state-focus s)))
                  (for/first ([r (in-hash-values (workspace-regions ws))]
                              #:when (eq? (region-role r) 'editor))
                    r)))
            (cond
              [(null? detached) (message ctx "attach: no detached view")]
              [(not fallback-region) (message ctx "attach: no region")]
              [else
               (define vid (car detached))
               (define ws* (workspace-attach-view ws (region-key fallback-region) vid))
               (transition-pure (state-set-focus (state-set-workspace s ws*) vid))])]))))

;; 在同一 region 的多个 view 之间循环 active / focus。
(define (cycle-region-view-command)
  (cmd (λ (ctx)
         (cond
           [(input-busy? ctx) (message ctx "cycle: input active")]
           [else
            (define s (ctx-state ctx))
            (define vid (view-subject ctx))
            (define ws (state-workspace s))
            (define reg (and vid (workspace-view-region ws vid)))
            (cond
              [(not reg) (message ctx "cycle: no region")]
              [else
               (define vids (workspace-region-views ws (region-key reg)))
               (cond
                 [(< (length vids) 2) (message ctx "cycle: single view")]
                 [else
                  (define active (region-active reg))
                  (define idx (index-of vids active))
                  (define next (list-ref vids (modulo (add1 (or idx -1))
                                                      (length vids))))
                  (define ws* (workspace-attach-view ws (region-key reg) next))
                  (transition-pure (state-set-focus (state-set-workspace s ws*) next))])])]))))

;;; ════════════════ 关闭 region / panel ════════════════

(define (subject-region ctx)
  (define subj (ctx-subject ctx))
  (define ws (state-workspace (ctx-state ctx)))
  (cond
    [(view-id? subj) (workspace-view-region ws subj)]
    [(region-id? subj) (workspace-region ws subj)]
    [else #f]))

(define (count-role-regions ws role)
  (for/sum ([r (in-hash-values (workspace-regions ws))]
            #:when (eq? (region-role r) role))
    1))

;; keep-last 的边界：同 role 只剩这一块。
(define (last-region-of-role? ws role)
  (= 1 (count-role-regions ws role)))

;; 把 region 里所有 view **摘出来**（保留资源），返回新 workspace + 无 effect。
(define (drop-region-views ws rid)
  (define vids (workspace-region-views ws rid))
  (values (for/fold ([w ws]) ([vid (in-list vids)])
            (workspace-detach-view w vid))
          '()))

;; 其它 region 的 active view（排除 rid）；没有 -> #f。
(define (fallback-view ws rid)
  (for/first ([r (in-hash-values (workspace-regions ws))]
              #:unless (equal? (region-key r) rid)
              #:when (view-id? (region-active r)))
    (region-active r)))

(define (close-region-command)
  (cmd (λ (ctx) (close-region ctx))))

(define (close-region ctx)
  (define s (ctx-state ctx))
  (define ws (state-workspace s))
  (define reg (subject-region ctx))
  (cond
    [(not reg) (message ctx "close-region: no region")]
    [else
     (define rid (region-key reg))
     (define role (region-role reg))
     (define policy (role-close-policy (environment-role (ctx-env ctx) role)))
     (case policy
       [(ignore)
        (message ctx "close-region: region ignores close")]

       [(hide)
        ;; 只从布局里隐藏；views / region 元数据都保留，之后可 show-region。
        (define ws1 (struct-copy workspace ws
                                 [layout (tree-hide (workspace-layout ws) rid)]))
        (define fb (fallback-view ws1 rid))
        (define ws2 (workspace-set-focus* ws1 fb #:push? #f))
        (transition (state-set-workspace s ws2) '())]

       [(delete)
        (define-values (ws1 evs) (drop-region-views ws rid))
        (define ws2 (workspace-remove-region ws1 rid))
        (define fb (fallback-view ws2 rid))
        (define ws3 (workspace-set-focus* ws2 fb #:push? #f))
        (transition (state-set-workspace s ws3) evs)]

       [(keep-last)
        (if (not (last-region-of-role? ws role))
            ;; 不是最后一块：按 delete 处理
            (let-values ([(ws1 evs) (drop-region-views ws rid)])
              (define ws2 (workspace-remove-region ws1 rid))
              (define fb (fallback-view ws2 rid))
              (define ws3 (workspace-set-focus* ws2 fb #:push? #f))
              (transition (state-set-workspace s ws3) evs))
            ;; 最后一块：清掉 views，但保留空 region 占位
            (let-values ([(ws1 evs) (drop-region-views ws rid)])
              (define fb (fallback-view ws1 rid))
              (define ws2 (workspace-set-focus* ws1 fb #:push? #f))
              (transition (state-set-workspace s ws2) evs)))]

       [else
        (message ctx (format "close-region: unknown policy ~a" policy))])]))

;;; ════════════════ 焦点移动 ════════════════

(define (focus-move-command dir)
  (cmd (λ (ctx) (focus-move ctx dir))))

(define (focus-move ctx dir)
  (define s (ctx-state ctx))
  (define vid (view-subject ctx))
  (define ws (state-workspace s))
  (define reg (and vid (workspace-view-region ws vid)))
  (cond
    [(input-busy? ctx) (message ctx "focus: input active")]
    [(not reg) (message ctx "focus: no view")]
    [else
     (define-values (rps _cuts)
       (geometry-solve (workspace-layout ws) (frame-area s)))
     ;; 用 region id 当 panel 的 owner，走 core 的方向导航。
     (define panels
       (for/list ([rp (in-list rps)])
         (make-panel (region-panel-region rp)
                     (region-panel-rect rp)
                     (region-panel-borders rp))))
     (define from
       (for/first ([p (in-list panels)]
                   #:when (equal? (panel-view p) (region-key reg)))
         p))
     (define nbr (and from (panel-neighbor panels from dir)))
     (define target-rid (and nbr (panel-view nbr)))
     (define target-reg (and target-rid (workspace-region ws target-rid)))
     (define target-vid (and target-reg (workspace-region-active ws target-rid)))
     (if (view-id? target-vid)
         (transition-pure (state-set-focus s target-vid))
         (message ctx "focus: no neighbor view"))]))

;;; ════════════════ 鼠标：点击落点 / 拖选 ════════════════

;; 屏幕 (row,col) -> 焦点 view 的文档 point。
;; view 的屏幕坐标是「panel 内容区」内的坐标，所以要先减去内容区原点。
(define (screen->point ctx vid row col)
  (define s (ctx-state ctx))
  (define ws (state-workspace s))
  (define reg (workspace-view-region ws vid))
  (define eview (ctx-engine ctx))
  (cond
    [(not (and reg eview)) #f]
    [else
     (define area (frame-area s))
     (define-values (rps _cuts) (geometry-solve (workspace-layout ws) area))
     (define rp
       (for/first ([p (in-list rps)]
                   #:when (equal? (region-panel-region p) (region-key reg)))
         p))
     (cond
       [(not rp) #f]
       [else
        (define content (region-panel-content rp))
        (define-values (line c)
          (engine-view-view-screen-position->point
           eview vid
           (- row (rect-y content))
           (- col (rect-x content))))
        (and line (point line c))])]))

(define (pointer-press-command)
  (cmd (λ (ctx)
         (define vid (view-subject ctx))
         (define ev (ctx-event ctx))
         (if (not (and vid (app:mouse-event? ev)))
             (transition-pure (ctx-state ctx))
             (let ([pt (screen->point ctx vid
                                      (app:mouse-event-row ev)
                                      (app:mouse-event-col ev))])
               (if (not pt)
                   (transition-pure (state-set-focus (ctx-state ctx) vid))
                   (let* ([s1 (state-set-focus (ctx-state ctx) vid)]
                          [s2 (state-input*
                               s1
                               (λ (i)
                                 (input-set-gesture
                                  i (make-gesture 'select vid (list vid pt)))))] )
                     (transition s2
                                 (list (select-effect
                                        vid
                                        (selections-one (caret pt))))))))))))

(define (pointer-drag-command)
  (cmd (λ (ctx)
         (define s (ctx-state ctx))
         (define d (input-gesture (state-input s)))
         (define ev (ctx-event ctx))
         (if (not (and (gesture? d) (eq? (gesture-kind d) 'select)))
             (transition-pure s)
             (let* ([vid (gesture-owner d)]
                    [anchor (cadr (gesture-data d))]
                    [pt (and (app:mouse-event? ev)
                             (screen->point ctx vid
                                            (app:mouse-event-row ev)
                                            (app:mouse-event-col ev)))])
               (if pt
                   (transition s
                               (list (select-effect
                                      vid
                                      (selections-one (selection anchor pt)))))
                   (transition-pure s)))))))

;;; ════════════════ 默认命令表 ════════════════

(define (default-command-table)
  (define base
    (hash 'quit         (request-quit-command)
        'request-quit (request-quit-command)
        'request-close-file (request-close-file-command)
        'nav-left     (nav-command 'left)
        'nav-right    (nav-command 'right)
        'nav-up       (nav-command 'up)
        'nav-down     (nav-command 'down)
        'nav-home     (nav-command 'home)
        'nav-end      (nav-command 'end)
        'insert-enter (insert-command "\n")
        'backspace    (edit-command (op-backspace))
        'delete       (edit-command (op-delete))
        'undo         (undo-command)
        'redo         (redo-command)
        'split-right  (split-view-command 'right)
        'split-down   (split-view-command 'down)
        'close-view   (close-view-command)
        'detach-view  (detach-view-command)
        'attach-detached (attach-detached-command)
        'cycle-view  (cycle-region-view-command)
        'close-region (close-region-command)
        'new-document (new-document-command)
        'open-file    (open-file-prompt-command)
        'save-current (save-current-command)
        'close-file   (request-close-file-command)
        'input-submit (input-submit-command)
        'input-cancel (input-cancel-command)
        'focus-left   (focus-move-command 'left)
        'focus-right  (focus-move-command 'right)
        'focus-up     (focus-move-command 'up)
        'focus-down   (focus-move-command 'down)
        'pointer-press (pointer-press-command)
        'pointer-drag  (pointer-drag-command)))
  (define h1
    (for/fold ([h base]) ([(k v) (in-hash (resource-command-table))])
      (hash-set h k v)))
  (for/fold ([h h1]) ([(k v) (in-hash (filetree-command-table))])
    (hash-set h k v)))
