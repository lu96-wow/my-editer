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
         "../host/final.rkt"
         "../host/layout.rkt")

;;; 1. layout 插件贡献 split 命令；C-w Right 走 host 事件路径。
(define-values (ed state) (make-demo-editor))
(define s1 (handle-editor-event ed state (key-event (key 'w 'ctrl))))
(check-equal? (editor-state-pending s1) (list (key 'w 'ctrl)))
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
  (make-editor-state #:plugin-states (plugins->states (list custom-plugin))
                     #:area (rect 0 0 40 10)
                     #:layout custom-layout))

;; registry -> table 的 leaf 带 owner。
(define-values (status entries)
  (command-table-lookup (editor-command-table custom-ed 'global)
                        (list (key 't 'ctrl))))
(check-eq? status 'command)
(check-equal? (map car entries) '(custom-command))

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
  (make-editor-state #:plugin-states (plugins->states (list blocked-plugin fallback-plugin))
                     #:area (rect 0 0 40 10)
                     #:layout (make-editor-layout #:editor-view 1)))
(define fallback-state*
  (handle-editor-event fallback-ed fallback-state (key-event (key 't 'ctrl))))
(check-equal? (engine-view-text engine2 1) "Y")

(displayln "edit-tui-rebuild/test/commands.rkt: ok")
