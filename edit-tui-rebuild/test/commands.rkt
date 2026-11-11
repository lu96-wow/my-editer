#lang racket

;;; 插件 commands 贡献：
;;;   · 插件提供 command-table
;;;   · host 合并后 lookup 到普通过程
;;;   · 普通过程只通过 editor/api.rkt 操作 editor

(require rackunit
         racket/string
         "../editor/host-api.rkt"
         "../core/command/api.rkt"
         "../host/final.rkt"
         "../host/layout.rkt")

;;; 1. layout 插件贡献 split / focus / close 命令
(define-values (ed state) (make-demo-editor))
(define plugin-table (plugins->command-table (editor-plugins ed)))

(define-values (status split-cmd)
  (command-table-lookup plugin-table (list (key 'w 'ctrl) (key 'right))))
(check-eq? status 'command)
(check-true (procedure? split-cmd))

(define-values (s-split _a1) (split-cmd ed state))
(check-equal? (length (editor-visible-editor-panels s-split)) 2)

;;; 2. 自定义插件命令：C-t 插入 "!"
(define engine (make-engine))
(void (engine-create-buffer! engine 1 "test" ""))
(void (engine-create-view! engine 1 1))
(void (engine-create-buffer! engine 2 "*status*" ""))
(void (engine-create-view! engine 2 2))

(define insert-bang-command
  (λ (ed state)
    (editor-insert! ed state (editor-focus-view-id state) "!")))

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

(define custom-table (plugins->command-table (editor-plugins custom-ed)))
(define-values (status2 cmd2)
  (command-table-lookup custom-table (list (key 't 'ctrl))))
(check-eq? status2 'command)
(define-values (custom-state* _a2) (cmd2 custom-ed custom-state))
(check-equal? (engine-view-text engine 1) "!")

(displayln "edit-tui-rebuild/test/commands.rkt: ok")
