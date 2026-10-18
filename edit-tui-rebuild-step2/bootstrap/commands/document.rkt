#lang racket

;;; layer  : bootstrap/commands
;;; effect : 文件读写 / 保存 / 关闭文档（read-file-effect / save-doc-effect / close-doc-effect）
;;;          另外会驱动 input 栏（打开文件、Save as、保存确认）
;;;
;;; document 生命周期 + 保存确认是一个整体，故意放在一个模块里：
;;;   open  : open-file-prompt -> read-file-effect -> open-doc-effect -> 装进 region
;;;   save  : save-current / save-doc-to-path
;;;   close : request-close-doc -> (dirty? 则 save-confirm) -> close-doc-effect
;;;   quit  : request-quit -> (dirty? 则 save-confirm) -> runtime.quit?
;;;
;;; 保存确认队列在 state.confirm（model/save.rkt），答案走 input 栏：
;;;   prompt = "Save <doc>? (y/n/yall/nall) "，提交后按字符串匹配。
;;; 这几件事互相递归（confirm 完成后要继续 close/quit；save-as 完成后要继续 confirm），
;;; 所以不再拆成多个模块 —— 拆了要么循环 require，要么到处传回调。

(provide open-file-prompt-command
         open-file-from-path
         save-current-command
         save-doc-to-path
         request-quit-command
         request-close-doc
         request-close-file-command
         close-file-command
         input-submit-command
         input-cancel-command
         confirm-cancel
         save-continuation-handlers
         default-input-commands
         saveable-doc?
         dirty-docs)

(require racket/path
         racket/string
         "../../base/id.rkt"
         "../../base/transition.rkt"
         "../../base/effect.rkt"
         "../../model/state.rkt"
         "../../model/workspace.rkt"
         "../../model/save.rkt"
         "../../model/chrome.rkt"
         "../../model/interaction.rkt"
         "../../env/command.rkt"
         "../../env/environment.rkt"
         "../../env/doc-type.rkt"
         "../../env/input-command.rkt"
         "../../effects/engine.rkt"
         "../../effects/interpreter.rkt"
         "../../dispatch/context.rkt"
         (only-in "../../chrome/input.rkt"
                  input-show input-show-state input-finish input-read-text input-active?
                  input-cancel)
         "util.rkt"
         "view.rkt")

;; confirm 取消：清 confirm + 从 interaction 栈移除 'confirm 项。
(define (confirm-cancel-state s)
  (state-interaction-pop-id (state-set-confirm s #f) 'confirm))

(define (confirm-cancel ctx)
  (notice-state (confirm-cancel-state (ctx-state ctx)) "save confirm cancelled"))

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
         (input-show ctx "Open file: " #:tag 'open-file))))

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
  (not (doc-meta-internal? dm)))

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
  (define c (state-confirm state))
  (and c
       (let ([idx (save-confirm-index c)])
         (and (< idx (length (save-confirm-docs c)))
              (list-ref (save-confirm-docs c) idx)))))

;; 显示当前 confirm 项的 prompt（input document）。
(define (save-confirm-show ctx did)
  (input-show ctx (save-confirm-label (ctx-state ctx) did)
              #:tag 'save-confirm
              #:data did
              #:cancel confirm-cancel-state))

(define (save-confirm-show-state state did)
  (input-show-state state (save-confirm-label state did)
                     #:tag 'save-confirm
                     #:data did
                     #:cancel confirm-cancel-state))

(define (save-confirm-start ctx docs action)
  ;; 先取消旧 input（若占用），再写新的 confirm；否则 input-show 的取消钩子
  ;; 会清掉刚设置的新 confirm。
  (define base (if (input-active? (ctx-state ctx))
                   (input-cancel ctx)
                   (ctx-state ctx)))
  (define s1 (state-set-confirm base (make-save-confirm docs action)))
  (define s2
    (state-interaction-push
     s1 (make-interaction 'confirm 'confirm #f)))
  (save-confirm-show-state s2 (car docs)))

;; 当前项处理完：还有下一个 -> 显示下一项；否则执行 action。
(define (confirm-next state)
  (define c (state-confirm state))
  (cond
    [(not c) (transition-pure state)]
    [else
     (define docs (save-confirm-docs c))
     (define idx* (add1 (save-confirm-index c)))
     (if (< idx* (length docs))
         (let* ([did (list-ref docs idx*)]
                [s1 (state-set-confirm
                     state (struct-copy save-confirm c [index idx*]))])
           (save-confirm-show-state s1 did))
         (confirm-finish state))]))

(define (confirm-finish state)
  (define state* (state-interaction-pop-id state 'confirm))
  (define c (state-confirm state*))
  (define action (and c (save-confirm-action c)))
  (define s1 (state-set-confirm state* #f))
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
                 "Save as: "
                 #:tag 'save-as
                 #:cancel confirm-cancel-state)]
    [else
     (transition state
                 (list (save-doc-effect
                        did
                        (make-continuation 'save-confirm did))))]))

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
        (define c (state-confirm state))
        (define idx (+ (save-confirm-index c) offset))
        (define s1 (state-set-confirm
                    state (struct-copy save-confirm c [index idx])))
        (save-confirm-show-state
         (notice-state-value s1 (format "no path; press y to Save as: ~a"
                                        (doc-label s1 did)))
         did)]
       [else
        (transition state
                    (list (save-doc-effect
                           did
                           (make-continuation 'save-docs-then (cons docs offset)))))])]))

;;; save-doc 的数据 continuation handlers（注册在 core-env）。
(define (save-continuation-handlers)
  (hash
   'save-current
   (λ (s path ok?)
     (if ok?
         (notice-state s (format "saved: ~a" path))
         (notice-state s (format "save failed: ~a" path))))
   'save-as
   (λ (s path ok?)
     (cond
       [(not ok?)
        (input-show-state
         (notice-state-value s (format "save failed: ~a" path))
         "Save as: "
         #:tag 'save-as
         #:data path
         #:cancel confirm-cancel-state)]
       [(state-confirm s) (confirm-next s)]
       [else (notice-state s (format "saved: ~a" path))]))
   'save-confirm
   (λ (s did ok?)
     (if ok?
         (confirm-next s)
         (save-confirm-show-state
          (notice-state-value
           s (format "save failed: ~a" (or (doc-label s did) did)))
          did)))
   'save-docs-then
   (λ (s data ok?)
     (define docs (car data))
     (define offset (cdr data))
     (define did (car docs))
     (if ok?
         (save-docs-then s (cdr docs) (add1 offset))
         (save-confirm-show-state
          (notice-state-value
           s (format "save failed: ~a" (or (doc-label s did) did)))
          did)))))

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
  (define c (state-confirm state))
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
                        (make-continuation 'save-as path))))]))

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
           [(not path) (input-show ctx "Save as: "
                                   #:tag 'save-as
                                   #:cancel confirm-cancel-state)]
           [else
            (transition
             s
             (list (save-doc-effect
                    did
                    (make-continuation 'save-current path))))]))))
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
    #:cancel confirm-cancel-state)
   (make-input-command
    'save-as
    (input-command-prefix "Save as: ")
    (λ (ctx path)
      (define state (input-finish (ctx-state ctx)))
      (save-doc-to-path ctx state path))
    #:cancel confirm-cancel-state)))

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
