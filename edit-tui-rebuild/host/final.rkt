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
         "event.rkt"
         "keymap.rkt"
         "../../edit-tui/render/core.rkt"
         "../../edit-tui/config/theme/default.rkt")

(provide run-editor
         make-demo-editor
         run-demo-editor
         render-frame
         sync-status!)

;;; ════════════════ 初始文档 ════════════════

(define editor-vid 1)
(define status-vid 2)

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
  ;; 从文档开头启动；避免 viewport 还没 sync 时把 top-line 锚在末尾。
  (engine-set-view-cursor! engine editor-vid 0 #:column 0)

  (define plugins (list pair-plugin
                        indent-plugin
                        racket-color-plugin
                        layout-plugin))
  (define registry (make-hook-registry (plugins->hooks plugins)))
  (define ed (make-editor #:engine engine
                          #:registry registry
                          #:plugins plugins))

  (define layout (make-editor-layout #:editor-view editor-vid
                                     #:status-view status-vid))
  (define state
    (make-editor-state #:plugin-states (plugins->states plugins)
                       #:area (rect 0 0 80 24)
                       #:layout layout
                       #:next-view-id 10
                       #:next-panel-id 100))
  (values ed state))

;;; ════════════════ action 解释 ════════════════

(define (run-actions state actions)
  (for/fold ([s state]) ([a (in-list actions)])
    (cond
      [(quit-action? a) (struct-copy editor-state s [quit? #t])]
      [(flash-action? a) (editor-state-with-flash s (flash-action-message a))]
      [else s])))

;;; ════════════════ 命令 ════════════════

(define (need-view state)
  (editor-focus-view-id state))

(define (flash state text)
  (values (editor-state-with-flash state text) '()))

(define (run-command ed state vid value)
  (cond
    ;; 插件 commands 是普通过程：(ed state -> values state actions)
    [(procedure? value) (value ed state)]
    [(insert-command? value)
     (if vid
         (editor-insert! ed state vid (insert-command-text value))
         (flash state "insert: no focused editor view"))]
    [(delete-command? value)
     (if vid
         (editor-delete! ed state vid (delete-command-kind value))
         (flash state "delete: no focused editor view"))]
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
     (if vid (editor-undo! ed state vid) (flash state "undo: no focused editor view"))]
    [(redo-command? value)
     (if vid (editor-redo! ed state vid) (flash state "redo: no focused editor view"))]
    [(kill-line-command? value)
     (if vid
         (editor-kill-line! ed state vid)
         (flash state "kill-line: no focused editor view"))]
    [(quit-command? value)
     (values state (list (quit-action)))]
    [else
     (values (editor-state-with-flash state (format "not a command: ~a" value))
             '())]))

;;; ════════════════ 键盘 step ════════════════

(define (step ed state tok table)
  (define s0 (editor-state-clear-flash state))
  (define pending (editor-state-pending s0))
  (define seq (append pending (list tok)))
  (let-values ([(status value) (command-table-lookup table seq)])
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
         [(and text (null? pending) vid)
          (editor-insert! ed s1 vid text)]
         [(and text (null? pending) (not vid))
          (values (editor-state-with-flash s1 "insert: no focused editor view") '())]
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
  (define pending (editor-state-pending state))
  (define pending-text
    (and (pair? pending)
         (format " [~a]" (string-join (map key->string pending) " "))))
  (define flash (editor-state-flash state))
  (string-join
   (filter values
           (list "scratch.rkt"
                 (format "~a:~a" line col)
                 (format "panes:~a" panes)
                 "pair+indent"
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

(define (run-editor ed state #:write-bytes [write-bytes (λ (b) (void))])
  ;; 插件命令优先于 host 默认表。
  (define command-table
    (command-table-merge (plugins->command-table (editor-plugins ed))
                         default-command-table))
  (let loop ([s state] [cache #f])
    (define-values (s1 cache* bytes)
      (render-frame ed s cache))
    (unless (zero? (bytes-length bytes))
      (write-bytes bytes))
    (define ev (read-app-event))
    (cond
      [(resize-event? ev)
       (define area (rect 0 0 (resize-event-cols ev) (resize-event-rows ev)))
       (loop (struct-copy editor-state s1 [area area]) #f)]
      [(paste-event? ev)
       (define vid (editor-focus-view-id s1))
       (cond
         [vid
          (define-values (s2 actions)
            (editor-paste! ed s1 vid (paste-event-bytes ev)))
          (loop (run-actions s2 actions) cache*)]
         [else (loop (editor-state-with-flash s1 "paste: no focused editor view") cache*)])]
      [(mouse-event? ev)
       (define-values (s2 actions)
         (editor-mouse! ed s1
                        (mouse-event-token ev)
                        (mouse-event-row ev)
                        (mouse-event-col ev)))
       (loop (run-actions s2 actions) cache*)]
      [(quit-event? ev)
       (struct-copy editor-state s1 [quit? #t])]
      [(key-event? ev)
       (define-values (s2 actions)
         (step ed s1 (key-event-token ev) command-table))
       (define s3 (run-actions s2 actions))
       (if (editor-state-quit? s3)
           s3
           (loop s3 cache*))]
      [else (loop s1 cache*)])))

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
