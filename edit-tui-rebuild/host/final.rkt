#lang racket

;;; edit-tui-rebuild/host/final.rkt —— TUI 装配 + 事件循环
;;;
;;; 这里负责：
;;;   · 创建 engine / 初始 buffer / 初始 layout
;;;   · 装配 plugins / hook registry / contribution registry
;;;   · 渲染循环、job / timer runtime、action 解释
;;;
;;; 键盘查找 / pending / command dispatch 在 host/input/；这里只调用 dispatch-key。

(require racket/string
         racket/async-channel
         (prefix-in tui: tui)
         "../editor/host-api.rkt"
         (only-in "../core/command/api.rkt" key->string)
         "../plugins/pair/plugin.rkt"
         "../plugins/indent/plugin.rkt"
         "../plugins/racket-color/plugin.rkt"
         "../plugins/layout/plugin.rkt"
         "../plugins/filetree/plugin.rkt"
         "../plugins/resources/plugin.rkt"
         "../plugins/completion/plugin.rkt"
         "../plugins/docs/plugin.rkt"
         "event.rkt"
         "keymap.rkt"
         "layout.rkt"
         "timers.rkt"
         "open.rkt"
         "close.rkt"
         "docs.rkt"
         "filetree-io.rkt"
         "input/dispatch.rkt"
         "../features/input/api.rkt"
         "../features/placement/api.rkt"
         "../features/mouse/api.rkt"
         "jobs.rkt"
         (only-in "../../core/editor.rkt" make-panel)
         "../../edit-tui/render/core.rkt"
         "../../edit-tui/config/theme/default.rkt")

(provide run-editor
         make-demo-editor
         run-demo-editor
         render-frame
         sync-status!
         handle-editor-event
         handle-job-result)

;;; ════════════════ 初始文档 ════════════════

(define editor-vid 1)
(define status-vid 2)
(define filetree-vid 3)
(define resources-vid 4)
(define input-vid 5)
(define completion-vid 6)
(define docs-vid 7)

;; host 装配知道具体 view id：把 panel/view 映射到命令 scope。
(define view-scopes
  (hash filetree-vid 'filetree
        resources-vid 'resources
        docs-vid 'docs))

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
  (void (engine-create-buffer! engine completion-vid "*completion*" ""))
  (void (engine-create-view! engine completion-vid completion-vid))
  (void (engine-create-buffer! engine docs-vid "*docs*" ""))
  (void (engine-create-view! engine docs-vid docs-vid))
  ;; 从文档开头启动；避免 viewport 还没 sync 时把 top-line 锚在末尾。
  (engine-set-view-cursor! engine editor-vid 0 #:column 0)

  (define workspace-root (resource-normalize-path (current-directory)))
  (define plugins (list pair-plugin
                        indent-plugin
                        (make-filetree-plugin
                         #:view filetree-vid
                         #:root workspace-root)
                        (make-resources-plugin #:view resources-vid)
                        racket-color-plugin
                        layout-plugin
                        (make-completion-plugin #:view completion-vid)
                        (make-docs-plugin #:view docs-vid #:panel-id 'docs)))
  (define registry (make-hook-registry (plugins->hooks plugins)))
  (define ed (make-editor #:engine engine
                          #:registry registry
                          #:plugins plugins))

  (define layout (make-editor-layout #:editor-view editor-vid
                                     #:status-views (list status-vid input-vid)
                                     #:sidebar-views (list filetree-vid resources-vid)
                                     #:docs-view docs-vid))
  ;; 初始 scratch resource：没有 path，但 mode 按 "scratch.rkt" 选 Racket。
  (define scratch-mode (doc-mode-for "scratch.rkt" initial-text))
  (define scratch
    (make-resource editor-vid editor-vid #f "scratch.rkt"
                   (list editor-vid) scratch-mode
                   (engine-doc-version engine editor-vid)
                   #:command-stack (mode-command-stack scratch-mode)))
  (define state
    (make-app-state #:plugin-states (plugins->states plugins)
                       #:workspace-root workspace-root
                       #:area (rect 0 0 80 24)
                       #:layout layout
                       #:layout-config rebuild-layout-config
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
      [(quit-action? a) (state-with-quit s #t)]
      [(flash-action? a) (state-with-flash s (flash-action-message a))]
      [(open-file-action? a)
       (define-values (s* more)
         (editor-open-file! ed s (open-file-action-path a)))
       (if (null? more) s* (run-actions ed s* more))]
      [(close-buffer-action? a)
       (define-values (s* more) (editor-close-buffer-command ed s))
       (if (null? more) s* (run-actions ed s* more))]
      [(show-docs-action? a)
       (define-values (s* more) (editor-show-docs! ed s (show-docs-action-name a)))
       (if (null? more) s* (run-actions ed s* more))]
      [(filetree-create-action? a)
       (define-values (s* more)
         (open-filetree-create-prompt! s
                                       (filetree-create-action-parent a)
                                       (filetree-create-action-kind a)))
       (if (null? more) s* (run-actions ed s* more))]
      [(filetree-delete-action? a)
       (define-values (s* more)
         (open-filetree-delete-prompt! s
                                       (filetree-delete-action-path a)
                                       (filetree-delete-action-kind a)))
       (if (null? more) s* (run-actions ed s* more))]
      [(filetree-rename-action? a)
       (define-values (s* more)
         (open-filetree-rename-prompt! s (filetree-rename-action-path a)))
       (if (null? more) s* (run-actions ed s* more))]
      [else s])))

;;; ════════════════ 命令 ════════════════

(define (editor-focused? state)
  (eq? (editor-focus-panel-kind state) 'editor))

;;; ════════════════ 渲染 ════════════════

(define (status-line state engine)
  (define vid (editor-focus-view-id state))
  (define line (add1 (or (and vid (engine-view-point-line engine vid)) 0)))
  (define col (add1 (or (and vid (engine-view-point-column engine vid)) 0)))
  (define panes (length (or (editor-visible-editor-panels state) '())))
  (define r (state-resource-for-view state vid))
  (define name
    (if r (or (resource-path r) (resource-name r)) "scratch.rkt"))
  (define dirty?
    (and r (resource-dirty? r (engine-doc-version engine (resource-doc-id r)))))
  (define pending (state-pending state))
  (define pending-text
    (and (pair? pending)
         (format " [~a]" (string-join (map key->string pending) " "))))
  (define placement (and (editor-placement-active? state) "placement"))
  (define flash (state-flash state))
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
  (define area (state-area state))
  (define rows (rect-h area))
  (define cols (rect-w area))
  (define panels (or (editor-layout-panels ed state) '()))
  ;; 顺序：panel 尺寸 -> status 内容 -> 插件 sync -> 渲染。
  ;; status 是 host 投影，先写好，避免派生插件在下一帧才发现它的 version 变了。
  (panels-sync! panels)
  (void (sync-status! state (editor-engine ed)))
  (void (editor-input-sync! ed state))
  (define state* (run-plugin-syncs ed state))
  (define engine (editor-engine ed))
  (define overlay-panels
    (for/list ([ov (in-list (run-plugin-overlays ed state*))])
      (make-panel (engine-view-object engine (editor-overlay-view-id ov))
                  (editor-overlay-rect ov)
                  (editor-overlay-borders ov)
                  #:face (editor-overlay-face ov)
                  #:weight (editor-overlay-weight ov)
                  #:deep (editor-overlay-deep ov))))
  (unless (null? overlay-panels)
    (panels-sync! overlay-panels))
  (define all-panels (append panels overlay-panels))
  (define focus-view (editor-focus-view ed state*))
  (define-values (cache* rows* sels*)
    (render-display-patch all-panels focus-view cols rows cache))
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
        (state-with-select-drag state1 #f)))
  (cond
    [(resize-event? ev)
     (state-with-area
      state (rect 0 0 (resize-event-cols ev) (resize-event-rows ev)))]
    [(paste-event? ev)
     (cond
       [(editor-input-active? state)
        (define-values (s2 actions) (editor-input-paste! state (paste-event-bytes ev)))
        (run-actions ed s2 actions)]
       [else
     (define vid (editor-focus-view-id state))
     (cond
       [(not vid) (state-with-flash state "paste: no focused editor view")]
       [(not (editor-focused? state))
        (state-with-flash state "paste: focus is not editor")]
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
     (state-with-quit state #t)]
    [(key-event? ev)
     (define-values (s2 actions)
       (dispatch-key ed state (key-event-token ev) view-scopes))
     (run-actions ed s2 actions)]
    [else state]))

(define (handle-job-result ed state ev)
  (define id (job-result-event-id ev))
  (define s1 (state-finish-job state id (job-result-event-result ev)))
  (define-values (s2 actions) (run-plugin-job-handlers ed s1 ev))
  (define s3 (run-actions ed s2 actions))
  (state-forget-job s3 id))

(define (run-editor ed state
                    #:read-event [read-event read-app-event]
                    #:write-bytes [write-bytes (λ (b) (void))]
                    #:job-runtime [job-runtime #f])
  (let loop ([s state] [cache #f])
    (when job-runtime
      (dispatch-jobs! job-runtime (state-jobs s)))
    (define-values (s1 cache* bytes)
      (render-frame ed s cache))
    (unless (zero? (bytes-length bytes))
      (write-bytes bytes))
    (when job-runtime
      (dispatch-jobs! job-runtime (state-jobs s1)))
    (define ev (read-event))
    (cond
      [(job-result-event? ev)
       (loop (handle-job-result ed s1 ev) cache*)]
      [(timer-event? ev)
       (define-values (s2 actions) (run-plugin-timer-handlers ed s1 ev))
       (loop (run-actions ed s2 actions) cache*)]
      [else
       (define s2 (handle-editor-event ed s1 ev))
       (if (state-quit? s2)
           s2
           (loop s2 (if (resize-event? ev) #f cache*)))])))

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
     (define event-channel (make-async-channel))
     (define input-thread
       (thread (λ ()
                 (let loop ()
                   (async-channel-put event-channel (read-app-event))
                   (loop)))))
     (define runtime
       (start-job-runtime (editor-services ed)
                          #:event-channel event-channel
                          #:workers 2))
     (define timer-runtime
       (start-timer-runtime #:event-channel event-channel))
     (editor-set-timer-service! ed (timer-runtime-service timer-runtime))
     (dynamic-wind
      void
      (λ ()
        (run-editor ed
                    (state-with-async (state-with-area state area) #t)
                    #:read-event (λ () (async-channel-get event-channel))
                    #:write-bytes (λ (b) (tui:put-bytes b) (tui:flush!))
                    #:job-runtime runtime))
      (λ ()
        (kill-thread input-thread)
        (stop-job-runtime runtime)
        (stop-timer-runtime timer-runtime))))))

(module+ main
  (void (run-demo-editor)))
