#lang racket

;;; edit-tui/demo/completion-docs.rkt —— 补全弹窗 + 文档面板 demo
;;;
;;; 布局：
;;;   editor
;;;   docs      （编辑区与状态栏之间，可显隐）
;;;   status
;;;
;;; 键：
;;;   C-o        打开补全（光标处前缀）
;;;   Up/Down    移动候选
;;;   Tab        下一个候选
;;;   Enter      接受
;;;   Esc/C-g    关闭
;;;   M-d        查看光标处标识符文档
;;;   C-x d      显 / 隐 docs 面板
;;;
;;; 运行：
;;;   racket edit-tui/demo/completion-docs.rkt

(require (except-in racket/list range)
         racket/async-channel
         racket/match
         racket/string
         racket/path
         (prefix-in tui: tui)
         "../config/keymap/default.rkt"
         "../config/layout/default.rkt"
         "../config/theme/default.rkt"
         "../config/mode.rkt"
         "../main.rkt"
         "../lang/racket/api.rkt"
         "../source/api.rkt"
         "completion-popup.rkt")

(provide demo-state demo-engine prepare-demo!
         empty-docs
         completion-service docs-service handle-job-result
         demo-services
         handle-auto-timer!
         run-demo)

;;; ════════════════ 数据 ════════════════

(struct demo-source
  (doc-id view-id source-id path mode text version line col workspace)
  #:transparent)

(struct completion-state
  (target-vid prefix candidates index source-info request-id status
   target-version anchor-line anchor-col)
  #:transparent)

(struct docs-state
  (lines faces)
  #:transparent)

(struct docs-request
  (id tag)
  #:transparent)

(struct auto-state
  (timer-id dismissed? suppress-next?)
  #:transparent)

(define empty-auto (auto-state #f #f #f))

(define (store-ref state key default)
  (hash-ref (app-state-store state) key default))

(define (store-set state key value)
  (struct-copy app-state state
               [store (hash-set (app-state-store state) key value)]))

(define empty-docs
  (docs-state (list "No docs yet — open completion or press M-d")
              (list 'docs-dim)))

(define (auto-state-of state)
  (store-ref state 'demo/auto empty-auto))

(define (auto-state-put state a)
  (store-set state 'demo/auto a))

;;; ════════════════ id / view ════════════════

(define editor-vid 1)
(define editor-did 1)
(define status-vid 20)
(define docs-vid 30)
(define completion-vid 40)

(define editor-text
  (string-append "#lang racket\n"
                 "(require racket/list)\n"
                 "\n"
                 "(define (twice x) (* 2 x))\n"
                 "(define (main xs)\n"
                 "  (tw)\n"))

;;; ════════════════ config / keymap ════════════════

;; docs 是独立 panel，可 hide/show；不 split / delete。
(define demo-layout-config
  (make-layout-config
   #:rules
   (hash
    'editor (config-panel-rule default-config 'editor)
    'sidebar (config-panel-rule default-config 'sidebar)
    'status (config-panel-rule default-config 'status)
    'docs (make-panel-rule #:splittable? #f
                           #:hideable? #t
                           #:deletable? #f
                           #:focusable? #t
                           #:min-w 1 #:max-w #f
                           #:min-h 3 #:max-h #f))))

;;; ════════════════ docs ════════════════

(define (doc-lines name local-doc maybe-doc)
  (define out
    (cond
      [local-doc
       (append (list (format "~a" name)
                     "── 本地定义 ──")
               (string-split (or (doc-signature local-doc) "") "\n"))]
      [maybe-doc
       (cons (format "~a" name)
             (string-split (string-trim (doc->text maybe-doc)) "\n"))]
      [else (list (format "~a" name) "(无文档)")]))
  (take out (min (length out) 40)))

(define (doc-faces lines local-doc maybe-doc)
  (for/list ([line (in-list lines)] [i (in-naturals)])
    (cond
      [(zero? i) 'docs-title]
      [(or (string-prefix? line "──") (string=? line "(无文档)")) 'docs-dim]
      [else 'docs-body])))

(define (docs-state-for info name)
  (cond
    [(not (buffer-mode-supports? (demo-source-mode info) 'docs))
     empty-docs]
    [else
     (define ws (demo-source-workspace info))
     (define sid (demo-source-source-id info))
     (define local-doc (docs-local ws sid name))
     (define ctx
       (make-completion-context (demo-source-path info)
                                (demo-source-text info)
                                #:workspace ws
                                #:id sid))
     (define binding
       (and ctx
            (with-handlers ([exn:fail? (lambda (_) #f)])
              (spec-binding-of name
                               (completion-context-specs ctx)
                               (completion-context-base-dir ctx)
                               (completion-context-open ctx)))))
     (define maybe-doc
       (and binding
            (with-handlers ([exn:fail? (lambda (_) #f)])
              (docs-for name #:modules (list (car binding))))))
     (define lines (doc-lines name local-doc maybe-doc))
     (docs-state lines (doc-faces lines local-doc maybe-doc))]))

;; 本地预览是同步的（只查 workspace 里的定义），库文档由 docs-service 异步补。
(define (local-docs-state-for info name)
  (cond
    [(not (buffer-mode-supports? (demo-source-mode info) 'docs))
     empty-docs]
    [else
     (define ws (demo-source-workspace info))
     (define sid (demo-source-source-id info))
     (define local-doc (docs-local ws sid name))
     (define lines (doc-lines name local-doc #f))
     (docs-state lines (doc-faces lines local-doc #f))]))

(define (make-docs-request-tag info name)
  (list 'docs (demo-source-source-id info) (demo-source-version info) name))

;; 设置本地预览，同时提交异步 docs job。
(define (request-docs! state info name)
  (cond
    [(not (buffer-mode-supports? (demo-source-mode info) 'docs))
     (store-set state 'demo/docs empty-docs)]
    [else
     (define tag (make-docs-request-tag info name))
     (define state1 (store-set state 'demo/docs (local-docs-state-for info name)))
     (define-values (state2 job)
       (app-state-submit-job state1 'docs (list 'docs info name) tag))
     (store-set state2 'demo/docs-request (docs-request (job-id job) tag))]))

(define (update-docs-for-name state name)
  (define info (store-ref state 'demo/source #f))
  (if (not info)
      state
      (request-docs! state info name)))

;;; ════════════════ 自动补全状态 ════════════════

(define (auto-clear-timer! state)
  (define a (auto-state-of state))
  (if (not (auto-state-timer-id a))
      state
      (auto-state-put state (struct-copy auto-state a [timer-id #f]))))

(define (auto-dismiss! state)
  (auto-state-put state
                  (struct-copy auto-state (auto-state-of state)
                               [timer-id #f]
                               [dismissed? #t])))

(define (auto-suppress-next! state)
  (auto-state-put state
                  (struct-copy auto-state (auto-state-of state)
                               [timer-id #f]
                               [suppress-next? #t])))

(define (auto-schedule! state timer-runtime delay-ms)
  (cond
    [(not timer-runtime) state]
    [else
     (define id (schedule-timer! timer-runtime delay-ms))
     (auto-state-put state
                     (struct-copy auto-state (auto-state-of state)
                                  [timer-id id]))]))

;; 自动补全只在前缀是 symbol token 时触发；string/comment 里不弹。
(define (auto-context-prefix info)
  (define text (demo-source-text info))
  (define line (demo-source-line info))
  (define col (demo-source-col info))
  (define prefix (completion-prefix text line col))
  (cond
    [(not (buffer-mode-supports? (demo-source-mode info) 'completion)) #f]
    [(zero? (string-length prefix)) #f]
    [else
     (define lines (string-split text "\n" #:trim? #f))
     (cond
       [(>= line (length lines)) #f]
       [else
        (define tokens (list-ref (tokenize text) line))
        (define t (line-token-at tokens col))
        (and t (eq? (token-kind t) 'symbol) prefix)])]))

;;; ════════════════ completion ════════════════

(define (current-completion state)
  (store-ref state 'demo/completion #f))

(define (close-completion state)
  (define c (current-completion state))
  (cond
    [(not c) state]
    [else (app-state-clear-key-owner
           (store-set state 'demo/completion #f))]))

(define (completion-context-for info)
  (and (buffer-mode-supports? (demo-source-mode info) 'completion)
       (make-completion-context (demo-source-path info)
                                (demo-source-text info)
                                #:workspace (demo-source-workspace info)
                                #:id (demo-source-source-id info))))

(define (completion-candidates-for info prefix)
  (define ctx (completion-context-for info))
  (and ctx (completion-candidates ctx prefix)))

(define (completion-local-candidates-for info prefix)
  (define ctx (completion-context-for info))
  (and ctx (completion-candidates/local ctx prefix)))

(define (completion-request-tag info prefix)
  (list 'completion
        (demo-source-source-id info)
        (demo-source-version info)
        prefix))

(define (set-completion-index state c index)
  (define cands (completion-state-candidates c))
  (cond
    [(or (null? cands)
         (not (exact-nonnegative-integer? index))
         (>= index (length cands)))
     state]
    [else
     (define c* (struct-copy completion-state c [index index]))
     (define state* (store-set state 'demo/completion c*))
     (define name (list-ref cands index))
     (request-docs! state* (completion-state-source-info c*) name)]))

(define (demo-complete-start state)
  (define info (store-ref state 'demo/source #f))
  (cond
    [(current-completion state) (values state '())]
    [(not info)
     (values (app-state-with-flash state "completion: no editor source") '())]
    [(not (buffer-mode-supports? (demo-source-mode info) 'completion))
     (values (app-state-with-flash state "completion: not supported in this buffer") '())]
    [else
     (define prefix (completion-prefix (demo-source-text info)
                                       (demo-source-line info)
                                       (demo-source-col info)))
     (cond
       [(zero? (string-length prefix))
        (values (app-state-with-flash state "completion: no prefix") '())]
       [else
        ;; 本地候选同步开菜单； require exports / docs 走后台。
        (define local0 (with-handlers ([exn:fail? (lambda (_) '())])
                         (completion-local-candidates-for info prefix)))
        (define local (take local0 (min 50 (length local0))))
        (define tag (completion-request-tag info prefix))
        (define c0 (completion-state (demo-source-view-id info)
                                     prefix local 0 info #f
                                     (if (null? local) 'loading 'local)
                                     (demo-source-version info)
                                     (demo-source-line info)
                                     (demo-source-col info)))
        (define state1 (store-set state 'demo/completion c0))
        (define state2
          (app-state-set-key-owner
           state1 'completion-menu
           completion-command-stack))
        (define state3
          (if (null? local)
              state2
              (request-docs! state2 info (car local))))
        (define-values (state4 job)
          (app-state-submit-job state3 'completion
                                (list 'completion info prefix) tag))
        (define c1 (struct-copy completion-state c0 [request-id (job-id job)]))
        (values (store-set state4 'demo/completion c1) '())])]))

;; 菜单已经打开时，change 触发的是 refine，而不是重新打开。
(define (auto-refine-completion! state info prefix)
  (define c (current-completion state))
  (define local0 (with-handlers ([exn:fail? (lambda (_) '())])
                   (completion-local-candidates-for info prefix)))
  (define local (take local0 (min 50 (length local0))))
  (define c1 (struct-copy completion-state c
                          [prefix prefix]
                          [candidates local]
                          [index 0]
                          [source-info info]
                          [status (if (null? local) 'loading 'local)]
                          [request-id #f]
                          [target-version (demo-source-version info)]
                          [anchor-line (demo-source-line info)]
                          [anchor-col (demo-source-col info)]))
  (define state1 (auto-clear-timer! (store-set state 'demo/completion c1)))
  (define state2 (if (null? local)
                     state1
                     (request-docs! state1 info (car local))))
  (define-values (state3 job)
    (app-state-submit-job state2 'completion
                          (list 'completion info prefix)
                          (completion-request-tag info prefix)))
  (define c2 (struct-copy completion-state c1 [request-id (job-id job)]))
  (store-set state3 'demo/completion c2))

(define (relevant-change? focus-info changes)
  (and focus-info
       (for/or ([dc (in-list changes)])
         (equal? (doc-change-doc-id dc) (demo-source-doc-id focus-info)))))

;; 消费 pending-doc-changes：schedule / refine / suppress。
(define (process-doc-changes! state focus-info changes timer-runtime)
  (cond
    [(not (relevant-change? focus-info changes)) state]
    [else
     (define a (auto-state-of state))
     (cond
       [(auto-state-suppress-next? a)
        (auto-state-put state (struct-copy auto-state a [suppress-next? #f]))]
       [else
        (define a1 (struct-copy auto-state a
                                [timer-id #f]
                                [dismissed? #f]))
        (define state1 (auto-state-put state a1))
        (cond
          [(input-active? state1) state1]
          [(app-state-placement state1) state1]
          [else
           (define c (current-completion state1))
           (define prefix (auto-context-prefix focus-info))
           (cond
             [(not prefix)
              (if c (close-completion state1) state1)]
             [(not c)
              (auto-schedule! state1 timer-runtime 180)]
             [else (auto-refine-completion! state1 focus-info prefix)])])])]))

(define (handle-auto-timer! state timer-id)
  (define a (auto-state-of state))
  (cond
    [(not (equal? timer-id (auto-state-timer-id a))) state]
    [else
     (define state1 (auto-clear-timer! state))
     (define info (store-ref state1 'demo/source #f))
     (define fp (app-state-focus-panel-resource state1))
     (cond
       [(or (not info)
            (not fp)
            (not (eq? (panel-kind fp) 'editor))
            (input-active? state1)
            (app-state-placement state1)
            (current-completion state1))
        state1]
       [(auto-context-prefix info)
        (define-values (state2 _actions) (demo-complete-start state1))
        state2]
       [else state1])]))

(define (demo-complete-next state)
  (define c (current-completion state))
  (define n (and c (length (completion-state-candidates c))))
  (cond
    [(or (not c) (zero? n)) (values state '())]
    [else
     (values (set-completion-index state c (modulo (add1 (completion-state-index c)) n)) '())]))

(define (demo-complete-prev state)
  (define c (current-completion state))
  (define n (and c (length (completion-state-candidates c))))
  (cond
    [(or (not c) (zero? n)) (values state '())]
    [else
     (values (set-completion-index state c (modulo (sub1 (completion-state-index c)) n)) '())]))

(define (demo-complete-accept state)
  (define c (current-completion state))
  (define cands (and c (completion-state-candidates c)))
  (cond
    [(not c) (values state '())]
    ;; 本地还没有候选时菜单可能是"loading"；此时 Enter 不能 list-ref。
    [(null? cands)
     (values (app-state-with-flash
              (auto-dismiss! (close-completion state))
              "completion: no candidates")
             '())]
    [else
     (define idx (min (completion-state-index c) (sub1 (length cands))))
     (define cand (list-ref cands idx))
     (define ins (completion-insert-text cand (completion-state-prefix c)))
     (define state1 (auto-suppress-next! (close-completion state)))
     (values state1
             (if (zero? (string-length ins))
                 '()
                 (list (view-action 'insert
                                    (completion-state-target-vid c)
                                    (string->bytes/utf-8 ins)))))]))

(define (demo-complete-cancel state)
  (values (if (current-completion state)
              (auto-dismiss! (close-completion state))
              state)
          '()))

;;; ════════════════ docs 命令 ════════════════

(define (demo-show-docs-command state)
  (define info (store-ref state 'demo/source #f))
  (cond
    [(not info) (values (app-state-with-flash state "docs: no editor source") '())]
    [(not (buffer-mode-supports? (demo-source-mode info) 'docs))
     (values (app-state-with-flash state "docs: not supported in this buffer") '())]
    [else
     (define name (identifier-at (demo-source-text info)
                                 (demo-source-line info)
                                 (demo-source-col info)))
     (cond
       [(not name) (values (app-state-with-flash state "docs: no identifier") '())]
       [else (values (update-docs-for-name state name) '())])]))

(define (docs-visible? state)
  (layout-panel-visible? (app-state-layout state) 'docs))

(define (demo-toggle-docs-command state)
  (define layout (app-state-layout state))
  (define area (app-state-area state))
  (cond
    [(docs-visible? state)
     (define-values (layout* ok?)
       (layout-panel-hide layout area 'docs #:config demo-layout-config))
     (values (if ok?
                 (struct-copy app-state state [layout layout*])
                 (app-state-with-flash state "docs: hide failed"))
             '())]
    [else
     (define-values (layout* ok?)
       (layout-panel-show layout area 'docs))
     (values (if ok?
                 (struct-copy app-state state [layout layout*])
                 (app-state-with-flash state "docs: show failed"))
             '())]))

;;; ════════════════ 焦点：completion menu <-> docs ════════════════

(define (demo-editor-panel-id state)
  (define layout (app-state-layout state))
  (or (for/first ([pid (in-list (layout-visible-panel-ids layout))]
                  #:when (eq? (panel-kind (layout-panel layout pid)) 'editor))
        pid)
      #f))

(define (demo-focus-docs-command state)
  (define layout (app-state-layout state))
  (define area (app-state-area state))
  (define-values (layout* ok?)
    (if (layout-panel-visible? layout 'docs)
        (values layout #t)
        (layout-panel-show layout area 'docs)))
  (cond
    [(not ok?) (values (app-state-with-flash state "docs: show failed") '())]
    [else
     (define c (current-completion state))
     (values (app-state-clear-key-owner
              (struct-copy app-state state
                           [layout (layout-set-focus layout* 'docs)]))
             '())]))

(define (demo-focus-menu-command state)
  (define c (current-completion state))
  (define layout (app-state-layout state))
  (define pid (or (and c (layout-panel-for-view layout (completion-state-target-vid c)))
                  (demo-editor-panel-id state)))
  (cond
    [(not pid) (values (app-state-with-flash state "completion: no editor panel") '())]
    [else
     (values (if c
                 (app-state-set-key-owner
                  (struct-copy app-state state [layout (layout-set-focus layout pid)])
                  'completion-menu
                  completion-command-stack)
                 (app-state-clear-key-owner
                  (struct-copy app-state state [layout (layout-set-focus layout pid)])))
             '())]))

(define completion-command-table
  (keys
   [(key 'down)  demo-complete-next]
   [(key 'up)    demo-complete-prev]
   [(key 'tab)   demo-complete-next]
   [(key 'enter) demo-complete-accept]
   [(key 'escape) demo-complete-cancel]
   [(key 'g 'ctrl) demo-complete-cancel]
   [(key 'x 'ctrl) (key 'o) demo-focus-docs-command]))

(define completion-command-stack
  (command-table-stack-from-tables (list completion-command-table)))

(define demo-docs-command-table
  (command-table-merge
   navigation-command-table
   (keys
    [(key 'x 'ctrl) (key 'o) demo-focus-menu-command]
    [(key 'escape) demo-complete-cancel]
    [(key 'g 'ctrl) demo-complete-cancel])))

(define demo-docs-panel-stack
  (command-table-stack-from-tables (list demo-docs-command-table)))

;;; ════════════════ demo keymap ════════════════

(define demo-command-table
  (keys
   [(key 'o 'ctrl) demo-complete-start]
   [(key 'd 'alt)  demo-show-docs-command]
   [(key 'x 'ctrl) (key 'd) demo-toggle-docs-command]
   [(key 'x 'ctrl) (key 'o) demo-focus-menu-command]))

(define demo-keymap
  (struct-copy keymap default-keymap
               [overlays
                (command-table-stack-over
                 (command-table-stack-from-tables (list demo-command-table))
                 (keymap-overlays default-keymap))]))

;;; ════════════════ 启动状态 ════════════════

(define engine (make-engine))
(define demo-engine engine)

(define state0
  (make-app-state #:layout-config demo-layout-config
                  #:keymap demo-keymap
                  #:area (rect 0 0 80 24)
                  #:next-panel-id 100))

(define demo-mode (buffer-mode-for-creation "demo.rkt" editor-text))
(define-values (store1 open-actions)
  (resource-open (app-state-resources state0)
                 #:name "demo.rkt"
                 #:text editor-text
                 #:key-table (buffer-mode-key-table demo-mode)
                 #:mode demo-mode))
(define state1
  (run-actions (struct-copy app-state state0 [resources store1])
               engine open-actions))

;; demo 初始光标放在 (tw 后面，方便直接 C-o。
(void (engine-apply-view-action!
       engine
       (view-action 'select editor-vid
                     (selections-one (caret (point 5 5))))))

;; chrome / docs / completion 都是普通 core buffer + view。
;; 区别只在它们挂在哪里：status/docs 进 layout panel，completion 进 overlay panel。
(define (create-plain-buffer-view! vid name)
  (void (engine-create-buffer! engine vid name ""))
  (void (engine-create-view! engine vid vid)))

(create-plain-buffer-view! status-vid "*status*")
(create-plain-buffer-view! docs-vid "*docs*")
(create-plain-buffer-view! completion-vid "*completion*")

(define state2 (status-install-state state1 status-vid))
(define state3 (store-set state2 'demo/docs empty-docs))
(define state4
  (struct-copy app-state
               (store-set state3 'demo/completion #f)
               [panel-stacks
                (hash-set
                 (hash-set (app-state-panel-stacks state3) 'docs demo-docs-panel-stack)
                 docs-vid demo-docs-panel-stack)]))

(define (docs-panel)
  (make-panel 'docs 'docs
              #:views (list docs-vid)
              #:active docs-vid
              #:fixed-h 8
              #:borders '(up down)))

(define (status-panel)
  (make-panel 'status 'status
              #:views (list status-vid)
              #:active status-vid
              #:fixed-h 1))

(define (editor-panel)
  (make-panel 'editor 'editor
              #:views (list editor-vid)
              #:active editor-vid
              #:borders '(up down left right)))

(define l0
  (make-layout #:root (make-leaf 'editor)
               #:panels (hash 'editor (editor-panel))
               #:focus 'editor))

(define-values (l1 ok1?)
  (layout-panel-attach l0 'editor 'down (docs-panel)))
(define-values (l2 ok2?)
  (layout-panel-attach l1 'docs 'down (status-panel)))
(unless (and ok1? ok2?)
  (error 'demo "layout attach failed"))

(define demo-state
  (struct-copy app-state state4 [layout l2]))

;;; ════════════════ prepare：source / docs / popup ════════════════

(define (collect-workspace state engine)
  (define resources (resource-list (app-state-resources state)))
  (define old-store (store-ref state 'demo/source-store source-store-empty))
  (define old-workspace (store-ref state 'demo/workspace workspace-empty))
  (define old-versions (store-ref state 'demo/source-versions (hash)))
  ;; 只重新读取 version 变化的 buffer；其它 source / workspace 跨帧复用。
  (define-values (source-store* workspace* versions*)
    (for/fold ([ss old-store]
               [ws old-workspace]
               [versions (hash)])
              ([r (in-list resources)])
      (define did (resource-doc-id r))
      (define path (resource-path (app-state-resources state) (resource-id r)))
      (define version (and did (engine-doc-version engine did)))
      (define version-key (list path version))
      (cond
        [(not did) (values ss ws versions)]
        [(equal? (hash-ref old-versions did #f) version-key)
         (values ss ws (hash-set versions did version-key))]
        [else
         (define text (engine-doc-text engine did))
         (cond
           [(not text) (values ss ws versions)]
           [else
            (define ss* (source-store-set-buffer ss did path text #:version version))
            (define snap (source-store-ref ss* (source-id 'buffer did)))
            (values ss*
                    (workspace-set-source ws snap)
                    (hash-set versions did version-key))])])))
  (values source-store* workspace* versions*))

;; 当前焦点的 editor source；焦点在 docs 时返回 #f。
;; 文本按 (doc-id, version) 复用，光标移动不重新复制整篇文本。
(define (editor-source-for state engine ws)
  (define fp (app-state-focus-panel-resource state))
  (define vid (and fp
                  (eq? (panel-kind fp) 'editor)
                  (app-state-focus-view-id state)))
  (define rid (app-state-focus-resource state))
  (define r (and rid (resource-ref (app-state-resources state) rid)))
  (define did (and r (resource-doc-id r)))
  (define cached (store-ref state 'demo/source #f))
  (cond
    [(or (not vid) (not did)) (values #f state)]
    [else
     (define version (engine-doc-version engine did))
     (define text
       (or (and cached
                (equal? did (demo-source-doc-id cached))
                (equal? version (demo-source-version cached))
                (demo-source-text cached))
           (engine-doc-text engine did)))
     (cond
       [(not text) (values #f state)]
       [else
        (values (demo-source did vid
                             (source-id 'buffer did)
                             (and r (resource-path (app-state-resources state) rid))
                             (and r (resource-mode r))
                             text
                             version
                             (or (engine-view-point-line engine vid) 0)
                             (or (engine-view-point-column engine vid) 0)
                             ws)
                state)])]))

(define (sync-docs-view! state engine)
  (define d (store-ref state 'demo/docs empty-docs))
  ;; 内容不变时绝不碰光标；内容变了才把光标放回顶部。
  (define changed?
    (engine-set-view-content! engine docs-vid
                             (docs-state-lines d)
                             (docs-state-faces d)))
  (when changed?
    (engine-set-view-cursor! engine docs-vid 0))
  state)

;; 所有可见 editor panel 的包围盒，而不是单个 panel。
(define (editor-area-rect layout rects)
  (define rs
    (for/list ([pid (in-list (layout-visible-panel-ids layout))]
               #:when (eq? (panel-kind (layout-panel layout pid)) 'editor))
      (hash-ref rects pid #f)))
  (define rs* (filter values rs))
  (cond
    [(null? rs*) #f]
    [else
     (define x (apply min (map rect-x rs*)))
     (define y (apply min (map rect-y rs*)))
     (define r (apply max (map rect-right rs*)))
     (define b (apply max (map rect-bottom rs*)))
     (rect x y (- r x) (- b y))]))

;; 目标 view 所在 panel 的内容区原点。
(define (panel-content-origin layout rects pid)
  (define p (and pid (layout-panel layout pid)))
  (define pr (and pid (hash-ref rects pid #f)))
  (define borders (if p (panel-borders p) '()))
  (values (+ (if pr (rect-x pr) 0) (if (memq 'left borders) 1 0))
          (+ (if pr (rect-y pr) 0) (if (memq 'up borders) 1 0))))

(define (sync-completion! state engine c)
  (define cands (completion-state-candidates c))
  (define idx (completion-state-index c))
  (define area (app-state-area state))
  (define layout (app-state-layout state))
  (define rects (and layout area (layout-panel-rects layout area)))
  (define edit-area (and rects (editor-area-rect layout rects)))
  (define target-vid (completion-state-target-vid c))
  (define pid (or (and layout (layout-panel-for-view layout target-vid))
                  (app-state-focus-panel-id state)))
  (define-values (ox oy) (if (and layout rects)
                             (panel-content-origin layout rects pid)
                             (values 0 0)))
  (define cur (engine-view-cursor-screen-position engine target-vid))
  (define cursor-x (+ ox (if cur (cdr cur) 0)))
  (define cursor-y (+ oy (if cur (car cur) 0)))
  (define max-w (for/fold ([m 1]) ([x (in-list cands)]) (max m (string-length x))))
  (define pl (and edit-area
                  (popup-geometry area edit-area cursor-x cursor-y
                                  (length cands) max-w)))
  (cond
    [(not pl) '()]
    [else
     (define lines (completion-lines cands (popup-layout-inner-width pl)))
     (define faces
       (for/list ([i (in-range (length lines))])
         (if (= i idx) 'completion-selected 'completion)))
     (engine-set-view-content! engine completion-vid lines faces)
     (engine-set-view-cursor! engine completion-vid idx)
     (list (make-overlay-panel (engine-view-object engine completion-vid)
                               (popup-layout-rect pl)
                               #:borders '(up down left right)
                               #:face 'float-border
                               #:deep 100
                               #:weight 100))]))

;; completion 菜单只有当前 layout focus 仍是 target editor 时才拥有键盘。
;; 焦点被 C-x 方向 / 鼠标 / docs 等移走后，overlay 表必须自动退出，
;; 不能只依赖 C-x o 这个特判。
(define (completion-menu-focused? state c)
  (define layout (app-state-layout state))
  (define pid (and layout (layout-panel-for-view layout (completion-state-target-vid c))))
  (and pid (equal? pid (app-state-focus-panel-id state))))

;; 补全打开后，目标是某个 view。若该 view 的文档版本没变、但光标移走了，
;; 说明是鼠标/其他导航，不是补全自己的输入；关闭并 dismiss。
;; 文本变化由 process-doc-changes -> auto-refine 更新 anchor，所以不会误关。
(define (sync-completion-cursor! state engine)
  (define c (current-completion state))
  (cond
    [(not c) state]
    [else
     (define info (completion-state-source-info c))
     (define did (and info (demo-source-doc-id info)))
     (define vid (completion-state-target-vid c))
     (define version (and did (engine-doc-version engine did)))
     (define line (and vid (engine-view-point-line engine vid)))
     (define col (and vid (engine-view-point-column engine vid)))
     (cond
       [(or (not version) (not line) (not col))
        (auto-dismiss! (close-completion state))]
       [(not (equal? version (completion-state-target-version c)))
        (auto-dismiss! (close-completion state))]
       [(and (= line (completion-state-anchor-line c))
             (= col (completion-state-anchor-col c)))
        state]
       [else
        (auto-dismiss! (close-completion state))])]))

(define (sync-completion-key-owner state)
  (define c (current-completion state))
  (cond
    [(not c) (app-state-clear-key-owner state)]
    [(completion-menu-focused? state c)
     (app-state-set-key-owner
      state 'completion-menu
      completion-command-stack)]
    [else (app-state-clear-key-owner state)]))

(define (prepare-demo! state engine #:timer-runtime [timer-runtime #f])
  (define-values (source-store* workspace* versions*)
    (collect-workspace state engine))
  (define state0
    (store-set (store-set (store-set state
                                    'demo/source-store source-store*)
                          'demo/workspace workspace*)
               'demo/source-versions versions*))
  (define-values (focus-info state1a)
    (editor-source-for state0 engine workspace*))
  (define state1
    (store-set state1a 'demo/source focus-info))
  ;; change 只在这里消费一次；自动补全的触发/refine 都在这一层做。
  (define-values (changes state2) (app-state-take-doc-changes state1))
  (define state3 (process-doc-changes! state2 focus-info changes timer-runtime))
  (define state3a (sync-completion-cursor! state3 engine))
  ;; docs 获得焦点时，completion 仍使用打开时的 source，不因为当前焦点是 docs 而关闭。
  (define c (current-completion state3a))
  (define state4 (sync-docs-view! state3a engine))
  (define state5 (sync-completion-key-owner state4))
  (cond
    [(not c) (values state5 '())]
    [(not (completion-state-source-info c)) (values (close-completion state5) '())]
    [else (values state5 (sync-completion! state5 engine c))]))

;;; ════════════════ 后台 services ════════════════

(define (completion-service payload)
  (match-define (list 'completion info prefix) payload)
  (completion-candidates-for info prefix))

(define (docs-service payload)
  (match-define (list 'docs info name) payload)
  (docs-state-for info name))

(define demo-services
  (append (list (service 'completion completion-service)
                (service 'docs docs-service))
          color-services))

;; job result -> state。只接受仍匹配当前 request-id 的结果。
(define (handle-job-result state ev)
  (define state0
    (handle-filetree-job-result
     (handle-color-job-result
      (app-state-finish-job state
                            (job-result-event-id ev)
                            (job-result-event-result ev))
      ev)
     ev))
  (case (job-result-event-kind ev)
    [(completion)
     (define c (current-completion state0))
     (cond
       [(not c) state0]
       [(not (equal? (completion-state-request-id c)
                     (job-result-event-id ev)))
        state0]
       [else
        (define result (job-result-event-result ev))
        (define cands
          (if (and (list? result) (andmap string? result))
              result
              (completion-state-candidates c)))
        (cond
          [(null? cands)
           ;; 异步结果为空时不要留下一个空菜单：用户下一次 Enter / Tab 会踩空。
           (app-state-with-flash (auto-dismiss! (close-completion state0))
                                 "completion: no candidates")]
          [else
           (define idx (min (completion-state-index c)
                            (sub1 (length cands))))
           (define c1 (struct-copy completion-state c
                                   [candidates cands]
                                   [index idx]
                                   [status 'ready]))
           (define state1 (store-set state0 'demo/completion c1))
           (request-docs! state1
                          (completion-state-source-info c1)
                          (list-ref cands idx))])])]
    [(docs)
     (define dr (store-ref state0 'demo/docs-request #f))
     (cond
       [(and dr (equal? (docs-request-id dr) (job-result-event-id ev)))
        (define result (job-result-event-result ev))
        (cond
          [(docs-state? result)
           (store-set (store-set state0 'demo/docs result)
                      'demo/docs-request #f)]
          [else (store-set state0 'demo/docs-request #f)])]
       [else state0])]
    [else state0]))

;;; ════════════════ 事件循环 ════════════════

(define (run-demo state engine)
  (tui:with-tui
   (lambda ()
     (tui:cursor-hide)
     (tui:enable-mouse!)
     (tui:enable-bracketed-paste!)
     (define-values (rows cols) (tui:get-window-size))
     (define state0
       (if (and rows cols (positive? rows) (positive? cols))
           (struct-copy app-state state [area (rect 0 0 cols rows)])
           state))
     (define (read-app-event)
       (let loop ()
         (define-values (type data mods) (tui:read-event/raw))
         (define e (tui-event->app type data mods))
         (if e e (loop))))
     (define event-channel (make-async-channel))
     (define input-thread
       (thread (λ ()
                 (let loop ()
                   (async-channel-put event-channel (read-app-event))
                   (loop)))))
     (define runtime
       (start-job-runtime (append demo-services filetree-services)
                          #:event-channel event-channel
                          #:workers 2))
     (define timer-runtime (start-timer-runtime #:event-channel event-channel))
     (dynamic-wind
      void
      (λ ()
        (let loop ([state state0] [cache #f])
          (dispatch-jobs! runtime (app-state-jobs state))
          (define-values (state1 panels)
            (sync-ui/panels! state engine #:async-filetree? #t))
          (define-values (state2 overlays)
            (prepare-demo! state1 engine #:timer-runtime timer-runtime))
          ;; sync / prepare 可能刚提交新 job；读事件前再派发一次。
          (dispatch-jobs! runtime (app-state-jobs state2))
          (define-values (cache* bytes)
            (render-frame state2 engine cache #:panels panels #:overlays overlays))
          (unless (zero? (bytes-length bytes))
            (tui:put-bytes bytes)
            (tui:flush!))
          (define ev (async-channel-get event-channel))
          (define cache** (if (resize-event? ev) #f cache*))
          (cond
            [(job-result-event? ev)
             (loop (handle-job-result state2 ev) cache**)]
            [(timer-event? ev)
             (loop (handle-auto-timer! state2 (timer-event-id ev)) cache**)]
            [else
             (define-values (state3 actions) (step state2 ev))
             (define state4 (run-actions state3 engine actions))
             (define-values (state5 more) (input-reconcile state4))
             (define state6 (run-actions state5 engine more))
             (if (app-state-quit? state6)
                 state6
                 (loop state6 cache**))])))
      (λ ()
        (kill-thread input-thread)
        (stop-job-runtime runtime)
        (stop-timer-runtime timer-runtime))))))

(module+ main
  (void (run-demo demo-state engine)))
