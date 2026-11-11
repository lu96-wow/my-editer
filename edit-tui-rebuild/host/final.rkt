#lang racket

;;; edit-tui-rebuild/host/final.rkt —— 第二阶段可运行 editor
;;;
;;; 相比第一阶段，新增：
;;;   · core/layout + panel + projection + focus
;;;   · C-w 方向 split、C-x 方向 focus、C-d close panel
;;;   · 多 editor panel 渲染（每个 panel 一个独立 view）
;;;   · layout 扩展点：layout-split / layout-close / layout-focus
;;;
;;; 还没有：filetree / resources / completion / docs / 异步 / 多进程。
;;; 但 editor 层的操作面、扩展点、插件状态、布局操作已经统一。

(require racket/string
         (prefix-in tui: tui)
         "../editor/host-api.rkt"
         "../core/command/api.rkt"
         "../plugins/pair/plugin.rkt"
         "../plugins/indent/plugin.rkt"
         "../plugins/racket-color/plugin.rkt"
         "../plugins/layout/plugin.rkt"
         "../plugins/filetree/plugin.rkt"
         "../plugins/resources/plugin.rkt"
         "event.rkt"
         "keymap.rkt"
         "../../edit-tui/render/core.rkt"
         "../../edit-tui/config/theme/default.rkt")

(provide run-editor
         make-demo-editor
         run-demo-editor
         render-frame
         sync-status!
         handle-editor-event)

;;; ════════════════ 初始文档 ════════════════

(define editor-vid 1)
(define status-vid 2)
(define filetree-vid 3)
(define resources-vid 4)
(define input-vid 5)

(define initial-text
  (string-append "#lang racket\n"
                 "\n"
                 "(define (main xs)\n"
                 "  (map add1 xs))\n"))

(define (make-demo-editor)
  (define engine (make-engine))
  (void (engine-create-buffer! engine editor-vid "scratch.rkt" initial-text))
  (void (engine-create-view! engine editor-vid editor-vid))
  (void (engine-create-buffer! engine status-vid "*status*" ""))
  (void (engine-create-view! engine status-vid status-vid))
  (void (engine-create-buffer! engine filetree-vid "*filetree*" ""))
  (void (engine-create-view! engine filetree-vid filetree-vid))
  (void (engine-create-buffer! engine resources-vid "*resources*" ""))
  (void (engine-create-view! engine resources-vid resources-vid))
  (void (engine-create-buffer! engine input-vid "*input*" ""))
  (void (engine-create-view! engine input-vid input-vid))
  ;; 从文档开头启动；避免 viewport 还没 sync 时把 top-line 锚在末尾。
  (engine-set-view-cursor! engine editor-vid 0 #:column 0)

  (define plugins (list pair-plugin
                        indent-plugin
                        (make-filetree-plugin
                         #:view filetree-vid
                         #:root (current-directory))
                        (make-resources-plugin #:view resources-vid)
                        racket-color-plugin
                        layout-plugin))
  (define registry (make-hook-registry (plugins->hooks plugins)))
  (define ed (make-editor #:engine engine
                          #:registry registry
                          #:plugins plugins))

  (define layout (make-editor-layout #:editor-view editor-vid
                                     #:status-views (list status-vid input-vid)
                                     #:sidebar-views (list filetree-vid resources-vid)))
  ;; 初始 scratch resource：没有 path，但 mode 按 "scratch.rkt" 选 Racket。
  (define scratch-mode (doc-mode-for "scratch.rkt" initial-text))
  (define scratch
    (make-resource editor-vid editor-vid #f "scratch.rkt"
                   (list editor-vid) scratch-mode
                   (engine-doc-version engine editor-vid)))
  (define state
    (make-editor-state #:plugin-states (plugins->states plugins)
                       #:area (rect 0 0 80 24)
                       #:layout layout
                       #:next-view-id 10
                       #:next-panel-id 100
                       #:resources (resources-add empty-resources scratch)
                       #:input (make-input-state #:panel-id 'status
                                                 #:status-view status-vid
                                                 #:input-view input-vid)))
  (values ed state))

;;; ════════════════ action 解释 ════════════════

(define (run-actions ed state actions)
  (for/fold ([s state]) ([a (in-list actions)])
    (cond
      [(quit-action? a) (struct-copy editor-state s [quit? #t])]
      [(flash-action? a) (editor-state-with-flash s (flash-action-message a))]
      [(open-file-action? a)
       (define-values (s* more)
         (editor-open-file! ed s (open-file-action-path a)))
       (if (null? more) s* (run-actions ed s* more))]
      [else s])))

;;; ════════════════ 命令 ════════════════

(define (need-view state)
  (editor-focus-view-id state))

(define (editor-focused? state)
  (eq? (editor-focus-panel-kind state) 'editor))

(define (flash state text)
  (values (editor-state-with-flash state text) '()))

(define (run-command ed state vid value)
  (cond
    ;; 插件 commands 是普通过程：(ed state -> values state actions)
    [(procedure? value) (value ed state)]
    [(guarded-command? value)
     ((guarded-command-run value) ed state)]
    [(insert-command? value)
     (cond
       [(not vid) (flash state "insert: no focused editor view")]
       [(not (editor-focused? state)) (flash state "insert: focus is not editor")]
       [else (editor-insert! ed state vid (insert-command-text value))])]
    [(delete-command? value)
     (cond
       [(not vid) (flash state "delete: no focused editor view")]
       [(not (editor-focused? state)) (flash state "delete: focus is not editor")]
       [else (editor-delete! ed state vid (delete-command-kind value))])]
    [(move-command? value)
     (if vid
         (editor-move! ed state vid
                       (move-command-dir value)
                       (move-command-extend? value))
         (flash state "move: no focused editor view"))]
    [(scroll-command? value)
     (if vid
         (editor-scroll! ed state vid (scroll-command-which value))
         (flash state "scroll: no focused editor view"))]
    [(undo-command? value)
     (cond
       [(or (not vid) (not (editor-focused? state)))
        (flash state "undo: focus is not editor")]
       [else (editor-undo! ed state vid)])]
    [(redo-command? value)
     (cond
       [(or (not vid) (not (editor-focused? state)))
        (flash state "redo: focus is not editor")]
       [else (editor-redo! ed state vid)])]
    [(kill-line-command? value)
     (cond
       [(or (not vid) (not (editor-focused? state)))
        (flash state "kill-line: focus is not editor")]
       [else (editor-kill-line! ed state vid)])]
    [(save-command? value)
     (editor-save-command ed state)]
    [(quit-command? value)
     (editor-request-quit ed state)]
    [else
     (values (editor-state-with-flash state (format "not a command: ~a" value))
             '())]))

;;; ════════════════ 键盘 step ════════════════

(define (lookup-command tables seq ed state)
  (let loop ([ts tables])
    (cond
      [(null? ts) (values 'unbound #f)]
      [else
       (define-values (status value) (command-table-lookup (car ts) seq))
       (case status
         [(command)
          (cond
            [(and (guarded-command? value)
                  (not ((guarded-command-when-fn value) ed state)))
             (loop (cdr ts))]
            [else (values 'command value)])]
         [(prefix) (values 'prefix #f)]
         [else (loop (cdr ts))])])))

(define (step ed state tok tables)
  (define s0 (editor-state-clear-flash state))
  (define pending (editor-state-pending s0))
  (define seq (append pending (list tok)))
  (let-values ([(status value) (lookup-command tables seq ed s0)])
    (case status
      [(command)
       (run-command ed (editor-state-clear-pending s0) (need-view s0) value)]
      [(prefix)
       (values (editor-state-with-pending s0 seq) '())]
      [else
       (define s1 (editor-state-clear-pending s0))
       (define text (key-text tok))
       (define vid (need-view s1))
       (cond
         [(and text (null? pending) (editor-input-active? s1))
          (editor-input-self-insert s1 tok)]
         [(and text (null? pending) vid (editor-focused? s1))
          (editor-insert! ed s1 vid text)]
         [(and text (null? pending) (not vid))
          (values (editor-state-with-flash s1 "insert: no focused editor view") '())]
         [(and text (null? pending) (not (editor-focused? s1)))
          (values (editor-state-with-flash s1 "insert: focus is not editor") '())]
         [else
          (values (editor-state-with-flash
                   s1
                   (format "unbound: ~a"
                           (string-join (map key->string seq) " ")))
                  '())])])))

;;; ════════════════ 渲染 ════════════════

(define (status-line state engine)
  (define vid (editor-focus-view-id state))
  (define line (add1 (or (and vid (engine-view-point-line engine vid)) 0)))
  (define col (add1 (or (and vid (engine-view-point-column engine vid)) 0)))
  (define panes (length (or (editor-visible-editor-panels state) '())))
  (define r (editor-state-resource-for-view state vid))
  (define name
    (if r (or (resource-path r) (resource-name r)) "scratch.rkt"))
  (define dirty?
    (and r (resource-dirty? r (engine-doc-version engine (resource-doc-id r)))))
  (define pending (editor-state-pending state))
  (define pending-text
    (and (pair? pending)
         (format " [~a]" (string-join (map key->string pending) " "))))
  (define placement (and (editor-placement-active? state) "placement"))
  (define flash (editor-state-flash state))
  (string-join
   (filter values
           (list name
                 (and dirty? "*")
                 (format "~a:~a" line col)
                 (format "panes:~a" panes)
                 "pair+indent"
                 placement
                 pending-text
                 (and (positive? (string-length flash)) flash)))
   "  "))

(define (sync-status! state engine)
  (define text (status-line state engine))
  (engine-set-view-content! engine status-vid (list text) (list 'status-bar))
  (engine-set-view-cursor! engine status-vid 0 #:column 0)
  state)

(define (render-frame ed state cache)
  (define area (editor-state-area state))
  (define rows (rect-h area))
  (define cols (rect-w area))
  (define panels (or (editor-layout-panels ed state) '()))
  ;; 顺序：panel 尺寸 -> status 内容 -> 插件 sync -> 渲染。
  ;; status 是 host 投影，先写好，避免派生插件在下一帧才发现它的 version 变了。
  (panels-sync! panels)
  (void (sync-status! state (editor-engine ed)))
  (void (editor-input-sync! ed state))
  (define state* (run-plugin-syncs ed state))
  (define focus-view (editor-focus-view ed state*))
  (define-values (cache* rows* sels*)
    (render-display-patch panels focus-view cols rows cache))
  (define out
    (bytes-append (if cache (bytes) (render-clear))
                  (render-pieces (append rows* sels*))))
  (values state* cache* out))

;;; ════════════════ TUI 入口 ════════════════

(define (read-app-event)
  (let loop ()
    (define-values (type data mods) (tui:read-event/raw))
    (define e (tui-event->app type data mods))
    (if e e (loop))))

(define (editor-command-tables ed)
  ;; 插件表按安装顺序先查；guarded-command 不成立时继续 host 默认表。
  (append (plugins->command-tables (editor-plugins ed))
          (list default-command-table)))

;; 单事件处理；返回 state'。host 循环和 headless 测试共用这一条路径。
(define (handle-editor-event ed state0 ev)
  ;; 输入栏是抢占式的：非 key / paste 事件先取消本次输入，再处理事件。
  (define state1
    (if (and (editor-input-active? state0)
             (not (key-event? ev))
             (not (paste-event? ev)))
        (editor-input-close state0)
        state0))
  (define state
    (if (mouse-event? ev)
        state1
        (struct-copy editor-state state1 [select-drag #f])))
  (define command-tables (editor-command-tables ed))
  (cond
    [(resize-event? ev)
     (struct-copy editor-state state
                  [area (rect 0 0 (resize-event-cols ev)
                              (resize-event-rows ev))])]
    [(paste-event? ev)
     (cond
       [(editor-input-active? state)
        (define-values (s2 actions) (editor-input-paste! state (paste-event-bytes ev)))
        (run-actions ed s2 actions)]
       [else
     (define vid (editor-focus-view-id state))
     (cond
       [(not vid) (editor-state-with-flash state "paste: no focused editor view")]
       [(not (editor-focused? state))
        (editor-state-with-flash state "paste: focus is not editor")]
       [else
        (define-values (s2 actions)
          (editor-paste! ed state vid (paste-event-bytes ev)))
        (run-actions ed s2 actions)])])]
    [(mouse-event? ev)
     (cond
       [(editor-placement-active? state)
        (define-values (s2 actions2 handled?)
          (editor-placement-mouse! ed state
                                   (mouse-event-row ev)
                                   (mouse-event-col ev)))
        (cond
          [handled? (run-actions ed s2 actions2)]
          [else
           (define-values (s3 actions3)
             (editor-mouse! ed state
                            (mouse-event-token ev)
                            (mouse-event-row ev)
                            (mouse-event-col ev)))
           (run-actions ed s3 actions3)])]
       [else
        (define-values (s2 actions)
          (editor-mouse! ed state
                         (mouse-event-token ev)
                         (mouse-event-row ev)
                         (mouse-event-col ev)))
        (run-actions ed s2 actions)])]
    [(quit-event? ev)
     (struct-copy editor-state state [quit? #t])]
    [(key-event? ev)
     (define tables
       (cond
         [(editor-input-active? state) (list editor-input-command-table)]
         [(editor-placement-active? state) (list placement-command-table)]
         [else command-tables]))
     (define-values (s2 actions)
       (step ed state (key-event-token ev) tables))
     (run-actions ed s2 actions)]
    [else state]))

(define (run-editor ed state #:write-bytes [write-bytes (λ (b) (void))])
  (let loop ([s state] [cache #f])
    (define-values (s1 cache* bytes)
      (render-frame ed s cache))
    (unless (zero? (bytes-length bytes))
      (write-bytes bytes))
    (define ev (read-app-event))
    (define s2 (handle-editor-event ed s1 ev))
    (if (editor-state-quit? s2)
        s2
        (loop s2 (if (resize-event? ev) #f cache*)))))

;;; ════════════════ 终端入口 ════════════════

(define (run-demo-editor)
  (define-values (ed state) (make-demo-editor))
  (tui:with-tui
   (lambda ()
     (tui:cursor-hide)
     (tui:enable-mouse!)
     (tui:enable-bracketed-paste!)
     (define-values (rows cols) (tui:get-window-size))
     (define area
       (if (and rows cols (positive? rows) (positive? cols))
           (rect 0 0 cols rows)
           (rect 0 0 80 24)))
     (run-editor ed
                 (struct-copy editor-state state [area area])
                 #:write-bytes (λ (b) (tui:put-bytes b) (tui:flush!))))))

(module+ main
  (void (run-demo-editor)))
