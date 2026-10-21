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
         racket/string
         racket/path
         (prefix-in tui: tui)
         "../config/keymap/default.rkt"
         "../config/layout/default.rkt"
         "../config/theme/default.rkt"
         "../main.rkt"
         "../lang/racket/api.rkt"
         "../source/api.rkt"
         "completion-popup.rkt")

(provide demo-state demo-engine prepare-demo!)

;;; ════════════════ 数据 ════════════════

(struct demo-source
  (doc-id view-id source-id path text line col workspace)
  #:transparent)

(struct completion-state
  (target-vid prefix candidates index source-info)
  #:transparent)

(struct docs-state
  (lines faces)
  #:transparent)

(define (store-ref state key default)
  (hash-ref (app-state-store state) key default))

(define (store-set state key value)
  (struct-copy app-state state
               [store (hash-set (app-state-store state) key value)]))

(define empty-docs
  (docs-state (list "No docs yet — open completion or press M-d")
              (list 'docs-dim)))

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
  (docs-state lines (doc-faces lines local-doc maybe-doc)))

(define (update-docs-for-name state name)
  (define info (store-ref state 'demo/source #f))
  (if (not info)
      state
      (store-set state 'demo/docs (docs-state-for info name))))

;;; ════════════════ completion ════════════════

(define (current-completion state)
  (store-ref state 'demo/completion #f))

(define (close-completion state)
  (define c (current-completion state))
  (cond
    [(not c) state]
    [else (app-state-clear-key-owner
           (store-set state 'demo/completion #f))]))

(define (completion-candidates-for info prefix)
  (define ctx
    (make-completion-context (demo-source-path info)
                             (demo-source-text info)
                             #:workspace (demo-source-workspace info)
                             #:id (demo-source-source-id info)))
  (and ctx (completion-candidates ctx prefix)))

(define (set-completion-index state c index)
  (define c* (struct-copy completion-state c [index index]))
  (define state* (store-set state 'demo/completion c*))
  (define name (list-ref (completion-state-candidates c*) index))
  (store-set state* 'demo/docs
             (docs-state-for (completion-state-source-info c*) name)))

(define (demo-complete-start state)
  (define info (store-ref state 'demo/source #f))
  (cond
    [(current-completion state) (values state '())]
    [(not info)
     (values (app-state-with-flash state "completion: no editor source") '())]
    [else
     (define prefix (completion-prefix (demo-source-text info)
                                       (demo-source-line info)
                                       (demo-source-col info)))
     (cond
       [(zero? (string-length prefix))
        (values (app-state-with-flash state "completion: no prefix") '())]
       [else
        (define cands0 (with-handlers ([exn:fail? (lambda (_) '())])
                         (completion-candidates-for info prefix)))
        (define cands (take cands0 (min 50 (length cands0))))
        (cond
          [(null? cands)
           (values (app-state-with-flash state "completion: no candidates") '())]
          [else
           (define c (completion-state (demo-source-view-id info)
                                       prefix cands 0
                                       info))
           (define state1 (store-set state 'demo/completion c))
           (define state2
             (app-state-set-key-owner
              state1 'completion-menu
              completion-command-stack))
           (values (set-completion-index state2 c 0) '())])])]))

(define (demo-complete-next state)
  (define c (current-completion state))
  (cond
    [(not c) (values state '())]
    [else
     (define n (length (completion-state-candidates c)))
     (values (set-completion-index state c (modulo (add1 (completion-state-index c)) n)) '())]))

(define (demo-complete-prev state)
  (define c (current-completion state))
  (cond
    [(not c) (values state '())]
    [else
     (define n (length (completion-state-candidates c)))
     (values (set-completion-index state c (modulo (sub1 (completion-state-index c)) n)) '())]))

(define (demo-complete-accept state)
  (define c (current-completion state))
  (cond
    [(not c) (values state '())]
    [else
     (define cand (list-ref (completion-state-candidates c)
                            (completion-state-index c)))
     (define ins (completion-insert-text cand (completion-state-prefix c)))
     (define state1 (close-completion state))
     (values state1
             (if (zero? (string-length ins))
                 '()
                 (list (view-action 'insert
                                    (completion-state-target-vid c)
                                    (string->bytes/utf-8 ins)))))]))

(define (demo-complete-cancel state)
  (values (close-completion state) '()))

;;; ════════════════ docs 命令 ════════════════

(define (demo-show-docs-command state)
  (define info (store-ref state 'demo/source #f))
  (cond
    [(not info) (values (app-state-with-flash state "docs: no editor source") '())]
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

(define-values (store1 open-actions)
  (resource-open (app-state-resources state0)
                 #:name "demo.rkt"
                 #:text editor-text
                 #:key-table edit-command-table))
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
  ;; workspace 跨帧保留：文本/版本没变时 workspace-set-source 复用 analysis。
  (define-values (_ss ws)
    (for/fold ([ss source-store-empty]
               [ws (store-ref state 'demo/workspace workspace-empty)])
              ([r (in-list resources)])
      (define did (resource-doc-id r))
      (define path (resource-path (app-state-resources state) (resource-id r)))
      (define text (and did (engine-doc-text engine did)))
      (cond
        [(not text) (values ss ws)]
        [else
         (define version (engine-doc-version engine did))
         (define ss* (source-store-set-buffer ss did path text #:version version))
         (define snap (source-store-ref ss* (source-id 'buffer did)))
         (values ss* (workspace-set-source ws snap))])))
  ws)

;; 当前焦点的 editor source；焦点在 docs 时返回 #f。
(define (editor-source-for state engine ws)
  (define fp (app-state-focus-panel-resource state))
  (define vid (and fp
                  (eq? (panel-kind fp) 'editor)
                  (app-state-focus-view-id state)))
  (define rid (app-state-focus-resource state))
  (define r (and rid (resource-ref (app-state-resources state) rid)))
  (define did (and r (resource-doc-id r)))
  (cond
    [(or (not vid) (not did)) #f]
    [else
     (demo-source did vid
                  (source-id 'buffer did)
                  (and r (resource-path (app-state-resources state) rid))
                  (engine-doc-text engine did)
                  (or (engine-view-point-line engine vid) 0)
                  (or (engine-view-point-column engine vid) 0)
                  ws)]))

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

(define (sync-completion-key-owner state)
  (define c (current-completion state))
  (cond
    [(not c) (app-state-clear-key-owner state)]
    [(completion-menu-focused? state c)
     (app-state-set-key-owner
      state 'completion-menu
      completion-command-stack)]
    [else (app-state-clear-key-owner state)]))

(define (prepare-demo! state engine)
  (define ws (collect-workspace state engine))
  (define focus-info (editor-source-for state engine ws))
  ;; docs 获得焦点时，completion 仍使用打开时的 source，不因为当前焦点是 docs 而关闭。
  (define c (current-completion state))
  (define state1
    (store-set (store-set state 'demo/source focus-info)
               'demo/workspace ws))
  (define state2 (sync-docs-view! state1 engine))
  (define state3 (sync-completion-key-owner state2))
  (cond
    [(not c) (values state3 '())]
    [(not (completion-state-source-info c)) (values (close-completion state3) '())]
    [else (values state3 (sync-completion! state3 engine c))]))

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
     (let loop ([state state0] [cache #f])
       (define-values (state1 panels) (sync-ui/panels! state engine))
       (define-values (state2 overlays) (prepare-demo! state1 engine))
       (define-values (cache* bytes)
         (render-frame state2 engine cache #:panels panels #:overlays overlays))
       (unless (zero? (bytes-length bytes))
         (tui:put-bytes bytes)
         (tui:flush!))
       (define ev (read-app-event))
       (define cache** (if (resize-event? ev) #f cache*))
       (define-values (state3 actions) (step state2 ev))
       (define state4 (run-actions state3 engine actions))
       (define-values (state5 more) (input-reconcile state4))
       (define state6 (run-actions state5 engine more))
       (if (app-state-quit? state6)
           state6
           (loop state6 cache**))))))

(module+ main
  (void (run-demo demo-state engine)))
