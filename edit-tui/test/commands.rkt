#lang racket

;;; 插件 commands 贡献：
;;;   · 插件 command-table 被拆成 command contribution
;;;   · host 从 registry 建 key -> ordered (owner . command) 表
;;;   · 命令只拿自己的 plugin-state，通过 editor/api.rkt 操作 editor

(require rackunit
         racket/string
         "../editor/host-api.rkt"
         "../core/command/api.rkt"
         "../host/event.rkt"
         "../edit.rkt"
         "fixture.rkt"
         "../app/layout.rkt")

;;; 1. layout 插件贡献 split 命令；C-w Right 走 host 事件路径。
(define-values (ed state) (make-test-editor))
(define s1 (handle-editor-event ed state (key-event (key 'w 'ctrl))))
(check-equal? (state-pending s1) (list (key 'w 'ctrl)))
(define s-split (handle-editor-event ed s1 (key-event (key 'right))))
(check-equal? (length (editor-visible-editor-panels s-split)) 2)

;;; 2. 自定义插件命令：C-t 插入 "!"
(define engine (make-engine))
(void (engine-create-buffer! engine 1 "test" ""))
(void (engine-create-view! engine 1 1))
(void (engine-create-buffer! engine 2 "*status*" ""))
(void (engine-create-view! engine 2 2))

(define insert-bang-command
  (λ (ed state ps)
    (define-values (state* actions)
      (editor-insert! ed state (editor-focus-view-id state) "!"))
    (values state* ps actions)))

(define custom-plugin
  (make-plugin
   #:id 'custom-command
   #:state #t
   #:commands (keys [(key 't 'ctrl) insert-bang-command])))

(define custom-ed
  (make-editor #:engine engine
               #:registry (make-hook-registry '())
               #:plugins (list custom-plugin)))
(define custom-layout (make-editor-layout #:editor-view 1 #:status-view 2))
(define custom-state
  (make-app-state #:plugin-states (plugins->states (list custom-plugin))
                     #:area (rect 0 0 40 10)
                     #:layout custom-layout))

;; registry -> table 的 leaf 带 owner。
(define-values (status entries)
  (command-table-lookup (editor-command-table custom-ed 'global)
                        (list (key 't 'ctrl))))
(check-eq? status 'command)
(check-equal? (map car entries) '(custom-command))
;; 插件命令在 contribution 表里是显式的 plugin-command，不是裸 procedure。
(check-true (plugin-command? (cdr (car entries))))

(define custom-state*
  (handle-editor-event custom-ed custom-state (key-event (key 't 'ctrl))))
(check-equal? (engine-view-text engine 1) "!")

;;; 3. 同一个 key 有多条命令时，guard 不成立会落到下一条 owner。
(define engine2 (make-engine))
(void (engine-create-buffer! engine2 1 "test" ""))
(void (engine-create-view! engine2 1 1))
(define (insert-command text)
  (λ (ed state ps)
    (define-values (state* actions)
      (editor-insert! ed state (editor-focus-view-id state) text))
    (values state* ps actions)))
(define blocked-plugin
  (make-plugin
   #:id 'blocked
   #:state #t
   #:commands (keys [(key 't 'ctrl)
                     (make-guarded-command
                      #:when (λ (ed state ps) #f)
                      #:run (insert-command "X"))])))
(define fallback-plugin
  (make-plugin
   #:id 'fallback
   #:state #t
   #:commands (keys [(key 't 'ctrl) (insert-command "Y")])))
(define fallback-ed
  (make-editor #:engine engine2
               #:registry (make-hook-registry '())
               #:plugins (list blocked-plugin fallback-plugin)))
(define fallback-state
  (make-app-state #:plugin-states (plugins->states (list blocked-plugin fallback-plugin))
                     #:area (rect 0 0 40 10)
                     #:layout (make-editor-layout #:editor-view 1)))
(define fallback-state*
  (handle-editor-event fallback-ed fallback-state (key-event (key 't 'ctrl))))
(check-equal? (engine-view-text engine2 1) "Y")


;;; 4. 同一物理 C-f，在 editor / filetree scope 下是不同含义。
;;;    editor: C-f = 右移；filetree: C-f 是局部前缀。
(define engine3 (make-engine))
(void (engine-create-buffer! engine3 1 "editor" "abc"))
(void (engine-create-view! engine3 1 1))
(void (engine-create-buffer! engine3 3 "*filetree*" ""))
(void (engine-create-view! engine3 3 3))
(define (mark-command text)
  (λ (ed state ps)
    (values (state-with-flash state text) ps '())))
(define scoped-plugin
  (make-plugin
   #:id 'filetree-scope-test
   #:state #t
   #:command-scope 'filetree
   #:commands (keys
               [(key 'f 'ctrl) (key 'd) (mark-command "ft-delete")]
               [(key 'f 'ctrl) (key 'n) (mark-command "ft-new")]
               [(key 'f 'ctrl) (key 'f 'ctrl) (key 'n)
                (mark-command "ft-new-dir")])))
(define scoped-ed
  (make-editor #:engine engine3
               #:registry (make-hook-registry '())
               #:plugins (list scoped-plugin)))
(define scoped-layout
  (make-editor-layout #:editor-view 1 #:sidebar-view 3))
(define scoped-state
  (make-app-state #:plugin-states (plugins->states (list scoped-plugin))
                  #:area (rect 0 0 50 12)
                  #:layout scoped-layout
                  #:view-scopes (hash 3 'filetree)))

;; editor 聚焦：C-f 仍然右移。
(engine-set-view-cursor! engine3 1 0 #:column 0)
(define s-editor-cf
  (handle-editor-event scoped-ed scoped-state (key-event (key 'f 'ctrl))))
(check-equal? (engine-view-point-column engine3 1) 1)
(check-equal? (state-pending s-editor-cf) '())

;; filetree 聚焦：C-f 进入局部前缀；C-f d 执行 filetree 命令。
(define-values (s-side _a-side) (editor-focus! scoped-ed scoped-state 'left))
(check-equal? (editor-focus-view-id s-side) 3)
(define s-ft-cf
  (handle-editor-event scoped-ed s-side (key-event (key 'f 'ctrl))))
(check-equal? (state-pending s-ft-cf) (list (key 'f 'ctrl)))
(define s-ft-d
  (handle-editor-event scoped-ed s-ft-cf (key-event (key 'd))))
(check-equal? (state-flash s-ft-d) "ft-delete")
(check-equal? (state-pending s-ft-d) '())

;; C-f C-f n 是更深一层前缀。
(define s-ft-cf2
  (handle-editor-event scoped-ed s-side (key-event (key 'f 'ctrl))))
(define s-ft-cf3
  (handle-editor-event scoped-ed s-ft-cf2 (key-event (key 'f 'ctrl))))
(check-equal? (state-pending s-ft-cf3)
              (list (key 'f 'ctrl) (key 'f 'ctrl)))
(define s-ft-dir
  (handle-editor-event scoped-ed s-ft-cf3 (key-event (key 'n))))
(check-equal? (state-flash s-ft-dir) "ft-new-dir")

;; pending 绑定 scope：C-f 后切回 editor，n 不应命中 filetree 的 C-f n。
(define-values (s-back _a-back) (editor-focus! scoped-ed s-ft-cf2 'right))
(check-equal? (editor-focus-view-id s-back) 1)
(define s-back-n
  (handle-editor-event scoped-ed s-back (key-event (key 'n))))
(check-equal? (state-pending s-back-n) '())
(check-not-equal? (state-flash s-back-n) "ft-new")

;;; 5. C-w d 关闭当前 editor panel；最后一个只清空 views，保留 slot。
(define-values (panel-ed panel-state) (make-test-editor))
(define panel-cw
  (handle-editor-event panel-ed panel-state (key-event (key 'w 'ctrl))))
(define panel-closed
  (handle-editor-event panel-ed panel-cw (key-event (key 'd))))
(check-equal? (length (editor-visible-editor-panels panel-closed)) 1)
(check-false (editor-focus-view-id panel-closed))
(check-not-false (engine-view-object (editor-engine panel-ed) 1))

(displayln "edit-tui/test/commands.rkt: ok")
